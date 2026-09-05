// Copyright 2026 Antmicro
//
// Per-instruction cycle-cost microbenchmark.
//
// The host (cocotb) writes the id of a single instruction to benchmark into
// `g_selected_bench`, runs this program to halt, then reads the raw mcycle
// delta back out of `g_result`. Running exactly one benchmark per program
// execution keeps each measurement isolated (no leftover vtype/register
// state, no dispatch overhead from a surrounding loop) and lets the host
// checkpoint results to disk after every single run.
//
// Each benchmark brackets 32 back-to-back (data-dependent, so this measures
// latency rather than best-case throughput) instances of one instruction
// with `mcycle` reads. `BENCH_NOP` measures the fixed overhead of the two
// `csrr` bracket instructions themselves, which the host subtracts off.

#include <stdint.h>

// clang-format off
enum BenchId {
  BENCH_NOP = 0,
  BENCH_ADD,
  BENCH_SUB,
  BENCH_AND,
  BENCH_OR,
  BENCH_XOR,
  BENCH_SLL,
  BENCH_SRL,
  BENCH_SRA,
  BENCH_SLT,
  BENCH_ADDI,
  BENCH_SLTI,
  BENCH_SLTIU,
  BENCH_ANDI,
  BENCH_ORI,
  BENCH_XORI,
  BENCH_SLLI,
  BENCH_SRLI,
  BENCH_SRAI,
  BENCH_LW,
  BENCH_SW,
  BENCH_LB,
  BENCH_SB,
  BENCH_BEQ_TAKEN,
  BENCH_BEQ_NOT_TAKEN,
  BENCH_JAL,
  BENCH_MUL,
  BENCH_MULH,
  BENCH_DIV,
  BENCH_DIVU,
  BENCH_REM,
  BENCH_FADD_S,
  BENCH_FMUL_S,
  BENCH_FDIV_S,
  BENCH_FSQRT_S,
  BENCH_FMADD_S,
  BENCH_VADD_VV,
  BENCH_VSUB_VV,
  BENCH_VAND_VV,
  BENCH_VMUL_VV,
  BENCH_VLE32_V,
  BENCH_VSE32_V,
  BENCH_VREDSUM_VS,
  BENCH_VFADD_VV,
  BENCH_VFMUL_VV,
  BENCH_COUNT
};
// clang-format on

volatile uint32_t g_selected_bench = 0xFFFFFFFFu;
volatile uint32_t g_result         = 0xFFFFFFFFu;

__attribute__((aligned(16), used)) uint32_t g_scratch[4]  = {0, 0, 0, 0};
__attribute__((aligned(16), used)) uint32_t g_vscratch[4] = {1, 2, 3, 4};

#define BENCH(fnname, setup, insn, ...)                                \
  static uint32_t fnname(void) {                                       \
    uint32_t start, end;                                               \
    asm volatile(setup "csrr %0, mcycle\n\t"                           \
                        ".rept 32\n\t" insn "\n\t"                     \
                        ".endr\n\t"                                    \
                        "csrr %1, mcycle\n\t"                          \
                 : "=r"(start), "=r"(end)                              \
                 :                                                     \
                 : "memory", ##__VA_ARGS__);                           \
    return end - start;                                                \
  }

BENCH(bench_nop, "", "nop")
BENCH(bench_add, "li t0, 1\n\tli t1, 2\n\t", "add t0, t0, t1", "t0", "t1")
BENCH(bench_sub, "li t0, 1\n\tli t1, 2\n\t", "sub t0, t0, t1", "t0", "t1")
BENCH(bench_and, "li t0, 1\n\tli t1, 2\n\t", "and t0, t0, t1", "t0", "t1")
BENCH(bench_or, "li t0, 1\n\tli t1, 2\n\t", "or t0, t0, t1", "t0", "t1")
BENCH(bench_xor, "li t0, 1\n\tli t1, 2\n\t", "xor t0, t0, t1", "t0", "t1")
BENCH(bench_sll, "li t0, 1\n\tli t1, 1\n\t", "sll t0, t0, t1", "t0", "t1")
BENCH(bench_srl, "li t0, 1\n\tli t1, 1\n\t", "srl t0, t0, t1", "t0", "t1")
BENCH(bench_sra, "li t0, 1\n\tli t1, 1\n\t", "sra t0, t0, t1", "t0", "t1")
BENCH(bench_slt, "li t0, 1\n\tli t1, 2\n\t", "slt t0, t0, t1", "t0", "t1")
BENCH(bench_addi, "li t0, 1\n\t", "addi t0, t0, 1", "t0")
BENCH(bench_slti, "li t0, 1\n\t", "slti t0, t0, 5", "t0")
BENCH(bench_sltiu, "li t0, 1\n\t", "sltiu t0, t0, 5", "t0")
BENCH(bench_andi, "li t0, 1\n\t", "andi t0, t0, 3", "t0")
BENCH(bench_ori, "li t0, 1\n\t", "ori t0, t0, 3", "t0")
BENCH(bench_xori, "li t0, 1\n\t", "xori t0, t0, 3", "t0")
BENCH(bench_slli, "li t0, 1\n\t", "slli t0, t0, 1", "t0")
BENCH(bench_srli, "li t0, 1\n\t", "srli t0, t0, 1", "t0")
BENCH(bench_srai, "li t0, 1\n\t", "srai t0, t0, 1", "t0")
BENCH(bench_lw, "la t3, g_scratch\n\t", "lw t0, 0(t3)", "t0", "t3")
BENCH(bench_sw, "la t3, g_scratch\n\tli t0, 42\n\t", "sw t0, 0(t3)", "t0", "t3")
BENCH(bench_lb, "la t3, g_scratch\n\t", "lb t0, 0(t3)", "t0", "t3")
BENCH(bench_sb, "la t3, g_scratch\n\tli t0, 42\n\t", "sb t0, 0(t3)", "t0", "t3")
BENCH(bench_mul, "li t0, 3\n\tli t1, 5\n\t", "mul t0, t0, t1", "t0", "t1")
BENCH(bench_mulh, "li t0, 3\n\tli t1, 5\n\t", "mulh t0, t0, t1", "t0", "t1")
BENCH(bench_div, "li t0, 100\n\tli t1, 3\n\t", "div t0, t0, t1", "t0", "t1")
BENCH(bench_divu, "li t0, 100\n\tli t1, 3\n\t", "divu t0, t0, t1", "t0", "t1")
BENCH(bench_rem, "li t0, 100\n\tli t1, 3\n\t", "rem t0, t0, t1", "t0", "t1")
BENCH(bench_fadd_s,
      "li t0, 1\n\tfcvt.s.w ft0, t0\n\tli t0, 2\n\tfcvt.s.w ft1, t0\n\t",
      "fadd.s ft0, ft0, ft1", "t0", "ft0", "ft1")
BENCH(bench_fmul_s,
      "li t0, 1\n\tfcvt.s.w ft0, t0\n\tli t0, 2\n\tfcvt.s.w ft1, t0\n\t",
      "fmul.s ft0, ft0, ft1", "t0", "ft0", "ft1")
BENCH(bench_fdiv_s,
      "li t0, 1\n\tfcvt.s.w ft0, t0\n\tli t0, 2\n\tfcvt.s.w ft1, t0\n\t",
      "fdiv.s ft0, ft0, ft1", "t0", "ft0", "ft1")
BENCH(bench_fsqrt_s, "li t0, 2\n\tfcvt.s.w ft0, t0\n\t", "fsqrt.s ft0, ft0",
      "t0", "ft0")
BENCH(bench_fmadd_s,
      "li t0, 1\n\tfcvt.s.w ft0, t0\n\tli t0, 2\n\tfcvt.s.w ft1, t0\n\t"
      "li t0, 3\n\tfcvt.s.w ft2, t0\n\t",
      "fmadd.s ft0, ft0, ft1, ft2", "t0", "ft0", "ft1", "ft2")
BENCH(bench_vadd_vv,
      "vsetivli x0, 4, e32, m1, ta, ma\n\tvmv.v.i v8, 1\n\tvmv.v.i v9, 2\n\t",
      "vadd.vv v8, v8, v9")
BENCH(bench_vsub_vv,
      "vsetivli x0, 4, e32, m1, ta, ma\n\tvmv.v.i v8, 1\n\tvmv.v.i v9, 2\n\t",
      "vsub.vv v8, v8, v9")
BENCH(bench_vand_vv,
      "vsetivli x0, 4, e32, m1, ta, ma\n\tvmv.v.i v8, 1\n\tvmv.v.i v9, 2\n\t",
      "vand.vv v8, v8, v9")
BENCH(bench_vmul_vv,
      "vsetivli x0, 4, e32, m1, ta, ma\n\tvmv.v.i v8, 1\n\tvmv.v.i v9, 2\n\t",
      "vmul.vv v8, v8, v9")
BENCH(bench_vle32_v,
      "vsetivli x0, 4, e32, m1, ta, ma\n\tla t3, g_vscratch\n\t",
      "vle32.v v8, (t3)", "t3")
BENCH(bench_vse32_v,
      "vsetivli x0, 4, e32, m1, ta, ma\n\tla t3, g_vscratch\n\tvmv.v.i v8, 7\n\t",
      "vse32.v v8, (t3)", "t3")
BENCH(bench_vredsum_vs,
      "vsetivli x0, 4, e32, m1, ta, ma\n\tvmv.v.i v8, 1\n\tvmv.v.i v9, 0\n\t",
      "vredsum.vs v9, v8, v9")
BENCH(bench_vfadd_vv,
      "vsetivli x0, 4, e32, m1, ta, ma\n\t"
      "li t0, 1\n\tfcvt.s.w ft0, t0\n\tli t0, 2\n\tfcvt.s.w ft1, t0\n\t"
      "vfmv.v.f v8, ft0\n\tvfmv.v.f v9, ft1\n\t",
      "vfadd.vv v8, v8, v9", "t0", "ft0", "ft1")
BENCH(bench_vfmul_vv,
      "vsetivli x0, 4, e32, m1, ta, ma\n\t"
      "li t0, 1\n\tfcvt.s.w ft0, t0\n\tli t0, 2\n\tfcvt.s.w ft1, t0\n\t"
      "vfmv.v.f v8, ft0\n\tvfmv.v.f v9, ft1\n\t",
      "vfmul.vv v8, v8, v9", "t0", "ft0", "ft1")

// Branch/jump benchmarks need per-iteration local labels, so they are
// written out by hand instead of through the BENCH() macro.

static uint32_t bench_beq_taken(void) {
  uint32_t start, end;
  asm volatile("csrr %0, mcycle\n\t"
               ".rept 32\n\t"
               "beq x0, x0, 1f\n\t"
               "1:\n\t"
               ".endr\n\t"
               "csrr %1, mcycle\n\t"
               : "=r"(start), "=r"(end)
               :
               : "memory");
  return end - start;
}

static uint32_t bench_beq_not_taken(void) {
  uint32_t start, end;
  asm volatile("li t0, 1\n\t"
               "li t1, 2\n\t"
               "csrr %0, mcycle\n\t"
               ".rept 32\n\t"
               "beq t0, t1, 1f\n\t"
               "1:\n\t"
               ".endr\n\t"
               "csrr %1, mcycle\n\t"
               : "=r"(start), "=r"(end)
               :
               : "t0", "t1", "memory");
  return end - start;
}

static uint32_t bench_jal(void) {
  uint32_t start, end;
  asm volatile("csrr %0, mcycle\n\t"
               ".rept 32\n\t"
               "jal t2, 1f\n\t"
               "1:\n\t"
               ".endr\n\t"
               "csrr %1, mcycle\n\t"
               : "=r"(start), "=r"(end)
               :
               : "t2", "memory");
  return end - start;
}

int main(void) {
  uint32_t result = 0xFFFFFFFFu;
  switch (g_selected_bench) {
    case BENCH_NOP: result = bench_nop(); break;
    case BENCH_ADD: result = bench_add(); break;
    case BENCH_SUB: result = bench_sub(); break;
    case BENCH_AND: result = bench_and(); break;
    case BENCH_OR: result = bench_or(); break;
    case BENCH_XOR: result = bench_xor(); break;
    case BENCH_SLL: result = bench_sll(); break;
    case BENCH_SRL: result = bench_srl(); break;
    case BENCH_SRA: result = bench_sra(); break;
    case BENCH_SLT: result = bench_slt(); break;
    case BENCH_ADDI: result = bench_addi(); break;
    case BENCH_SLTI: result = bench_slti(); break;
    case BENCH_SLTIU: result = bench_sltiu(); break;
    case BENCH_ANDI: result = bench_andi(); break;
    case BENCH_ORI: result = bench_ori(); break;
    case BENCH_XORI: result = bench_xori(); break;
    case BENCH_SLLI: result = bench_slli(); break;
    case BENCH_SRLI: result = bench_srli(); break;
    case BENCH_SRAI: result = bench_srai(); break;
    case BENCH_LW: result = bench_lw(); break;
    case BENCH_SW: result = bench_sw(); break;
    case BENCH_LB: result = bench_lb(); break;
    case BENCH_SB: result = bench_sb(); break;
    case BENCH_BEQ_TAKEN: result = bench_beq_taken(); break;
    case BENCH_BEQ_NOT_TAKEN: result = bench_beq_not_taken(); break;
    case BENCH_JAL: result = bench_jal(); break;
    case BENCH_MUL: result = bench_mul(); break;
    case BENCH_MULH: result = bench_mulh(); break;
    case BENCH_DIV: result = bench_div(); break;
    case BENCH_DIVU: result = bench_divu(); break;
    case BENCH_REM: result = bench_rem(); break;
    case BENCH_FADD_S: result = bench_fadd_s(); break;
    case BENCH_FMUL_S: result = bench_fmul_s(); break;
    case BENCH_FDIV_S: result = bench_fdiv_s(); break;
    case BENCH_FSQRT_S: result = bench_fsqrt_s(); break;
    case BENCH_FMADD_S: result = bench_fmadd_s(); break;
    case BENCH_VADD_VV: result = bench_vadd_vv(); break;
    case BENCH_VSUB_VV: result = bench_vsub_vv(); break;
    case BENCH_VAND_VV: result = bench_vand_vv(); break;
    case BENCH_VMUL_VV: result = bench_vmul_vv(); break;
    case BENCH_VLE32_V: result = bench_vle32_v(); break;
    case BENCH_VSE32_V: result = bench_vse32_v(); break;
    case BENCH_VREDSUM_VS: result = bench_vredsum_vs(); break;
    case BENCH_VFADD_VV: result = bench_vfadd_vv(); break;
    case BENCH_VFMUL_VV: result = bench_vfmul_vv(); break;
    default: result = 0xFFFFFFFFu; break;
  }
  g_result = result;
  return 0;
}
