// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef TESTS_COCOTB_RVV_LOAD_STORE_RVV_LSU_TEST_UTILS_H_
#define TESTS_COCOTB_RVV_LOAD_STORE_RVV_LSU_TEST_UTILS_H_

#include <stddef.h>
#include <stdint.h>

// -----------------------------------------------------------------------------
// Subtest auto-registration for dual Cocotb / standalone UVM execution
//
// Subtests defined with RVV_SUBTEST(name) export their symbol for Cocotb
// lookup/dispatch via `test_fn` or `impl` while automatically registering a
// function pointer in the `rvv_subtests` linker section so standalone UVM runs
// can iterate `[__start_rvv_subtests, __stop_rvv_subtests)` without maintaining
// a manual list in main().
//
// Input, mask, and index buffers are seeded at compile time (`constexpr`) via
// `RvvSeededInput`, `RvvSeededMask`, and `RvvSeededIndex` so non-zero stimulus
// is embedded directly in `.data` without executing setup code on the DUT.
//
// In standalone UVM mode (`selected_fn == nullptr`), the runner helpers below:
//   1. Pre-fill the active output buffer window with a subtest-specific canary
//      pattern before each subtest so untouched/masked-off bytes and missing
//      stores are never masked by zeros or prior subtest outputs.
//   2. Read the active output buffer window back into architectural vector
//      registers (`vle8.v`) after each subtest so 3-way RVVI co-simulation
//      (RTL + MPACT + Spike) verifies stored memory contents via `v_wb`.
// -----------------------------------------------------------------------------
extern "C" {
typedef void (*rvv_test_func_t)(void);
extern rvv_test_func_t __start_rvv_subtests[];
extern rvv_test_func_t __stop_rvv_subtests[];
}

#define RVV_SUBTEST(name)                                                        \
  __attribute__((used, retain)) void name(void);                                 \
  static rvv_test_func_t __rvv_subtest_##name                                    \
      __attribute__((used, retain, no_reorder, section("rvv_subtests"))) = name; \
  __attribute__((used, retain)) void name(void)

// Cap the active byte window initialized at compile time and read back per
// subtest in standalone mode so large 30KB LUT/scatter buffers exercise byte
// offsets >= 256 without incurring excessive overhead.
static constexpr size_t kRvvStandaloneWindowBytes = 512;

// Returns the smaller of two byte counts to clamp buffer operations to the active window.
static constexpr size_t rvv_min_size(size_t a, size_t b) { return (a < b) ? a : b; }

// Compile-time seeded input buffer embedded directly in `.data` with non-zero
// bytes (`((byte_idx * 29) + 13) | 1`) so standalone UVM runs have non-trivial
// load/store stimulus in memory before `_start` without executing setup code on the DUT.
template <typename T, size_t N>
struct RvvSeededInput {
  T data[N]{};

  constexpr RvvSeededInput() {
    const size_t active_elems = rvv_min_size(N * sizeof(T), kRvvStandaloneWindowBytes) / sizeof(T);
    for (size_t i = 0; i < active_elems; ++i) {
      T val = 0;
      for (size_t b = 0; b < sizeof(T); ++b) {
        const size_t byte_idx  = i * sizeof(T) + b;
        const uint8_t byte_val = static_cast<uint8_t>(((byte_idx * 29) + 13) | 1);
        val |= static_cast<T>(static_cast<T>(byte_val) << (b * 8));
      }
      data[i] = val;
    }
  }

  constexpr operator T *() { return data; }
  constexpr operator const T *() const { return data; }
};

// Compile-time seeded mask buffer embedded in `.data` with repeating 8-bit
// patterns containing balanced alternating and grouped 1/0 bit runs so `v0.t`
// masked loads and stores exercise both active and inactive elements.
template <size_t N>
struct RvvSeededMask {
  uint8_t data[N]{};

  constexpr RvvSeededMask() {
    constexpr uint8_t kMaskPatterns[8] = {0xA5, 0x5A, 0x3C, 0xC3, 0x96, 0x69, 0xD2, 0x2D};
    for (size_t i = 0; i < N; ++i) {
      data[i] = kMaskPatterns[i & 7];
    }
  }

  constexpr operator uint8_t *() { return data; }
  constexpr operator const uint8_t *() const { return data; }
};

// Compile-time seeded index buffer embedded in `.data` with distinct,
// non-sequential byte offsets (`(i * 19 + 5) % num_slots`) spaced by
// `8 * sizeof(InT)` bytes so up to 8 segments stay aligned and do not overlap.
template <typename IdxT, size_t IdxN, typename InT = IdxT>
struct RvvSeededIndex {
  IdxT data[IdxN]{};

  constexpr RvvSeededIndex() {
    const size_t stride_bytes = 8 * sizeof(InT);
    const size_t window_bytes = (sizeof(IdxT) == 1) ? 256 : kRvvStandaloneWindowBytes;
    const size_t num_slots    = window_bytes / stride_bytes;
    for (size_t i = 0; i < IdxN; ++i) {
      data[i] = static_cast<IdxT>(((i * 19 + 5) % num_slots) * stride_bytes);
    }
  }

  constexpr operator IdxT *() { return data; }
  constexpr operator const IdxT *() const { return data; }
};

// Pre-fills `buf` in 128-byte (`m8`) chunks by XORing lane indices (`vid.v`) with a
// `subtest_idx`-derived seed (XORed with `0xC0` to shift values into the upper byte range)
// so unwritten/masked bytes never match zero, `in_buf`, or prior subtest outputs.
static inline void rvv_fill_output_canary(void *buf, size_t num_bytes, size_t subtest_idx) {
  if (buf == nullptr)
    return;
  uint8_t *ptr     = static_cast<uint8_t *>(buf);
  size_t remaining = rvv_min_size(num_bytes, kRvvStandaloneWindowBytes);
  uint8_t seed     = static_cast<uint8_t>(0xC0 ^ ((subtest_idx + 1) * 19));
  while (remaining >= 128) {
    size_t vl;
    asm("vsetvli %[vl], %[rem], e8, m8, ta, ma\n\t"
        "vid.v v8\n\t"
        "vxor.vx v8, v8, %[seed]\n\t"
        "vse8.v v8, %[mem]\n\t"
        : [vl] "=&r"(vl), [mem] "=A"(*reinterpret_cast<uint8_t(*)[128]>(ptr))
        : [rem] "r"(remaining), [seed] "r"(seed)
        : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "vtype");
    ptr += vl;
    remaining -= vl;
    seed = static_cast<uint8_t>(seed + 37);
  }
  while (remaining > 0) {
    size_t vl;
    using vla_t = uint8_t[remaining];
    asm("vsetvli %[vl], %[rem], e8, m8, ta, ma\n\t"
        "vid.v v8\n\t"
        "vxor.vx v8, v8, %[seed]\n\t"
        "vse8.v v8, %[mem]\n\t"
        : [vl] "=&r"(vl), [mem] "=A"(*reinterpret_cast<vla_t *>(ptr))
        : [rem] "r"(remaining), [seed] "r"(seed)
        : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "vtype");
    ptr += vl;
    remaining -= vl;
    seed = static_cast<uint8_t>(seed + 37);
  }
}

// Loads `buf` into `v8..v15` in 128-byte (`m8` at VLEN=128) chunks followed by an `m1` tail
// so 3-way RVVI co-simulation checks stored SRAM contents via architectural `v_wb` writebacks.
static inline void rvv_readback_output_bytes(const void *buf, size_t num_bytes) {
  if (buf == nullptr)
    return;
  const uint8_t *ptr = static_cast<const uint8_t *>(buf);
  size_t remaining   = rvv_min_size(num_bytes, kRvvStandaloneWindowBytes);
  while (remaining >= 128) {
    size_t vl;
    asm volatile(
        "vsetvli %[vl], %[rem], e8, m8, ta, ma\n\t"
        "vle8.v v8, %[mem]\n\t"
        : [vl] "=&r"(vl)
        : [rem] "r"(remaining), [mem] "A"(*reinterpret_cast<const uint8_t(*)[128]>(ptr))
        : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "vtype");
    ptr += vl;
    remaining -= vl;
  }
  while (remaining > 0) {
    size_t vl;
    const size_t chunk_bytes = rvv_min_size(remaining, 16);
    using vla_t              = const uint8_t[chunk_bytes];
    asm volatile(
        "vsetvli %[vl], %[rem], e8, m1, ta, ma\n\t"
        "vle8.v v8, %[mem]\n\t"
        : [vl] "=&r"(vl)
        : [rem] "r"(remaining), [mem] "A"(*reinterpret_cast<vla_t *>(ptr))
        : "v8", "vl", "vtype");
    ptr += vl;
    remaining -= vl;
  }
}

// Dispatches `selected_fn` directly under Cocotb, or iterates all registered subtests with
// per-subtest output canary pre-fill and vector register readback in standalone UVM mode.
static inline void rvv_run_subtests_bytes(rvv_test_func_t selected_fn, void *out_buf,
                                          size_t out_bytes) {
  if (selected_fn != nullptr) {
    selected_fn();
    return;
  }
  size_t subtest_idx = 0;
  for (const rvv_test_func_t *fn = __start_rvv_subtests; fn < __stop_rvv_subtests;
       ++fn, ++subtest_idx) {
    rvv_fill_output_canary(out_buf, out_bytes, subtest_idx);
    (*fn)();
    rvv_readback_output_bytes(out_buf, out_bytes);
  }
}

// Runs subtests that manage their own internal buffers or do not use a shared output array.
static inline void rvv_run_subtests(rvv_test_func_t selected_fn) {
  rvv_run_subtests_bytes(selected_fn, nullptr, 0);
}

// Typed wrapper around `rvv_run_subtests_bytes` that deduces the output array byte size.
template <typename OutT, size_t OutN>
static inline void rvv_run_subtests(rvv_test_func_t selected_fn, OutT (&out_buf)[OutN]) {
  rvv_run_subtests_bytes(selected_fn, out_buf, sizeof(out_buf));
}

#endif  // TESTS_COCOTB_RVV_LOAD_STORE_RVV_LSU_TEST_UTILS_H_
