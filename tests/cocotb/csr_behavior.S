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
 * CSR Behavior Test
 *
 * Checks behavior of various CSRs to ensure compliance/correctness.
 * - MIE: Checks that only supported bits (MEIE, MTIE, MSIE -> 0x888) are writable.
 * - MTVAL: Checks that ECALL and EBREAK traps clear mtval to 0.
 */
    .section .text
    .balign 4
    .global _start
_start:
    # 1. Test MIE Register
    li t0, -1
    csrw mie, t0
    csrr a0, mie
    li t1, 0x10000
    sw a0, 0(t1) # Store mie value to address 0x10000 (DTCM). Expect 0x888.

    # 2. Test ECALL clears mtval to 0
    la t0, ecall_handler
    csrw mtvec, t0
    li t0, 0xdeadbeef
    csrw mtval, t0
    ecall
    wfi

    .balign 4
ecall_handler:
    csrr a1, mtval
    sw a1, 4(t1) # Store post-ecall mtval to address 0x10004 (DTCM). Expect 0.
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

    .balign 4
    .global ebreak_test
ebreak_test:
    li t0, 0xdeadbeef
    csrw mtval, t0
    ebreak
