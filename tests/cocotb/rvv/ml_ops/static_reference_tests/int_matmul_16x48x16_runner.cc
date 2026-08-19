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

// Fully frozen dimensions
constexpr size_t kLhsRows = 16;
constexpr size_t kRhsCols = 16;
constexpr size_t kInner   = 48;

extern "C" {
// Statically compiled dimensions (not writable or configurable at runtime)
const uint32_t lhs_rows           = kLhsRows;
const uint32_t rhs_cols           = kRhsCols;
const uint32_t inner              = kInner;
volatile uint32_t csr_cycle_count = 0;
}

// Statically allocated and padded buffers
int8_t lhs_input[kLhsRows * kInner] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));
int8_t rhs_input[kInner * kRhsCols] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));
int32_t result_output[kLhsRows * kRhsCols] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));

extern "C" void MatMul(size_t lhs_rows, size_t inner, size_t rhs_cols, const int8_t *lhs,
                       const int8_t *rhs, int32_t *result);

int main() {
  // Flag start of power-critical section (write to mcontext0)
  uint32_t mcontext0_write_value = 1;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  cycle_counter_reset();
  uint64_t start_cycles = mcycle_read();

  MatMul(lhs_rows, inner, rhs_cols, lhs_input, rhs_input, result_output);

  uint64_t end_cycles = mcycle_read();
  csr_cycle_count     = static_cast<uint32_t>(end_cycles - start_cycles);

  // Flag end of power-critical section (write to mcontext0)
  mcontext0_write_value = 0;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  return 0;
}
