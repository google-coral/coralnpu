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
 * Tests vector-originated trap (vill) tag matching in loops.
 * In a tight loop with identical instruction PCs across iterations:
 * - Iteration 1 executes a multi-cycle vector division (vdiv.vv) under a valid
 *   configuration (SEW=e32, LMUL=m1).
 * - Iteration 2 configures an illegal vtype (SEW=e64 -> vill=1) and executes
 *   vdiv.vv at the same loop PC, immediately raising an illegal instruction trap.
 * Verifies that the RetirementBuffer uses rob_tag to match the vector trap,
 * ensuring Iteration 1 is not prematurely aborted or discarded, and completes
 * its computation cleanly before the trap is taken.
 */

.section .data
.align 16

.global input_data
input_data:
    .word 100, 200, 300, 400

.global output_data
output_data:
    .word 0, 0, 0, 0

.global trap_info
trap_info:
    .word 0   // mcause
    .word 0   // mepc
    .word 0   // mtval
    .word 0   // trap count

.section .text
.global main
.global coralnpu_exception_handler
.option norelax

coralnpu_exception_handler:
    la t6, trap_info
    csrr a1, mcause
    csrr a2, mepc
    csrr a3, mtval
    sw a1, 0(t6)
    sw a2, 4(t6)
    sw a3, 8(t6)
    lw a4, 12(t6)
    addi a4, a4, 1
    sw a4, 12(t6)
    // Resume at end of test (skip faulting instruction)
    la a2, test_done
    csrw mepc, a2
    mret

main:
    la t3, input_data
    la t4, output_data

    // Initial load: v8 = [100, 200, 300, 400], v9 = [100, 200, 300, 400]
    vsetivli x0, 4, e32, m1, ta, ma
    vle32.v v8, (t3)
    vle32.v v9, (t3)

    // In a loop of 2 iterations:
    // Iteration 1: Valid configuration (e32, m1). Executes vdiv.vv (takes ~15 cycles).
    // Iteration 2: Sets vill=1 (e64). Executes vdiv.vv (same PC) -> immediately traps.
    li t1, 2

loop_start:
    // If t1 == 1, set vill=1 by selecting invalid SEW=e64
    li t2, 1
    beq t1, t2, set_invalid_vtype
    vsetivli x0, 4, e32, m1, ta, ma
    j do_vdiv

set_invalid_vtype:
    // vsetvli x0, x0, e64, m1, ta, ma (SEW=e64 -> 0x0d807057, illegal in Zve32f -> sets vill=1)
    .word 0x0d807057

do_vdiv:
.global loop_vdiv
loop_vdiv:
    vdiv.vv v8, v8, v9

    addi t1, t1, -1
    bnez t1, loop_start

test_done:
    // Restore valid configuration to store result
    vsetivli x0, 4, e32, m1, ta, ma
    vse32.v v8, (t4)

    li t5, 0x800
    csrs mie, t5
    wfi
    ret
