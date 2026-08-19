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
void rvv_residual_add_f32(const float *A, const float *B, float *Y, size_t total_elements);

#define MAX_ELEMENTS (256 * 640)

float A[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
float B[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
float Y[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));

uint32_t active_elements __attribute__((section(".data"), used, retain));
uint32_t cycle_count __attribute__((section(".data"), used, retain));
}

int main() {
  uint32_t start_cycles = mcycle_read();

  rvv_residual_add_f32(A, B, Y, active_elements);

  uint32_t end_cycles = mcycle_read();
  cycle_count         = end_cycles - start_cycles;

  return 0;
}
