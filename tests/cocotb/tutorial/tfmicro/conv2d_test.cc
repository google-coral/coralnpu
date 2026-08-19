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

#include "sw/opt/litert-micro/conv.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"

namespace {
constexpr size_t kMaxOutDepth   = 48;
constexpr size_t kMaxInDepth    = 48;
constexpr size_t kFilterBufSize = kMaxInDepth * 4 * 4 * kMaxOutDepth;
}  // namespace

static tflite::ConvParams params = {
    .padding_values =
        {
            .width  = 1,
            .height = 1,
        },
    // .stride_width filled in prep()
    // .stride_height filled in prep()
    .dilation_width_factor    = 1,
    .dilation_height_factor   = 1,
    .input_offset             = 128,
    .weights_offset           = 0,
    .output_offset            = -128,
    .quantized_activation_min = -128,
    .quantized_activation_max = 127,
};

static tflite::RuntimeShape input_shape_;
static tflite::RuntimeShape filter_shape_;
static tflite::RuntimeShape bias_shape_;
static tflite::RuntimeShape output_shape_;

// A patch of a node in hps
int32_t input_shape[4] __attribute__((section(".data")))  = {1, 32, 32, 16};
int32_t filter_shape[4] __attribute__((section(".data"))) = {16, 4, 4, 16};
int32_t bias_shape[1] __attribute__((section(".data")))   = {16};
int32_t output_shape[4] __attribute__((section(".data"))) = {1, 32, 32, 16};
int stride __attribute__((section(".data")))              = 1;

// Expecting weights to be in axi memory
int8_t filter_data[kFilterBufSize] __attribute__((section(".extdata"), aligned(16)));
int32_t bias_data[kMaxOutDepth] __attribute__((section(".extdata"), aligned(16)));

const int32_t output_multiplier[kMaxOutDepth] __attribute__((section(".rodata"), aligned(16))) = {
    1235840340, 1520469761, 1656859321, 1103093522, 1192854726, 1402908252, 1974709089, 2034447402,
    1915563165, 2014775867, 1508993251, 2121015926, 1271486218, 1606426928, 1085270251, 2108678555,
    1136288467, 1476413841, 1077808616, 1191061642, 1377805069, 1174791369, 1787043784, 1674404702,
    1426900540, 1546138407, 1380396539, 1702080653, 1121365462, 1144420619, 1122488162, 2145134492,
    1461154981, 1595052156, 1907144767, 1077003598, 1422688689, 1585130899, 1286683399, 1865152526,
    2139474298, 1527320570, 1511848683, 1287305898, 1644075469, 1597290527, 1482922030, 1820744170};

const int32_t output_shift[kMaxOutDepth] __attribute__((section(".rodata"), aligned(16))) = {
    -9, -9, -9, -8, -11, -9, -9, -10, -9,  -9, -8, -10, -9, -9, -8, -10,
    -8, -9, -8, -8, -8,  -9, -9, -9,  -9,  -8, -9, -9,  -8, -8, -9, -9,
    -9, -9, -9, -8, -9,  -9, -9, -9,  -10, -9, -8, -9,  -9, -9, -9, -9};
const int32_t bias[kMaxOutDepth] __attribute__((aligned(16))) = {
    1297, -845, -2096, -1360, -1355, -653, -396,  -1309, 399,  193,   766,        497,
    89,   -454, -417,  -1449, -363,  -95,  17,    -313,  510,  -233,  -241,       -463,
    568,  71,   186,   -1829, -108,  -226, -4205, 476,   -372, -1551, 1143 - 436, 185,
    170,  -268, -20,   -444,  -1136, -592, 697,   -848,  407,  -540,  -72};

// Expecting model arena to be in dtcm.
// Expecting model arena to be in dtcm.
int8_t input_data[32 * 32 * kMaxInDepth] __attribute__((section(".data"), aligned(16)));
int8_t output_data[32 * 32 * kMaxOutDepth] __attribute__((section(".data"), aligned(16)));

void prep() {
  input_shape_.ReplaceWith(4, input_shape);
  filter_shape_.ReplaceWith(4, filter_shape);
  bias_shape_.ReplaceWith(1, bias_shape);
  output_shape_.ReplaceWith(4, output_shape);
  params.stride_width  = stride;
  params.stride_height = stride;
}

extern "C" {
__attribute__((used, retain)) void run_ref() {
  tflite::reference_integer_ops::ConvPerChannel(
      params, output_multiplier, output_shift, input_shape_, input_data, filter_shape_, filter_data,
      bias_shape_, bias_data, output_shape_, output_data);
}
// Dummy context and data for standalone test
static TfLiteContext dummy_context;
static coralnpu_v2::opt::litert_micro::OpDataConvCustom dummy_data;

// Simple scratch buffer for testing
// Use kMaxOutDepth (48) to allow testing larger output depths without overflow
// Moving to .extdata to avoid overflowing DTCM (1MB)
static int32_t scratch_buf[120 * 160 * kMaxOutDepth]
    __attribute__((section(".extdata"), aligned(16)));
static void *GetScratchBuffer(TfLiteContext *ctx, int idx) { return scratch_buf; }

__attribute__((used, retain)) void run_opt() {
  if (dummy_context.GetScratchBuffer == nullptr) {
    dummy_context.GetScratchBuffer = GetScratchBuffer;
  }
  coralnpu_v2::opt::litert_micro::ConvPerChannel(
      params, dummy_data, output_multiplier, output_shift, &dummy_context, input_shape_, input_data,
      filter_shape_, filter_data, bias_shape_, bias_data, output_shape_, output_data);
}
}

void (*impl)() __attribute__((section(".data"))) = run_opt;

int main(void) {
  prep();
  impl();
  return 0;
}
