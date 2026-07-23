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

// Max sizes for allocation (supports up to 128x512x128 and 12x640x512)
#define MAX_M 128
#define MAX_K 640
#define MAX_N 512

extern "C" {
void rvv_gemv_int8(const int8_t *__restrict__ A, const int8_t *__restrict__ B,
                   int32_t *__restrict__ C, size_t K, size_t N);
void rvv_matmul_int8(const int8_t *__restrict__ A, const int8_t *__restrict__ B,
                     int32_t *__restrict__ C, int M, int K, int N);

int8_t lhs_input[MAX_M * MAX_K] __attribute__((aligned(16), section(".data")));
int8_t rhs_input[MAX_K * MAX_N] __attribute__((aligned(16), section(".data")));
int32_t result_output[MAX_M * MAX_N] __attribute__((aligned(16), section(".data")));

size_t active_m __attribute__((section(".data")));
size_t active_k __attribute__((section(".data")));
size_t active_n __attribute__((section(".data")));

uint32_t cycle_count __attribute__((section(".data")));
}

int main() {
  uint32_t start_cycles = mcycle_read();

  if (active_m == 1) {
    rvv_gemv_int8(lhs_input, rhs_input, result_output, active_k, active_n);
  } else {
    rvv_matmul_int8(lhs_input, rhs_input, result_output, active_m, active_k, active_n);
  }

  uint32_t end_cycles = mcycle_read();
  cycle_count         = end_cycles - start_cycles;

  return 0;
}
