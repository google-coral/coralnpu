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

#include <riscv_vector.h>

#include <algorithm>
#include <cstdint>

#include "tensorflow/lite/kernels/internal/reference/integer_ops/pooling.h"
#include "tensorflow/lite/kernels/internal/tensor_ctypes.h"
#include "tensorflow/lite/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/pooling.h"

namespace coralnpu_v2::opt::litert_micro {

void MaxPool(const tflite::PoolParams &params, const tflite::RuntimeShape &input_shape,
             const int8_t *input_data, const tflite::RuntimeShape &output_shape,
             int8_t *output_data) {
  const int batches           = tflite::MatchingDim(input_shape, 0, output_shape, 0);
  const int depth             = tflite::MatchingDim(input_shape, 3, output_shape, 3);
  const int input_height      = input_shape.Dims(1);
  const int input_width       = input_shape.Dims(2);
  const int output_height     = output_shape.Dims(1);
  const int output_width      = output_shape.Dims(2);
  const int stride_height     = params.stride_height;
  const int stride_width      = params.stride_width;
  const int filter_height     = params.filter_height;
  const int filter_width      = params.filter_width;
  const int padding_height    = params.padding_values.height;
  const int padding_width     = params.padding_values.width;
  const int8_t activation_min = params.quantized_activation_min;
  const int8_t activation_max = params.quantized_activation_max;

  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = 0; out_y < output_height; ++out_y) {
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin    = (out_x * stride_width) - padding_width;
        const int in_y_origin    = (out_y * stride_height) - padding_height;
        const int filter_x_start = std::max(0, -in_x_origin);
        const int filter_x_end   = std::min(filter_width, input_width - in_x_origin);
        const int filter_y_start = std::max(0, -in_y_origin);
        const int filter_y_end   = std::min(filter_height, input_height - in_y_origin);

        int channel     = 0;
        int channel_rem = depth;
        while (channel_rem > 0) {
          size_t vl       = __riscv_vsetvl_e8m8(channel_rem);
          vint8m8_t max_v = __riscv_vmv_v_x_i8m8(-128, vl);

          for (int filter_y = filter_y_start; filter_y < filter_y_end; ++filter_y) {
            for (int filter_x = filter_x_start; filter_x < filter_x_end; ++filter_x) {
              const int in_x = in_x_origin + filter_x;
              const int in_y = in_y_origin + filter_y;
              const int8_t *in_ptr =
                  input_data + tflite::Offset(input_shape, batch, in_y, in_x, channel);
              vint8m8_t val_v = __riscv_vle8_v_i8m8(in_ptr, vl);
              max_v           = __riscv_vmax_vv_i8m8(max_v, val_v, vl);
            }
          }

          // Clamping
          max_v = __riscv_vmax_vx_i8m8(max_v, activation_min, vl);
          max_v = __riscv_vmin_vx_i8m8(max_v, activation_max, vl);

          int8_t *out_ptr =
              output_data + tflite::Offset(output_shape, batch, out_y, out_x, channel);
          __riscv_vse8_v_i8m8(out_ptr, max_v, vl);

          channel += vl;
          channel_rem -= vl;
        }
      }
    }
  }
}

namespace {

TfLiteStatus MaxEval(TfLiteContext *context, TfLiteNode *node) {
  auto *params                      = reinterpret_cast<TfLitePoolParams *>(node->builtin_data);
  const tflite::OpDataPooling *data = static_cast<const tflite::OpDataPooling *>(node->user_data);

  const TfLiteEvalTensor *input =
      tflite::micro::GetEvalInput(context, node, tflite::kPoolingInputTensor);
  TfLiteEvalTensor *output =
      tflite::micro::GetEvalOutput(context, node, tflite::kPoolingOutputTensor);

  if (input->type == kTfLiteInt8) {
    tflite::PoolParams op_params;
    op_params.stride_height            = params->stride_height;
    op_params.stride_width             = params->stride_width;
    op_params.filter_height            = params->filter_height;
    op_params.filter_width             = params->filter_width;
    op_params.padding_values.height    = data->padding.height;
    op_params.padding_values.width     = data->padding.width;
    op_params.quantized_activation_min = data->activation_min;
    op_params.quantized_activation_max = data->activation_max;

    MaxPool(op_params, tflite::micro::GetTensorShape(input),
            tflite::micro::GetTensorData<int8_t>(input), tflite::micro::GetTensorShape(output),
            tflite::micro::GetTensorData<int8_t>(output));
    return kTfLiteOk;
  }

  return tflite::Register_MAX_POOL_2D().invoke(context, node);
}

}  // namespace

TFLMRegistration Register_MAX_POOL_2D() {
  auto registration   = tflite::Register_MAX_POOL_2D();
  registration.invoke = MaxEval;
  return registration;
}

}  // namespace coralnpu_v2::opt::litert_micro
