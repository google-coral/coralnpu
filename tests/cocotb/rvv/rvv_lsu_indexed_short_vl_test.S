/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Reproduction for bug with short vl under fractional LMUL:
 * When an indexed vector load/store is executed with a short vector length
 * (e.g. SEW=32 with vl <= 2, or SEW=16 with vl <= 2), dynamic LMUL reduction
 * in RvvFrontEnd reduces LMUL to LMUL1_2 (mf2) or LMUL1_4 (mf4).
 * On unpatched RTL, Lsu.scala countActiveVectorCells is missing fractional LMUL
 * entries for E32 and E16, returning activeCellCount = 0.
 * The LSU skips the indexed operation without handshaking with RVV, leaving a uop
 * in RVV's u_lsu_rs FIFO.
 * When a subsequent vector store executes, the LSU pops the stale uop and asserts:
 * assert(!acceptVectorData.get || !write || isVmeInst || vectorData.get.bits.vregfile.valid)
 */

.section .data
.align 16

.global src_data
.global idx_data_32
.global idx_data_16
.global out_data_indexed_e32_vl2
.global out_data_indexed_e32_vl1
.global out_data_indexed_e16_vl2
.global store_data
.global out_data_store
.global out_data_indexed_store

src_data:
    .word 0x11111111, 0x22222222, 0x33333333, 0x44444444

idx_data_32:
    .word 8, 4, 0, 12

idx_data_16:
    .half 4, 2, 0, 6

out_data_indexed_e32_vl2:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

out_data_indexed_e32_vl1:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

out_data_indexed_e16_vl2:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

store_data:
    .byte 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
    .byte 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00

out_data_store:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

out_data_indexed_store:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

.section .text
.global main
.option norelax

main:
    // =========================================================================
    // Test Case 1: SEW=32, vl=2 -> dynamic reduction to LMUL1_2 (mf2)
    // =========================================================================
    // Load 32-bit indices into v12
    vsetivli t0, 4, e32, m1, ta, ma
    la t2, idx_data_32
    vle32.v v12, (t2)

    // Execute indexed load with short vl=2 (sew=e32, m1).
    // Dynamic LMUL reduction in RvvFrontEnd reduces LMUL to mf2 ("b111").
    // With idx_data_32 = [8, 4, ...]:
    // v4[0] = src_data[8 bytes offset] = 0x33333333
    // v4[1] = src_data[4 bytes offset] = 0x22222222
    vsetivli t0, 2, e32, m1, ta, ma
    la t1, src_data
    vluxei32.v v4, (t1), v12

    .rept 10
    nop
    .endr

    // Vector strided store (vsse8.v as in KELVIN-64).
    // On unpatched RTL, this store triggers the assertion failure:
    // assert(!acceptVectorData.get || !write || isVmeInst || vectorData.get.bits.vregfile.valid)
    vsetivli t0, 4, e8, m1, ta, ma
    la t3, store_data
    vle8.v v10, (t3)
    la t4, out_data_store
    li s2, 1
    vsse8.v v10, (t4), s2

    // Store indexed load output
    vsetivli t0, 2, e32, m1, ta, ma
    la t5, out_data_indexed_e32_vl2
    vse32.v v4, (t5)

    // =========================================================================
    // Test Case 2: SEW=32, vl=1 -> dynamic reduction to LMUL1_4 (mf4)
    // =========================================================================
    vsetivli t0, 1, e32, m1, ta, ma
    la t1, src_data
    vluxei32.v v5, (t1), v12

    .rept 10
    nop
    .endr

    vsetivli t0, 1, e32, m1, ta, ma
    la t5, out_data_indexed_e32_vl1
    vse32.v v5, (t5)

    // =========================================================================
    // Test Case 3: SEW=16, vl=2 -> dynamic reduction to LMUL1_4 (mf4)
    // =========================================================================
    vsetivli t0, 4, e16, m1, ta, ma
    la t2, idx_data_16
    vle16.v v14, (t2)

    vsetivli t0, 2, e16, m1, ta, ma
    la t1, src_data
    vluxei16.v v6, (t1), v14

    .rept 10
    nop
    .endr

    vsetivli t0, 2, e16, m1, ta, ma
    la t5, out_data_indexed_e16_vl2
    vse16.v v6, (t5)

    // =========================================================================
    // Test Case 4: Indexed store vsuxei32.v with vl=2 (mf2)
    // =========================================================================
    vsetivli t0, 2, e32, m1, ta, ma
    la t6, out_data_indexed_store
    vsuxei32.v v4, (t6), v12

    .rept 30
    nop
    .endr

    li t6, 0x800
    csrs mie, t6
    wfi
    ret
