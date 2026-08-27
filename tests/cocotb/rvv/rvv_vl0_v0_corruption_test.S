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
 * Verifies that executing a vector instruction (such as vmsbc.vvm) when vl = 0:
 * 1. Preserves undisturbed vector registers (specifically mask register v0).
 * 2. Leaves the destination register (v29) unmodified.
 * 3. Advances normally through the pipeline and ROB without trapping or deadlocking.
 */

.section .data
.align 16

.global v0_init
.global op_data_a
.global op_data_b
.global output_v0_after_vmsbc
.global output_v29_after_vmsbc

v0_init:
    // 0xf0b0e6759579717a4fc03532a0a512b6 in little-endian:
    .word 0xa0a512b6, 0x4fc03532, 0x9579717a, 0xf0b0e675

op_data_a:
    .word 0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00

op_data_b:
    .word 0x01020304, 0x05060708, 0x090a0b0c, 0x0d0e0f10

output_v0_after_vmsbc:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

output_v29_after_vmsbc:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

.section .text
.global main
.option norelax

main:
    // 1. Pre-load v0 with known non-zero pattern (VLEN=128, SEW=32, LMUL=1)
    vsetivli x0, 4, e32, m1, ta, ma
    la t0, v0_init
    vle32.v v0, (t0)

    // Pre-load operands into v23, v5, v29
    la t1, op_data_a
    la t2, op_data_b
    vle32.v v23, (t1)
    vle32.v v5, (t2)
    vle32.v v29, (t1)

    // Wait for vector memory loads
    .rept 20
    nop
    .endr

    // 2. Set vl = 0: vsetivli t1, 0, e8, mf4, tu, mu (0xc0607357)
    .word 0xc0607357

    .rept 10
    nop
    .endr

    // 3. 0x40740: vmsbc.vvm v29, v23, v5, v0 (0x4d728ed7)
    .word 0x4d728ed7

    // Wait for vmsbc to commit in ROB
    .rept 30
    nop
    .endr

    // Read out v0 and v29
    vsetivli x0, 4, e32, m1, ta, ma
    la t3, output_v0_after_vmsbc
    vse32.v v0, (t3)
    la t4, output_v29_after_vmsbc
    vse32.v v29, (t4)

    .rept 30
    nop
    .endr

    li t5, 0x800
    csrs mie, t5
    wfi
    ret
