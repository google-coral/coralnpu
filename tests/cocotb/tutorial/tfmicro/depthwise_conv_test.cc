// Copyright 2025 Google LLC
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

#include "sw/opt/litert-micro/depthwise_conv.h"

#include <cstdint>

#include "tensorflow/lite/kernels/internal/reference/integer_ops/depthwise_conv.h"

namespace {
constexpr size_t kMaxOutDepth   = 256;
constexpr size_t kFilterBufSize = 3 * 3 * kMaxOutDepth;
}  // namespace

static tflite::DepthwiseParams params = {
    .padding_values =
        {
            .width  = 1,
            .height = 1,
        },
    // .stride_width filled in prep()
    // .stride_height filled in prep()
    // TODO(davidgao): cover this in another test?
    .dilation_width_factor  = 1,
    .dilation_height_factor = 1,
    // .depth_multiplier filled in prep()
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

// A patch of a node in mobilenet v1
int32_t input_shape[4] __attribute__((section(".data")))  = {1, 8, 8, 16};
int32_t filter_shape[4] __attribute__((section(".data"))) = {1, 3, 3, 32};
int32_t bias_shape[1] __attribute__((section(".data")))   = {32};
int32_t output_shape[4] __attribute__((section(".data"))) = {1, 4, 4, 32};
int stride __attribute__((section(".data")))              = 2;
int dm __attribute__((section(".data")))                  = 2;

// Expecting weights to be in axi memory
int8_t filter_data[kFilterBufSize] __attribute__((section(".extdata"), aligned(16)));
int32_t bias_data[kMaxOutDepth] __attribute__((section(".extdata"), aligned(16)));

// Expecting quantization parameters to be in tensor arena (dtcm)
// Taken from a node in mobilenet v1, duplicated 8 times
const int32_t output_multiplier[kMaxOutDepth] __attribute__((aligned(16))) = {
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
    1215836872, 1185328645, 2021922132, 1293877495, 1998015473, 1311410766, 1264495606, 1275161392,
    1117173051, 1337281014, 1333632221, 1344518575, 2123709422, 1204213014, 2004037101, 1403589537,
    1353512509, 1184963313, 1213021689, 1414462760, 1222505637, 1256031519, 1133123072, 1150781908,
    1255231012, 1152753331, 1238298425, 1294933879, 1111570159, 1309309916, 1251381292, 1218702370,
};
const int32_t output_shift[kMaxOutDepth] __attribute__((aligned(16))) = {
    -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -7, -7,
    -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7,
    -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7,
    -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7,
    -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -7, -7,
    -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7,
    -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7,
    -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7,
    -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -7, -7,
    -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7, -7, -7, -7, -7, -7, -7, -8, -7, -8, -7,
    -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7, -7,
};

// Expecting model arena to be in dtcm.
int8_t input_data[131072] __attribute__((section(".data"), aligned(16)));
int8_t output_data[131072] __attribute__((section(".data"), aligned(16)));

void prep() {
  input_shape_.ReplaceWith(4, input_shape);
  filter_shape_.ReplaceWith(4, filter_shape);
  bias_shape_.ReplaceWith(1, bias_shape);
  output_shape_.ReplaceWith(4, output_shape);
  params.stride_width     = stride;
  params.stride_height    = stride;
  params.depth_multiplier = dm;
}

extern "C" {
__attribute__((used, retain)) void run_ref() {
  tflite::reference_integer_ops::DepthwiseConvPerChannel(
      params, output_multiplier, output_shift, input_shape_, input_data, filter_shape_, filter_data,
      bias_shape_, bias_data, output_shape_, output_data);
}

// Simple scratch buffer for testing
// Moving to .extdata to avoid overflowing DTCM
static int32_t scratch_buf[32768] __attribute__((section(".extdata"), aligned(16)));

__attribute__((used, retain)) void run_optimized() {
  coralnpu_v2::opt::litert_micro::DepthwiseConvPerChannel(
      params, output_multiplier, output_shift, input_shape_, input_data, filter_shape_, filter_data,
      bias_shape_, bias_data, output_shape_, output_data, scratch_buf);
}
}

void (*impl)() __attribute__((section(".data"))) = run_optimized;

int main(void) {
  prep();
  impl();
  return 0;
}
