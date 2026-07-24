// Copyright 2026 Google LLC
#include "sw/opt/litert-micro/conv.h"

#include <cstdint>
#include <cstring>

#include "sw/utils/utils.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
#include "tensorflow/lite/micro/kernels/conv.h"

using namespace coralnpu_v2::opt::litert_micro;

extern "C" {
// Buffers
int8_t input_data[65536] __attribute__((section(".data"), aligned(16)))      = {0};
int8_t filter_data[65536] __attribute__((section(".data"), aligned(16)))     = {0};
int32_t bias_data[256] __attribute__((section(".data"), aligned(16)))        = {0};
int8_t output_data[65536] __attribute__((section(".data"), aligned(16)))     = {0};
int8_t output_data_ref[65536] __attribute__((section(".data"), aligned(16))) = {0};

// Dimensions
int32_t input_dims[4] __attribute__((section(".data")))  = {0};
int32_t filter_dims[4] __attribute__((section(".data"))) = {0};
int32_t bias_dims[4] __attribute__((section(".data")))   = {0};
int32_t output_dims[4] __attribute__((section(".data"))) = {0};

// Parameters
int32_t params_stride_width __attribute__((section(".data")))   = 0;
int32_t params_stride_height __attribute__((section(".data")))  = 0;
int32_t params_padding_width __attribute__((section(".data")))  = 0;
int32_t params_padding_height __attribute__((section(".data"))) = 0;
int32_t params_input_offset __attribute__((section(".data")))   = 0;
int32_t params_output_offset __attribute__((section(".data")))  = 0;
int32_t params_activation_min __attribute__((section(".data"))) = 0;
int32_t params_activation_max __attribute__((section(".data"))) = 0;

int32_t per_channel_multiplier[256] __attribute__((section(".data"))) = {0};
int32_t per_channel_shift[256] __attribute__((section(".data")))      = {0};

// Cycles and status
uint64_t ref_cycles __attribute__((section(".data"), used)) = 0;
uint64_t opt_cycles __attribute__((section(".data"), used)) = 0;
int32_t heartbeat __attribute__((section(".data"), used))   = 0xAA;

// Scratch and persistent buffers for mock context
int8_t scratch_buffer[262144] __attribute__((section(".data"), aligned(16)))    = {0};
int8_t persistent_buffer[262144] __attribute__((section(".data"), aligned(16))) = {0};
size_t persistent_offset                                                        = 0;

TfLiteStatus MockRequestScratchBuffer(TfLiteContext *context, size_t bytes, int *buffer_idx) {
  *buffer_idx = 0;  // Only one scratch buffer supported for now
  return kTfLiteOk;
}

void *MockGetScratchBuffer(TfLiteContext *context, int buffer_idx) { return scratch_buffer; }

void *MockAllocatePersistentBuffer(TfLiteContext *context, size_t bytes) {
  void *ptr = persistent_buffer + persistent_offset;
  persistent_offset += (bytes + 15) & ~15;
  return ptr;
}

__attribute__((used, retain)) void run_ref() {
  heartbeat = 0x11;
  tflite::ConvParams params;
  params.stride_width             = params_stride_width;
  params.stride_height            = params_stride_height;
  params.dilation_width_factor    = 1;
  params.dilation_height_factor   = 1;
  params.padding_values.width     = params_padding_width;
  params.padding_values.height    = params_padding_height;
  params.input_offset             = params_input_offset;
  params.output_offset            = params_output_offset;
  params.quantized_activation_min = params_activation_min;
  params.quantized_activation_max = params_activation_max;

  uint64_t start = mcycle_read();
  tflite::reference_integer_ops::ConvPerChannel(
      params, per_channel_multiplier, per_channel_shift, tflite::RuntimeShape(4, input_dims),
      input_data, tflite::RuntimeShape(4, filter_dims), filter_data,
      tflite::RuntimeShape(4, bias_dims), bias_data, tflite::RuntimeShape(4, output_dims),
      output_data_ref);
  ref_cycles = mcycle_read() - start;
  heartbeat  = 0x12;
}

__attribute__((used, retain)) void run_optimized() {
  heartbeat = 0x21;
  tflite::ConvParams params;
  params.stride_width             = params_stride_width;
  params.stride_height            = params_stride_height;
  params.dilation_width_factor    = 1;
  params.dilation_height_factor   = 1;
  params.padding_values.width     = params_padding_width;
  params.padding_values.height    = params_padding_height;
  params.input_offset             = params_input_offset;
  params.output_offset            = params_output_offset;
  params.quantized_activation_min = params_activation_min;
  params.quantized_activation_max = params_activation_max;

  TfLiteContext context;
  context.GetScratchBuffer            = MockGetScratchBuffer;
  context.RequestScratchBufferInArena = MockRequestScratchBuffer;
  context.AllocatePersistentBuffer    = MockAllocatePersistentBuffer;

  OpDataConvCustom data;
  memset(&data, 0, sizeof(data));
  data.per_channel_output_multiplier = per_channel_multiplier;
  data.per_channel_output_shift      = per_channel_shift;
  data.output_activation_min         = params_activation_min;
  data.output_activation_max         = params_activation_max;

  // Some kernels need these pre-populated or will try to allocate them
  data.accs_buffer_index          = 0;
  data.tiled_input_buffer_index   = 0;
  data.generic_tiled_buffer_index = 0;

  int input_depth   = input_dims[3];
  int output_depth  = output_dims[3];
  int filter_height = filter_dims[1];
  int filter_width  = filter_dims[2];

  persistent_offset = 0;

  if (filter_height == 4 && filter_width == 4 && input_depth == 48 && output_depth == 48) {
    size_t repacked_weights_size =
        output_depth * filter_height * filter_width * input_depth * sizeof(int16_t);
    data.repacked_weights =
        (int16_t *)MockAllocatePersistentBuffer(&context, repacked_weights_size);
    data.weight_sums =
        (int32_t *)MockAllocatePersistentBuffer(&context, output_depth * sizeof(int32_t));
    RepackWeightsD48(filter_data, data.repacked_weights, data.weight_sums, output_depth,
                     filter_height, filter_width, input_depth);
  } else if (filter_height == 4 && filter_width == 4) {
    size_t repacked_size          = output_depth * filter_height * filter_width * input_depth;
    data.repacked_weights_generic = (int8_t *)MockAllocatePersistentBuffer(&context, repacked_size);
    int8_t *dst                   = data.repacked_weights_generic;
    for (int ky = 0; ky < filter_height; ++ky) {
      for (int kx = 0; kx < filter_width; ++kx) {
        for (int ic = 0; ic < input_depth; ++ic) {
          for (int oc = 0; oc < output_depth; ++oc) {
            int src_idx = oc * (filter_height * filter_width * input_depth) +
                          ky * (filter_width * input_depth) + kx * input_depth + ic;
            *dst++ = filter_data[src_idx];
          }
        }
      }
    }
  }

  uint64_t start = mcycle_read();
  ConvPerChannel(params, data, per_channel_multiplier, per_channel_shift, &context,
                 tflite::RuntimeShape(4, input_dims), input_data,
                 tflite::RuntimeShape(4, filter_dims), filter_data,
                 tflite::RuntimeShape(4, bias_dims), bias_data,
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
}
