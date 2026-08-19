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

#include "sw/opt/litert-micro/pooling.h"

#include <cstdint>

#include "sw/utils/utils.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/pooling.h"

namespace {
constexpr size_t kMaxOutDepth = 256;
}  // namespace

static tflite::PoolParams params = {
    .padding_values =
        {
            .width  = 0,
            .height = 0,
        },
    .stride_height            = 2,
    .stride_width             = 2,
    .filter_height            = 2,
    .filter_width             = 2,
    .quantized_activation_min = -128,
    .quantized_activation_max = 127,
};

static tflite::RuntimeShape input_shape_;
static tflite::RuntimeShape output_shape_;

int32_t input_shape[4] __attribute__((section(".data")))  = {1, 8, 8, 16};
int32_t output_shape[4] __attribute__((section(".data"))) = {1, 4, 4, 16};
int stride __attribute__((section(".data")))              = 2;
int filter_size __attribute__((section(".data")))         = 2;

int8_t input_data[131072] __attribute__((section(".data"), aligned(16)));
int8_t output_data[131072] __attribute__((section(".data"), aligned(16)));

uint64_t ref_cycles __attribute__((section(".data")));
uint64_t opt_cycles __attribute__((section(".data")));

void prep() {
  input_shape_.ReplaceWith(4, input_shape);
  output_shape_.ReplaceWith(4, output_shape);
  params.stride_height = stride;
  params.stride_width  = stride;
  params.filter_height = filter_size;
  params.filter_width  = filter_size;
}

extern "C" {
__attribute__((used, retain)) void run_ref() {
  uint64_t start = mcycle_read();
  tflite::reference_integer_ops::MaxPool(params, input_shape_, input_data, output_shape_,
                                         output_data);
  ref_cycles = mcycle_read() - start;
}

__attribute__((used, retain)) void run_optimized() {
  uint64_t start = mcycle_read();
  coralnpu_v2::opt::litert_micro::MaxPool(params, input_shape_, input_data, output_shape_,
                                          output_data);
  opt_cycles = mcycle_read() - start;
}
}

void (*impl)() __attribute__((section(".data"))) = run_optimized;

int main(void) {
  prep();
  impl();
  return 0;
}
