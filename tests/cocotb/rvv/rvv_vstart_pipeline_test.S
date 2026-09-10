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
 * Directed test to verify vstart reset across in-flight vector instructions:
 * 1. In-flight vector multiply followed by scalar instruction and vector move:
 *    vmulhu.vv (with vstart=1) followed by a scalar instruction and vmv.v.x.
 *    vmv.v.x must execute with vstart=0 (writing all elements, including element 0).
 * 2. Back-to-back vector arithmetic:
 *    vadd.vv (vstart=2) immediately followed by vadd.vv.
 *    The second vadd.vv must execute with vstart=0 (computing all elements from 0).
 * 3. Dual-dispatch in same cycle:
 *    vadd.vv + vadd.vv co-dispatched in same cycle.
 *    First vadd.vv executes with vstart=2, second with vstart=0.
 */

.section .data
.align 16

.global input_a
input_a:
    .word 10, 20, 30, 40

.global input_b
input_b:
    .word 1, 2, 3, 4

.global output_reopen
output_reopen:
    .word 0, 0, 0, 0

.global output_b2b_0
output_b2b_0:
    .word 0, 0, 0, 0

.global output_b2b_1
output_b2b_1:
    .word 0, 0, 0, 0

.global output_dual_0
output_dual_0:
    .word 0, 0, 0, 0

.global output_dual_1
output_dual_1:
    .word 0, 0, 0, 0

.section .text
.global main
.option norelax

main:
    // Configure vectors: 4 elements, e32, m1
    vsetivli x0, 4, e32, m1, ta, ma
    la a1, input_a
    la a2, input_b
    vle32.v v14, (a1)
    vle32.v v10, (a2)

    // Unmask all elements in v0
    li t0, -1
    vmv.s.x v0, t0

    // ---------------------------------------------------------
    // Test 1: In-flight vector multiply followed by vmv.v.x
    // csrrwi zero, vstart, 1
    // vmulhu.vv v12, v14, v10, v0.t
    // addi t1, zero, 42
    // vmv.v.x v3, t3
    // ---------------------------------------------------------
    li t0, 0xAAAAAAAA
    vmv.v.x v12, t0
    li t0, 0x55555555
    vmv.v.x v3, t0

    // Set vstart = 1
    csrrwi zero, vstart, 1

    // Vector multiply high with vstart = 1 (element 0 untouched)
    vmulhu.vv v12, v14, v10, v0.t
    addi t1, zero, 42
    li t3, 0x33333333
    vmv.v.x v3, t3

    // Store results
    la t4, output_reopen
    vse32.v v3, (t4)

    // ---------------------------------------------------------
    // Test 2: Back-to-back vector arithmetic (no delay)
    // ---------------------------------------------------------
    vmv.v.i v8, 0
    vmv.v.i v11, 0

    li t0, 2
    csrw vstart, t0

    vadd.vv v8, v14, v10
    vadd.vv v11, v14, v10

    la t4, output_b2b_0
    vse32.v v8, (t4)
    la t4, output_b2b_1
    vse32.v v11, (t4)

    // ---------------------------------------------------------
    // Test 3: Dual-dispatch in same cycle
    // ---------------------------------------------------------
    vmv.v.i v8, 0
    vmv.v.i v11, 0

    li t0, 2
    csrw vstart, t0

    .p2align 3
    vadd.vv v8, v14, v10
    vadd.vv v11, v14, v10

    la t4, output_dual_0
    vse32.v v8, (t4)
    la t4, output_dual_1
    vse32.v v11, (t4)

    // Drain pipeline
    .rept 50
    nop
    .endr

    li t5, 0x800
    csrs mie, t5
    wfi
    ret
