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

constexpr size_t kMaxLhsRows = 32;
constexpr size_t kMaxRhsCols = 32;
constexpr size_t kMaxInner   = 128;

extern "C" {
volatile uint32_t lhs_rows        = 32;
volatile uint32_t rhs_cols        = 32;
volatile uint32_t inner           = 128;
volatile uint32_t csr_cycle_count = 0;
}

// mcontext0 val used in test for power period extraction
uint32_t mcontext0_write_value;

int8_t lhs_input[kMaxLhsRows * kMaxInner] __attribute__((section(".data")))
__attribute__((aligned(16)));
int8_t rhs_input[kMaxInner * kMaxRhsCols] __attribute__((section(".data")))
__attribute__((aligned(16)));
int32_t result_output[kMaxLhsRows * kMaxRhsCols] __attribute__((section(".data")))
__attribute__((aligned(16)));

extern "C" void MatMul(size_t lhs_rows, size_t inner, size_t rhs_cols, const int8_t *lhs,
                       const int8_t *rhs, int32_t *result);

int main() {
  mcontext0_write_value = 0x01;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));
  cycle_counter_reset();
  uint64_t start_cycles = mcycle_read();
  MatMul(lhs_rows, inner, rhs_cols, lhs_input, rhs_input, result_output);
  uint64_t end_cycles   = mcycle_read();
  csr_cycle_count       = static_cast<uint32_t>(end_cycles - start_cycles);
  mcontext0_write_value = 0x00;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));
  return 0;
}
