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

#ifndef SW_OPT_LITERT_MICRO_LOGISTIC_H_
#define SW_OPT_LITERT_MICRO_LOGISTIC_H_

#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/micro/kernels/logistic.h"
#include "tensorflow/lite/micro/micro_common.h"

namespace coralnpu_v2::opt::litert_micro {

void LogisticInit(int32_t input_zero_point, int32_t input_range_radius, int32_t input_multiplier,
                  int32_t input_left_shift);

void Logistic(int32_t input_zero_point, int32_t input_range_radius, int32_t input_multiplier,
              int32_t input_left_shift, int32_t input_size, const int8_t *input_data,
              int8_t *output_data);

TFLMRegistration Register_LOGISTIC();

}  // namespace coralnpu_v2::opt::litert_micro

#endif  // SW_OPT_LITERT_MICRO_LOGISTIC_H_
