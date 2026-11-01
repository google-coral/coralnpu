// Copyright 2026 Antmicro
//
// Single source of truth for the per-instruction cycle-cost microbenchmark.
//
// Every benchmark is one entry in one of the BENCH_LIST_<GROUP>() X-macro
// lists below:
//
//   X(ID, "display mnemonic", "category", "setup asm", "measured asm", clobbers...)
//
// `isa_cycle_bench.cc` expands the list selected by -DBENCH_GROUP=<GROUP>
// into a body per entry and a dispatch table indexed by list position.
// `isa_cycle_bench_test.py` parses this header directly for the display
// mnemonic and category, so the host table can never drift from the firmware.
//
// The measured asm is repeated BENCH_REPS times inside a `.rept` block that
// is bracketed by two `csrr mcycle` reads. Operands are chained wherever the
// instruction can legally read its own destination, so that those rows report
// back-to-back latency rather than best-case throughput. The instructions
// that cannot do that - loads, stores, splats, scalar/vector moves, mask
// producing compares, the width-changing extends, `vrgather`, `vslideup` and
// control flow - are listed in BENCH_THROUGHPUT_IDS below, and their rows
// report sustained issue rate instead. The two are not comparable, which is
// why the host emits a column saying which one a row is.
//
// Each group is compiled into its own ELF because ITCM is only 8 KiB; keep a
// group at roughly 32 entries or fewer so the image still fits. When adding a
// group here, add it to ISA_CYCLE_BENCH_GROUPS in tests/cocotb/BUILD too.

#ifndef TESTS_COCOTB_ISA_CYCLE_BENCH_DEFS_H_
#define TESTS_COCOTB_ISA_CYCLE_BENCH_DEFS_H_

// Number of back-to-back copies of the measured instruction per benchmark.
#define BENCH_REPS 32

// X() ids whose consecutive instances share no read-after-write dependency,
// because the instruction cannot read the register it writes. Their rows
// report sustained issue rate; every other row reports back-to-back latency.
// FSQRT_S and VFSQRT_V are listed even though they could chain, because
// repeated square roots converge on 1.0 within a handful of steps and the
// iterative unit then reports its fast path rather than a representative
// cost. REM and VREM_VV are listed for the same reason: chained remainders
// shrink towards 0 (see S_INIT_DIV).
// Only read by isa_cycle_bench_test.py, which checks that every id here
// exists. Whitespace separated.
//
// clang-format off
#define BENCH_THROUGHPUT_IDS                                                 \
  "NOP LUI "                                                                 \
  "LW LH LHU LB LBU SW SH SB "                                               \
  "BEQ_T BEQ_NT BNE_T BNE_NT BLT_T BLT_NT BLTU_T BLTU_NT "                   \
  "BGE_T BGE_NT BGEU_T BGEU_NT JAL J JALR CALL_RET CSRR CSRW CSRRWI "        \
  "REM FSQRT_S "                                                             \
  "FEQ_S FLE_S FLT_S FMV_W_X FMV_X_W FCVT_S_W FCVT_W_S FLW FSW "             \
  "VSETIVLI VSETVLI "                                                        \
  "VZEXT_VF2 VSEXT_VF2 VSEXT_VF4 VID_V "                                     \
  "VMSEQ_VV VMSEQ_VX VMSEQ_VI VMSNE_VI VMSLT_VX VMSLTU_VX VMSLEU_VI "        \
  "VMSGTU_VI "                                                               \
  "VMV_V_V VMV_V_X VMV_V_I VMV_S_X VMV_X_S VMV1R_V VMV2R_V VMV4R_V "         \
  "VMV8R_V VFMV_S_F VFMV_F_S VFMV_V_F VRGATHER_VI VSLIDEUP_VI VSLIDEUP_VX "  \
  "VLE8_V VLE16_V VLE32_V VSE8_V VSE16_V VSE32_V "                           \
  "VLSE8_V VLSE16_V VLSE32_V VLUXEI32_V "                                    \
  "VL1RE8_V VL2RE8_V VL4RE8_V VL8RE8_V VS1R_V VS2R_V VS4R_V VS8R_V "         \
  "VMFEQ_VV VMFEQ_VF VMFNE_VV VMFLT_VF VMFLE_VV VMFLE_VF VMFGT_VF VMFGE_VF " \
  "VREM_VV VFSQRT_V"

// ---------------------------------------------------------------------------
// Shared setup fragments.
// ---------------------------------------------------------------------------

// Scalar integer operands.
#define S_INIT       "li t0, 1\n\tli t1, 2\n\t"
#define S_INIT_SHIFT "li t0, 1\n\tli t1, 1\n\t"

// Divide is iterative, so what it costs depends on the operand values, and a
// naively chained `div t0, t0, t1` reaches 0 within a few steps. Instead the
// divisor is chained: t1 = t0 * t0 + 12345 with t0 = 46337, so
// `div t0, t1, t0` keeps producing 46337, a fixed point with a full-width
// dividend and a 16-bit quotient on every repetition.
#define S_INIT_DIV "li t0, 46337\n\tli t1, 2147129914\n\t"

// Scalar memory operand: t3 points at a 16-byte aligned scratch buffer.
#define S_ADDR     "la t3, g_scratch\n\t"
#define S_ADDR_VAL "la t3, g_scratch\n\tli t0, 42\n\t"

// Scalar float operands ft0=1.0, ft1=2.0, ft2=3.0.
#define F_INIT                       \
  "li t0, 1\n\tfcvt.s.w ft0, t0\n\t" \
  "li t0, 2\n\tfcvt.s.w ft1, t0\n\t" \
  "li t0, 3\n\tfcvt.s.w ft2, t0\n\t"

// Re-seeds ft0=7.0 and ft1=3.0 so that `fdiv.s ft0, ft0, ft1` chains through
// quotients 7/3^n that are never exactly representable, instead of the exact
// power-of-two halving that 1.0/2.0 would give.
#define F_INIT_DIV                       \
  F_INIT                                 \
      "li t0, 7\n\tfcvt.s.w ft0, t0\n\t" \
      "li t0, 3\n\tfcvt.s.w ft1, t0\n\t"

// vtype configurations. VLEN is 128, so LMUL=1 holds 16xe8, 8xe16 or 4xe32.
#define VS_E8M1  "vsetivli x0, 16, e8, m1, ta, ma\n\t"
#define VS_E16M1 "vsetivli x0, 8, e16, m1, ta, ma\n\t"
#define VS_E32M1 "vsetivli x0, 4, e32, m1, ta, ma\n\t"

// Integer vector operands. v8/v9/v10 are LMUL=1 sources, v12 feeds the
// widening/extending forms, v0 is an all-ones mask for the .vvm/.vxm/.vim
// merges and v1/v2/v3 are mask-register operands.
#define VI_INIT                                          \
  "vmv.v.i v8, 1\n\tvmv.v.i v9, 2\n\tvmv.v.i v10, 3\n\t" \
  "vmv.v.i v12, 4\n\t"
#define VI_INIT_MASK                         \
  VI_INIT                                    \
      "vmv.v.i v0, -1\n\tvmv.v.i v1, -1\n\t" \
      "vmv.v.i v2, -1\n\tvmv.v.i v3, 1\n\t"

// Integer divide operands, splatted from S_INIT_DIV: v8=46337 and
// v11=46337*46337+12345, so `vdiv.vv v8, v11, v8` is a fixed point.
#define VI_INIT_DIV S_INIT_DIV "vmv.v.x v8, t0\n\tvmv.v.x v11, t1\n\t"

// Float vector operands v8=1.0, v9=2.0, v10=2.0.
#define VF_INIT                                        \
  "li t0, 1\n\tfcvt.s.w ft0, t0\n\t"                   \
  "li t0, 2\n\tfcvt.s.w ft1, t0\n\t"                   \
  "vfmv.v.f v8, ft0\n\tvfmv.v.f v9, ft1\n\tvfmv.v.f v10, ft1\n\t"

// Divide and square root are iterative, so what they cost depends on the
// operand values. This re-seeds v8=7.0 and ft2=v11=3.0 so that both the
// forward and the reverse divide rows chain through quotients that never
// land on an exactly representable value, instead of measuring the fast
// path.
#define VF_INIT_DIV                      \
  VF_INIT                                \
      "li t0, 7\n\tfcvt.s.w ft2, t0\n\t" \
      "vfmv.v.f v8, ft2\n\t"             \
      "li t0, 3\n\tfcvt.s.w ft2, t0\n\t" \
      "vfmv.v.f v11, ft2\n\t"

// Vector memory operand: t3 points at a 16-byte aligned 256-byte buffer,
// which is large enough for a whole-register group transfer (8 x VLEN/8).
#define V_ADDR "la t3, g_vscratch\n\t"

// ---------------------------------------------------------------------------
// Scalar groups.
// ---------------------------------------------------------------------------

#define BENCH_LIST_SCALAR_ALU(X) \
  X(NOP, "nop", "baseline", "", "nop") \
  X(ADD, "add", "RV32I ALU", S_INIT, "add t0, t0, t1", "t0", "t1") \
  X(SUB, "sub", "RV32I ALU", S_INIT, "sub t0, t0, t1", "t0", "t1") \
  X(AND, "and", "RV32I ALU", S_INIT, "and t0, t0, t1", "t0", "t1") \
  X(OR, "or", "RV32I ALU", S_INIT, "or t0, t0, t1", "t0", "t1") \
  X(XOR, "xor", "RV32I ALU", S_INIT, "xor t0, t0, t1", "t0", "t1") \
  X(SLL, "sll", "RV32I ALU", S_INIT_SHIFT, "sll t0, t0, t1", "t0", "t1") \
  X(SRL, "srl", "RV32I ALU", S_INIT_SHIFT, "srl t0, t0, t1", "t0", "t1") \
  X(SRA, "sra", "RV32I ALU", S_INIT_SHIFT, "sra t0, t0, t1", "t0", "t1") \
  X(SLT, "slt", "RV32I ALU", S_INIT, "slt t0, t0, t1", "t0", "t1") \
  X(SLTU, "sltu", "RV32I ALU", S_INIT, "sltu t0, t0, t1", "t0", "t1") \
  X(ADDI, "addi", "RV32I ALU immediate", "li t0, 1\n\t", "addi t0, t0, 1", "t0") \
  X(SLTI, "slti", "RV32I ALU immediate", "li t0, 1\n\t", "slti t0, t0, 5", "t0") \
  X(SLTIU, "sltiu", "RV32I ALU immediate", "li t0, 1\n\t", "sltiu t0, t0, 5", "t0") \
  X(ANDI, "andi", "RV32I ALU immediate", "li t0, 1\n\t", "andi t0, t0, 3", "t0") \
  X(ORI, "ori", "RV32I ALU immediate", "li t0, 1\n\t", "ori t0, t0, 3", "t0") \
  X(XORI, "xori", "RV32I ALU immediate", "li t0, 1\n\t", "xori t0, t0, 3", "t0") \
  X(SLLI, "slli", "RV32I ALU immediate", "li t0, 1\n\t", "slli t0, t0, 1", "t0") \
  X(SRLI, "srli", "RV32I ALU immediate", "li t0, 1\n\t", "srli t0, t0, 1", "t0") \
  X(SRAI, "srai", "RV32I ALU immediate", "li t0, 1\n\t", "srai t0, t0, 1", "t0") \
  X(LUI, "lui", "RV32I ALU immediate", "", "lui t0, 0x12345", "t0")

#define BENCH_LIST_SCALAR_MEM(X) \
  X(LW, "lw", "Load/Store", S_ADDR, "lw t0, 0(t3)", "t0", "t3") \
  X(LH, "lh", "Load/Store", S_ADDR, "lh t0, 0(t3)", "t0", "t3") \
  X(LHU, "lhu", "Load/Store", S_ADDR, "lhu t0, 0(t3)", "t0", "t3") \
  X(LB, "lb", "Load/Store", S_ADDR, "lb t0, 0(t3)", "t0", "t3") \
  X(LBU, "lbu", "Load/Store", S_ADDR, "lbu t0, 0(t3)", "t0", "t3") \
  X(SW, "sw", "Load/Store", S_ADDR_VAL, "sw t0, 0(t3)", "t0", "t3") \
  X(SH, "sh", "Load/Store", S_ADDR_VAL, "sh t0, 0(t3)", "t0", "t3") \
  X(SB, "sb", "Load/Store", S_ADDR_VAL, "sb t0, 0(t3)", "t0", "t3") \
  X(MUL, "mul", "M extension", S_INIT, "mul t0, t0, t1", "t0", "t1") \
  X(MULH, "mulh", "M extension", S_INIT, "mulh t0, t0, t1", "t0", "t1") \
  X(MULHU, "mulhu", "M extension", S_INIT, "mulhu t0, t0, t1", "t0", "t1") \
  X(DIV, "div", "M extension", S_INIT_DIV, "div t0, t1, t0", "t0", "t1") \
  X(DIVU, "divu", "M extension", S_INIT_DIV, "divu t0, t1, t0", "t0", "t1") \
  X(REM, "rem", "M extension", S_INIT_DIV, "rem t2, t1, t0", "t0", "t1", "t2")

// Branches jump to the label immediately behind them, so a "taken" row is the
// cost of a correctly-resolved redirect and a "not taken" row is the
// fall-through cost. The `ret` row uses an assembler-time counter so that
// every `jalr x0, off(t0)` targets the next one without any extra
// instruction in the loop; `ret` is `jalr x0, 0(ra)`, the same encoding with
// a different base register, so this is its cost. The
// `call` round trip suppresses linker relaxation so the row really measures
// the two-instruction `auipc`+`jalr` expansion rather than a relaxed `jal`,
// which already has a row of its own.
#define BENCH_LIST_SCALAR_CTRL(X) \
  X(BEQ_T, "beq (taken)", "Control flow", "", "beq x0, x0, 1f\n\t1:") \
  X(BEQ_NT, "beq (not taken)", "Control flow", S_INIT, "beq t0, t1, 1f\n\t1:", "t0", "t1") \
  X(BNE_T, "bne (taken)", "Control flow", S_INIT, "bne t0, t1, 1f\n\t1:", "t0", "t1") \
  X(BNE_NT, "bne (not taken)", "Control flow", "", "bne x0, x0, 1f\n\t1:") \
  X(BLT_T, "blt (taken)", "Control flow", S_INIT, "blt t0, t1, 1f\n\t1:", "t0", "t1") \
  X(BLT_NT, "blt (not taken)", "Control flow", S_INIT, "blt t1, t0, 1f\n\t1:", "t0", "t1") \
  X(BLTU_T, "bltu (taken)", "Control flow", S_INIT, "bltu t0, t1, 1f\n\t1:", "t0", "t1") \
  X(BLTU_NT, "bltu (not taken)", "Control flow", S_INIT, "bltu t1, t0, 1f\n\t1:", "t0", "t1") \
  X(BGE_T, "bge (taken)", "Control flow", S_INIT, "bge t1, t0, 1f\n\t1:", "t0", "t1") \
  X(BGE_NT, "bge (not taken)", "Control flow", S_INIT, "bge t0, t1, 1f\n\t1:", "t0", "t1") \
  X(BGEU_T, "bgeu (taken)", "Control flow", S_INIT, "bgeu t1, t0, 1f\n\t1:", "t0", "t1") \
  X(BGEU_NT, "bgeu (not taken)", "Control flow", S_INIT, "bgeu t0, t1, 1f\n\t1:", "t0", "t1") \
  X(JAL, "jal", "Control flow", "", "jal t2, 1f\n\t1:", "t2") \
  X(J, "j", "Control flow", "", "j 1f\n\t1:") \
  X(JALR, "ret (jalr)", "Control flow", "la t0, 9f\n\t.set jaloff, 4\n\t", "9: jalr x0, jaloff(t0)\n\t.set jaloff, jaloff+4", "t0") \
  X(CALL_RET, "call + ret (round trip)", "Control flow", "", ".option push\n\t.option norelax\n\t" "call bench_call_target\n\t" ".option pop", "ra") \
  X(CSRR, "csrr", "Zicsr", "", "csrr t0, mcycle", "t0") \
  X(CSRW, "csrw", "Zicsr", "li t0, 1\n\t", "csrw mscratch, t0", "t0") \
  X(CSRRWI, "csrrwi", "Zicsr", "", "csrrwi x0, mscratch, 1")

#define BENCH_LIST_SCALAR_FP(X) \
  X(FADD_S, "fadd.s", "F extension", F_INIT, "fadd.s ft0, ft0, ft1", "t0", "ft0", "ft1", "ft2") \
  X(FSUB_S, "fsub.s", "F extension", F_INIT, "fsub.s ft0, ft0, ft1", "t0", "ft0", "ft1", "ft2") \
  X(FMUL_S, "fmul.s", "F extension", F_INIT, "fmul.s ft0, ft0, ft1", "t0", "ft0", "ft1", "ft2") \
  X(FDIV_S, "fdiv.s", "F extension", F_INIT_DIV, "fdiv.s ft0, ft0, ft1", "t0", "ft0", "ft1", "ft2") \
  X(FSQRT_S, "fsqrt.s", "F extension", F_INIT, "fsqrt.s ft0, ft1", "t0", "ft0", "ft1", "ft2") \
  X(FMADD_S, "fmadd.s", "F extension", F_INIT, "fmadd.s ft0, ft0, ft1, ft2", "t0", "ft0", "ft1", "ft2") \
  X(FSGNJ_S, "fsgnj.s", "F extension", F_INIT, "fsgnj.s ft0, ft0, ft1", "t0", "ft0", "ft1", "ft2") \
  X(FEQ_S, "feq.s", "F extension", F_INIT, "feq.s t1, ft0, ft1", "t0", "t1", "ft0", "ft1", "ft2") \
  X(FLE_S, "fle.s", "F extension", F_INIT, "fle.s t1, ft0, ft1", "t0", "t1", "ft0", "ft1", "ft2") \
  X(FLT_S, "flt.s", "F extension", F_INIT, "flt.s t1, ft0, ft1", "t0", "t1", "ft0", "ft1", "ft2") \
  X(FMV_W_X, "fmv.w.x", "F extension", "li t0, 1\n\t", "fmv.w.x ft0, t0", "t0", "ft0") \
  X(FMV_X_W, "fmv.x.w", "F extension", F_INIT, "fmv.x.w t1, ft0", "t0", "t1", "ft0", "ft1", "ft2") \
  X(FCVT_S_W, "fcvt.s.w", "F extension", "li t0, 7\n\t", "fcvt.s.w ft0, t0", "t0", "ft0") \
  X(FCVT_W_S, "fcvt.w.s", "F extension", F_INIT, "fcvt.w.s t1, ft0", "t0", "t1", "ft0", "ft1", "ft2") \
  X(FLW, "flw", "F extension", S_ADDR, "flw ft0, 0(t3)", "t3", "ft0") \
  X(FSW, "fsw", "F extension", S_ADDR "li t0, 1\n\tfcvt.s.w ft0, t0\n\t", "fsw ft0, 0(t3)", "t0", "t3", "ft0")

// ---------------------------------------------------------------------------
// Vector groups. Unless a row says otherwise the vtype is e32, m1, vl=4.
// ---------------------------------------------------------------------------

#define BENCH_LIST_VECTOR_INT_A(X) \
  X(VSETIVLI, "vsetivli", "RVV config", "", "vsetivli x0, 4, e32, m1, ta, ma") \
  X(VSETVLI, "vsetvli", "RVV config", "li t1, 4\n\t", "vsetvli t0, t1, e32, m1, ta, ma", "t0", "t1") \
  X(VADD_VV, "vadd.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vadd.vv v8, v8, v9") \
  X(VADD_VX, "vadd.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vadd.vx v8, v8, t0", "t0", "t1") \
  X(VADD_VI, "vadd.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vadd.vi v8, v8, 3") \
  X(VSUB_VV, "vsub.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vsub.vv v8, v8, v9") \
  X(VRSUB_VX, "vrsub.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vrsub.vx v8, v8, t0", "t0", "t1") \
  X(VRSUB_VI, "vrsub.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vrsub.vi v8, v8, 3") \
  X(VAND_VV, "vand.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vand.vv v8, v8, v9") \
  X(VAND_VX, "vand.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vand.vx v8, v8, t0", "t0", "t1") \
  X(VAND_VI, "vand.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vand.vi v8, v8, 3") \
  X(VOR_VV, "vor.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vor.vv v8, v8, v9") \
  X(VOR_VX, "vor.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vor.vx v8, v8, t0", "t0", "t1") \
  X(VOR_VI, "vor.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vor.vi v8, v8, 3") \
  X(VXOR_VV, "vxor.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vxor.vv v8, v8, v9") \
  X(VXOR_VX, "vxor.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vxor.vx v8, v8, t0", "t0", "t1") \
  X(VXOR_VI, "vxor.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vxor.vi v8, v8, 3") \
  X(VSLL_VV, "vsll.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vsll.vv v8, v8, v9") \
  X(VSLL_VI, "vsll.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vsll.vi v8, v8, 1") \
  X(VSRL_VV, "vsrl.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vsrl.vv v8, v8, v9") \
  X(VSRL_VI, "vsrl.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vsrl.vi v8, v8, 1") \
  X(VSRA_VV, "vsra.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vsra.vv v8, v8, v9") \
  X(VSRA_VI, "vsra.vi", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vsra.vi v8, v8, 1") \
  X(VMIN_VV, "vmin.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vmin.vv v8, v8, v9") \
  X(VMIN_VX, "vmin.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vmin.vx v8, v8, t0", "t0", "t1") \
  X(VMINU_VX, "vminu.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vminu.vx v8, v8, t0", "t0", "t1") \
  X(VMAX_VV, "vmax.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vmax.vv v8, v8, v9") \
  X(VMAX_VX, "vmax.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vmax.vx v8, v8, t0", "t0", "t1")

#define BENCH_LIST_VECTOR_INT_B(X) \
  X(VMUL_VV, "vmul.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vmul.vv v8, v8, v9") \
  X(VMUL_VX, "vmul.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vmul.vx v8, v8, t0", "t0", "t1") \
  X(VMULH_VX, "vmulh.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vmulh.vx v8, v8, t0", "t0", "t1") \
  X(VMADD_VV, "vmadd.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vmadd.vv v8, v9, v10") \
  X(VMADD_VX, "vmadd.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vmadd.vx v8, t0, v10", "t0", "t1") \
  X(VMACC_VV, "vmacc.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT, "vmacc.vv v8, v9, v10") \
  X(VMACC_VX, "vmacc.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vmacc.vx v8, t0, v10", "t0", "t1") \
  X(VNMSAC_VX, "vnmsac.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vnmsac.vx v8, t0, v10", "t0", "t1") \
  X(VNMSUB_VX, "vnmsub.vx", "RVV integer (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vnmsub.vx v8, t0, v10", "t0", "t1") \
  X(VDIV_VV, "vdiv.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT_DIV, "vdiv.vv v8, v11, v8", "t0", "t1") \
  X(VDIVU_VV, "vdivu.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT_DIV, "vdivu.vv v8, v11, v8", "t0", "t1") \
  X(VREM_VV, "vrem.vv", "RVV integer (e32,m1)", VS_E32M1 VI_INIT_DIV, "vrem.vv v9, v11, v8", "t0", "t1") \
  X(VZEXT_VF2, "vzext.vf2", "RVV widen/narrow (e32,m1)", VS_E32M1 VI_INIT, "vzext.vf2 v8, v12") \
  X(VSEXT_VF2, "vsext.vf2", "RVV widen/narrow (e32,m1)", VS_E32M1 VI_INIT, "vsext.vf2 v8, v12") \
  X(VSEXT_VF4, "vsext.vf4", "RVV widen/narrow (e32,m1)", VS_E32M1 VI_INIT, "vsext.vf4 v8, v12") \
  X(VNSRL_WI, "vnsrl.wi", "RVV widen/narrow (e16,m1)", VS_E16M1 VI_INIT, "vnsrl.wi v10, v10, 1") \
  X(VWADD_WV, "vwadd.wv", "RVV widen/narrow (e16,m1)", VS_E16M1 VI_INIT, "vwadd.wv v10, v10, v12") \
  X(VREDSUM_VS, "vredsum.vs", "RVV reduction (e32,m1)", VS_E32M1 VI_INIT, "vredsum.vs v9, v8, v9") \
  X(VID_V, "vid.v", "RVV permute (e32,m1)", VS_E32M1, "vid.v v8")

#define BENCH_LIST_VECTOR_MASK(X) \
  X(VMSEQ_VV, "vmseq.vv", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmseq.vv v1, v8, v9") \
  X(VMSEQ_VX, "vmseq.vx", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK S_INIT, "vmseq.vx v1, v8, t0", "t0", "t1") \
  X(VMSEQ_VI, "vmseq.vi", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmseq.vi v1, v8, 3") \
  X(VMSNE_VI, "vmsne.vi", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmsne.vi v1, v8, 3") \
  X(VMSLT_VX, "vmslt.vx", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK S_INIT, "vmslt.vx v1, v8, t0", "t0", "t1") \
  X(VMSLTU_VX, "vmsltu.vx", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK S_INIT, "vmsltu.vx v1, v8, t0", "t0", "t1") \
  X(VMSLEU_VI, "vmsleu.vi", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmsleu.vi v1, v8, 3") \
  X(VMSGTU_VI, "vmsgtu.vi", "RVV compare (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmsgtu.vi v1, v8, 3") \
  X(VMAND_MM, "vmand.mm", "RVV mask (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmand.mm v1, v1, v3") \
  X(VMOR_MM, "vmor.mm", "RVV mask (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmor.mm v1, v1, v3") \
  X(VMXOR_MM, "vmxor.mm", "RVV mask (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmxor.mm v1, v1, v3") \
  X(VMNAND_MM, "vmnand.mm", "RVV mask (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmnand.mm v1, v1, v3") \
  X(VMNOR_MM, "vmnor.mm", "RVV mask (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmnor.mm v1, v1, v3") \
  X(VMXNOR_MM, "vmxnor.mm", "RVV mask (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmxnor.mm v1, v1, v3") \
  X(VMANDN_MM, "vmandn.mm", "RVV mask (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmandn.mm v1, v1, v3")

#define BENCH_LIST_VECTOR_PERM(X) \
  X(VMERGE_VVM, "vmerge.vvm", "RVV permute (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmerge.vvm v8, v8, v10, v0") \
  X(VMERGE_VXM, "vmerge.vxm", "RVV permute (e32,m1)", VS_E32M1 VI_INIT_MASK S_INIT, "vmerge.vxm v8, v8, t0, v0", "t0", "t1") \
  X(VMERGE_VIM, "vmerge.vim", "RVV permute (e32,m1)", VS_E32M1 VI_INIT_MASK, "vmerge.vim v8, v8, 3, v0") \
  X(VMV_V_V, "vmv.v.v", "RVV permute (e32,m1)", VS_E32M1 VI_INIT, "vmv.v.v v8, v9") \
  X(VMV_V_X, "vmv.v.x", "RVV permute (e32,m1)", VS_E32M1 S_INIT, "vmv.v.x v8, t0", "t0", "t1") \
  X(VMV_V_I, "vmv.v.i", "RVV permute (e32,m1)", VS_E32M1, "vmv.v.i v8, 3") \
  X(VMV_S_X, "vmv.s.x", "RVV permute (e32,m1)", VS_E32M1 S_INIT, "vmv.s.x v8, t0", "t0", "t1") \
  X(VMV_X_S, "vmv.x.s", "RVV permute (e32,m1)", VS_E32M1 VI_INIT, "vmv.x.s t0, v8", "t0") \
  X(VMV1R_V, "vmv1r.v", "RVV whole-register move", VS_E32M1 VI_INIT, "vmv1r.v v8, v9") \
  X(VMV2R_V, "vmv2r.v", "RVV whole-register move", VS_E32M1 VI_INIT, "vmv2r.v v8, v10") \
  X(VMV4R_V, "vmv4r.v", "RVV whole-register move", VS_E32M1 VI_INIT, "vmv4r.v v8, v12") \
  X(VMV8R_V, "vmv8r.v", "RVV whole-register move", VS_E32M1 VI_INIT, "vmv8r.v v8, v16") \
  X(VFMV_S_F, "vfmv.s.f", "RVV permute (e32,m1)", VS_E32M1 VF_INIT, "vfmv.s.f v8, ft0", "t0", "ft0", "ft1") \
  X(VFMV_F_S, "vfmv.f.s", "RVV permute (e32,m1)", VS_E32M1 VF_INIT, "vfmv.f.s ft0, v8", "t0", "ft0", "ft1") \
  X(VFMV_V_F, "vfmv.v.f", "RVV permute (e32,m1)", VS_E32M1 VF_INIT, "vfmv.v.f v8, ft1", "t0", "ft0", "ft1") \
  X(VRGATHER_VI, "vrgather.vi", "RVV permute (e32,m1)", VS_E32M1 VI_INIT, "vrgather.vi v8, v9, 1") \
  X(VSLIDEUP_VI, "vslideup.vi", "RVV permute (e32,m1)", VS_E32M1 VI_INIT, "vslideup.vi v8, v9, 1") \
  X(VSLIDEUP_VX, "vslideup.vx", "RVV permute (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vslideup.vx v8, v9, t0", "t0", "t1") \
  X(VSLIDEDOWN_VI, "vslidedown.vi", "RVV permute (e32,m1)", VS_E32M1 VI_INIT, "vslidedown.vi v8, v8, 1") \
  X(VSLIDEDOWN_VX, "vslidedown.vx", "RVV permute (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vslidedown.vx v8, v8, t0", "t0", "t1") \
  X(VSLIDE1DOWN_VX, "vslide1down.vx", "RVV permute (e32,m1)", VS_E32M1 VI_INIT S_INIT, "vslide1down.vx v8, v8, t0", "t0", "t1") \
  X(VFSLIDE1DOWN_VF, "vfslide1down.vf", "RVV permute (e32,m1)", VS_E32M1 VF_INIT, "vfslide1down.vf v8, v8, ft0", "t0", "ft0", "ft1")

#define BENCH_LIST_VECTOR_MEM(X) \
  X(VLE8_V, "vle8.v", "RVV load/store (e8,m1)", VS_E8M1 V_ADDR, "vle8.v v8, (t3)", "t3") \
  X(VLE16_V, "vle16.v", "RVV load/store (e16,m1)", VS_E16M1 V_ADDR, "vle16.v v8, (t3)", "t3") \
  X(VLE32_V, "vle32.v", "RVV load/store (e32,m1)", VS_E32M1 V_ADDR, "vle32.v v8, (t3)", "t3") \
  X(VSE8_V, "vse8.v", "RVV load/store (e8,m1)", VS_E8M1 V_ADDR VI_INIT, "vse8.v v8, (t3)", "t3") \
  X(VSE16_V, "vse16.v", "RVV load/store (e16,m1)", VS_E16M1 V_ADDR VI_INIT, "vse16.v v8, (t3)", "t3") \
  X(VSE32_V, "vse32.v", "RVV load/store (e32,m1)", VS_E32M1 V_ADDR VI_INIT, "vse32.v v8, (t3)", "t3") \
  X(VLSE8_V, "vlse8.v", "RVV load/store (e8,m1)", VS_E8M1 V_ADDR "li t4, 2\n\t", "vlse8.v v8, (t3), t4", "t3", "t4") \
  X(VLSE16_V, "vlse16.v", "RVV load/store (e16,m1)", VS_E16M1 V_ADDR "li t4, 4\n\t", "vlse16.v v8, (t3), t4", "t3", "t4") \
  X(VLSE32_V, "vlse32.v", "RVV load/store (e32,m1)", VS_E32M1 V_ADDR "li t4, 8\n\t", "vlse32.v v8, (t3), t4", "t3", "t4") \
  X(VLUXEI32_V, "vluxei32.v", "RVV load/store (e32,m1)", VS_E32M1 V_ADDR "vid.v v12\n\tvsll.vi v12, v12, 2\n\t", "vluxei32.v v8, (t3), v12", "t3") \
  X(VL1RE8_V, "vl1re8.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vl1re8.v v8, (t3)", "t3") \
  X(VL2RE8_V, "vl2re8.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vl2re8.v v8, (t3)", "t3") \
  X(VL4RE8_V, "vl4re8.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vl4re8.v v8, (t3)", "t3") \
  X(VL8RE8_V, "vl8re8.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vl8re8.v v8, (t3)", "t3") \
  X(VS1R_V, "vs1r.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vs1r.v v8, (t3)", "t3") \
  X(VS2R_V, "vs2r.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vs2r.v v8, (t3)", "t3") \
  X(VS4R_V, "vs4r.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vs4r.v v8, (t3)", "t3") \
  X(VS8R_V, "vs8r.v", "RVV whole-register load/store", VS_E32M1 V_ADDR, "vs8r.v v8, (t3)", "t3")

#define BENCH_LIST_VECTOR_FP_A(X) \
  X(VFADD_VV, "vfadd.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfadd.vv v8, v8, v9", "t0", "ft0", "ft1") \
  X(VFADD_VF, "vfadd.vf", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfadd.vf v8, v8, ft1", "t0", "ft0", "ft1") \
  X(VFSUB_VV, "vfsub.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfsub.vv v8, v8, v9", "t0", "ft0", "ft1") \
  X(VFSUB_VF, "vfsub.vf", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfsub.vf v8, v8, ft1", "t0", "ft0", "ft1") \
  X(VFRSUB_VF, "vfrsub.vf", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfrsub.vf v8, v8, ft1", "t0", "ft0", "ft1") \
  X(VFMUL_VV, "vfmul.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfmul.vv v8, v8, v9", "t0", "ft0", "ft1") \
  X(VFMUL_VF, "vfmul.vf", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfmul.vf v8, v8, ft1", "t0", "ft0", "ft1") \
  X(VFDIV_VV, "vfdiv.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT_DIV, "vfdiv.vv v8, v8, v11", "t0", "ft0", "ft1", "ft2") \
  X(VFRDIV_VF, "vfrdiv.vf", "RVV float (e32,m1)", VS_E32M1 VF_INIT_DIV, "vfrdiv.vf v8, v8, ft2", "t0", "ft0", "ft1", "ft2") \
  X(VFSQRT_V, "vfsqrt.v", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfsqrt.v v8, v9", "t0", "ft0", "ft1") \
  X(VFMACC_VV, "vfmacc.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfmacc.vv v8, v9, v10", "t0", "ft0", "ft1") \
  X(VFMACC_VF, "vfmacc.vf", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfmacc.vf v8, ft1, v10", "t0", "ft0", "ft1") \
  X(VFMADD_VV, "vfmadd.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfmadd.vv v8, v9, v10", "t0", "ft0", "ft1") \
  X(VFMADD_VF, "vfmadd.vf", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfmadd.vf v8, ft1, v10", "t0", "ft0", "ft1") \
  X(VFSGNJ_VV, "vfsgnj.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfsgnj.vv v8, v8, v9", "t0", "ft0", "ft1") \
  X(VFSGNJN_VV, "vfsgnjn.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfsgnjn.vv v8, v8, v9", "t0", "ft0", "ft1") \
  X(VFSGNJX_VV, "vfsgnjx.vv", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfsgnjx.vv v8, v8, v9", "t0", "ft0", "ft1") \
  X(VFCLASS_V, "vfclass.v", "RVV float (e32,m1)", VS_E32M1 VF_INIT, "vfclass.v v8, v8", "t0", "ft0", "ft1") \
  X(VFREDOSUM_VS, "vfredosum.vs", "RVV reduction (e32,m1)", VS_E32M1 VF_INIT, "vfredosum.vs v9, v8, v9", "t0", "ft0", "ft1")

#define BENCH_LIST_VECTOR_FP_B(X) \
  X(VMFEQ_VV, "vmfeq.vv", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmfeq.vv v1, v8, v9", "t0", "ft0", "ft1") \
  X(VMFEQ_VF, "vmfeq.vf", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmfeq.vf v1, v8, ft1", "t0", "ft0", "ft1") \
  X(VMFNE_VV, "vmfne.vv", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmfne.vv v1, v8, v9", "t0", "ft0", "ft1") \
  X(VMFLT_VF, "vmflt.vf", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmflt.vf v1, v8, ft1", "t0", "ft0", "ft1") \
  X(VMFLE_VV, "vmfle.vv", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmfle.vv v1, v8, v9", "t0", "ft0", "ft1") \
  X(VMFLE_VF, "vmfle.vf", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmfle.vf v1, v8, ft1", "t0", "ft0", "ft1") \
  X(VMFGT_VF, "vmfgt.vf", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmfgt.vf v1, v8, ft1", "t0", "ft0", "ft1") \
  X(VMFGE_VF, "vmfge.vf", "RVV float compare (e32,m1)", VS_E32M1 VF_INIT, "vmfge.vf v1, v8, ft1", "t0", "ft0", "ft1") \
  X(VFCVT_X_F_V, "vfcvt.x.f.v", "RVV float convert (e32,m1)", VS_E32M1 VF_INIT, "vfcvt.x.f.v v8, v8", "t0", "ft0", "ft1") \
  X(VFCVT_RTZ_X_F_V, "vfcvt.rtz.x.f.v", "RVV float convert (e32,m1)", VS_E32M1 VF_INIT, "vfcvt.rtz.x.f.v v8, v8", "t0", "ft0", "ft1") \
  X(VFCVT_F_X_V, "vfcvt.f.x.v", "RVV float convert (e32,m1)", VS_E32M1 VI_INIT, "vfcvt.f.x.v v8, v8") \
  X(VFCVT_F_XU_V, "vfcvt.f.xu.v", "RVV float convert (e32,m1)", VS_E32M1 VI_INIT, "vfcvt.f.xu.v v8, v8") \
  X(VFWCVT_F_X_V, "vfwcvt.f.x.v", "RVV float convert (e16,m1)", VS_E16M1 VI_INIT, "vfwcvt.f.x.v v8, v9") \
  X(VFWCVT_F_XU_V, "vfwcvt.f.xu.v", "RVV float convert (e16,m1)", VS_E16M1 VI_INIT, "vfwcvt.f.xu.v v8, v9")
// clang-format on

#endif  // TESTS_COCOTB_ISA_CYCLE_BENCH_DEFS_H_
