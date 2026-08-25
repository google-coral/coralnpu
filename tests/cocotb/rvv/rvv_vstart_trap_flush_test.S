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
 * Directed test to verify vstart preservation across pipeline trap/flush:
 * When an in-flight vector instruction is shadowed and flushed by a preceding
 * exception (e.g. LSU load access fault), architectural vstart is preserved
 * in the trap handler rather than speculatively cleared.
 */

.section .data
.align 16

.global input_a
input_a:
    .word 10, 20, 30, 40

.global input_b
input_b:
    .word 1, 2, 3, 4

.global test_results_trap
test_results_trap:
    .word 0xDEAD, 0xDEAD, 0xDEAD, 0

.section .text
.global main
.option norelax

trap_handler:
    // Entry 0 in trap handler: nop
    nop

    // Entry 1 in trap handler: read vstart and store to test_results_trap
    csrr t6, vstart
    csrw vstart, zero
    vmv.s.x v8, t6
    vse32.v v8, (t4)

    // Advance mepc past faulting lw (4 bytes) and shadowed vadd (4 bytes)
    csrr t0, mepc
    addi t0, t0, 8
    csrw mepc, t0
    mret

main:
    // Set mtvec to trap_handler
    la t0, trap_handler
    csrw mtvec, t0

    la t4, test_results_trap

    vsetivli x0, 4, e32, m1, ta, ma
    la t1, input_a
    la t2, input_b
    vle32.v v9, (t1)
    vle32.v v10, (t2)
    vmv.v.i v8, 0

    li t0, 5
    csrw vstart, t0

    // Preceding instruction at tag 0: causes load access fault in LSU
    li a5, 0xA0000000
    lw a4, 0(a5)

    // Shadowed instruction: vadd.vv is flushed by preceding lw fault
    vadd.vv v8, v9, v10

after_trap:
    li t5, 0x800
    csrs mie, t5
    wfi
    ret
