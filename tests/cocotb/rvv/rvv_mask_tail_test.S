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
 * Verifies RVV mask-register logical and mask-set instructions for both
 * partial-length (vl < VLEN, has_mask_tail = 1) and full-length (vl = VLEN,
 * has_mask_tail = 0) configurations.
 */

.section .data
.align 16

.global v1_init
.global v2_init
.global v1_result
.global v2_result
.global v3_result
.global v5_result
.global v6_result

v1_init:
    .word 0x00000000, 0x00000000, 0x00000000, 0x00000000

v2_init:
    .word 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF

v1_result:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

v2_result:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

v3_result:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

v5_result:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

v6_result:
    .word 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF

.section .text
.global main
.option norelax

main:
    // 1. Initialize v1 and v2 to 0 in VRF, and v3 and v4 to all 1s.
    vsetivli x0, 4, e32, m1, ta, ma
    la t0, v1_init
    vle32.v v1, (t0)
    vle32.v v2, (t0)
    la t0, v2_init
    vle32.v v3, (t0)
    vle32.v v4, (t0)

    // 2. Set vl = 1 (has_mask_tail = 1) and execute:
    //    - vmnot.m v1, v1: bit 0 becomes 1; tail bits 1..127 remain 0.
    //    - vmv1r.v v2, v4 followed by vmxor.mm v2, v1, v1: bit 0 becomes 0;
    //      tail bits 1..127 preserve the all-1s value from vmv1r.v.
    //    - vmsbf.m v3, v1: bit 0 becomes 0; tail bits 1..127 remain 1.
    vsetivli x0, 1, e8, m1, ta, ma
    vmnot.m v1, v1
    vmv1r.v v2, v4
    vmxor.mm v2, v1, v1
    vmsbf.m v3, v1

    // 3. Set vl = 128 (has_mask_tail = 0) and execute:
    //    - vmv1r.v v5, v4 followed by vmxor.mm v5, v4, v4: all 128 bits become 0.
    //    - vmv1r.v v6, v4 followed by vmsbf.m v6, v1: bit 0 of v1 is 1, so all
    //      128 bits of v6 become 0.
    vsetvli t0, x0, e8, m8, ta, ma
    vmv1r.v v5, v4
    vmxor.mm v5, v4, v4
    vmv1r.v v6, v4
    vmsbf.m v6, v1

    // 4. Store all 128 bits of v1, v2, v3, v5, and v6.
    vsetivli x0, 4, e32, m1, ta, ma
    la t1, v1_result
    vse32.v v1, (t1)
    la t1, v2_result
    vse32.v v2, (t1)
    la t1, v3_result
    vse32.v v3, (t1)
    la t1, v5_result
    vse32.v v5, (t1)
    la t1, v6_result
    vse32.v v6, (t1)

    li a0, 0
    ret
