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

.section .data
.align 16

.global trap_record
trap_record:
    // 3 entries, each 16 bytes:
    // +0: mcause
    // +4: mepc
    // +8: mtval
    // +12: saved ra
    .space 48

.global total_traps
total_traps:
    .word 0

.global resume_target
resume_target:
    .word 0

.global test_failed_flag
test_failed_flag:
    .word 0

.section .text
.global main
.global coralnpu_exception_handler
.global jump_jal
.global fault_jal
.global jump_jalr
.global fault_jalr
.global branch_inst
.global fault_branch
.global jump_fallthrough
.global target_fallthrough
.global test_done

.option norelax

coralnpu_exception_handler:
    mv t1, ra

    la t6, total_traps
    lw t5, 0(t6)

    li t4, 3
    bge t5, t4, handler_overflow

    slli t4, t5, 4
    la t3, trap_record
    add t3, t3, t4

    csrr a1, mcause
    csrr a2, mepc
    csrr a3, mtval

    sw a1, 0(t3)
    sw a2, 4(t3)
    sw a3, 8(t3)
    sw t1, 12(t3)

    addi t5, t5, 1
    sw t5, 0(t6)

    la t2, resume_target
    lw a4, 0(t2)
    csrw mepc, a4
    mret

handler_overflow:
    la t0, test_failed_flag
    li t1, 1
    sw t1, 0(t0)
    la a4, test_done
    csrw mepc, a4
    mret

main:
    // -------------------------------------------------------------
    // Test 1: JAL directly to an illegal instruction.
    // The JAL must retire cleanly (trap=0, ra=jump_jal+4),
    // and fault_jal must retire as a trap (mepc=fault_jal).
    // -------------------------------------------------------------
    la a0, resume_jal
    la a5, resume_target
    sw a0, 0(a5)

jump_jal:
    jal ra, fault_jal
    j test_fail

fault_jal:
    .word 0x0000007b

resume_jal:

    // -------------------------------------------------------------
    // Test 2: JALR directly to an illegal instruction.
    // The JALR must retire cleanly (trap=0, ra=jump_jalr+4),
    // and fault_jalr must retire as a trap (mepc=fault_jalr).
    // -------------------------------------------------------------
    la a0, resume_jalr
    la a5, resume_target
    sw a0, 0(a5)
    la t0, fault_jalr

jump_jalr:
    jalr ra, 0(t0)
    j test_fail

fault_jalr:
    .word 0x0000007b

resume_jalr:

    // -------------------------------------------------------------
    // Test 3: Taken branch (BNE) directly to an illegal instruction.
    // The branch must retire cleanly (trap=0),
    // and fault_branch must retire as a trap (mepc=fault_branch).
    // -------------------------------------------------------------
    la a0, resume_branch
    la a5, resume_target
    sw a0, 0(a5)
    li t0, 1

branch_inst:
    bne t0, zero, fault_branch
    j test_fail

fault_branch:
    .word 0x0000007b

resume_branch:

    // -------------------------------------------------------------
    // Test 4: JAL jumping OVER an illegal instruction.
    // In a 4-wide fetch window, the illegal instruction is fetched
    // alongside or after the jump, but should NOT cause a trap.
    // -------------------------------------------------------------
    la a0, test_fail
    la a5, resume_target
    sw a0, 0(a5)

jump_fallthrough:
    jal ra, target_fallthrough
    .word 0x0000007b

target_fallthrough:
    j test_done

test_fail:
    la t0, test_failed_flag
    li t1, 1
    sw t1, 0(t0)
    la t0, tohost
    li t1, 3
    sw t1, 0(t0)
    wfi

test_done:
    la t0, test_failed_flag
    lw t1, 0(t0)
    bnez t1, test_fail
    la t0, tohost
    li t1, 1
    sw t1, 0(t0)
    wfi

.pushsection .tohost, "aw", @progbits
.balign 64
.global tohost
tohost:
    .dword 0
.global fromhost
fromhost:
    .dword 0
.popsection
