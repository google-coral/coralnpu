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
 */
    .section .text
    .balign 4
    .global _start
_start:
    # Test MIE Register
    li t0, -1
    csrw mie, t0
    csrr a0, mie
    li t1, 0x10000
    sw a0, 0(t1) # Store mie value to address 0x10000 (DTCM). Expect 0x888.
    wfi
