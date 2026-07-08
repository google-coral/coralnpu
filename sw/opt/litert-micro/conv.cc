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

#include "sw/opt/litert-micro/conv.h"

#include <riscv_vector.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>

#include "sw/opt/litert-micro/accumulator_util.h"
#include "sw/opt/litert-micro/memory_util.h"
#include "sw/opt/rvv_opt.h"
#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
#include "tensorflow/lite/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"
#ifdef USE_TFLM_COMPRESSION
#error "USE_TFLM_COMPRESSION is not supported"
#endif  // USE_TFLM_COMPRESSION

// Leverage compiler register allocator, but inline assembly MAC

#define CONV_MAC(in_ptr, fil, acc_reg)                       \
  asm("vsetvli zero, %[vl], e16, m2, ta, ma;"                \
      "vle8.v v30, %[input_ptr];"                            \
      "vsext.vf2 v18, v30;"                                  \
      "vadd.vx v18, v18, %[input_offset];"                   \
      "vsext.vf2 v30, %[filter];"                            \
      "vwmacc.vv %[acc], v18, v30;"                          \
      : [acc] "+vr"(acc_reg)                                 \
      : [vl] "r"(vl), [input_ptr] "A"(*in_ptr),              \
        [input_offset] "r"(input_offset), [filter] "vr"(fil) \
      : "v18", "v19", "v30", "v31", "vl", "vtype");

#define CONV_MAC_2X(in_ptr, fil_for_acc1, fil_for_acc2)              \
  asm("vsetvli zero, %[vl], e16, m2, ta, ma;"                        \
      "vle8.v v30, %[input_ptr];"                                    \
      "vsext.vf2 v18, v30;"                                          \
      "vadd.vx v18, v18, %[input_offset];"                           \
      "vsext.vf2 v30, %[fil1];"                                      \
      "vwmacc.vv %[acc1], v18, v30;"                                 \
      "vsext.vf2 v30, %[fil2];"                                      \
      "vwmacc.vv %[acc2], v18, v30;"                                 \
      : [acc1] "+vr"(mul_acc1), [acc2] "+vr"(mul_acc2)               \
      : [vl] "r"(vl), [input_ptr] "A"(*in_ptr),                      \
        [input_offset] "r"(input_offset), [fil1] "vr"(fil_for_acc1), \
        [fil2] "vr"(fil_for_acc2)                                    \
      : "v18", "v19", "v30", "v31", "vl", "vtype");

namespace coralnpu_v2::opt::litert_micro {

using tflite::ConvParams;
using tflite::kConvBiasTensor;
using tflite::kConvInputTensor;
using tflite::kConvOutputTensor;
using tflite::kConvWeightsTensor;
using tflite::NumInputs;
using tflite::OpDataConv;
using tflite::RuntimeShape;
using tflite::micro::GetEvalInput;
using tflite::micro::GetEvalOutput;
using tflite::micro::GetOptionalTensorData;
using tflite::micro::GetTensorData;
using tflite::micro::GetTensorShape;

constexpr size_t kInputBufferSize = 64 * 1024;
constexpr int kPadPixel = 4;

// Helper to pad input. Returns pointer to the start of VALID data (0,0) in the
// buffer.
const int8_t* PadInput(int8_t* dst_buffer, const int8_t* val_ptr,
                       int input_height, int input_width, int input_depth,
                       int32_t input_offset, int pad_h, int pad_w, int stride_h,
                       int stride_w) {
  // Fill with -input_offset (effectively 0)
  memset(dst_buffer, -input_offset, kInputBufferSize);

  int row_bytes = input_width * input_depth;
  int pad_bytes = kPadPixel * input_depth;
  int stride_padded = row_bytes + 2 * pad_bytes;

  // Check size
  int required_size = input_height * stride_padded;
  const int kMargin = 1024;
  if (static_cast<size_t>(required_size + kMargin) > kInputBufferSize) {
    return nullptr;
  }

  int8_t* buffer_start = dst_buffer + kMargin;

  // Row-wise copy
  for (int y = 0; y < input_height; ++y) {
    int8_t* dest_row = buffer_start + y * stride_padded + pad_bytes;
    const int8_t* src_row = val_ptr + y * row_bytes;
    coralnpu_v2::opt::Memcpy(dest_row, src_row, row_bytes);
  }

  // Return pointer to (0,0) of the first row
  return buffer_start + pad_bytes;
}

// Specialized 4x4 Conv2D kernel with LMUL=4 for high channel counts (up to 64).
void Conv2D_4x4(const tflite::ConvParams& params,
                const coralnpu_v2::opt::litert_micro::OpDataConvCustom& data,
                const tflite::RuntimeShape& input_shape,
                const int8_t* input_data,
                const tflite::RuntimeShape& filter_shape,
                const int8_t* filter_data, const int32_t* bias_data,
                const tflite::RuntimeShape& output_shape, int8_t* output_data,
                const int8_t* repacked_weights, TfLiteContext* context) {
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int32_t input_offset = params.input_offset;
  const int32_t output_offset = params.output_offset;

  const int batches = input_shape.Dims(0);
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int input_depth = input_shape.Dims(3);

  const int filter_height = 4;
  const int filter_width = 4;
  const int filter_depth = filter_shape.Dims(3);
  const int output_depth = filter_shape.Dims(0);
  const int stride_filter = filter_height * filter_width * filter_depth;

  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);

  int8_t* generic_tiled_buffer =
      (data.generic_tiled_buffer_index != -1)
          ? static_cast<int8_t*>(context->GetScratchBuffer(
                context, data.generic_tiled_buffer_index))
          : nullptr;

  for (int out_channel_start = 0; out_channel_start < output_depth;) {
    int rem_out_channels = output_depth - out_channel_start;
    size_t vl = __riscv_vsetvl_e32m4(rem_out_channels);  // LMUL=4!

    // Preload Bias/Quant params
    // These are heavy loads (LMUL=4), but done once per massive block.
    vint32m4_t bias_v =
        __riscv_vle32_v_i32m4(bias_data + out_channel_start, vl);

    vint32m4_t mult_v = __riscv_vle32_v_i32m4(
        data.per_channel_output_multiplier + out_channel_start, vl);
    vint32m4_t shift_v = __riscv_vle32_v_i32m4(
        data.per_channel_output_shift + out_channel_start, vl);

    // Quantization constants
    vint32m4_t left_shift_v = __riscv_vmax_vx_i32m4(shift_v, 0, vl);
    vint32m4_t right_shift_v =
        __riscv_vmax_vx_i32m4(__riscv_vneg_v_i32m4(shift_v, vl), 0, vl);
    vint32m4_t shift_minus_1_v = __riscv_vsub_vx_i32m4(right_shift_v, 1, vl);
    vbool8_t mask_gt0 = __riscv_vmsgt_vx_i32m4_b8(right_shift_v, 0, vl);
    vint32m4_t nudge_v = __riscv_vmv_v_x_i32m4(0, vl);
    nudge_v = __riscv_vsll_vv_i32m4_mu(
        mask_gt0, nudge_v, __riscv_vmv_v_x_i32m4(1, vl),
        __riscv_vreinterpret_v_i32m4_u32m4(shift_minus_1_v), vl);

    for (int batch = 0; batch < batches; ++batch) {
      // Input Padding Optimization
      // Pad the entire input image for this batch to a static buffer.
      // This allows us to remove boundary checks in the inner loop.
      const int8_t* batch_base =
          input_data + batch * input_height * input_width * input_depth;
      const int8_t* padded_input_base = nullptr;
      if (generic_tiled_buffer) {
        padded_input_base =
            PadInput(generic_tiled_buffer, batch_base, input_height,
                     input_width, input_depth, params.input_offset, 0, 0, 0, 0);
      }

      for (int out_y = 0; out_y < output_height; ++out_y) {
        const int in_y_origin = (out_y * stride_height) - pad_height;

        int out_x = 0;
        for (; out_x <= output_width - 4; out_x += 4) {
          const int in_x_origin0 = (out_x * stride_width) - pad_width;
          const int in_x_origin1 = ((out_x + 1) * stride_width) - pad_width;
          const int in_x_origin2 = ((out_x + 2) * stride_width) - pad_width;
          const int in_x_origin3 = ((out_x + 3) * stride_width) - pad_width;

          vint32m4_t acc0 = bias_v;
          vint32m4_t acc1 = bias_v;
          vint32m4_t acc2 = bias_v;
          vint32m4_t acc3 = bias_v;

          for (int ky = 0; ky < 4; ++ky) {
            const int in_y = in_y_origin + dilation_height_factor * ky;

            if (in_y < 0 || in_y >= input_height) continue;

            for (int kx = 0; kx < 4; ++kx) {
              const int in_x0 = in_x_origin0 + dilation_width_factor * kx;
              const int in_x1 = in_x_origin1 + dilation_width_factor * kx;
              const int in_x2 = in_x_origin2 + dilation_width_factor * kx;
              const int in_x3 = in_x_origin3 + dilation_width_factor * kx;

              // Calculate pointers
              const int offset = (in_y * input_width * input_depth);
              const int8_t* val_ptr = batch_base + offset;  // Original pointer

              const int pad_bytes = kPadPixel * input_depth;
              const int stride_padded =
                  (input_width * input_depth) + 2 * pad_bytes;
              // padded_input_base points to (0,0).
              // We need (in_y, 0).
              const int8_t* pad_ptr =
                  padded_input_base ? (padded_input_base + in_y * stride_padded)
                                    : nullptr;

              const int8_t* f_ptr =
                  filter_data + (out_channel_start * stride_filter) +
                  (ky * filter_width * filter_depth) + (kx * filter_depth);

              if (repacked_weights) {
                // Optimized path
                const int8_t* packed_ptr =
                    repacked_weights +
                    (ky * filter_width * input_depth * output_depth) +
                    (kx * input_depth * output_depth) +
                    (0 * output_depth) +  // kc=0 initially
                    out_channel_start;

                for (int kc = 0; kc < input_depth; ++kc) {
                  vint8m1_t w =
                      __riscv_vle8_v_i8m1(packed_ptr + kc * output_depth, vl);
                  vint16m2_t w16 = __riscv_vwadd_vx_i16m2(w, 0, vl);

                  if (pad_ptr) {
                    // Branchless access using padded buffer!
                    // We can blindly access pad_ptr[in_x * depth + kc] because:
                    // 1. If in_x is out of bounds (negative or large), it hits
                    // the padding/margin.
                    // 2. Padding is initialized to -input_offset.
                    // 3. (val + input_offset) becomes 0.
                    // Note: We need to ensure margin covers max
                    // negative/positive stride.
                    acc0 = __riscv_vwmacc_vx_i32m4(
                        acc0,
                        (int16_t)(pad_ptr[in_x0 * input_depth + kc] +
                                  params.input_offset),
                        w16, vl);
                    acc1 = __riscv_vwmacc_vx_i32m4(
                        acc1,
                        (int16_t)(pad_ptr[in_x1 * input_depth + kc] +
                                  params.input_offset),
                        w16, vl);
                    acc2 = __riscv_vwmacc_vx_i32m4(
                        acc2,
                        (int16_t)(pad_ptr[in_x2 * input_depth + kc] +
                                  params.input_offset),
                        w16, vl);
                    acc3 = __riscv_vwmacc_vx_i32m4(
                        acc3,
                        (int16_t)(pad_ptr[in_x3 * input_depth + kc] +
                                  params.input_offset),
                        w16, vl);
                  } else {
                    // Fallback with branches
                    if (in_x0 >= 0 && in_x0 < input_width) {
                      acc0 = __riscv_vwmacc_vx_i32m4(
                          acc0,
                          (int16_t)(val_ptr[in_x0 * input_depth + kc] +
                                    params.input_offset),
                          w16, vl);
                    }
                    if (in_x1 >= 0 && in_x1 < input_width) {
                      acc1 = __riscv_vwmacc_vx_i32m4(
                          acc1,
                          (int16_t)(val_ptr[in_x1 * input_depth + kc] +
                                    params.input_offset),
                          w16, vl);
                    }
                    if (in_x2 >= 0 && in_x2 < input_width) {
                      acc2 = __riscv_vwmacc_vx_i32m4(
                          acc2,
                          (int16_t)(val_ptr[in_x2 * input_depth + kc] +
                                    params.input_offset),
                          w16, vl);
                    }
                    if (in_x3 >= 0 && in_x3 < input_width) {
                      acc3 = __riscv_vwmacc_vx_i32m4(
                          acc3,
                          (int16_t)(val_ptr[in_x3 * input_depth + kc] +
                                    params.input_offset),
                          w16, vl);
                    }
                  }
                }
              } else {
                // Original path: strided loads
                for (int kc = 0; kc < input_depth; ++kc) {
                  vint8m1_t w =
                      __riscv_vlse8_v_i8m1(f_ptr + kc, stride_filter, vl);

                  // Widen to int16 (LMUL=2)
                  vint16m2_t w16 = __riscv_vwadd_vx_i16m2(w, 0, vl);

                  if (in_x0 >= 0 && in_x0 < input_width) {
                    int16_t v = (int16_t)(val_ptr[in_x0 * input_depth + kc] +
                                          input_offset);
                    acc0 = __riscv_vwmacc_vx_i32m4(acc0, v, w16, vl);
                  }
                  if (in_x1 >= 0 && in_x1 < input_width) {
                    int16_t v = (int16_t)(val_ptr[in_x1 * input_depth + kc] +
                                          input_offset);
                    acc1 = __riscv_vwmacc_vx_i32m4(acc1, v, w16, vl);
                  }
                  if (in_x2 >= 0 && in_x2 < input_width) {
                    int16_t v = (int16_t)(val_ptr[in_x2 * input_depth + kc] +
                                          input_offset);
                    acc2 = __riscv_vwmacc_vx_i32m4(acc2, v, w16, vl);
                  }
                  if (in_x3 >= 0 && in_x3 < input_width) {
                    int16_t v = (int16_t)(val_ptr[in_x3 * input_depth + kc] +
                                          input_offset);
                    acc3 = __riscv_vwmacc_vx_i32m4(acc3, v, w16, vl);
                  }
                }
              }
            }
          }

// Quantize and Store Macro
// Need to handle LMUL=4 types
#define QUANTIZE_AND_STORE_4(ACC_V, OFFSET)                                   \
  {                                                                           \
    vint32m4_t a = ACC_V;                                                     \
    a = __riscv_vsll_vv_i32m4(                                                \
        a, __riscv_vreinterpret_v_i32m4_u32m4(left_shift_v), vl);             \
    a = __riscv_vsmul_vv_i32m4(a, mult_v, 0, vl);                             \
    a = __riscv_vadd_vv_i32m4(a, nudge_v, vl);                                \
    a = __riscv_vsra_vv_i32m4(                                                \
        a, __riscv_vreinterpret_v_i32m4_u32m4(right_shift_v), vl);            \
    a = __riscv_vadd_vx_i32m4(a, output_offset, vl);                          \
    a = __riscv_vmax_vx_i32m4(a, data.output_activation_min, vl);             \
    a = __riscv_vmin_vx_i32m4(a, data.output_activation_max, vl);             \
    vint16m2_t a16 = __riscv_vnclip_wx_i16m2(a, 0, 0, vl);                    \
    vint8m1_t a8 = __riscv_vnclip_wx_i8m1(a16, 0, 0, vl);                     \
    int8_t* out_ptr = output_data +                                           \
                      (batch * output_height * output_width * output_depth) + \
                      (out_y * output_width * output_depth) +                 \
                      ((out_x + OFFSET) * output_depth) + out_channel_start;  \
    __riscv_vse8_v_i8m1(out_ptr, a8, vl);                                     \
  }

          QUANTIZE_AND_STORE_4(acc0, 0);
          QUANTIZE_AND_STORE_4(acc1, 1);
          QUANTIZE_AND_STORE_4(acc2, 2);
          QUANTIZE_AND_STORE_4(acc3, 3);
#undef QUANTIZE_AND_STORE_4
        }

        // Remainder loop for X
        for (; out_x < output_width; ++out_x) {
          const int in_x_origin = (out_x * stride_width) - pad_width;
          vint32m4_t acc = bias_v;
          for (int ky = 0; ky < 4; ++ky) {
            const int in_y = in_y_origin + dilation_height_factor * ky;
            if (in_y < 0 || in_y >= input_height) continue;
            for (int kx = 0; kx < 4; ++kx) {
              const int in_x = in_x_origin + dilation_width_factor * kx;
              if (in_x < 0 || in_x >= input_width) continue;

              const int8_t* val_ptr =
                  input_data +
                  (batch * input_height * input_width * input_depth) +
                  (in_y * input_width * input_depth);
              const int8_t* f_ptr =
                  filter_data + (out_channel_start * stride_filter) +
                  (ky * filter_width * filter_depth) + (kx * filter_depth);
              for (int kc = 0; kc < input_depth; ++kc) {
                vint8m1_t w =
                    __riscv_vlse8_v_i8m1(f_ptr + kc, stride_filter, vl);
                vint16m2_t w16 = __riscv_vwadd_vx_i16m2(w, 0, vl);
                int16_t v =
                    (int16_t)(val_ptr[in_x * input_depth + kc] + input_offset);
                acc = __riscv_vwmacc_vx_i32m4(acc, v, w16, vl);
              }
            }
          }
// Quantize
#define QUANTIZE_AND_STORE_1(ACC_V, OFFSET)                                   \
  {                                                                           \
    vint32m4_t a = ACC_V;                                                     \
    a = __riscv_vsll_vv_i32m4(                                                \
        a, __riscv_vreinterpret_v_i32m4_u32m4(left_shift_v), vl);             \
    a = __riscv_vsmul_vv_i32m4(a, mult_v, 0, vl);                             \
    a = __riscv_vadd_vv_i32m4(a, nudge_v, vl);                                \
    a = __riscv_vsra_vv_i32m4(                                                \
        a, __riscv_vreinterpret_v_i32m4_u32m4(right_shift_v), vl);            \
    a = __riscv_vadd_vx_i32m4(a, output_offset, vl);                          \
    a = __riscv_vmax_vx_i32m4(a, data.output_activation_min, vl);             \
    a = __riscv_vmin_vx_i32m4(a, data.output_activation_max, vl);             \
    vint16m2_t a16 = __riscv_vnclip_wx_i16m2(a, 0, 0, vl);                    \
    vint8m1_t a8 = __riscv_vnclip_wx_i8m1(a16, 0, 0, vl);                     \
    int8_t* out_ptr = output_data +                                           \
                      (batch * output_height * output_width * output_depth) + \
                      (out_y * output_width * output_depth) +                 \
                      ((out_x + OFFSET) * output_depth) + out_channel_start;  \
    __riscv_vse8_v_i8m1(out_ptr, a8, vl);                                     \
  }
          QUANTIZE_AND_STORE_1(acc, 0);
#undef QUANTIZE_AND_STORE_1
        }
      }
    }
    out_channel_start += vl;
  }
}

void Conv_4_4_16_StrideN(
    const ConvParams& params, const OpDataConvCustom& data,
    const int32_t* output_multiplier, const uint8_t* shift_left,
    const uint8_t* shift_right, TfLiteContext* context,
    const RuntimeShape& input_shape, const int8_t* input_data,
    const RuntimeShape& filter_shape, const int8_t* filter_data,
    const RuntimeShape& bias_shape, const int32_t* bias_data,
    const RuntimeShape& output_shape, int8_t* output_data) {
  const auto batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int16_t input_offset = params.input_offset;  // r = s(q - Z)
  const auto output_offset = params.output_offset;
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;
  const auto stride_width = params.stride_width;
  const auto stride_height = params.stride_height;
  const auto pad_width = params.padding_values.width;
  const auto pad_height = params.padding_values.height;
  const auto input_height = input_shape.Dims(1);
  const auto input_width = input_shape.Dims(2);
  const auto input_depth = input_shape.Dims(3);

  const auto filter_height = filter_shape.Dims(1);
  const auto filter_width = filter_shape.Dims(2);
  TFLITE_DCHECK_EQ(filter_height, 4);
  TFLITE_DCHECK_EQ(filter_width, 4);
  TFLITE_DCHECK_LE(input_depth, 16);

  const auto output_height = output_shape.Dims(1);
  const auto output_width = output_shape.Dims(2);
  const auto output_depth = output_shape.Dims(3);
  size_t vl = __riscv_vsetvl_e8m1(input_depth);
  const int row_stride = input_width * input_depth;
  const int col_stride = input_depth;
  const int row_step = stride_height * row_stride;
  const int col_step = stride_width * col_stride;

  const int filter_row_stride = filter_shape.Dims(2) * input_depth;
  const int filter_col_stride = input_depth;

  int32_t* accs_buf = static_cast<int32_t*>(
      context->GetScratchBuffer(context, data.accs_buffer_index));
  TFLITE_DCHECK_NE(accs_buf, nullptr);
  // Clear the accumulator buffer
  Memset(
      accs_buf, 0,
      batches * output_height * output_width * output_depth * sizeof(int32_t));

  for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
    const int8_t* filter_base_ptr =
        &filter_data[Offset(filter_shape, out_channel, 0, 0, 0)];
    register vint8m1_t fil00 __asm__("v1");
    register vint8m1_t fil01 __asm__("v2");
    register vint8m1_t fil02 __asm__("v3");
    register vint8m1_t fil03 __asm__("v4");
    register vint8m1_t fil10 __asm__("v5");
    register vint8m1_t fil11 __asm__("v6");
    register vint8m1_t fil12 __asm__("v7");
    register vint8m1_t fil13 __asm__("v8");
    register vint8m1_t fil20 __asm__("v9");
    register vint8m1_t fil21 __asm__("v10");
    register vint8m1_t fil22 __asm__("v11");
    register vint8m1_t fil23 __asm__("v12");
    register vint8m1_t fil30 __asm__("v13");
    register vint8m1_t fil31 __asm__("v14");
    register vint8m1_t fil32 __asm__("v15");
    register vint8m1_t fil33 __asm__("v16");

    fil00 = __riscv_vle8_v_i8m1(filter_base_ptr, vl);
    fil01 = __riscv_vle8_v_i8m1(filter_base_ptr + 1 * filter_col_stride, vl);
    fil02 = __riscv_vle8_v_i8m1(filter_base_ptr + 2 * filter_col_stride, vl);
    fil03 = __riscv_vle8_v_i8m1(filter_base_ptr + 3 * filter_col_stride, vl);
    fil10 = __riscv_vle8_v_i8m1(filter_base_ptr + filter_row_stride, vl);
    fil11 = __riscv_vle8_v_i8m1(
        filter_base_ptr + filter_row_stride + 1 * filter_col_stride, vl);
    fil12 = __riscv_vle8_v_i8m1(
        filter_base_ptr + filter_row_stride + 2 * filter_col_stride, vl);
    fil13 = __riscv_vle8_v_i8m1(
        filter_base_ptr + filter_row_stride + 3 * filter_col_stride, vl);
    fil20 = __riscv_vle8_v_i8m1(filter_base_ptr + 2 * filter_row_stride, vl);
    fil21 = __riscv_vle8_v_i8m1(
        filter_base_ptr + 2 * filter_row_stride + 1 * filter_col_stride, vl);
    fil22 = __riscv_vle8_v_i8m1(
        filter_base_ptr + 2 * filter_row_stride + 2 * filter_col_stride, vl);
    fil23 = __riscv_vle8_v_i8m1(
        filter_base_ptr + 2 * filter_row_stride + 3 * filter_col_stride, vl);
    fil30 = __riscv_vle8_v_i8m1(filter_base_ptr + 3 * filter_row_stride, vl);
    fil31 = __riscv_vle8_v_i8m1(
        filter_base_ptr + 3 * filter_row_stride + 1 * filter_col_stride, vl);
    fil32 = __riscv_vle8_v_i8m1(
        filter_base_ptr + 3 * filter_row_stride + 2 * filter_col_stride, vl);
    fil33 = __riscv_vle8_v_i8m1(
        filter_base_ptr + 3 * filter_row_stride + 3 * filter_col_stride, vl);

    for (int batch = 0; batch < batches; ++batch) {
      const int8_t* batch_base_ptr =
          &input_data[Offset(input_shape, batch, 0, 0, 0)];
      const int8_t* row_ptr =
          batch_base_ptr - pad_height * row_stride - pad_width * col_stride;
      for (int out_y = 0; out_y < output_height; ++out_y) {
        const int in_y_origin = (out_y * stride_height) - pad_height;
        const int8_t* base_ptr = row_ptr;

        for (int out_x = 0; out_x < output_width; ++out_x) {
          const int in_x_origin = (out_x * stride_width) - pad_width;

          vint32m4_t mul_acc1;
          mul_acc1 = __riscv_vmv_v_x_i32m4(0, vl);

          const int8_t* in_ptrs[4][4];
          for (int r = 0; r < 4; ++r) {
            for (int c = 0; c < 4; ++c) {
              in_ptrs[r][c] = base_ptr + r * row_stride + c * col_stride;
            }
          }
          if (in_y_origin >= 0 && in_y_origin + 3 < input_height &&
              in_x_origin >= 0 && in_x_origin + 3 < input_width) {
            // Fast Path: Entirely inside the image
            CONV_MAC(in_ptrs[0][0], fil00, mul_acc1);
            CONV_MAC(in_ptrs[0][1], fil01, mul_acc1);
            CONV_MAC(in_ptrs[0][2], fil02, mul_acc1);
            CONV_MAC(in_ptrs[0][3], fil03, mul_acc1);
            CONV_MAC(in_ptrs[1][0], fil10, mul_acc1);
            CONV_MAC(in_ptrs[1][1], fil11, mul_acc1);
            CONV_MAC(in_ptrs[1][2], fil12, mul_acc1);
            CONV_MAC(in_ptrs[1][3], fil13, mul_acc1);
            CONV_MAC(in_ptrs[2][0], fil20, mul_acc1);
            CONV_MAC(in_ptrs[2][1], fil21, mul_acc1);
            CONV_MAC(in_ptrs[2][2], fil22, mul_acc1);
            CONV_MAC(in_ptrs[2][3], fil23, mul_acc1);
            CONV_MAC(in_ptrs[3][0], fil30, mul_acc1);
            CONV_MAC(in_ptrs[3][1], fil31, mul_acc1);
            CONV_MAC(in_ptrs[3][2], fil32, mul_acc1);
            CONV_MAC(in_ptrs[3][3], fil33, mul_acc1);
          } else {
            // Slow Path: Crosses boundaries, handle with guards
            const bool rv0 =
                (in_y_origin + 0 >= 0) && (in_y_origin + 0 < input_height);
            const bool rv1 =
                (in_y_origin + 1 >= 0) && (in_y_origin + 1 < input_height);
            const bool rv2 =
                (in_y_origin + 2 >= 0) && (in_y_origin + 2 < input_height);
            const bool rv3 =
                (in_y_origin + 3 >= 0) && (in_y_origin + 3 < input_height);

            const bool cv0 =
                (in_x_origin + 0 >= 0) && (in_x_origin + 0 < input_width);
            const bool cv1 =
                (in_x_origin + 1 >= 0) && (in_x_origin + 1 < input_width);
            const bool cv2 =
                (in_x_origin + 2 >= 0) && (in_x_origin + 2 < input_width);
            const bool cv3 =
                (in_x_origin + 3 >= 0) && (in_x_origin + 3 < input_width);

            if (rv0) {
              if (cv0) {
                CONV_MAC(in_ptrs[0][0], fil00, mul_acc1);
              }
              if (cv1) {
                CONV_MAC(in_ptrs[0][1], fil01, mul_acc1);
              }
              if (cv2) {
                CONV_MAC(in_ptrs[0][2], fil02, mul_acc1);
              }
              if (cv3) {
                CONV_MAC(in_ptrs[0][3], fil03, mul_acc1);
              }
            }
            if (rv1) {
              if (cv0) {
                CONV_MAC(in_ptrs[1][0], fil10, mul_acc1);
              }
              if (cv1) {
                CONV_MAC(in_ptrs[1][1], fil11, mul_acc1);
              }
              if (cv2) {
                CONV_MAC(in_ptrs[1][2], fil12, mul_acc1);
              }
              if (cv3) {
                CONV_MAC(in_ptrs[1][3], fil13, mul_acc1);
              }
            }
            if (rv2) {
              if (cv0) {
                CONV_MAC(in_ptrs[2][0], fil20, mul_acc1);
              }
              if (cv1) {
                CONV_MAC(in_ptrs[2][1], fil21, mul_acc1);
              }
              if (cv2) {
                CONV_MAC(in_ptrs[2][2], fil22, mul_acc1);
              }
              if (cv3) {
                CONV_MAC(in_ptrs[2][3], fil23, mul_acc1);
              }
            }
            if (rv3) {
              if (cv0) {
                CONV_MAC(in_ptrs[3][0], fil30, mul_acc1);
              }
              if (cv1) {
                CONV_MAC(in_ptrs[3][1], fil31, mul_acc1);
              }
              if (cv2) {
                CONV_MAC(in_ptrs[3][2], fil32, mul_acc1);
              }
              if (cv3) {
                CONV_MAC(in_ptrs[3][3], fil33, mul_acc1);
              }
            }
          }
          int32_t temp_acc =
              __riscv_vmv_x_s_i32m1_i32(__riscv_vredsum_vs_i32m4_i32m1(
                  mul_acc1, __riscv_vmv_v_x_i32m1(0, 1), vl));
          accs_buf[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              temp_acc;
          base_ptr += col_step;
        }
        row_ptr += row_step;
      }
    }
  }

  // Post process the entire batch of accumulators at once
  PostprocessAcc(accs_buf, bias_data, shift_left, output_multiplier,
                 shift_right, output_offset, output_activation_min,
                 output_activation_max, output_data,
                 batches * output_height * output_width, output_depth);
}

// Kernel for 4x4 filter, 48 input channels, stride 1
// Strategy:
// - Divide 48 input channels into 3 chunks of 16.
// - Outer loops: batch, output_channel.
// - Inner loop: chunk (0..2).
//   - Load 4x4x16 filter path into registers v1-v16.
//   - Loop over spatial dimensions (out_y, out_x).
//     - Compute 2x output pixels (out_x, out_x+1).
//     - Accumulate into accs_buf.
void Conv_4_4_48_Stride1(
    const ConvParams& params, const OpDataConvCustom& data,
    const int32_t* output_multiplier, const uint8_t* shift_left,
    const uint8_t* shift_right, TfLiteContext* context,
    const RuntimeShape& input_shape, const int8_t* input_data,
    const RuntimeShape& filter_shape, const int8_t* filter_data,
    const RuntimeShape& bias_shape, const int32_t* bias_data,
    const RuntimeShape& output_shape, int8_t* output_data) {
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int input_depth = input_shape.Dims(3);
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  const int output_depth = output_shape.Dims(3);
  const int32_t output_offset = params.output_offset;
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;
  const int filter_row_stride = filter_shape.Dims(2) * input_depth;
  const int filter_col_stride = input_depth;
  const int32_t input_offset = params.input_offset;

  int32_t* accs_buf = static_cast<int32_t*>(
      context->GetScratchBuffer(context, data.accs_buffer_index));
  TFLITE_DCHECK_NE(accs_buf, nullptr);
  // Clear the accumulator buffer
  Memset(
      accs_buf, 0,
      batches * output_height * output_width * output_depth * sizeof(int32_t));

  for (int batch = 0; batch < batches; ++batch) {
    for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
      const int8_t* filter_base_ptr =
          filter_data + Offset(filter_shape, out_channel, 0, 0, 0);

      int rem_channels = input_depth;
      // Divide input depth (48) into 3 chunks of 16 (or more for general depth)
      // Use (input_depth + 15) / 16 to determine number of chunks
      int num_chunks = (input_depth + 15) / 16;
      for (int chunk = 0; chunk < num_chunks; ++chunk) {
        const int8_t* chunk_ptr = filter_base_ptr + chunk * 16;

        // Pin filter patch to registers to match Conv_4_4_16 strategy
        register vint8m1_t fil00 __asm__("v1");
        register vint8m1_t fil01 __asm__("v2");
        register vint8m1_t fil02 __asm__("v3");
        register vint8m1_t fil03 __asm__("v4");
        register vint8m1_t fil10 __asm__("v5");
        register vint8m1_t fil11 __asm__("v6");
        register vint8m1_t fil12 __asm__("v7");
        register vint8m1_t fil13 __asm__("v8");
        register vint8m1_t fil20 __asm__("v9");
        register vint8m1_t fil21 __asm__("v10");
        register vint8m1_t fil22 __asm__("v11");
        register vint8m1_t fil23 __asm__("v12");
        register vint8m1_t fil30 __asm__("v13");
        register vint8m1_t fil31 __asm__("v14");
        register vint8m1_t fil32 __asm__("v15");
        register vint8m1_t fil33 __asm__("v16");

        size_t vl = __riscv_vsetvl_e8m1(rem_channels);
        rem_channels -= 16;

        fil00 = __riscv_vle8_v_i8m1(chunk_ptr, vl);
        fil01 = __riscv_vle8_v_i8m1(chunk_ptr + 1 * filter_col_stride, vl);
        fil02 = __riscv_vle8_v_i8m1(chunk_ptr + 2 * filter_col_stride, vl);
        fil03 = __riscv_vle8_v_i8m1(chunk_ptr + 3 * filter_col_stride, vl);
        fil10 = __riscv_vle8_v_i8m1(chunk_ptr + filter_row_stride, vl);
        fil11 = __riscv_vle8_v_i8m1(
            chunk_ptr + filter_row_stride + 1 * filter_col_stride, vl);
        fil12 = __riscv_vle8_v_i8m1(
            chunk_ptr + filter_row_stride + 2 * filter_col_stride, vl);
        fil13 = __riscv_vle8_v_i8m1(
            chunk_ptr + filter_row_stride + 3 * filter_col_stride, vl);
        fil20 = __riscv_vle8_v_i8m1(chunk_ptr + 2 * filter_row_stride, vl);
        fil21 = __riscv_vle8_v_i8m1(
            chunk_ptr + 2 * filter_row_stride + 1 * filter_col_stride, vl);
        fil22 = __riscv_vle8_v_i8m1(
            chunk_ptr + 2 * filter_row_stride + 2 * filter_col_stride, vl);
        fil23 = __riscv_vle8_v_i8m1(
            chunk_ptr + 2 * filter_row_stride + 3 * filter_col_stride, vl);
        fil30 = __riscv_vle8_v_i8m1(chunk_ptr + 3 * filter_row_stride, vl);
        fil31 = __riscv_vle8_v_i8m1(
            chunk_ptr + 3 * filter_row_stride + 1 * filter_col_stride, vl);
        fil32 = __riscv_vle8_v_i8m1(
            chunk_ptr + 3 * filter_row_stride + 2 * filter_col_stride, vl);
        fil33 = __riscv_vle8_v_i8m1(
            chunk_ptr + 3 * filter_row_stride + 3 * filter_col_stride, vl);

        const int row_stride = input_width * input_depth;
        const int col_stride = input_depth;

        const int pad_width = params.padding_values.width;
        const int pad_height = params.padding_values.height;

        const int8_t* base_ptr =
            input_data + Offset(input_shape, batch, 0, 0, chunk * 16);

        // Loop over spatial dimensions
        for (int out_y = 0; out_y < output_height; ++out_y) {
          const int in_y_origin = out_y - pad_height;
          const int8_t* row_ptr = base_ptr + in_y_origin * row_stride;

          for (int out_x = 0; out_x < output_width; out_x += 2) {
            const int in_x_origin1 = out_x - pad_width;
            const int in_x_origin2 = out_x + 1 - pad_width;

            // Pointers to the 16-element chunks
            const int8_t* in_ptrs[4][5];
            // Initialize assuming fast path first
            const int8_t* curr_ptr = row_ptr + in_x_origin1 * col_stride;

            for (int r = 0; r < 4; ++r) {
              for (int c = 0; c < 5; ++c) {
                in_ptrs[r][c] = curr_ptr + r * row_stride + c * col_stride;
              }
            }

            // Accumulators
            register vint32m4_t mul_acc1 __asm__("v20");
            register vint32m4_t mul_acc2 __asm__("v24");
            mul_acc1 = __riscv_vmv_v_x_i32m4(0, 16);
            mul_acc2 = __riscv_vmv_v_x_i32m4(0, 16);

            if (in_y_origin >= 0 && in_y_origin + 3 < input_height &&
                in_x_origin1 >= 0 && in_x_origin2 + 3 < input_width) {
              // Fast Path
              CONV_MAC(in_ptrs[0][0], fil00, mul_acc1);
              CONV_MAC_2X(in_ptrs[0][1], fil01, fil00);
              CONV_MAC_2X(in_ptrs[0][2], fil02, fil01);
              CONV_MAC_2X(in_ptrs[0][3], fil03, fil02);
              CONV_MAC(in_ptrs[0][4], fil03, mul_acc2);

              CONV_MAC(in_ptrs[1][0], fil10, mul_acc1);
              CONV_MAC_2X(in_ptrs[1][1], fil11, fil10);
              CONV_MAC_2X(in_ptrs[1][2], fil12, fil11);
              CONV_MAC_2X(in_ptrs[1][3], fil13, fil12);
              CONV_MAC(in_ptrs[1][4], fil13, mul_acc2);

              CONV_MAC(in_ptrs[2][0], fil20, mul_acc1);
              CONV_MAC_2X(in_ptrs[2][1], fil21, fil20);
              CONV_MAC_2X(in_ptrs[2][2], fil22, fil21);
              CONV_MAC_2X(in_ptrs[2][3], fil23, fil22);
              CONV_MAC(in_ptrs[2][4], fil23, mul_acc2);

              CONV_MAC(in_ptrs[3][0], fil30, mul_acc1);
              CONV_MAC_2X(in_ptrs[3][1], fil31, fil30);
              CONV_MAC_2X(in_ptrs[3][2], fil32, fil31);
              CONV_MAC_2X(in_ptrs[3][3], fil33, fil32);
              CONV_MAC(in_ptrs[3][4], fil33, mul_acc2);
            } else {
              const bool rv[4] = {
                  (in_y_origin + 0 >= 0) && (in_y_origin + 0 < input_height),
                  (in_y_origin + 1 >= 0) && (in_y_origin + 1 < input_height),
                  (in_y_origin + 2 >= 0) && (in_y_origin + 2 < input_height),
                  (in_y_origin + 3 >= 0) && (in_y_origin + 3 < input_height)};
              const bool cv1[4] = {
                  (in_x_origin1 + 0 >= 0) && (in_x_origin1 + 0 < input_width),
                  (in_x_origin1 + 1 >= 0) && (in_x_origin1 + 1 < input_width),
                  (in_x_origin1 + 2 >= 0) && (in_x_origin1 + 2 < input_width),
                  (in_x_origin1 + 3 >= 0) && (in_x_origin1 + 3 < input_width)};
              // Reconstruct slow path input pointers to handle OOB
              const int8_t* in_ptrs1[4][4];
              const int8_t* in_ptrs2[4][4];
              for (int r = 0; r < 4; ++r) {
                for (int c = 0; c < 4; ++c) {
                  in_ptrs1[r][c] = curr_ptr + r * row_stride + c * col_stride;
                  in_ptrs2[r][c] = in_ptrs1[r][c] + col_stride;
                }
              }

              if (rv[0]) {
                if (cv1[0]) CONV_MAC(in_ptrs1[0][0], fil00, mul_acc1);
                if (cv1[1]) CONV_MAC(in_ptrs1[0][1], fil01, mul_acc1);
                if (cv1[2]) CONV_MAC(in_ptrs1[0][2], fil02, mul_acc1);
                if (cv1[3]) CONV_MAC(in_ptrs1[0][3], fil03, mul_acc1);
              }
              if (rv[1]) {
                if (cv1[0]) CONV_MAC(in_ptrs1[1][0], fil10, mul_acc1);
                if (cv1[1]) CONV_MAC(in_ptrs1[1][1], fil11, mul_acc1);
                if (cv1[2]) CONV_MAC(in_ptrs1[1][2], fil12, mul_acc1);
                if (cv1[3]) CONV_MAC(in_ptrs1[1][3], fil13, mul_acc1);
              }
              if (rv[2]) {
                if (cv1[0]) CONV_MAC(in_ptrs1[2][0], fil20, mul_acc1);
                if (cv1[1]) CONV_MAC(in_ptrs1[2][1], fil21, mul_acc1);
                if (cv1[2]) CONV_MAC(in_ptrs1[2][2], fil22, mul_acc1);
                if (cv1[3]) CONV_MAC(in_ptrs1[2][3], fil23, mul_acc1);
              }
              if (rv[3]) {
                if (cv1[0]) CONV_MAC(in_ptrs1[3][0], fil30, mul_acc1);
                if (cv1[1]) CONV_MAC(in_ptrs1[3][1], fil31, mul_acc1);
                if (cv1[2]) CONV_MAC(in_ptrs1[3][2], fil32, mul_acc1);
                if (cv1[3]) CONV_MAC(in_ptrs1[3][3], fil33, mul_acc1);
              }

              const bool cv2[4] = {
                  (in_x_origin2 + 0 >= 0) && (in_x_origin2 + 0 < input_width),
                  (in_x_origin2 + 1 >= 0) && (in_x_origin2 + 1 < input_width),
                  (in_x_origin2 + 2 >= 0) && (in_x_origin2 + 2 < input_width),
                  (in_x_origin2 + 3 >= 0) && (in_x_origin2 + 3 < input_width)};

              if (rv[0]) {
                if (cv2[0]) CONV_MAC(in_ptrs2[0][0], fil00, mul_acc2);
                if (cv2[1]) CONV_MAC(in_ptrs2[0][1], fil01, mul_acc2);
                if (cv2[2]) CONV_MAC(in_ptrs2[0][2], fil02, mul_acc2);
                if (cv2[3]) CONV_MAC(in_ptrs2[0][3], fil03, mul_acc2);
              }
              if (rv[1]) {
                if (cv2[0]) CONV_MAC(in_ptrs2[1][0], fil10, mul_acc2);
                if (cv2[1]) CONV_MAC(in_ptrs2[1][1], fil11, mul_acc2);
                if (cv2[2]) CONV_MAC(in_ptrs2[1][2], fil12, mul_acc2);
                if (cv2[3]) CONV_MAC(in_ptrs2[1][3], fil13, mul_acc2);
              }
              if (rv[2]) {
                if (cv2[0]) CONV_MAC(in_ptrs2[2][0], fil20, mul_acc2);
                if (cv2[1]) CONV_MAC(in_ptrs2[2][1], fil21, mul_acc2);
                if (cv2[2]) CONV_MAC(in_ptrs2[2][2], fil22, mul_acc2);
                if (cv2[3]) CONV_MAC(in_ptrs2[2][3], fil23, mul_acc2);
              }
              if (rv[3]) {
                if (cv2[0]) CONV_MAC(in_ptrs2[3][0], fil30, mul_acc2);
                if (cv2[1]) CONV_MAC(in_ptrs2[3][1], fil31, mul_acc2);
                if (cv2[2]) CONV_MAC(in_ptrs2[3][2], fil32, mul_acc2);
                if (cv2[3]) CONV_MAC(in_ptrs2[3][3], fil33, mul_acc2);
              }
            }

            // Reduce and Accumulate to Buffer
            // Reduce mul_acc1
            int32_t acc1_val =
                __riscv_vmv_x_s_i32m1_i32(__riscv_vredsum_vs_i32m4_i32m1(
                    mul_acc1, __riscv_vmv_v_x_i32m1(0, 1), vl));
            // Reduce mul_acc2
            int32_t acc2_val =
                __riscv_vmv_x_s_i32m1_i32(__riscv_vredsum_vs_i32m4_i32m1(
                    mul_acc2, __riscv_vmv_v_x_i32m1(0, 1), vl));

            // Read-Modify-Write to Buffer
            int idx1 = Offset(output_shape, batch, out_y, out_x, out_channel);
            int idx2 =
                Offset(output_shape, batch, out_y, out_x + 1, out_channel);

            if (chunk == 0) {
              accs_buf[idx1] = acc1_val;
              if (out_x + 1 < output_width) accs_buf[idx2] = acc2_val;
            } else {
              accs_buf[idx1] += acc1_val;
              if (out_x + 1 < output_width) accs_buf[idx2] += acc2_val;
            }
          }
        }
      }
    }
  }
  // After all batches processed
  PostprocessAcc(accs_buf, bias_data, shift_left, output_multiplier,
                 shift_right, output_offset, output_activation_min,
                 output_activation_max, output_data,
                 batches * output_height * output_width, output_depth);
}

void Conv_4_4_16(const ConvParams& params, const OpDataConvCustom& data,
                 const int32_t* output_multiplier, const uint8_t* shift_left,
                 const uint8_t* shift_right, TfLiteContext* context,
                 const RuntimeShape& input_shape, const int8_t* input_data,
                 const RuntimeShape& filter_shape, const int8_t* filter_data,
                 const RuntimeShape& bias_shape, const int32_t* bias_data,
                 const RuntimeShape& output_shape, int8_t* output_data) {
  // Todo add a Stride specific strategy for Stride == 1 and 2
  Conv_4_4_16_StrideN(params, data, output_multiplier, shift_left, shift_right,
                      context, input_shape, input_data, filter_shape,
                      filter_data, bias_shape, bias_data, output_shape,
                      output_data);
}

#undef CONV_MAC

void RepackWeightsD48(const int8_t* __restrict src, int16_t* __restrict dst,
                      int32_t* __restrict weight_sums, int output_depth,
                      int filter_height, int filter_width, int input_depth) {
  for (int oc = 0; oc < output_depth; ++oc) weight_sums[oc] = 0;

  const int oc_block_size = 16;
  for (int oc_block = 0; oc_block < output_depth; oc_block += oc_block_size) {
    for (int ky = 0; ky < filter_height; ++ky) {
      for (int kx = 0; kx < filter_width; ++kx) {
        for (int ic = 0; ic < input_depth; ++ic) {
          for (int oc_inner = 0; oc_inner < oc_block_size; ++oc_inner) {
            int oc = oc_block + oc_inner;
            if (oc < output_depth) {
              int src_idx = oc * (filter_height * filter_width * input_depth) +
                            ky * (filter_width * input_depth) +
                            kx * input_depth + ic;
              int8_t val = src[src_idx];
              *dst++ = static_cast<int16_t>(val);
              weight_sums[oc] += static_cast<int32_t>(val);
            } else {
              *dst++ = 0;
            }
          }
        }
      }
    }
  }
}

const int8_t* TiledPadInput(int8_t* __restrict dst_buffer,
                            const int8_t* __restrict src_batch,
                            int input_height, int input_width, int input_depth,
                            int32_t input_offset) {
  int stride_h_bytes = input_width * input_depth;
  const int margin_h = 4;
  const int margin_w = 4;

  int padded_width = input_width + 2 * margin_w;
  int dst_stride = padded_width * input_depth;

  std::memset(dst_buffer, static_cast<int8_t>(-input_offset),
              (input_height + 2 * margin_h) * dst_stride);

  int8_t* dst_base =
      dst_buffer + (margin_h * dst_stride) + (margin_w * input_depth);

  for (int y = 0; y < input_height; ++y) {
    const int8_t* src_row = src_batch + y * stride_h_bytes;
    int8_t* dst_row = dst_base + y * dst_stride;
    std::memcpy(dst_row, src_row, stride_h_bytes);
  }

  return dst_buffer;
}

void Conv_4x4_OCVectorized(const tflite::ConvParams& params,
                           const tflite::OpDataConv& op_data,
                           const tflite::RuntimeShape& input_shape,
                           const int8_t* __restrict input_data,
                           const tflite::RuntimeShape& filter_shape,
                           const int8_t* __restrict filter_data,
                           const int32_t* __restrict bias_data,
                           const tflite::RuntimeShape& output_shape,
                           int8_t* __restrict output_data,
                           const int16_t* __restrict repacked_weights,
                           const int32_t* __restrict weight_sums,
                           const int8_t* __restrict tiled_input_buffer) {
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  const int output_depth = output_shape.Dims(3);
  const int input_depth = input_shape.Dims(3);
  const int batches = input_shape.Dims(0);

  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int32_t output_offset = params.output_offset;
  const int32_t input_offset_val = params.input_offset;

  int32_t adjusted_bias[256];
  for (int i = 0; i < output_depth; ++i) {
    adjusted_bias[i] = bias_data[i] + input_offset_val * weight_sums[i];
  }

  int padded_width = input_shape.Dims(2) + 8;
  int stride_padded_bytes = padded_width * input_depth;
  int pad_margin_offset = 4 * stride_padded_bytes + 4 * input_depth;

  // Pre-calculate strides for performance
  const int row_stride0 = 0;
  const int row_stride1 = stride_padded_bytes;
  const int row_stride2 = stride_padded_bytes * 2;
  const int row_stride3 = stride_padded_bytes * 3;
  const int s_step =
      stride_width * input_depth;  // Stride per spatial pixel in bytes

  for (int batch = 0; batch < batches; ++batch) {
    const int8_t* batch_src = input_data + batch * input_shape.Dims(1) *
                                               input_shape.Dims(2) *
                                               input_depth;
    TiledPadInput(const_cast<int8_t*>(tiled_input_buffer), batch_src,
                  input_shape.Dims(1), input_shape.Dims(2), input_depth,
                  input_offset_val);
    const int8_t* input_base = tiled_input_buffer + pad_margin_offset;

    for (int oc_block = 0; oc_block < output_depth;) {
      size_t vl = __riscv_vsetvl_e32m4(output_depth - oc_block);

      // --- Bias & Quantization Parameter Loading ---
      vint32m4_t bias_v = __riscv_vle32_v_i32m4(adjusted_bias + oc_block, vl);
      vint32m4_t mult_v = __riscv_vle32_v_i32m4(
          op_data.per_channel_output_multiplier + oc_block, vl);
      vint32m4_t shift_v = __riscv_vle32_v_i32m4(
          op_data.per_channel_output_shift + oc_block, vl);

      vint32m4_t left_shift_v = __riscv_vmax_vx_i32m4(shift_v, 0, vl);
      vint32m4_t right_shift_v =
          __riscv_vmax_vx_i32m4(__riscv_vneg_v_i32m4(shift_v, vl), 0, vl);
      vint32m4_t nudge_v = __riscv_vmv_v_x_i32m4(0, vl);
      vbool8_t mask_gt0 = __riscv_vmsgt_vx_i32m4_b8(right_shift_v, 0, vl);
      vint32m4_t shift_minus_1_v = __riscv_vsub_vx_i32m4(right_shift_v, 1, vl);
      nudge_v = __riscv_vsll_vv_i32m4_mu(
          mask_gt0, nudge_v, __riscv_vmv_v_x_i32m4(1, vl),
          __riscv_vreinterpret_v_i32m4_u32m4(shift_minus_1_v), vl);

      for (int out_y = 0; out_y < output_height; ++out_y) {
        const int in_y_origin = (out_y * stride_height) - pad_height;
        const int8_t* row_ptr_base =
            input_base + in_y_origin * stride_padded_bytes;

        // Pointers for 4 rows of the kernel
        const int8_t* r0 = row_ptr_base + row_stride0;
        const int8_t* r1 = row_ptr_base + row_stride1;
        const int8_t* r2 = row_ptr_base + row_stride2;
        const int8_t* r3 = row_ptr_base + row_stride3;

        int out_x = 0;
        // --- 4x Unrolled Spatial Loop ---
        for (; out_x <= output_width - 4; out_x += 4) {
          // Initialize accumulators with bias
          vint32m4_t acc0 = bias_v;
          vint32m4_t acc1 = bias_v;
          vint32m4_t acc2 = bias_v;
          vint32m4_t acc3 = bias_v;

          const int in_x_offset =
              ((out_x * stride_width) - pad_width) * input_depth;
          const int16_t* w_ptr =
              repacked_weights + (oc_block * 4 * 4 * input_depth);

          // Pointers to the 4 horizontal spatial inputs
          const int8_t* p0_base = r0 + in_x_offset;
          const int8_t* p1_base = r1 + in_x_offset;
          const int8_t* p2_base = r2 + in_x_offset;
          const int8_t* p3_base = r3 + in_x_offset;

          // Kernel Height Loop (4)
          for (int ky = 0; ky < 4; ++ky) {
            const int8_t* p0 =
                (ky == 0)
                    ? p0_base
                    : ((ky == 1) ? p1_base : ((ky == 2) ? p2_base : p3_base));
            const int8_t* p_sp0 = p0;
            const int8_t* p_sp1 = p0 + s_step;
            const int8_t* p_sp2 = p0 + s_step * 2;
            const int8_t* p_sp3 = p0 + s_step * 3;

            // Kernel Width Loop (4)
            for (int kx = 0; kx < 4; ++kx) {
              // **OPTIMIZATION CORE**: Unroll IC by 4
              for (int ic = 0; ic < input_depth; ic += 4) {
                // Load weights for next 4 depth steps
                vint16m2_t w_0 = __riscv_vle16_v_i16m2(w_ptr, vl);
                vint16m2_t w_1 = __riscv_vle16_v_i16m2(w_ptr + vl, vl);
                vint16m2_t w_2 = __riscv_vle16_v_i16m2(w_ptr + 2 * vl, vl);
                vint16m2_t w_3 = __riscv_vle16_v_i16m2(w_ptr + 3 * vl, vl);
                w_ptr += 4 * vl;

                // IC Step 0
                acc0 = __riscv_vwmacc_vx_i32m4(acc0, *p_sp0++, w_0, vl);
                acc1 = __riscv_vwmacc_vx_i32m4(acc1, *p_sp1++, w_0, vl);
                acc2 = __riscv_vwmacc_vx_i32m4(acc2, *p_sp2++, w_0, vl);
                acc3 = __riscv_vwmacc_vx_i32m4(acc3, *p_sp3++, w_0, vl);

                // IC Step 1
                acc0 = __riscv_vwmacc_vx_i32m4(acc0, *p_sp0++, w_1, vl);
                acc1 = __riscv_vwmacc_vx_i32m4(acc1, *p_sp1++, w_1, vl);
                acc2 = __riscv_vwmacc_vx_i32m4(acc2, *p_sp2++, w_1, vl);
                acc3 = __riscv_vwmacc_vx_i32m4(acc3, *p_sp3++, w_1, vl);

                // IC Step 2
                acc0 = __riscv_vwmacc_vx_i32m4(acc0, *p_sp0++, w_2, vl);
                acc1 = __riscv_vwmacc_vx_i32m4(acc1, *p_sp1++, w_2, vl);
                acc2 = __riscv_vwmacc_vx_i32m4(acc2, *p_sp2++, w_2, vl);
                acc3 = __riscv_vwmacc_vx_i32m4(acc3, *p_sp3++, w_2, vl);

                // IC Step 3
                acc0 = __riscv_vwmacc_vx_i32m4(acc0, *p_sp0++, w_3, vl);
                acc1 = __riscv_vwmacc_vx_i32m4(acc1, *p_sp1++, w_3, vl);
                acc2 = __riscv_vwmacc_vx_i32m4(acc2, *p_sp2++, w_3, vl);
                acc3 = __riscv_vwmacc_vx_i32m4(acc3, *p_sp3++, w_3, vl);
              }
            }
          }

// Quantize and Store Block (Macroized to save space)
#define QUANTIZE_AND_STORE(acc, idx)                                      \
  {                                                                       \
    acc = __riscv_vsll_vv_i32m4(                                          \
        acc, __riscv_vreinterpret_v_i32m4_u32m4(left_shift_v), vl);       \
    acc = __riscv_vsmul_vv_i32m4(acc, mult_v, 0, vl);                     \
    acc = __riscv_vadd_vv_i32m4(acc, nudge_v, vl);                        \
    acc = __riscv_vsra_vv_i32m4(                                          \
        acc, __riscv_vreinterpret_v_i32m4_u32m4(right_shift_v), vl);      \
    acc = __riscv_vadd_vx_i32m4(acc, output_offset, vl);                  \
    acc = __riscv_vmax_vx_i32m4(acc, op_data.output_activation_min, vl);  \
    acc = __riscv_vmin_vx_i32m4(acc, op_data.output_activation_max, vl);  \
    vint16m2_t a16 = __riscv_vnclip_wx_i16m2(acc, 0, 0, vl);              \
    vint8m1_t a8 = __riscv_vnclip_wx_i8m1(a16, 0, 0, vl);                 \
    int8_t* dst = output_data +                                           \
                  (batch * output_height * output_width * output_depth) + \
                  (out_y * output_width * output_depth) +                 \
                  ((out_x + idx) * output_depth) + oc_block;              \
    __riscv_vse8_v_i8m1(dst, a8, vl);                                     \
  }

          QUANTIZE_AND_STORE(acc0, 0);
          QUANTIZE_AND_STORE(acc1, 1);
          QUANTIZE_AND_STORE(acc2, 2);
          QUANTIZE_AND_STORE(acc3, 3);
#undef QUANTIZE_AND_STORE
        }

        // --- Handle Remaining Columns (1..3) ---
        // (Simplified scalar loop for boundaries)
        for (; out_x < output_width; ++out_x) {
          vint32m4_t acc = bias_v;
          const int in_x_offset =
              ((out_x * stride_width) - pad_width) * input_depth;
          const int16_t* w_ptr =
              repacked_weights + (oc_block * 4 * 4 * input_depth);

          // Pointers to the kernel rows
          const int8_t* r_ptrs[] = {r0 + in_x_offset, r1 + in_x_offset,
                                    r2 + in_x_offset, r3 + in_x_offset};

          for (int ky = 0; ky < 4; ++ky) {
            const int8_t* p = r_ptrs[ky];
            for (int kx = 0; kx < 4; ++kx) {
              // Vectorized Inner Loop for boundary (unroll by 4 still helps)
              for (int ic = 0; ic < input_depth; ic += 4) {
                vint16m2_t w_0 = __riscv_vle16_v_i16m2(w_ptr, vl);
                vint16m2_t w_1 = __riscv_vle16_v_i16m2(w_ptr + vl, vl);
                vint16m2_t w_2 = __riscv_vle16_v_i16m2(w_ptr + 2 * vl, vl);
                vint16m2_t w_3 = __riscv_vle16_v_i16m2(w_ptr + 3 * vl, vl);
                w_ptr += 4 * vl;

                acc = __riscv_vwmacc_vx_i32m4(acc, *p++, w_0, vl);
                acc = __riscv_vwmacc_vx_i32m4(acc, *p++, w_1, vl);
                acc = __riscv_vwmacc_vx_i32m4(acc, *p++, w_2, vl);
                acc = __riscv_vwmacc_vx_i32m4(acc, *p++, w_3, vl);
              }
            }
          }
#define QUANTIZE_AND_STORE_1(acc)                                         \
  {                                                                       \
    acc = __riscv_vsll_vv_i32m4(                                          \
        acc, __riscv_vreinterpret_v_i32m4_u32m4(left_shift_v), vl);       \
    acc = __riscv_vsmul_vv_i32m4(acc, mult_v, 0, vl);                     \
    acc = __riscv_vadd_vv_i32m4(acc, nudge_v, vl);                        \
    acc = __riscv_vsra_vv_i32m4(                                          \
        acc, __riscv_vreinterpret_v_i32m4_u32m4(right_shift_v), vl);      \
    acc = __riscv_vadd_vx_i32m4(acc, output_offset, vl);                  \
    acc = __riscv_vmax_vx_i32m4(acc, op_data.output_activation_min, vl);  \
    acc = __riscv_vmin_vx_i32m4(acc, op_data.output_activation_max, vl);  \
    vint16m2_t a16 = __riscv_vnclip_wx_i16m2(acc, 0, 0, vl);              \
    vint8m1_t a8 = __riscv_vnclip_wx_i8m1(a16, 0, 0, vl);                 \
    int8_t* dst = output_data +                                           \
                  (batch * output_height * output_width * output_depth) + \
                  (out_y * output_width * output_depth) +                 \
                  (out_x * output_depth) + oc_block;                      \
    __riscv_vse8_v_i8m1(dst, a8, vl);                                     \
  }
          QUANTIZE_AND_STORE_1(acc);
#undef QUANTIZE_AND_STORE_1
        }
      }
      oc_block += vl;
    }
  }
}

void ConvPerChannel(const ConvParams& params, const OpDataConvCustom& data,
                    const int32_t* output_multiplier,
                    const int32_t* output_shift, TfLiteContext* context,
                    const RuntimeShape& input_shape, const int8_t* input_data,
                    const RuntimeShape& filter_shape, const int8_t* filter_data,
                    const RuntimeShape& bias_shape, const int32_t* bias_data,
                    const RuntimeShape& output_shape, int8_t* output_data) {
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);

  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);

  const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_NE(groups, 0);
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int filters_per_group = output_depth / groups;
  TFLITE_DCHECK_NE(filters_per_group, 0);

  // Copy filter and bias to dtcm.
  auto filter_data_copy =
      make_aligned_array<int8_t>(16, filter_shape.FlatSize(), filter_data);
  // TODO(davidgao): if allocation fails, don't copy, use orig
  TFLITE_DCHECK_NE(filter_data_copy, nullptr);

  aligned_array<int32_t> bias_data_copy;
  if (bias_data) {
    bias_data_copy = make_aligned_array<int32_t>(16, output_depth, bias_data);
    // TODO(davidgao): if allocation fails, don't copy, use orig
    TFLITE_DCHECK_NE(bias_data_copy, nullptr);
  }

  // Shifting from quantization params for vectorization
  auto shift_left = make_aligned_array<uint8_t>(16, output_depth);
  TFLITE_DCHECK_NE(shift_left, nullptr);
  auto shift_right = make_aligned_array<uint8_t>(16, output_depth);
  TFLITE_DCHECK_NE(shift_right, nullptr);
  PrepareShiftParams(shift_left.get(), shift_right.get(), output_shift,
                     output_depth);

  if (filter_height == 4 && filter_width == 4 && (input_depth % 4 == 0) &&
      data.repacked_weights != nullptr) {
    int8_t* tiled_buffer = static_cast<int8_t*>(
        context->GetScratchBuffer(context, data.tiled_input_buffer_index));
    Conv_4x4_OCVectorized(params, data, input_shape, input_data, filter_shape,
                          filter_data_copy.get(), bias_data_copy.get(),
                          output_shape, output_data, data.repacked_weights,
                          data.weight_sums, tiled_buffer);
  } else if (filter_height == 4 && filter_width == 4 &&
             data.repacked_weights_generic != nullptr && output_depth >= 32) {
    // Prefer generic optimized kernel for large output depth
    Conv2D_4x4(params, data, input_shape, input_data, filter_shape,
               filter_data_copy.get(), bias_data_copy.get(), output_shape,
               output_data, data.repacked_weights_generic, context);
  } else if (filter_height == 4 && filter_width == 4 && input_depth <= 16) {
    Conv_4_4_16(params, data, output_multiplier, shift_left.get(),
                shift_right.get(), context, input_shape, input_data,
                filter_shape, filter_data_copy.get(), bias_shape,
                bias_data_copy.get(), output_shape, output_data);
  } else if (filter_height == 4 && filter_width == 4 && input_depth <= 48 &&
             params.stride_width == 1 && params.stride_height == 1) {
    Conv_4_4_48_Stride1(params, data, output_multiplier, shift_left.get(),
                        shift_right.get(), context, input_shape, input_data,
                        filter_shape, filter_data_copy.get(), bias_shape,
                        bias_data_copy.get(), output_shape, output_data);
  } else if (filter_height == 4 && filter_width == 4 &&
             data.repacked_weights_generic != nullptr) {
    Conv2D_4x4(params, data, input_shape, input_data, filter_shape,
               filter_data_copy.get(), bias_data_copy.get(), output_shape,
               output_data, data.repacked_weights_generic, context);
  } else {
    MicroPrintf("Fallback kernel: fh=%d fw=%d id=%d od=%d oh=%d ow=%d", filter_height, filter_width,
                input_depth, output_depth, output_shape.Dims(1), output_shape.Dims(2));
    tflite::reference_integer_ops::ConvPerChannel(
        params, output_multiplier, output_shift, input_shape, input_data,
        filter_shape, filter_data, bias_shape, bias_data, output_shape,
        output_data);
  }
}

TfLiteStatus ConvEval(TfLiteContext* context, TfLiteNode* node) {
  TFLITE_DCHECK(node->user_data != nullptr);
  TFLITE_DCHECK(node->builtin_data != nullptr);

  const auto& params =
      *(reinterpret_cast<TfLiteConvParams*>(node->builtin_data));
  const auto& data = *(static_cast<const OpDataConvCustom*>(node->user_data));

  TfLiteEvalTensor* output = GetEvalOutput(context, node, kConvOutputTensor);
  const TfLiteEvalTensor* input = GetEvalInput(context, node, kConvInputTensor);
  const TfLiteEvalTensor* filter =
      GetEvalInput(context, node, kConvWeightsTensor);
  const TfLiteEvalTensor* bias =
      (NumInputs(node) == 3) ? GetEvalInput(context, node, kConvBiasTensor)
                             : nullptr;

  switch (input->type) {  // Already know in/out types are same.
    case kTfLiteInt8: {
      switch (filter->type) {
        case kTfLiteInt8: {
          ConvPerChannel(
              tflite::ConvParamsQuantized(params, data), data,
              data.per_channel_output_multiplier, data.per_channel_output_shift,
              context, GetTensorShape(input), GetTensorData<int8_t>(input),
              GetTensorShape(filter), GetTensorData<int8_t>(filter),
              GetTensorShape(bias), GetOptionalTensorData<int32_t>(bias),
              GetTensorShape(output), GetTensorData<int8_t>(output));
          break;
        }
        default:
          return tflite::Register_CONV_2D().invoke(context, node);
      }
      break;
    }
    default:
      return tflite::Register_CONV_2D().invoke(context, node);
  }
  return kTfLiteOk;
}

void* ConvInit(TfLiteContext* context, const char* buffer, size_t length) {
  // Default tflite::ConvInit as a custom structure (OpDataConvCustom) is used
  // to store the scratch buffer index for our full-tensor accumulator buffering
  // strategy, so we cannot use the default tflite::ConvInit.
  TFLITE_DCHECK(context->AllocatePersistentBuffer != nullptr);
  void* ptr =
      context->AllocatePersistentBuffer(context, sizeof(OpDataConvCustom));
  if (ptr) {
    OpDataConvCustom* data = static_cast<OpDataConvCustom*>(ptr);
    memset(data, 0, sizeof(OpDataConvCustom));
    data->accs_buffer_index = -1;
    data->tiled_input_buffer_index = -1;
    data->generic_tiled_buffer_index = -1;
  }
  return ptr;
}

TfLiteStatus ConvPrepare(TfLiteContext* context, TfLiteNode* node) {
  TF_LITE_ENSURE_OK(context, tflite::ConvPrepare(context, node));

  // A custom Prepare to allocate the full-tensor accumulator buffer used for
  // vectorized post-processing, saving the index in our custom data.
  OpDataConvCustom* data = static_cast<OpDataConvCustom*>(node->user_data);
  tflite::MicroContext* micro_context = tflite::GetMicroContext(context);
  TfLiteTensor* output =
      micro_context->AllocateTempOutputTensor(node, kConvOutputTensor);
  TF_LITE_ENSURE(context, output != nullptr);

  const int batches = output->dims->data[0];
  const int output_height = output->dims->data[1];
  const int output_width = output->dims->data[2];
  const int output_depth = output->dims->data[3];

  size_t required_bytes =
      batches * output_height * output_width * output_depth * sizeof(int32_t);

  TF_LITE_ENSURE_STATUS(context->RequestScratchBufferInArena(
      context, required_bytes, &data->accs_buffer_index));

  TfLiteTensor* input =
      micro_context->AllocateTempInputTensor(node, kConvInputTensor);
  TfLiteTensor* filter =
      micro_context->AllocateTempInputTensor(node, kConvWeightsTensor);
  TF_LITE_ENSURE(context, input != nullptr);
  TF_LITE_ENSURE(context, filter != nullptr);

  const int input_depth = input->dims->data[3];
  const int input_width = input->dims->data[2];
  const int filter_height = filter->dims->data[1];
  const int filter_width = filter->dims->data[2];

  if (filter_height == 4 && filter_width == 4) {
    // Check for 4x4 optimization opportunity (Generic)
    size_t repacked_size =
        output_depth * filter_height * filter_width * input_depth;
    data->repacked_weights_generic = static_cast<int8_t*>(
        context->AllocatePersistentBuffer(context, repacked_size));
    if (data->repacked_weights_generic) {
      const int8_t* original_weights = filter->data.int8;
      int8_t* dst = data->repacked_weights_generic;
      for (int ky = 0; ky < filter_height; ++ky) {
        for (int kx = 0; kx < filter_width; ++kx) {
          for (int ic = 0; ic < input_depth; ++ic) {
            for (int oc = 0; oc < output_depth; ++oc) {
              int src_idx = oc * (filter_height * filter_width * input_depth) +
                            ky * (filter_width * input_depth) +
                            kx * input_depth + ic;
              *dst++ = original_weights[src_idx];
            }
          }
        }
      }
    }
    TF_LITE_ENSURE_STATUS(context->RequestScratchBufferInArena(
        context, kInputBufferSize, &data->generic_tiled_buffer_index));
  }

  if (filter_height == 4 && filter_width == 4 && (input_depth % 4 == 0) &&
      output_depth <= 256) {
    size_t repacked_weights_size = output_depth * filter_height * filter_width *
                                   input_depth * sizeof(int16_t);
    data->repacked_weights = static_cast<int16_t*>(
        context->AllocatePersistentBuffer(context, repacked_weights_size));
    TF_LITE_ENSURE(context, data->repacked_weights != nullptr);

    size_t weight_sums_size = output_depth * sizeof(int32_t);
    data->weight_sums = static_cast<int32_t*>(
        context->AllocatePersistentBuffer(context, weight_sums_size));
    TF_LITE_ENSURE(context, data->weight_sums != nullptr);

    RepackWeightsD48(filter->data.int8, data->repacked_weights,
                     data->weight_sums, output_depth, filter_height,
                     filter_width, input_depth);

    int padded_width = input_width + 8;  // margin_w * 2
    int stride_padded_bytes = padded_width * input_depth;
    int input_height_val = input->dims->data[1];
    size_t tiled_buffer_size = (input_height_val + 8) * stride_padded_bytes;
    TF_LITE_ENSURE_STATUS(context->RequestScratchBufferInArena(
        context, tiled_buffer_size, &data->tiled_input_buffer_index));
  } else {
    data->repacked_weights = nullptr;
    data->weight_sums = nullptr;
  }

  micro_context->DeallocateTempTfLiteTensor(input);
  micro_context->DeallocateTempTfLiteTensor(filter);
  micro_context->DeallocateTempTfLiteTensor(output);

  return kTfLiteOk;
}

TFLMRegistration Register_CONV_2D() {
  auto registration = tflite::Register_CONV_2D();
  registration.init = ConvInit;
  registration.prepare = ConvPrepare;
  registration.invoke = ConvEval;
  return registration;
}

}  // namespace coralnpu_v2::opt::litert_micro
