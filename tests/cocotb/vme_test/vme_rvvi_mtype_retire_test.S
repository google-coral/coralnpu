# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Directed test for per-ROB-slot RVVI mtype CSR (0xC23) retirement tracking
# under overlapping Zvt matrix configuration instructions.
#
# Specification references (RISC-V Zvt v0.4):
# - Section 12.1.1.2 ("Matrix Type (mtype) CSR"): mtype (CSR 0xC23) holds
#   tm[13:0] in bits [23:10], tk[2:0] in bits [7:5], and mtwiden[1:0] in
#   bits [1:0].
# - Section 12.1.1.4 ("Matrix Configuration Instructions"): msetmtype,
#   msetmtypei, msettm, and msettk update mtype; vector configuration
#   instructions (vsetvli, vsetivli, vsetvl) clear mtype to zero.
#
# Microarchitectural hazard under test:
# When multiple mset* instructions execute back-to-back (for example, msettm
# followed immediately by msettk, or back-to-back msetmtypei instructions),
# RvvFrontEnd updates its architectural mtype_q register as each instruction
# issues, while both instructions can retire in the same RetirementBuffer
# window. Each retiring instruction must report its own post-execution mtype
# value on RVVI csr_wb[0xC23] rather than sampling the younger instruction's
# live mtype_q state.

.section .text
.balign 4
.global _start
.type _start, @function
_start:
    # Zero .bss.
.option push
.option norelax
    la   x1, __bss_start__
    la   x2, __bss_end__
.option pop
    andi x3, x2, -4
    bgeu x1, x3, 2f
1:
    sw   x0, 0(x1)
    addi x1, x1, 4
    bltu x1, x3, 1b
2:
    bgeu x1, x2, 4f
3:
    sb   x0, 0(x1)
    addi x1, x1, 1
    bltu x1, x2, 3b
4:

    # Architectural GPR normalization
    li   x1, 0
    li   x2, 0
    li   x3, 0
    li   x4, 0
    li   x5, 0
    li   x6, 0
    li   x7, 0
    li   x8, 0
    li   x9, 0
    li   x10, 0
    li   x11, 0
    li   x12, 0
    li   x13, 0
    li   x14, 0
    li   x15, 0
    li   x16, 0
    li   x17, 0
    li   x18, 0
    li   x19, 0
    li   x20, 0
    li   x21, 0
    li   x22, 0
    li   x23, 0
    li   x24, 0
    li   x25, 0
    li   x26, 0
    li   x27, 0
    li   x28, 0
    li   x29, 0
    li   x30, 0
    li   x31, 0

    # Enable FPU (FS=01) and Vector (VS=01) in mstatus
    li   x1, 0x00002200
    csrs mstatus, x1

    # FPR normalization
    fmv.w.x f0, x0
    fmv.w.x f1, x0
    fmv.w.x f2, x0
    fmv.w.x f3, x0
    fmv.w.x f4, x0
    fmv.w.x f5, x0
    fmv.w.x f6, x0
    fmv.w.x f7, x0
    fmv.w.x f8, x0
    fmv.w.x f9, x0
    fmv.w.x f10, x0
    fmv.w.x f11, x0
    fmv.w.x f12, x0
    fmv.w.x f13, x0
    fmv.w.x f14, x0
    fmv.w.x f15, x0
    fmv.w.x f16, x0
    fmv.w.x f17, x0
    fmv.w.x f18, x0
    fmv.w.x f19, x0
    fmv.w.x f20, x0
    fmv.w.x f21, x0
    fmv.w.x f22, x0
    fmv.w.x f23, x0
    fmv.w.x f24, x0
    fmv.w.x f25, x0
    fmv.w.x f26, x0
    fmv.w.x f27, x0
    fmv.w.x f28, x0
    fmv.w.x f29, x0
    fmv.w.x f30, x0
    fmv.w.x f31, x0
    csrw fcsr, x0

    # Vector register normalization (zero v0..v31 with m8)
    vsetvli  x1, x0, e32, m8, tu, mu
    vmv.v.i  v0, 0
    vmv.v.i  v8, 0
    vmv.v.i  v16, 0
    vmv.v.i  v24, 0
    csrw     vstart, x0
    csrw     vxrm, x0
    csrw     vxsat, x0
    vsetvli  x1, x0, e32, m1, tu, mu

    # Matrix tile normalization (zero all 4 TEW32 tiles mt0, mt4, mt8, mt12)
    .word 0x8940f057  # msetmtypei sew=32, mtwiden=1
    li       x1, 16
    .insn r 0b1010111, 0b111, 0b1000100, x0, x1, x0  # msettn tn=16
    .insn r 0b1010111, 0b111, 0b1000100, x0, x1, x1  # msettm tm=16
    .word 0x43e06057  # vtzero mt0
    .word 0x43e06457  # vtzero mt4
    .word 0x43e06857  # vtzero mt8
    .word 0x43e06c57  # vtzero mt12
    vsetivli x0, 4, e32, m1, tu, mu  # close matrix epoch
    li       x1, 0

.option push
.option norelax
    la   x17, scratch_buf
.option pop

    # =========================================================================
    # Case 1: Overlapping msettm and msettk retiring in the same ROB window
    # (Zvt v0.4 Section 12.1.1.2 & Section 12.1.1.4).
    #
    # 1. msetmtypei sew=8, mtwiden=3 -> mtype = 0x00000003
    # 2. msettn tn=16                -> vl = 16
    # 3. msettm tm=16                -> mtype = (16 << 10) | 3 = 0x00004003
    # 4. msettk tk=4                 -> mtype = (16 << 10) | (4 << 5) | 3 = 0x00004083
    # 5. Back-to-back msettm (tm=8) and msettk (tk=2) with pre-loaded operands:
    #    - msettm x13, x12 retires with mtype = (8 << 10) | (4 << 5) | 3 = 0x00002083
    #    - msettk x15, x14 retires with mtype = (8 << 10) | (2 << 5) | 3 = 0x00002043
    # =========================================================================
    .word 0x8841f057  # zvt: msetmtypei sew=8, mtwiden=3 (mtype = 0x00000003)
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x0  # zvt: msettn x10, x10 (tn=16)
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x1  # zvt: msettm x10, x10 (mtype = 0x00004003)
    addi     x10, x0, 4
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x2  # zvt: msettk x10, x10 (mtype = 0x00004083)

    # Pre-load both operands so msettm and msettk issue and retire in the same window.
    addi     x12, x0, 8
    addi     x14, x0, 2
    .insn r 0b1010111, 0b111, 0b1000100, x13, x12, x1  # zvt: msettm x13, x12 (mtype = 0x00002083)
    .insn r 0b1010111, 0b111, 0b1000100, x15, x14, x2  # zvt: msettk x15, x14 (mtype = 0x00002043)

    # Verify architectural mtype CSR readback == 0x00002043
    csrr     x5, 0xC23
    li       x6, 0x00002043
    bne      x5, x6, test_fail

    # =========================================================================
    # Case 2: Back-to-back msetmtypei, msetmtype, msettk, and msettm
    # transitions interleaved with vector and tile operations.
    # =========================================================================
    .word 0x8841f057  # zvt: msetmtypei sew=8, mtwiden=3 (mtype = 0x00000003)
    .word 0x8940f057  # zvt: msetmtypei sew=32, mtwiden=1 (mtype = 0x00000001)
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x0  # zvt: msettn x10, x10
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x1  # zvt: msettm x10, x10 (mtype = 0x00004001)
    addi     x10, x0, 1
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x2  # zvt: msettk x10, x10 (mtype = 0x00004021)
    .word 0x43e06c57  # zvt: vtzero mt12

    # msetmtype x0, x10, x11 (sew=16, mtwiden=2, tm=1, tk=2 -> mtype = 0x00000442)
    lui      x10, 0x2
    addi     x10, x10, -1982
    addi     x11, x0, 264
    .insn r 0b1010111, 0b111, 0b1000010, x0, x10, x11  # zvt: msetmtype x0, x10, x11
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x0  # zvt: msettn x10, x10
    .word 0x43e06057  # zvt: vtzero mt0
    vsetivli x0, 4, e32, m1, tu, mu                     # clears mtype to 0x00000000

    # Verify vsetivli cleared mtype to 0 per Zvt v0.4 Section 12.1.1.4
    csrr     x5, 0xC23
    bne      x5, x0, test_fail

    # Rapid msettk -> msettk back-to-back update
    .word 0x88c0f057  # zvt: msetmtypei sew=16, mtwiden=1 (mtype = 0x00000001)
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x0  # zvt: msettn x10, x10
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x1  # zvt: msettm x10, x10 (mtype = 0x00004001)
    addi     x10, x0, 1
    addi     x11, x0, 2
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x2  # zvt: msettk x10, x10 (tk=1 -> 0x00004021)
    .insn r 0b1010111, 0b111, 0b1000100, x4, x11, x2   # zvt: msettk x4, x11  (tk=2 -> 0x00004041)

    csrr     x5, 0xC23
    li       x6, 0x00004041
    bne      x5, x6, test_fail

    # Rapid msettm -> msettk -> msettm back-to-back update
    .word 0x8840f057  # zvt: msetmtypei sew=8, mtwiden=1 (mtype = 0x00000001)
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x0  # zvt: msettn x10, x10
    addi     x10, x0, 16
    addi     x11, x0, 1
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x1  # zvt: msettm x10, x10 (tm=16 -> 0x00004001)
    .insn r 0b1010111, 0b111, 0b1000100, x10, x11, x2  # zvt: msettk x10, x11 (tk=1  -> 0x00004021)
    .insn r 0b1010111, 0b111, 0b1000100, x5, x11, x1   # zvt: msettm x5, x11  (tm=1  -> 0x00000421)

    csrr     x5, 0xC23
    li       x6, 0x00000421
    bne      x5, x6, test_fail

    # Close matrix epoch
    vsetivli x0, 4, e32, m1, tu, mu

    # =========================================================================
    # Case 3: Unconfigured msettm and msettk with rd = x0 (mtwiden == 0)
    # must trap as illegal instructions (mcause = 2) on their own PC without
    # retiring early as non-writing instructions or asserting csr_wb[0xC23].
    # =========================================================================
    la       x1, trap_handler_skip_4
    csrw     mtvec, x1
    li       x28, 0
    li       x29, 0

    # 3a: msettm x0, x10 when mtwiden == 0 (should trap at 1f, not retire early)
    li       x10, 16
1:
    .insn r 0b1010111, 0b111, 0b1000100, x0, x10, x1   # zvt: msettm x0, x10 (traps)
    addi     x5, x0, 1
    la       x6, 1b
    bne      x28, x6, test_fail
    li       x6, 2
    bne      x29, x6, test_fail

    # 3b: msettk x0, x10 when mtwiden == 0 (should trap at 2f, not retire early)
    li       x28, 0
    li       x29, 0
    li       x10, 4
2:
    .insn r 0b1010111, 0b111, 0b1000100, x0, x10, x2   # zvt: msettk x0, x10 (traps)
    addi     x5, x0, 2
    la       x6, 2b
    bne      x28, x6, test_fail
    li       x6, 2
    bne      x29, x6, test_fail

    # Test completion: write PASS (1) to tohost and mpause
    li   x1, 1
.option push
.option norelax
    la   x2, tohost
.option pop
    sw   x1, 0(x2)
    .word 0x08000073  # mpause
5:
    j    5b

.balign 4
trap_handler_skip_4:
    csrr x28, mepc
    csrr x29, mcause
    addi x30, x28, 4
    csrw mepc, x30
    mret

test_fail:
    li   x1, 2
.option push
.option norelax
    la   x2, tohost
.option pop
    sw   x1, 0(x2)
    .word 0x08000073  # mpause
6:
    j    6b

.section .htif, "aw", @progbits
.balign 64
.global tohost
tohost:
    .word 0
    .word 0

.section .bss
.balign 64
.global scratch_buf
scratch_buf:
    .zero 2048
