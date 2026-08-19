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

#include "sw/opt/litert-micro/logistic.h"

#include <cstdint>

#include "sw/utils/utils.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/logistic.h"

extern "C" {
int32_t input_zero_point __attribute__((section(".data")));
int32_t input_range_radius __attribute__((section(".data")));
int32_t input_multiplier __attribute__((section(".data")));
int32_t input_left_shift __attribute__((section(".data")));
int32_t input_size __attribute__((section(".data")));

int8_t input_data[1024] __attribute__((section(".data"), aligned(16)));
int8_t output_data[1024] __attribute__((section(".data"), aligned(16)));

uint64_t ref_cycles __attribute__((section(".data")));
uint64_t opt_cycles __attribute__((section(".data")));

uint32_t debug_val __attribute__((section(".data")));
int8_t debug_lut[256] __attribute__((section(".data")));

__attribute__((used, retain)) void run_ref() {
  uint64_t start = mcycle_read();
  tflite::reference_integer_ops::Logistic(input_zero_point, input_range_radius, input_multiplier,
                                          input_left_shift, input_size, input_data, output_data);
  ref_cycles = mcycle_read() - start;
}

__attribute__((used, retain)) void run_optimized() {
  uint64_t start = mcycle_read();
  coralnpu_v2::opt::litert_micro::Logistic(input_zero_point, input_range_radius, input_multiplier,
                                           input_left_shift, input_size, input_data, output_data);
  opt_cycles = mcycle_read() - start;
}

__attribute__((used, retain)) void run_init() {
  coralnpu_v2::opt::litert_micro::LogisticInit(input_zero_point, input_range_radius,
                                               input_multiplier, input_left_shift);
}

void (*impl)() __attribute__((section(".data"))) = run_optimized;

int main(void) {
  impl();
  return 0;
}
}
