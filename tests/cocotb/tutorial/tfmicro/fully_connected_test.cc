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

#include "sw/opt/litert-micro/fully_connected.h"

#include <cstdint>

#include "sw/utils/utils.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/fully_connected.h"

namespace {
constexpr size_t kMaxDepth = 1024;
}  // namespace

static tflite::FullyConnectedParams params = {
    .input_offset             = 0,
    .weights_offset           = 0,
    .output_offset            = 0,
    .output_multiplier        = 1073741824,  // 0.5 in Q31
    .output_shift             = -1,
    .quantized_activation_min = -128,
    .quantized_activation_max = 127,
};

static tflite::RuntimeShape input_shape_;
static tflite::RuntimeShape filter_shape_;
static tflite::RuntimeShape bias_shape_;
static tflite::RuntimeShape output_shape_;

extern "C" {
int32_t input_offset __attribute__((section(".data")));
int32_t filter_offset __attribute__((section(".data")));
int32_t output_offset __attribute__((section(".data")));
int32_t output_multiplier __attribute__((section(".data")));
int32_t output_shift __attribute__((section(".data")));
int32_t activation_min __attribute__((section(".data")));
int32_t activation_max __attribute__((section(".data")));

int32_t input_dims[4] __attribute__((section(".data")));
int32_t filter_dims[4] __attribute__((section(".data")));
int32_t bias_dims[4] __attribute__((section(".data")));
int32_t output_dims[4] __attribute__((section(".data")));

int8_t input_data[131072] __attribute__((section(".data"), aligned(16)));
int8_t filter_data[131072] __attribute__((section(".data"), aligned(16)));
int32_t bias_data[1024] __attribute__((section(".data"), aligned(16)));
int8_t output_data[131072] __attribute__((section(".data"), aligned(16)));

uint64_t ref_cycles __attribute__((section(".data")));
uint64_t opt_cycles __attribute__((section(".data")));

void prep() {
  params.input_offset             = input_offset;
  params.weights_offset           = filter_offset;
  params.output_offset            = output_offset;
  params.output_multiplier        = output_multiplier;
  params.output_shift             = output_shift;
  params.quantized_activation_min = activation_min;
  params.quantized_activation_max = activation_max;

  input_shape_.ReplaceWith(4, input_dims);
  filter_shape_.ReplaceWith(4, filter_dims);
  bias_shape_.ReplaceWith(1, bias_dims);
  output_shape_.ReplaceWith(4, output_dims);
}

__attribute__((used, retain)) void run_ref() {
  uint64_t start = mcycle_read();
  tflite::reference_integer_ops::FullyConnected(params, input_shape_, input_data, filter_shape_,
                                                filter_data, bias_shape_, bias_data, output_shape_,
                                                output_data);
  ref_cycles = mcycle_read() - start;
}

__attribute__((used, retain)) void run_optimized() {
  uint64_t start = mcycle_read();
  coralnpu_v2::opt::litert_micro::FullyConnected(params, input_shape_, input_data, filter_shape_,
                                                 filter_data, bias_shape_, bias_data, output_shape_,
                                                 output_data);
  opt_cycles = mcycle_read() - start;
}
void (*impl)() __attribute__((section(".data"))) = run_optimized;

int main(void) {
  prep();
  impl();
  return 0;
}
}
