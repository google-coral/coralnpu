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

#include "sw/utils/utils.h"

extern "C" void rvv_tanh_gelu_mul_f32(const float *gate, const float *up, float *output,
                                      size_t total_elements);

#define MAX_ELEMENTS (256 * 2048)

float Gate[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
float Up[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
float Output[MAX_ELEMENTS] __attribute__((section(".ddr_data"), used, retain, aligned(16)));

uint32_t active_elements __attribute__((section(".data"), used, retain)) = 1;
uint32_t cycle_count __attribute__((section(".data"), used, retain))     = 0;

int main() {
  uint32_t elements = active_elements;
  if (elements > MAX_ELEMENTS) {
    elements = MAX_ELEMENTS;
  }

  uint64_t start = mcycle_read();
  rvv_tanh_gelu_mul_f32(Gate, Up, Output, elements);
  uint64_t end = mcycle_read();

  cycle_count = (uint32_t)(end - start);
  return 0;
}
