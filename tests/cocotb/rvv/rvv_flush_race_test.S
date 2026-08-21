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
 * Tests scalar-originated trap vs vector pipeline flush race condition.
 * Initiates a long-latency vector division (vdiv.vv), immediately followed by
 * a faulting scalar store (sw to unmapped address) that triggers an exception.
 * In the trap handler, new vector operations (vadd.vv) are dispatched.
 * Verifies that the in-flight divider is successfully flushed upon trap entry
 * and does not write back afterwards to corrupt post-trap instructions or VRF state.
 */

.section .data
.align 16

.global input_div_a
input_div_a:
    .word 1000, 2000, 3000, 4000

.global input_div_b
input_div_b:
    .word 2, 2, 2, 2

.global input_add_a
input_add_a:
    .word 10, 20, 30, 40

.global input_add_b
input_add_b:
    .word 1, 2, 3, 4

.global output_data
output_data:
    .word 0, 0, 0, 0

.section .text
.global main
.option norelax

trap_handler:
    // Entry 0 in trap handler (tag 0):
    nop

    // Entry 1 in trap handler (tag 1):
    // vadd.vv is dispatched at tag 1, writing to v8.
    // Expected: input_add_a + input_add_b = [11, 22, 33, 44]
    vadd.vv v8, v10, v11
    vse32.v v8, (t4)

    // Advance mepc past the faulting lw (4 bytes)
    csrr t0, mepc
    addi t0, t0, 8   // skip faulting lw AND shadowed vdiv
    csrw mepc, t0
    mret

main:
    // Set mtvec to trap_handler
    la t0, trap_handler
    csrw mtvec, t0

    vsetivli x0, 4, e32, m1, ta, ma
    la t1, input_div_a
    la t2, input_div_b
    vle32.v v8, (t1)
    vle32.v v9, (t2)

    la t1, input_add_a
    la t2, input_add_b
    vle32.v v10, (t1)
    vle32.v v11, (t2)

    la t4, output_data

    // Preceding instruction at tag 0: causes load access fault in LSU (takes ~2 cycles)
    li a5, 0xA0000000
    lw a4, 0(a5)

    // Shadowed instruction at tag 1: vdiv.vv dispatched at tag 1 while lw is in LSU
    vdiv.vv v8, v8, v9

after_trap:
    li t5, 0x800
    csrs mie, t5
    wfi
    ret
