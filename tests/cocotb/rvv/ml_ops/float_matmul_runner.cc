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

#include <cstdint>

#include "sw/utils/utils.h"

constexpr size_t kMaxLhsRows = 16;
constexpr size_t kMaxRhsCols = 16;
constexpr size_t kMaxInner   = 48;

extern "C" {
volatile uint32_t lhs_rows        = 16;
volatile uint32_t rhs_cols        = 16;
volatile uint32_t inner           = 48;
volatile uint32_t csr_cycle_count = 0;
}

// mcontext0 val used in test for power period extraction
uint32_t mcontext0_write_value;

float lhs_input[kMaxLhsRows * kMaxInner] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));
float rhs_input[kMaxInner * kMaxRhsCols] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));
float result_output[kMaxLhsRows * kMaxRhsCols] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));

extern "C" void MatMulF(size_t lhs_rows, size_t inner, size_t rhs_cols, const float *lhs,
                        const float *rhs, float *result);

int main(int argc, char **argv) {
  uint32_t mcontext0_write_value = 1;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  cycle_counter_reset();
  uint64_t start_cycles = mcycle_read();
  MatMulF(lhs_rows, inner, rhs_cols, lhs_input, rhs_input, result_output);
  uint64_t end_cycles = mcycle_read();
  csr_cycle_count     = static_cast<uint32_t>(end_cycles - start_cycles);

  mcontext0_write_value = 0;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  return 0;
}
