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

#ifndef SW_OPT_LITERT_MICRO_DEPTHWISE_CONV_H_
#define SW_OPT_LITERT_MICRO_DEPTHWISE_CONV_H_

#include "tensorflow/lite/micro/kernels/depthwise_conv.h"

namespace coralnpu_v2::opt::litert_micro {
void DepthwiseConvPerChannel(const tflite::DepthwiseParams &params,
                             const int32_t *output_multiplier, const int32_t *output_shift,
                             const tflite::RuntimeShape &in_shape, const int8_t *in_data,
                             const tflite::RuntimeShape &f_shape, const int8_t *f_data,
                             const tflite::RuntimeShape &bias_shape, const int32_t *bias_data,
                             const tflite::RuntimeShape &out_shape, int8_t *out_data,
                             int32_t *accs_buf);

TFLMRegistration Register_DEPTHWISE_CONV_2D();
}  // namespace coralnpu_v2::opt::litert_micro

#endif  // SW_OPT_LITERT_MICRO_DEPTHWISE_CONV_H_
