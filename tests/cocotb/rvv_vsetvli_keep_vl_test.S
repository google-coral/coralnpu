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
 * Reproduction test for vsetvli retaining current vector length (vl)
 * when rd == x0 and rs1 == x0.
 *
 * According to RISC-V Vector ISA v1.0 Section 6.2 (Table 8):
 * When rd == x0 and rs1 == x0, the instruction operates as if the current
 * vector length in vl is used as the AVL, and keeps the existing vl (if
 * the new SEW/LMUL ratio does not change VLMAX).
 *
 * If a simulator incorrectly resets vl to VLMAX upon `vsetvli zero, zero, ...`,
 * subsequent vector operations like `vid.v` will overwrite tail elements
 * beyond the preserved vl, causing co-simulation vector mismatches against RTL.
 */

.section .data
.align 16

.global init_pattern
init_pattern:
    .quad 0x5bae85e0cb2c1dac, 0xac951238e94acd49

.section .text
.global main
.option norelax

main:
    # 1. Preload v1 with known pattern where byte 15 (bits [127:120]) is 0xac.
    la t1, init_pattern
    vsetivli x0, 16, e8, m1, ta, ma
    vle8.v v1, (t1)

    # 2. Set AVL=31 with e8, m4, tu (tail undisturbed).
    # With VLEN=128 (16 bytes), LMUL=4 gives VLMAX=64.
    # Since AVL=31 <= VLMAX, vl is set to 31.
    li t0, 31
    vsetvli t0, t0, e8, m4, tu, mu

    # 3. Execute vsetvli with rd=x0, rs1=x0 and identical SEW/LMUL.
    # The specification mandates that vl is preserved at 31.
    vsetvli zero, zero, e8, m4, tu, mu

    # 4. Execute vid.v into v0 (register group v0..v3 for m4).
    # Active elements (vl = 31, indices 0..30, total 31 elements):
    # - v0 holds 16 elements: indices 0..15 (values 0x00..0x0f).
    # - v1 holds 15 elements: indices 16..30 (values 0x10..0x1e in bytes 0..14).
    # Tail elements (indices >= vl, i.e., index >= 31):
    # - Index 31 is the 32nd element (byte 15 / bits [127:120] of v1).
    # - Under tu (tail undisturbed), byte 15 of v1 must remain untouched (0xac).
    # - If a simulator buggy reset vl to VLMAX (64), byte 15 of v1 would be
    #   incorrectly overwritten with element index 31 (0x1f).
    vid.v v0

    # Clean exit
    li a0, 0
    ret
