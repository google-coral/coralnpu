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

#include <riscv_vector.h>
#include <stddef.h>

extern "C" {

// Small scratchpad copy used only by the A-cache experiment below. The
// high-memory test targets place .data in the 1 MiB DTCM, while A itself is
// deliberately allocated in external DDR by the runners.
static __bf16 rvv_gemv_a_cache[2048]
    __attribute__((section(".data"), used, retain, aligned(16)));

void rvv_gemv_1d_bf16(const __bf16 *__restrict__ A, const __bf16 *__restrict__ B,
                      __bf16 *__restrict__ C, int K, int N) {
  int c = 0;
  while (c <= N - 64) {
    size_t vl_bf16_m2 = __riscv_vsetvl_e16m2(16);
    size_t vl_bf16_m4 = 2 * vl_bf16_m2;

    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; k++) {
      __bf16 a = A[k];

      vbfloat16m4_t vb0 = __riscv_vle16_v_bf16m4(rhs_ptr, vl_bf16_m4);
      vacc0             = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a, vb0, vl_bf16_m4);
      vbfloat16m4_t vb1 = __riscv_vle16_v_bf16m4(rhs_ptr + vl_bf16_m4, vl_bf16_m4);
      vacc1             = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a, vb1, vl_bf16_m4);

      rhs_ptr += N;
    }

    vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
    vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);

    __riscv_vse16_v_bf16m4(C + c, vbf0, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c + vl_bf16_m4, vbf1, vl_bf16_m4);

    c += 2 * vl_bf16_m4;
  }

  while (c < N) {
    size_t vl_bf16     = __riscv_vsetvl_e16m2(N - c);
    size_t vl_f32      = vl_bf16;
    vfloat32m4_t vacc0 = __riscv_vfmv_v_f_f32m4(0.0f, vl_f32);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; k++) {
      __bf16 a          = A[k];
      vbfloat16m2_t vb0 = __riscv_vle16_v_bf16m2(rhs_ptr, vl_bf16);
      vacc0             = __riscv_vfwmaccbf16_vf_f32m4(vacc0, a, vb0, vl_bf16);
      rhs_ptr += N;
    }
    vbfloat16m2_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m2(vacc0, vl_f32);
    __riscv_vse16_v_bf16m2(C + c, vbf0, vl_bf16);
    c += vl_bf16;
  }
}

// Exploratory schedule for the DDR-backed decode path. The baseline loop
// reuses one source register for vb0/vb1, which forces the first widening FMA
// to be issued before the second load can overwrite that register. This
// variant keeps the two source vectors live, issues both loads first, and then
// performs the two independent FMAs. It is built only by the experimental
// RVV_BF16_GEMV_PAIR_LOADS target; the baseline ABI and code path are
// unchanged.
void rvv_gemv_1d_bf16_pair_loads(const __bf16 *__restrict__ A,
                                 const __bf16 *__restrict__ B,
                                 __bf16 *__restrict__ C, int K, int N) {
  int c = 0;
  while (c <= N - 64) {
    size_t vl_bf16_m2 = __riscv_vsetvl_e16m2(16);
    size_t vl_bf16_m4 = 2 * vl_bf16_m2;

    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; k++) {
      __bf16 a = A[k];

      // Keep the source vectors distinct so both memory operations can be
      // scheduled before either dependent widening FMA.
      vbfloat16m4_t vb0 = __riscv_vle16_v_bf16m4(rhs_ptr, vl_bf16_m4);
      vbfloat16m4_t vb1 =
          __riscv_vle16_v_bf16m4(rhs_ptr + vl_bf16_m4, vl_bf16_m4);
      vacc0 = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a, vb0, vl_bf16_m4);
      vacc1 = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a, vb1, vl_bf16_m4);

      rhs_ptr += N;
    }

    vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
    vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);

    __riscv_vse16_v_bf16m4(C + c, vbf0, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c + vl_bf16_m4, vbf1, vl_bf16_m4);

    c += 2 * vl_bf16_m4;
  }

  // Keep the existing tail implementation so this experiment changes only
  // the full 64-element loop used by the Gemma projection shapes.
  while (c < N) {
    size_t vl_bf16     = __riscv_vsetvl_e16m2(N - c);
    size_t vl_f32      = vl_bf16;
    vfloat32m4_t vacc0 = __riscv_vfmv_v_f_f32m4(0.0f, vl_f32);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; k++) {
      __bf16 a          = A[k];
      vbfloat16m2_t vb0 = __riscv_vle16_v_bf16m2(rhs_ptr, vl_bf16);
      vacc0 = __riscv_vfwmaccbf16_vf_f32m4(vacc0, a, vb0, vl_bf16);
      rhs_ptr += N;
    }
    vbfloat16m2_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m2(vacc0, vl_f32);
    __riscv_vse16_v_bf16m2(C + c, vbf0, vl_bf16);
    c += vl_bf16;
  }
}

// Experimental packed-weight schedule. For every 64-column block, the host
// stores [B[c + 0], B[c + 32], B[c + 1], B[c + 33], ...]. A segment-2 load
// reconstructs the two 32-element source vectors in one RVV memory
// instruction. The caller must use the matching packed layout; non-64-aligned
// shapes deliberately fall back to the baseline implementation.
void rvv_gemv_1d_bf16_segment2(const __bf16 *__restrict__ A,
                                const __bf16 *__restrict__ B,
                                __bf16 *__restrict__ C, int K, int N) {
  if ((N & 63) != 0) {
    rvv_gemv_1d_bf16(A, B, C, K, N);
    return;
  }

  int c = 0;
  while (c < N) {
    size_t vl_bf16_m2 = __riscv_vsetvl_e16m2(16);
    size_t vl_bf16_m4 = 2 * vl_bf16_m2;

    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; k++) {
      __bf16 a = A[k];
      vbfloat16m4x2_t pair =
          __riscv_vlseg2e16_v_bf16m4x2(rhs_ptr, vl_bf16_m4);
      vbfloat16m4_t vb0 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 0);
      vbfloat16m4_t vb1 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 1);

      vacc0 = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a, vb0, vl_bf16_m4);
      vacc1 = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a, vb1, vl_bf16_m4);
      rhs_ptr += N;
    }

    vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
    vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c, vbf0, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c + vl_bf16_m4, vbf1, vl_bf16_m4);
    c += 2 * vl_bf16_m4;
  }
}

// Row-major segment-2 plus A-cache control. B uses the same per-row packing as
// rvv_gemv_1d_bf16_segment2, while A is copied to DTCM once. Comparing this
// target with the block-major combined target separates B layout effects from
// the repeated scalar-A load effect.
void rvv_gemv_1d_bf16_segment2_a_cache(const __bf16 *__restrict__ A,
                                       const __bf16 *__restrict__ B,
                                       __bf16 *__restrict__ C, int K, int N) {
  if ((N & 63) != 0 || K > 2048) {
    rvv_gemv_1d_bf16(A, B, C, K, N);
    return;
  }
  for (int k = 0; k < K; ++k) {
    rvv_gemv_a_cache[k] = A[k];
  }

  int c = 0;
  while (c < N) {
    size_t vl_bf16_m2 = __riscv_vsetvl_e16m2(16);
    size_t vl_bf16_m4 = 2 * vl_bf16_m2;
    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; ++k) {
      __bf16 a = rvv_gemv_a_cache[k];
      vbfloat16m4x2_t pair =
          __riscv_vlseg2e16_v_bf16m4x2(rhs_ptr, vl_bf16_m4);
      vbfloat16m4_t vb0 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 0);
      vbfloat16m4_t vb1 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 1);
      vacc0 = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a, vb0, vl_bf16_m4);
      vacc1 = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a, vb1, vl_bf16_m4);
      rhs_ptr += N;
    }

    vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
    vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c, vbf0, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c + vl_bf16_m4, vbf1, vl_bf16_m4);
    c += 2 * vl_bf16_m4;
  }
}

// Experimental block-major packed-weight schedule. The caller stores each
// 64-column block contiguously across K as
// [block][k][B[c + 0], B[c + 32], B[c + 1], B[c + 33], ...]. Unlike the
// segment2 schedule above, rhs_ptr advances by one 64-element block per k,
// so the inner loop walks sequential DDR addresses instead of jumping by N.
// This is a separate ABI: the input matrix must be packed with the matching
// block-major layout. Shapes not divisible by 64 use the baseline ABI/path.
void rvv_gemv_1d_bf16_block_segment2(const __bf16 *__restrict__ A,
                                     const __bf16 *__restrict__ B,
                                     __bf16 *__restrict__ C, int K, int N) {
  if ((N & 63) != 0) {
    rvv_gemv_1d_bf16(A, B, C, K, N);
    return;
  }

  int c = 0;
  while (c < N) {
    size_t vl_bf16_m2 = __riscv_vsetvl_e16m2(16);
    size_t vl_bf16_m4 = 2 * vl_bf16_m2;

    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

    // Each block owns K rows of 64 BF16 values in the packed matrix.
    const __bf16 *rhs_ptr = B + (c / 64) * K * 64;
    for (int k = 0; k < K; k++) {
      __bf16 a = A[k];
      vbfloat16m4x2_t pair =
          __riscv_vlseg2e16_v_bf16m4x2(rhs_ptr, vl_bf16_m4);
      vbfloat16m4_t vb0 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 0);
      vbfloat16m4_t vb1 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 1);

      vacc0 = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a, vb0, vl_bf16_m4);
      vacc1 = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a, vb1, vl_bf16_m4);
      rhs_ptr += 64;
    }

    vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
    vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c, vbf0, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c + vl_bf16_m4, vbf1, vl_bf16_m4);
    c += 2 * vl_bf16_m4;
  }
}

// A-cache experiment using the original row-major B ABI. A is copied once to
// DTCM, then reused for every output block. This isolates the cost of the
// repeated scalar A[k] DDR loads from the B/LSU schedule.
void rvv_gemv_1d_bf16_a_cache(const __bf16 *__restrict__ A,
                              const __bf16 *__restrict__ B,
                              __bf16 *__restrict__ C, int K, int N) {
  if (K > 2048) {
    rvv_gemv_1d_bf16(A, B, C, K, N);
    return;
  }
  for (int k = 0; k < K; ++k) {
    rvv_gemv_a_cache[k] = A[k];
  }

  int c = 0;
  while (c <= N - 64) {
    size_t vl_bf16_m2 = __riscv_vsetvl_e16m2(16);
    size_t vl_bf16_m4 = 2 * vl_bf16_m2;

    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; ++k) {
      __bf16 a          = rvv_gemv_a_cache[k];
      vbfloat16m4_t vb0 = __riscv_vle16_v_bf16m4(rhs_ptr, vl_bf16_m4);
      vacc0             = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a, vb0,
                                                        vl_bf16_m4);
      vbfloat16m4_t vb1 =
          __riscv_vle16_v_bf16m4(rhs_ptr + vl_bf16_m4, vl_bf16_m4);
      vacc1 = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a, vb1, vl_bf16_m4);
      rhs_ptr += N;
    }

    vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
    vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c, vbf0, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c + vl_bf16_m4, vbf1, vl_bf16_m4);
    c += 2 * vl_bf16_m4;
  }

  while (c < N) {
    size_t vl_bf16     = __riscv_vsetvl_e16m2(N - c);
    size_t vl_f32      = vl_bf16;
    vfloat32m4_t vacc0 = __riscv_vfmv_v_f_f32m4(0.0f, vl_f32);

    const __bf16 *rhs_ptr = B + c;
    for (int k = 0; k < K; ++k) {
      __bf16 a          = rvv_gemv_a_cache[k];
      vbfloat16m2_t vb0 = __riscv_vle16_v_bf16m2(rhs_ptr, vl_bf16);
      vacc0 = __riscv_vfwmaccbf16_vf_f32m4(vacc0, a, vb0, vl_bf16);
      rhs_ptr += N;
    }
    vbfloat16m2_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m2(vacc0, vl_f32);
    __riscv_vse16_v_bf16m2(C + c, vbf0, vl_bf16);
    c += vl_bf16;
  }
}

// Combined A-cache + block-major segment-2 experiment. This uses the same
// packed B ABI as rvv_gemv_1d_bf16_block_segment2 while also placing A in
// DTCM once per call, so it measures the maximum benefit of both software
// locality changes without altering the default path.
void rvv_gemv_1d_bf16_block_segment2_a_cache(
    const __bf16 *__restrict__ A, const __bf16 *__restrict__ B,
    __bf16 *__restrict__ C, int K, int N) {
  if ((N & 63) != 0 || K > 2048) {
    rvv_gemv_1d_bf16(A, B, C, K, N);
    return;
  }
  for (int k = 0; k < K; ++k) {
    rvv_gemv_a_cache[k] = A[k];
  }

  int c = 0;
  while (c < N) {
    size_t vl_bf16_m2 = __riscv_vsetvl_e16m2(16);
    size_t vl_bf16_m4 = 2 * vl_bf16_m2;
    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

    const __bf16 *rhs_ptr = B + (c / 64) * K * 64;
    for (int k = 0; k < K; ++k) {
      __bf16 a = rvv_gemv_a_cache[k];
      vbfloat16m4x2_t pair =
          __riscv_vlseg2e16_v_bf16m4x2(rhs_ptr, vl_bf16_m4);
      vbfloat16m4_t vb0 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 0);
      vbfloat16m4_t vb1 = __riscv_vget_v_bf16m4x2_bf16m4(pair, 1);
      vacc0 = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a, vb0, vl_bf16_m4);
      vacc1 = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a, vb1, vl_bf16_m4);
      rhs_ptr += 64;
    }

    vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
    vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c, vbf0, vl_bf16_m4);
    __riscv_vse16_v_bf16m4(C + c + vl_bf16_m4, vbf1, vl_bf16_m4);
    c += 2 * vl_bf16_m4;
  }
}

// 2D x 2D Prefill MatMul (Tiled MatMul for BFloat16 using 2x2 tiling)
void rvv_tiled_matmul_2d_bf16(const __bf16 *__restrict__ A, const __bf16 *__restrict__ B,
                              __bf16 *__restrict__ C, int M, int K, int N) {
  int m = 0;
  while (m <= M - 2) {
    int n = 0;
    // Main column loop for 32-column blocks (1 branch per iteration)
    while (n <= N - 32) {
      size_t vl_bf16_m4 = __riscv_vsetvl_e16m4(32);  // VLMAX m4 = 32

      vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);
      vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_bf16_m4);

      for (int k = 0; k < K; k++) {
        __bf16 a0 = A[(m + 0) * K + k];
        __bf16 a1 = A[(m + 1) * K + k];

        vbfloat16m4_t vb0 = __riscv_vle16_v_bf16m4(B + k * N + n, vl_bf16_m4);

        vacc0 = __riscv_vfwmaccbf16_vf_f32m8(vacc0, a0, vb0, vl_bf16_m4);
        vacc1 = __riscv_vfwmaccbf16_vf_f32m8(vacc1, a1, vb0, vl_bf16_m4);
      }

      vbfloat16m4_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc0, vl_bf16_m4);
      vbfloat16m4_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m4(vacc1, vl_bf16_m4);

      __riscv_vse16_v_bf16m4(C + (m + 0) * N + n, vbf0, vl_bf16_m4);
      __riscv_vse16_v_bf16m4(C + (m + 1) * N + n, vbf1, vl_bf16_m4);

      n += vl_bf16_m4;
    }

    // Tail columns for row pair
    while (n < N) {
      size_t vl_bf16     = __riscv_vsetvl_e16m2(N - n);
      size_t vl_f32      = vl_bf16;
      vfloat32m4_t vacc0 = __riscv_vfmv_v_f_f32m4(0.0f, vl_f32);
      vfloat32m4_t vacc1 = __riscv_vfmv_v_f_f32m4(0.0f, vl_f32);

      for (int k = 0; k < K; k++) {
        __bf16 a0        = A[(m + 0) * K + k];
        __bf16 a1        = A[(m + 1) * K + k];
        vbfloat16m2_t vb = __riscv_vle16_v_bf16m2(B + k * N + n, vl_bf16);
        vacc0            = __riscv_vfwmaccbf16_vf_f32m4(vacc0, a0, vb, vl_bf16);
        vacc1            = __riscv_vfwmaccbf16_vf_f32m4(vacc1, a1, vb, vl_bf16);
      }

      vbfloat16m2_t vbf0 = __riscv_vfncvtbf16_f_f_w_bf16m2(vacc0, vl_f32);
      vbfloat16m2_t vbf1 = __riscv_vfncvtbf16_f_f_w_bf16m2(vacc1, vl_f32);

      __riscv_vse16_v_bf16m2(C + (m + 0) * N + n, vbf0, vl_bf16);
      __riscv_vse16_v_bf16m2(C + (m + 1) * N + n, vbf1, vl_bf16);

      n += vl_bf16;
    }

    m += 2;
  }

  // Single tail row if M is odd
  while (m < M) {
    int c = 0;
    while (c < N) {
      size_t vl_bf16    = __riscv_vsetvl_e16m2(N - c);
      size_t vl_f32     = vl_bf16;
      vfloat32m4_t vacc = __riscv_vfmv_v_f_f32m4(0.0f, vl_f32);
      for (int k = 0; k < K; k++) {
        __bf16 a         = A[m * K + k];
        vbfloat16m2_t vb = __riscv_vle16_v_bf16m2(B + k * N + c, vl_bf16);
        vacc             = __riscv_vfwmaccbf16_vf_f32m4(vacc, a, vb, vl_bf16);
      }
      vbfloat16m2_t vbf = __riscv_vfncvtbf16_f_f_w_bf16m2(vacc, vl_f32);
      __riscv_vse16_v_bf16m2(C + m * N + c, vbf, vl_bf16);
      c += vl_bf16;
    }
    m++;
  }
}

}  // extern "C"
