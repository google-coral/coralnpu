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
 * Directed test to verify vstart reset for vector instruction writing scalar
 * register (vmv.x.s): non-zero vstart is reset to zero upon in-order
 * architectural retirement.
 */

.section .data
.align 16

.global input_a
input_a:
    .word 10, 20, 30, 40

.global test_results_vmv_scalar
test_results_vmv_scalar:
    .word 0xDEAD, 0xDEAD, 0xDEAD, 0

.section .text
.global main
.option norelax

main:
    la t4, test_results_vmv_scalar
    vsetivli x0, 4, e32, m1, ta, ma
    la t1, input_a
    vle32.v v8, (t1)

    li t0, 3
    csrw vstart, t0
    vmv.x.s a0, v8
    .rept 50
    nop
    .endr
    csrr t1, vstart
    sw t1, 0(t4)

    li t5, 0x800
    csrs mie, t5
    wfi
    ret
