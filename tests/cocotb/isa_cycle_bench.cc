// Copyright 2026 Antmicro
//
// Per-instruction cycle-cost microbenchmark.
//
// The host (cocotb) writes the index of a single instruction to benchmark
// into `g_selected_bench`, runs this program to halt, then reads the raw
// mcycle delta back out of `g_result`. Running exactly one benchmark per
// program execution keeps each measurement isolated (no leftover vtype or
// register state, no dispatch overhead from a surrounding loop) and lets the
// host checkpoint results to disk after every single run.
//
// For subprocess-per-run backends like UVM (especially VCS UVM on EDACloud,
// where each `simv` cold start and license checkout takes ~45-50s), setting
// `g_selected_bench = BENCH_RUN_ALL` executes all `BENCH_COUNT` benchmarks of
// this ELF in a single invocation and writes their cycle deltas to
// `g_results[]`, avoiding one simulator startup per benchmark.
//
// Each benchmark brackets BENCH_REPS back-to-back instances of one
// instruction with `mcycle` reads. Instances are data-dependent where the
// instruction allows it, so most rows measure latency; the exceptions are
// listed in BENCH_THROUGHPUT_IDS. The host subtracts a fixed cost for the two
// `csrr` bracket instructions; the `nop` row is kept as a baseline to check
// that cost against.
//
// The benchmarks themselves live in isa_cycle_bench_defs.h. ITCM is only
// 8 KiB, which is not enough room for every instruction we care about, so
// that header splits them into groups and this file is compiled once per
// group with -DBENCH_GROUP=<GROUP>. The host walks every group's ELF in
// turn. See tests/cocotb/BUILD for the group list.

#include <stdint.h>

#include "isa_cycle_bench_defs.h"

#ifndef BENCH_GROUP
#error "isa_cycle_bench.cc must be compiled with -DBENCH_GROUP=<GROUP>"
#endif

#define BENCH_CAT_(a, b) a##b
#define BENCH_CAT(a, b)  BENCH_CAT_(a, b)
#define BENCH_STR_(x)    #x
#define BENCH_STR(x)     BENCH_STR_(x)

// The list of benchmarks compiled into this particular ELF.
#define BENCH_LIST(X) BENCH_CAT(BENCH_LIST_, BENCH_GROUP)(X)

volatile uint32_t g_selected_bench = 0xFFFFFFFFu;
volatile uint32_t g_result         = 0xFFFFFFFFu;

// Number of benchmarks in this ELF, so the host can check that the group it
// parsed out of the header is the group that actually got compiled in.
volatile uint32_t g_bench_count = 0;

// Scalar scratch, and a vector scratch big enough for a whole eight-register
// group transfer (8 * VLEN/8 = 128 bytes at VLEN=128).
__attribute__((aligned(16), used)) uint32_t g_scratch[8]   = {0, 0, 0, 0, 0, 0, 0, 0};
__attribute__((aligned(16), used)) uint8_t g_vscratch[256] = {0};

// Call target for the `call + ret` round-trip benchmark. Written as file
// scope asm so it stays a bare `ret` with no prologue of its own.
__asm__(
    ".text\n\t"
    ".p2align 2\n"
    "bench_call_target:\n\t"
    "ret\n\t");

// Defines the body of one benchmark. The generated names are uppercase
// because they are pasted together from the X-macro's enum suffix.
#define BENCH_FN(id, setup, insn, ...)                                \
  static uint32_t BENCH_CAT(bench_, id)(void) {                       \
    uint32_t start, end;                                              \
    asm volatile(setup                                                \
                 "csrr %0, mcycle\n\t"                                \
                 ".rept " BENCH_STR(BENCH_REPS) "\n\t" insn           \
                                                "\n\t"                \
                                                ".endr\n\t"           \
                                                "csrr %1, mcycle\n\t" \
                 : "=r"(start), "=r"(end)                             \
                 :                                                    \
                 : "memory", ##__VA_ARGS__);                          \
    return end - start;                                               \
  }

#define X(id, mnemonic, category, setup, insn, ...) BENCH_FN(id, setup, insn, ##__VA_ARGS__)
BENCH_LIST(X)
#undef X

typedef uint32_t (*bench_fn_t)(void);

static bench_fn_t const kBenches[] = {
#define X(id, mnemonic, category, ...) BENCH_CAT(bench_, id),
    BENCH_LIST(X)
#undef X
};

#define BENCH_COUNT   (sizeof(kBenches) / sizeof(kBenches[0]))
#define BENCH_RUN_ALL 0xFFFFFFFEu

__attribute__((aligned(16), used)) volatile uint32_t g_results[BENCH_COUNT];

static uint32_t run_bench(uint32_t bench_id) {
  return (bench_id < BENCH_COUNT) ? kBenches[bench_id]() : 0xFFFFFFFFu;
}

int main(void) {
  g_bench_count           = BENCH_COUNT;
  const uint32_t selected = g_selected_bench;
  if (selected == BENCH_RUN_ALL) {
    for (uint32_t i = 0; i < BENCH_COUNT; ++i) {
      g_results[i] = run_bench(i);
    }
    return 0;
  }

  g_result = run_bench(selected);
  return 0;
}
