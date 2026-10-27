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
# Directed test verifying that Zvt vtdiscard and de2rt w_valid=0 retirement
# lanes do not emit spurious v0 = 0 writebacks on RVVI when v0 holds non-zero
# data.
#
# Specification references (RISC-V Zvt v0.4):
# - Section 12.1.1.10 ("Context Status - Zvt Context Discard Instruction"):
#   vtdiscard (funct6=010000, vm=1, vs2=11100, rs1=00000, funct3=110,
#   rd=00000, opcode=1010111) sets mstatus.MS to Initial and encodes rd=00000
#   as a fixed instruction field without writing vector register v0.
#
# Microarchitectural hazard under test:
# In rvv_backend_decode.sv, instructions or tail uops discarded at decode time
# (including vtdiscard, tail uops of tile instructions when tn < 16 or tm < 16,
# and vector instructions when vl == 0) retire immediately via de2rt on
# rd_valid_rob2rt_o[5:4] with rd_rob2rt_o[5:4].w_valid = 1'b0 and
# w_index = 5'd0. SCore and RetirementBuffer must gate vector register
# writeback matching and RVVI v_wb assertion on w_valid so that retiring on
# de2rt does not falsely report a write of zero to v0.

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

    # Populate v0 with non-zero pattern (0xffffffff_ffffffff_ffffffff_ffffffff)
    # so any spurious RVVI v_wb[v0] = 0 assertion immediately diverges from
    # MPACT and Spike.
    vsetvli  x1, x0, e32, m1, tu, mu
    vmv.v.i  v0, -1
    vmv.v.i  v8, 3
    vmv.v.i  v12, 5

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
    # Case 1: vtdiscard retirement while v0 holds non-zero data
    # (Zvt v0.4 Section 12.1.1.10).
    #
    # vtdiscard retires via de2rt (rd_rob2rt_o[5:4]) with w_valid=0, w_index=0.
    # =========================================================================
    .word 0x8940f057  # zvt: msetmtypei sew=32, mtwiden=1
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x0  # zvt: msettn x10, x10
    addi     x10, x0, 16
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x1  # zvt: msettm x10, x10
    addi     x10, x0, 1
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x2  # zvt: msettk x10, x10
    .word 0x43c06057  # zvt: vtdiscard
    .word 0x43c06057  # zvt: vtdiscard

    # Re-initialize tiles after vtdiscard so matrix state is well-defined
    .word 0x43e06057  # zvt: vtzero mt0
    .word 0x43e06457  # zvt: vtzero mt4
    .word 0x43e06857  # zvt: vtzero mt8
    .word 0x43e06c57  # zvt: vtzero mt12

    # =========================================================================
    # Case 2: Partial-dimension tile operations (tm < 16 and tn < 16) retiring
    # discarded tail uops via de2rt (rd_rob2rt_o[5:4] with w_valid=0, w_index=0)
    # while v0 holds non-zero data.
    # =========================================================================
    .word 0x8840f057  # zvt: msetmtypei sew=8, mtwiden=1
    addi     x10, x0, 8
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x0  # zvt: msettn x10, x10 (tn=8)
    addi     x10, x0, 8
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x1  # zvt: msettm x10, x10 (tm=8)
    addi     x10, x0, 1
    .insn r 0b1010111, 0b111, 0b1000100, x10, x10, x2  # zvt: msettk x10, x10 (tk=1)

    # Partial-tile vtzero, vtle8, vtse8, vtmv.t.v, and vtmv.v.t (into v4, not v0)
    .word 0x43e06457  # zvt: vtzero mt4 (tm=8 -> tail uops discarded via de2rt)
    lui      x10, 0x40000
    addi     x10, x10, 4
    .insn r 0b0000111, 0b111, 0b0001001, x0, x17, x10   # zvt: vtle8 x10, (x17) (tm=8 -> tail uops via de2rt)
    .insn r 0b0100111, 0b111, 0b0001001, x0, x17, x10   # zvt: vtse8 x10, (x17) (tm=8 -> tail uops via de2rt)
    .insn r 0b1010111, 0b110, 0b0101111, x0, x10, x8    # zvt: vtmv.t.v x10, v8
    .insn r 0b1010111, 0b110, 0b0100001, x4, x10, x31   # zvt: vtmv.v.t v4, x10

    # =========================================================================
    # Case 3: Vector instructions executed with vl == 0 retiring via de2rt
    # (rd_rob2rt_o[5:4] with w_valid=0, w_index=0) while v0 holds non-zero data.
    # =========================================================================
    vsetivli x0, 0, e32, m1, tu, mu
    vadd.vv  v4, v8, v12
    vadd.vv  v0, v8, v12

    # Restore vl = 4 and verify v0 still contains 0xffffffff (-1)
    vsetivli x0, 4, e32, m1, tu, mu
    vmv.x.s  x5, v0
    li       x6, -1
    bne      x5, x6, test_fail

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
