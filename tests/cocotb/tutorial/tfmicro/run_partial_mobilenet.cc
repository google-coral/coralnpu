// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "sw/opt/litert-micro/depthwise_conv.h"
#include "tensorflow/lite/core/c/common.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/system_setup.h"
#include "tests/cocotb/tutorial/tfmicro/mobilenet_v1_025_partial_layers.h"

namespace {
using MobilenetOpResolver = tflite::MicroMutableOpResolver<2>;
using coralnpu_v2::opt::litert_micro::Register_DEPTHWISE_CONV_2D;
TfLiteStatus RegisterOps(MobilenetOpResolver &op_resolver) {
  TF_LITE_ENSURE_STATUS(op_resolver.AddConv2D());
  TF_LITE_ENSURE_STATUS(op_resolver.AddDepthwiseConv2D(Register_DEPTHWISE_CONV_2D()));
  return kTfLiteOk;
}
}  // namespace

extern "C" {
// aligned(16)
constexpr size_t kTensorArenaSize = 2048 * 1024;
int8_t inference_status           = -1;
char inference_status_message[31] __attribute__((section(".data"), aligned(16)));
uint8_t tensor_arena[kTensorArenaSize] __attribute__((section(".extdata"), aligned(16)));
}

int main(int argc, char **argv) {
  const tflite::Model *model = tflite::GetModel(g_mobilenet_v1_025_partial_layers_model_data);
  MobilenetOpResolver op_resolver;
  RegisterOps(op_resolver);
  std::strncpy(inference_status_message, "Halted after op resolver", 31);
  tflite::MicroInterpreter interpreter(model, op_resolver, tensor_arena, kTensorArenaSize);
  std::strncpy(inference_status_message, "Halted after Interpreter setup", 31);
  if (interpreter.AllocateTensors() != kTfLiteOk) {
    std::strncpy(inference_status_message, "Error during AllocateTensors", 31);
    return -1;
  }
  if (interpreter.Invoke() != kTfLiteOk) {
    std::strncpy(inference_status_message, "Error during Invoke", 31);
    return -1;
  }
  std::strncpy(inference_status_message, "Invoke successful", 31);
  inference_status = 0;
  return 0;
}
