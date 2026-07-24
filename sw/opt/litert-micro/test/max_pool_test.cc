// Copyright 2026 Google LLC
#include <cstdint>

#include "sw/opt/litert-micro/pooling.h"
#include "sw/utils/utils.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/pooling.h"

extern "C" {
int32_t input_dims[4] __attribute__((section(".data"))) = {0};
int8_t input_data[307200]
    __attribute__((section(".data"), aligned(16))) = {0};  // Largest input 300KB

int32_t output_dims[4] __attribute__((section(".data")))                      = {0};
int8_t output_data[307200] __attribute__((section(".data"), aligned(16)))     = {0};
int8_t output_data_ref[307200] __attribute__((section(".data"), aligned(16))) = {0};

int32_t params_stride_width __attribute__((section(".data")))   = 0;
int32_t params_stride_height __attribute__((section(".data")))  = 0;
int32_t params_filter_width __attribute__((section(".data")))   = 0;
int32_t params_filter_height __attribute__((section(".data")))  = 0;
int32_t params_padding_width __attribute__((section(".data")))  = 0;
int32_t params_padding_height __attribute__((section(".data"))) = 0;
int32_t params_activation_min __attribute__((section(".data"))) = 0;
int32_t params_activation_max __attribute__((section(".data"))) = 0;

uint64_t ref_cycles __attribute__((section(".data"), used)) = 0;
uint64_t opt_cycles __attribute__((section(".data"), used)) = 0;
int32_t heartbeat __attribute__((section(".data"), used))   = 0xAA;

__attribute__((used, retain)) void run_ref() {
  heartbeat = 0x11;
  tflite::PoolParams params;
  params.stride_height            = params_stride_height;
  params.stride_width             = params_stride_width;
  params.filter_height            = params_filter_height;
  params.filter_width             = params_filter_width;
  params.padding_values.height    = params_padding_height;
  params.padding_values.width     = params_padding_width;
  params.quantized_activation_min = params_activation_min;
  params.quantized_activation_max = params_activation_max;

  uint64_t start = mcycle_read();
  tflite::reference_integer_ops::MaxPool(params, tflite::RuntimeShape(4, input_dims), input_data,
                                         tflite::RuntimeShape(4, output_dims), output_data_ref);
  ref_cycles = mcycle_read() - start;
  heartbeat  = 0x12;
}

__attribute__((used, retain)) void run_optimized() {
  heartbeat = 0x21;
  tflite::PoolParams params;
  params.stride_height            = params_stride_height;
  params.stride_width             = params_stride_width;
  params.filter_height            = params_filter_height;
  params.filter_width             = params_filter_width;
  params.padding_values.height    = params_padding_height;
  params.padding_values.width     = params_padding_width;
  params.quantized_activation_min = params_activation_min;
  params.quantized_activation_max = params_activation_max;

  uint64_t start = mcycle_read();
  coralnpu_v2::opt::litert_micro::MaxPool(params, tflite::RuntimeShape(4, input_dims), input_data,
                                          tflite::RuntimeShape(4, output_dims), output_data);
  opt_cycles = mcycle_read() - start;
  heartbeat  = 0x22;
}
__attribute__((used, retain)) void run_verify() {
  run_ref();
  run_optimized();
}

void (*impl)() __attribute__((section(".data"), used)) = run_verify;

int main(void) {
  impl();
  return 0;
}
}  // extern "C"
