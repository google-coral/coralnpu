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

#include <stddef.h>
#include <stdint.h>

#include "sw/utils/utils.h"

extern "C" {
void rvv_tiled_matmul_2d_bf16(const __bf16 *__restrict__ A, const __bf16 *__restrict__ B,
                              __bf16 *__restrict__ C, int M, int K, int N);
void rvv_gemv_1d_bf16(const __bf16 *__restrict__ A, const __bf16 *__restrict__ B,
                      __bf16 *__restrict__ C, int K, int N);
#ifdef RVV_BF16_GEMV_PAIR_LOADS
void rvv_gemv_1d_bf16_pair_loads(const __bf16 *__restrict__ A,
                                 const __bf16 *__restrict__ B,
                                 __bf16 *__restrict__ C, int K, int N);
#endif
#ifdef RVV_BF16_GEMV_SEG2_LOADS
void rvv_gemv_1d_bf16_segment2(const __bf16 *__restrict__ A,
                                const __bf16 *__restrict__ B,
                                __bf16 *__restrict__ C, int K, int N);
#endif
#ifdef RVV_BF16_GEMV_BLOCK_SEG2_LOADS
void rvv_gemv_1d_bf16_block_segment2(const __bf16 *__restrict__ A,
                                      const __bf16 *__restrict__ B,
                                      __bf16 *__restrict__ C, int K, int N);
#endif
#ifdef RVV_BF16_GEMV_A_CACHE
void rvv_gemv_1d_bf16_a_cache(const __bf16 *__restrict__ A,
                              const __bf16 *__restrict__ B,
                              __bf16 *__restrict__ C, int K, int N);
#endif
#ifdef RVV_BF16_GEMV_BLOCK_SEG2_A_CACHE
void rvv_gemv_1d_bf16_block_segment2_a_cache(
    const __bf16 *__restrict__ A, const __bf16 *__restrict__ B,
    __bf16 *__restrict__ C, int K, int N);
#endif
#ifdef RVV_BF16_GEMV_SEG2_A_CACHE
void rvv_gemv_1d_bf16_segment2_a_cache(const __bf16 *__restrict__ A,
                                       const __bf16 *__restrict__ B,
                                       __bf16 *__restrict__ C, int K, int N);
#endif
}

// 覆盖 Gemma 3 270M Decoder Layer 的最大 MLP 投影形状：
// 1x2048 乘 2048x640，以及 1x640 乘 640x2048。
#define MAX_M 256
#define MAX_K 2048
#define MAX_N 2048

extern "C" {
// Inputs in ExtMem (.ddr_data)
__bf16 lhs_input[MAX_M * MAX_K] __attribute__((section(".ddr_data"), used, retain, aligned(16)));

__bf16 rhs_input[MAX_K * MAX_N] __attribute__((section(".ddr_data"), used, retain, aligned(16)));

__bf16 result_output[MAX_M * MAX_N]
    __attribute__((section(".ddr_data"), used, retain, aligned(16)));

uint32_t active_m __attribute__((section(".data"), used, retain));
uint32_t active_k __attribute__((section(".data"), used, retain));
uint32_t active_n __attribute__((section(".data"), used, retain));

uint32_t cycle_count __attribute__((section(".data"), used, retain));
}

int main() {
  uint32_t start_cycles = mcycle_read();

  if (active_m == 1) {
#ifdef RVV_BF16_GEMV_PAIR_LOADS
    rvv_gemv_1d_bf16_pair_loads(lhs_input, rhs_input, result_output, active_k,
                                 active_n);
#elif defined(RVV_BF16_GEMV_SEG2_LOADS)
    rvv_gemv_1d_bf16_segment2(lhs_input, rhs_input, result_output, active_k,
                               active_n);
#elif defined(RVV_BF16_GEMV_BLOCK_SEG2_LOADS)
    rvv_gemv_1d_bf16_block_segment2(lhs_input, rhs_input, result_output,
                                    active_k, active_n);
#elif defined(RVV_BF16_GEMV_A_CACHE)
    rvv_gemv_1d_bf16_a_cache(lhs_input, rhs_input, result_output, active_k,
                              active_n);
#elif defined(RVV_BF16_GEMV_BLOCK_SEG2_A_CACHE)
    rvv_gemv_1d_bf16_block_segment2_a_cache(
        lhs_input, rhs_input, result_output, active_k, active_n);
#elif defined(RVV_BF16_GEMV_SEG2_A_CACHE)
    rvv_gemv_1d_bf16_segment2_a_cache(lhs_input, rhs_input, result_output,
                                       active_k, active_n);
#else
    rvv_gemv_1d_bf16(lhs_input, rhs_input, result_output, active_k, active_n);
#endif
  } else {
    rvv_tiled_matmul_2d_bf16(lhs_input, rhs_input, result_output, active_m, active_k, active_n);
  }

  uint32_t end_cycles = mcycle_read();
  cycle_count         = end_cycles - start_cycles;

  return 0;
}
