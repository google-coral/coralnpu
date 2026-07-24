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

#ifndef SW_OPT_LITERT_MICRO_CONV_H_
#define SW_OPT_LITERT_MICRO_CONV_H_

#include "sw/opt/litert-micro/memory_util.h"
#include "tensorflow/lite/micro/kernels/conv.h"

namespace coralnpu_v2::opt::litert_micro {

void ConvPerChannel(const tflite::ConvParams &params, const OpDataConvCustom &data,
                    const int32_t *output_multiplier, const int32_t *output_shift,
                    TfLiteContext *context, const tflite::RuntimeShape &input_shape,
                    const int8_t *input_data, const tflite::RuntimeShape &filter_shape,
                    const int8_t *filter_data, const tflite::RuntimeShape &bias_shape,
                    const int32_t *bias_data, const tflite::RuntimeShape &output_shape,
                    int8_t *output_data);

TFLMRegistration Register_CONV_2D();

void RepackWeightsD48(const int8_t *__restrict src, int16_t *__restrict dst,
                      int32_t *__restrict weight_sums, int output_depth, int filter_height,
                      int filter_width, int input_depth);
}  // namespace coralnpu_v2::opt::litert_micro

#endif  // SW_OPT_LITERT_MICRO_CONV_H_
