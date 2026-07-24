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

#include <riscv_vector.h>

#include <algorithm>
#include <cstdint>

#include "tensorflow/lite/kernels/internal/reference/integer_ops/logistic.h"
#include "tensorflow/lite/kernels/internal/tensor_ctypes.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/logistic.h"
#include "tensorflow/lite/micro/kernels/micro_ops.h"

namespace coralnpu_v2::opt::litert_micro {

namespace {
static int8_t lut[256];
static bool lut_initialized = false;
}  // namespace

void LogisticInit(int32_t input_zero_point, int32_t input_range_radius, int32_t input_multiplier,
                  int32_t input_left_shift) {
  for (int i = 0; i < 256; ++i) {
    int8_t input_val = static_cast<int8_t>(i);
    tflite::reference_integer_ops::Logistic(input_zero_point, input_range_radius, input_multiplier,
                                            input_left_shift, 1, &input_val, &lut[i]);
  }
  lut_initialized = true;
}

void Logistic(int32_t input_zero_point, int32_t input_range_radius, int32_t input_multiplier,
              int32_t input_left_shift, int32_t input_size, const int8_t *input_data,
              int8_t *output_data) {
  if (!lut_initialized && input_size > 0) {
    LogisticInit(input_zero_point, input_range_radius, input_multiplier, input_left_shift);
  }

  if (input_size <= 0)
    return;

  // CoralNPU VLEN=128, SEW=8, LMUL=8 -> VLMAX=128.
  size_t vlmax     = __riscv_vsetvlmax_e8m8();
  vint8m8_t lut0_v = __riscv_vle8_v_i8m8(lut, vlmax);
  vint8m8_t lut1_v = __riscv_vle8_v_i8m8(lut + 128, vlmax);

  int i     = 0;
  int n_rem = input_size;

  while (n_rem > 0) {
    size_t vl      = __riscv_vsetvl_e8m8(n_rem);
    vint8m8_t in_v = __riscv_vle8_v_i8m8(&input_data[i], vl);

    vuint8m8_t idx_v = __riscv_vreinterpret_v_i8m8_u8m8(in_v);

    // Mask for elements that index into the second half of the LUT (128-255)
    vbool1_t mask1 = __riscv_vmsgeu_vx_u8m8_b1(idx_v, 128, vl);

    // Gather from first half (indices 0-127)
    vint8m8_t out_v = __riscv_vrgather_vv_i8m8(lut0_v, idx_v, vl);

    // Gather from second half (indices 128-255)
    // Subtract 128 to get relative index [0-127]
    vuint8m8_t idx1_v = __riscv_vsub_vx_u8m8(idx_v, 128, vl);
    vint8m8_t res1_v  = __riscv_vrgather_vv_i8m8(lut1_v, idx1_v, vl);

    // Select result based on high bit of index
    out_v = __riscv_vmerge_vvm_i8m8(out_v, res1_v, mask1, vl);

    __riscv_vse8_v_i8m8(&output_data[i], out_v, vl);

    i += vl;
    n_rem -= vl;
  }
}

namespace {
TfLiteStatus LogisticEval(TfLiteContext *context, TfLiteNode *node) {
  const TfLiteEvalTensor *input =
      tflite::micro::GetEvalInput(context, node, tflite::kLogisticInputTensor);
  TfLiteEvalTensor *output =
      tflite::micro::GetEvalOutput(context, node, tflite::kLogisticOutputTensor);

  TFLITE_DCHECK(node->user_data != nullptr);
  auto *data = static_cast<tflite::OpDataLogistic *>(node->user_data);

  if (input->type == kTfLiteInt8 && output->type == kTfLiteInt8) {
    Logistic(data->input_zero_point, data->input_range_radius, data->input_multiplier,
             data->input_left_shift,
             static_cast<int32_t>(tflite::micro::GetTensorShape(input).FlatSize()),
             tflite::micro::GetTensorData<int8_t>(input),
             tflite::micro::GetTensorData<int8_t>(output));
    return kTfLiteOk;
  }

  return tflite::Register_LOGISTIC().invoke(context, node);
}
}  // namespace

TFLMRegistration Register_LOGISTIC() {
  auto registration   = tflite::Register_LOGISTIC();
  registration.invoke = LogisticEval;
  return registration;
}

}  // namespace coralnpu_v2::opt::litert_micro
