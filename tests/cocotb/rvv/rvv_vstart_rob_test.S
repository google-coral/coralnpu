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
 * Directed test to verify vstart CSR management via the RetirementBuffer:
 * Normal execution: non-zero vstart is used by a vector arithmetic instruction
 * (leaving earlier destination elements undisturbed) and is automatically reset
 * to zero upon in-order architectural retirement.
 */

.section .data
.align 16

.global input_a
input_a:
    .word 10, 20, 30, 40

.global input_b
input_b:
    .word 1, 2, 3, 4

.global output_normal
output_normal:
    .word 0, 0, 0, 0

.global test_results_normal
test_results_normal:
    .word 0xDEAD, 0xDEAD, 0xDEAD, 0

.section .text
.global main
.option norelax

main:
    la t4, test_results_normal

    // ---------------------------------------------------------
    // Test 1: Normal vector instruction retirement resets vstart
    // ---------------------------------------------------------
    vsetivli x0, 4, e32, m1, ta, ma
    la t1, input_a
    la t2, input_b
    vle32.v v9, (t1)
    vle32.v v10, (t2)
    vmv.v.i v8, 0

    li t0, 2
    csrw vstart, t0
    vadd.vv v8, v9, v10

    // Wait for vector execution to complete and retire in ROB
    .rept 50
    nop
    .endr

    // Read vstart after vadd.vv retires
    csrr t1, vstart
    vmv.s.x v11, t1
    vse32.v v11, (t4)    // test_results_normal[0] = vstart after normal retire

    la t3, output_normal
    vse32.v v8, (t3)

    // Wait for vse32.v to complete
    .rept 50
    nop
    .endr

    li t5, 0x800
    csrs mie, t5
    wfi
    ret
