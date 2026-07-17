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
}

// Max sizes for allocation (supports up to 128x512x128 and 12x640x512)
#define MAX_M 128
#define MAX_K 640
#define MAX_N 512

extern "C" {
// Inputs in ExtMem (.ddr_data)
uint16_t lhs_input[MAX_M * MAX_K] __attribute__((section(".ddr_data")))
__attribute__((aligned(16)));

uint16_t rhs_input[MAX_K * MAX_N] __attribute__((section(".ddr_data")))
__attribute__((aligned(16)));

uint16_t result_output[MAX_M * MAX_N] __attribute__((section(".ddr_data")))
__attribute__((aligned(16)));

volatile uint32_t active_m __attribute__((section(".data")));
volatile uint32_t active_k __attribute__((section(".data")));
volatile uint32_t active_n __attribute__((section(".data")));

volatile uint32_t cycle_count __attribute__((section(".data")));
}

int main() {
  uint32_t start_cycles = mcycle_read();

  if (active_m == 1) {
    rvv_gemv_1d_bf16((const __bf16 *)lhs_input, (const __bf16 *)rhs_input, (__bf16 *)result_output,
                     active_k, active_n);
  } else {
    rvv_tiled_matmul_2d_bf16((const __bf16 *)lhs_input, (const __bf16 *)rhs_input,
                             (__bf16 *)result_output, active_m, active_k, active_n);
  }

  uint32_t end_cycles = mcycle_read();
  cycle_count         = end_cycles - start_cycles;

  return 0;
}
