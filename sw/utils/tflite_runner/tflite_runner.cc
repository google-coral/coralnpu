/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "sw/utils/utils.h"
#include "tensorflow/lite/core/c/common.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_log.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/system_setup.h"

#ifdef __riscv_vector
#include "sw/opt/litert-micro/conv.h"
#include "sw/opt/litert-micro/depthwise_conv.h"
#include "sw/opt/litert-micro/fully_connected.h"
#include "sw/opt/litert-micro/logistic.h"
#include "sw/opt/litert-micro/pooling.h"
#endif

// Define sizes: 512KB for model, ~3.5MB for arena (fits in 4MB EXTMEM with logs)
#define MAX_MODEL_SIZE    (512 * 1024)
#define TENSOR_ARENA_SIZE (3570 * 1024)

// Buffers in EXTMEM to save DTCM space
uint8_t model_buffer[MAX_MODEL_SIZE] __attribute__((section(".extdata"), aligned(16)));
uint8_t tensor_arena[TENSOR_ARENA_SIZE] __attribute__((section(".extbss"), aligned(16)));

#define LOG_BUFFER_SIZE 8192

extern "C" {
volatile uint32_t model_size __attribute__((section(".noinit")));
volatile uint64_t cycle_count  = 0;
volatile int32_t init_status   = 0;
volatile int32_t invoke_status = 0;
char debug_log_buffer[LOG_BUFFER_SIZE] __attribute__((section(".extbss"), aligned(16)));
volatile uint32_t debug_log_ptr = 0;
}

extern "C" void __wrap_DebugLog(const char *format, va_list args) {
  if (debug_log_ptr >= LOG_BUFFER_SIZE - 256) {
    return;
  }
  int available = LOG_BUFFER_SIZE - debug_log_ptr - 1;
  int len       = vsnprintf(debug_log_buffer + debug_log_ptr, available, format, args);
  if (len > 0) {
    debug_log_ptr += len;
  }
}

using GenericOpResolver = tflite::MicroMutableOpResolver<30>;

TfLiteStatus RegisterOps(GenericOpResolver &op_resolver) {
#ifdef __riscv_vector
  TF_LITE_ENSURE_STATUS(op_resolver.AddConv2D(coralnpu_v2::opt::litert_micro::Register_CONV_2D()));
  TF_LITE_ENSURE_STATUS(
      op_resolver.AddDepthwiseConv2D(coralnpu_v2::opt::litert_micro::Register_DEPTHWISE_CONV_2D()));
  TF_LITE_ENSURE_STATUS(
      op_resolver.AddFullyConnected(coralnpu_v2::opt::litert_micro::Register_FULLY_CONNECTED()));
  TF_LITE_ENSURE_STATUS(
      op_resolver.AddMaxPool2D(coralnpu_v2::opt::litert_micro::Register_MAX_POOL_2D()));
  TF_LITE_ENSURE_STATUS(op_resolver.AddAveragePool2D());
  TF_LITE_ENSURE_STATUS(op_resolver.AddLogistic());
#else
  TF_LITE_ENSURE_STATUS(op_resolver.AddConv2D());
  TF_LITE_ENSURE_STATUS(op_resolver.AddDepthwiseConv2D());
  TF_LITE_ENSURE_STATUS(op_resolver.AddFullyConnected());
  TF_LITE_ENSURE_STATUS(op_resolver.AddMaxPool2D());
  TF_LITE_ENSURE_STATUS(op_resolver.AddAveragePool2D());
  TF_LITE_ENSURE_STATUS(op_resolver.AddLogistic());
#endif

  // Register common reference ops
  TF_LITE_ENSURE_STATUS(op_resolver.AddReshape());
  TF_LITE_ENSURE_STATUS(op_resolver.AddSoftmax());
  TF_LITE_ENSURE_STATUS(op_resolver.AddAdd());
  TF_LITE_ENSURE_STATUS(op_resolver.AddMul());
  TF_LITE_ENSURE_STATUS(op_resolver.AddSub());
  TF_LITE_ENSURE_STATUS(op_resolver.AddConcatenation());
  TF_LITE_ENSURE_STATUS(op_resolver.AddPad());
  TF_LITE_ENSURE_STATUS(op_resolver.AddQuantize());
  TF_LITE_ENSURE_STATUS(op_resolver.AddDequantize());
  TF_LITE_ENSURE_STATUS(op_resolver.AddMean());
  TF_LITE_ENSURE_STATUS(op_resolver.AddPack());
  TF_LITE_ENSURE_STATUS(op_resolver.AddUnpack());
  TF_LITE_ENSURE_STATUS(op_resolver.AddSplit());
  TF_LITE_ENSURE_STATUS(op_resolver.AddResizeNearestNeighbor());
  TF_LITE_ENSURE_STATUS(op_resolver.AddStridedSlice());

  return kTfLiteOk;
}

int main() {
  tflite::InitializeTarget();

  MicroPrintf("Generic TFLite Runner Started. Model size: %d", model_size);

  if (model_size == 0 || model_size > MAX_MODEL_SIZE) {
    init_status = -1;
    return -1;
  }

  const tflite::Model *model = tflite::GetModel(model_buffer);
  if (model->version() != TFLITE_SCHEMA_VERSION) {
    init_status = -2;
    return -2;
  }

  GenericOpResolver op_resolver;
  if (RegisterOps(op_resolver) != kTfLiteOk) {
    init_status = -3;
    return -3;
  }

  tflite::MicroInterpreter interpreter(model, op_resolver, tensor_arena, TENSOR_ARENA_SIZE);

  if (interpreter.AllocateTensors() != kTfLiteOk) {
    init_status = -4;
    return -4;
  }
  init_status = 1;  // Success

  // Zero out inputs
  for (size_t i = 0; i < interpreter.inputs_size(); ++i) {
    TfLiteTensor *input = interpreter.input(i);
    if (input->data.raw) {
      std::memset(input->data.raw, 0, input->bytes);
    }
  }

  // Profile the Invoke call
  cycle_counter_reset();
  uint64_t start_cycles = mcycle_read();
  TfLiteStatus status   = interpreter.Invoke();
  uint64_t end_cycles   = mcycle_read();

  if (status != kTfLiteOk) {
    invoke_status = -1;
    return -5;
  }
  invoke_status = 1;  // Success

  cycle_count = end_cycles - start_cycles;

  return 0;
}
