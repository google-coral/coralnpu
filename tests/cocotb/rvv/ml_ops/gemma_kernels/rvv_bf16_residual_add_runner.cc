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

#include <cstddef>
#include <cstdint>

#include "sw/utils/utils.h"

extern "C" {
void rvv_residual_add_bf16(const __bf16 *A, const __bf16 *B, __bf16 *Y, size_t total_elements);

#define MAX_ELEMENTS (16 * 1024)

__bf16 A[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
__bf16 B[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
__bf16 Y[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));

uint32_t active_elements __attribute__((section(".data"), used, retain));
uint32_t cycle_count __attribute__((section(".data"), used, retain));
}

int main() {
  uint32_t elements = active_elements;
  if (elements > MAX_ELEMENTS) {
    elements = MAX_ELEMENTS;
  }

  uint64_t start = mcycle_read();
  rvv_residual_add_bf16(A, B, Y, elements);
  uint64_t end = mcycle_read();

  cycle_count = (uint32_t)(end - start);
  return 0;
}
