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
 * Directed test to recreate/verify OPFVF instructions with scalar float register frs1:
 * vfrdiv.vf v18, v18, f1, v0.t
 */

.section .data
.align 16

.global v18_init
v18_init:
    .word 0xfebca84a, 0xdd6762d4, 0x6a56839a, 0x3cad5c3c

.global v0_init
v0_init:
    .word 0x0000000d, 0x00000000, 0x00000000, 0x00000000

.global frs1_val
frs1_val:
    .word 0x80000000

.global f4_val
f4_val:
    .word 0x40000000

.global v18_result
v18_result:
    .space 16

.section .text
.global main
.option norelax

main:
    la a0, v18_init
    la a1, v0_init
    la a2, frs1_val
    la a3, v18_result
    la a4, f4_val

    // Load initial vector registers
    vsetvli x24, x0, e32, m1, tu, mu
    vle32.v v18, (a0)
    vle32.v v0, (a1)
    flw f4, (a4)
    flw f1, (a2)
    fdiv.s f3, f4, f4
    vfrdiv.vf v18, v18, f1, v0.t

    // Store result
    vse32.v v18, (a3)

    .rept 50
    nop
    .endr

    li t5, 0x800
    csrs mie, t5
    wfi
    ret
