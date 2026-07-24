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

#include <riscv_vector.h>

#include <algorithm>
#include <cstdint>

#include "sw/opt/litert-micro/accumulator_util.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/fully_connected.h"
#include "tensorflow/lite/kernels/internal/tensor_ctypes.h"
#include "tensorflow/lite/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"

namespace coralnpu_v2::opt::litert_micro {

void FullyConnected(const tflite::FullyConnectedParams &params,
                    const tflite::RuntimeShape &input_shape, const int8_t *input_data,
                    const tflite::RuntimeShape &filter_shape, const int8_t *filter_data,
                    const tflite::RuntimeShape &bias_shape, const int32_t *bias_data,
                    const tflite::RuntimeShape &output_shape, int8_t *output_data) {
  const int32_t input_offset          = params.input_offset;
  const int32_t filter_offset         = params.weights_offset;
  const int32_t output_offset         = params.output_offset;
  const int32_t output_multiplier     = params.output_multiplier;
  const int output_shift              = params.output_shift;
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  const int batches = tflite::FlatSizeSkipDim(output_shape, output_shape.DimensionsCount() - 1);
  const int output_depth = output_shape.Dims(output_shape.DimensionsCount() - 1);
  const int accum_depth  = filter_shape.Dims(filter_shape.DimensionsCount() - 1);

  for (int b = 0; b < batches; ++b) {
    for (int out_c = 0; out_c < output_depth; ++out_c) {
      int d     = 0;
      int d_rem = accum_depth;

      // Use m4 for 32-bit accumulation to allow headroom
      vint32m4_t acc_v = __riscv_vmv_v_x_i32m4(0, __riscv_vsetvlmax_e32m4());

      while (d_rem > 0) {
        size_t vl           = __riscv_vsetvl_e8m1(d_rem);
        vint8m1_t in_v8     = __riscv_vle8_v_i8m1(&input_data[b * accum_depth + d], vl);
        vint8m1_t weight_v8 = __riscv_vle8_v_i8m1(&filter_data[out_c * accum_depth + d], vl);

        // input + input_offset
        vint16m2_t in_v16 =
            __riscv_vadd_vx_i16m2(__riscv_vsext_vf2_i16m2(in_v8, vl), input_offset, vl);
        // weight + filter_offset
        vint16m2_t weight_v16 =
            __riscv_vadd_vx_i16m2(__riscv_vsext_vf2_i16m2(weight_v8, vl), filter_offset, vl);

        // acc_v += (input + input_offset) * (weight + filter_offset)
        acc_v = __riscv_vwmacc_vv_i32m4(acc_v, in_v16, weight_v16, vl);

        d += vl;
        d_rem -= vl;
      }

      // Reduction
      vint32m1_t zero_v = __riscv_vmv_v_x_i32m1(0, 1);
      vint32m1_t sum_v  = __riscv_vredsum_vs_i32m4_i32m1(acc_v, zero_v, __riscv_vsetvlmax_e32m4());
      int32_t acc       = __riscv_vmv_x_s_i32m1_i32(sum_v);

      if (bias_data) {
        acc += bias_data[out_c];
      }

      int32_t acc_scaled =
          tflite::MultiplyByQuantizedMultiplier(acc, output_multiplier, output_shift);
      acc_scaled += output_offset;
      acc_scaled                            = std::max(acc_scaled, output_activation_min);
      acc_scaled                            = std::min(acc_scaled, output_activation_max);
      output_data[out_c + output_depth * b] = static_cast<int8_t>(acc_scaled);
    }
  }
}

namespace {
TfLiteStatus FullyConnectedEval(TfLiteContext *context, TfLiteNode *node) {
  const auto &data = *(static_cast<const tflite::OpDataFullyConnected *>(node->user_data));

  const TfLiteEvalTensor *input =
      tflite::micro::GetEvalInput(context, node, tflite::kFullyConnectedInputTensor);
  const TfLiteEvalTensor *filter =
      tflite::micro::GetEvalInput(context, node, tflite::kFullyConnectedWeightsTensor);
  const TfLiteEvalTensor *bias =
      tflite::micro::GetEvalInput(context, node, tflite::kFullyConnectedBiasTensor);
  TfLiteEvalTensor *output =
      tflite::micro::GetEvalOutput(context, node, tflite::kFullyConnectedOutputTensor);

  if (input->type == kTfLiteInt8 && filter->type == kTfLiteInt8) {
    FullyConnected(
        tflite::FullyConnectedParamsQuantized(data), tflite::micro::GetTensorShape(input),
        tflite::micro::GetTensorData<int8_t>(input), tflite::micro::GetTensorShape(filter),
        tflite::micro::GetTensorData<int8_t>(filter), tflite::micro::GetTensorShape(bias),
        tflite::micro::GetOptionalTensorData<int32_t>(bias), tflite::micro::GetTensorShape(output),
        tflite::micro::GetTensorData<int8_t>(output));
    return kTfLiteOk;
  }

  return tflite::Register_FULLY_CONNECTED().invoke(context, node);
}
}  // namespace

TFLMRegistration Register_FULLY_CONNECTED() {
  auto registration   = tflite::Register_FULLY_CONNECTED();
  registration.invoke = FullyConnectedEval;
  return registration;
}

}  // namespace coralnpu_v2::opt::litert_micro
