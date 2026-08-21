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
 * Tests RVV instruction retirement and ROB tag tracking in tight loops where
 * back-to-back iterations execute vector arithmetic (vadd.vv) at identical PCs.
 * Verifies that instructions are retired based on rob_tag rather than PC matching
 * to prevent premature retirement and data corruption.
 */

.section .data
.align 16

.global input_data
input_data:
    .word 1, 2, 3, 4

.global output_data
output_data:
    .word 0, 0, 0, 0

.section .text
.global main
.option norelax

main:
    la t3, input_data
    la t4, output_data

    vsetivli x0, 4, e32, m1, ta, ma
    vle32.v v8, (t3)
    vle32.v v9, (t3)

    li t0, 32
1:
    vadd.vv v8, v8, v9
    addi t0, t0, -1
    bnez t0, 1b

    vse32.v v8, (t4)

    li t5, 0x800
    csrs mie, t5
    wfi
    ret
