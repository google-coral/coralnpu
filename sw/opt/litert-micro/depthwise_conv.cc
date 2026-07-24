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

#include "sw/opt/litert-micro/depthwise_conv.h"

#include <riscv_vector.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>

#include "sw/opt/litert-micro/accumulator_util.h"
#include "sw/opt/litert-micro/memory_util.h"
#include "sw/opt/rvv_opt.h"
#include "tensorflow/lite/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"

#ifdef USE_TFLM_COMPRESSION
#error "USE_TFLM_COMPRESSION is not supported"
#endif  // USE_TFLM_COMPRESSION

namespace coralnpu_v2::opt::litert_micro {

using tflite::DepthwiseParams;
using tflite::kDepthwiseConvBiasTensor;
using tflite::kDepthwiseConvInputTensor;
using tflite::kDepthwiseConvOutputTensor;
using tflite::kDepthwiseConvWeightsTensor;
using tflite::NumInputs;
using tflite::OpDataConv;
using tflite::RuntimeShape;
using tflite::micro::GetEvalInput;
using tflite::micro::GetEvalOutput;
using tflite::micro::GetOptionalTensorData;
using tflite::micro::GetTensorData;
using tflite::micro::GetTensorShape;

namespace {
// TODO(davidgao): move away?
inline int idiv_ceil(int x, int y) { return (x + y - 1) / y; }

void DepthwiseConvPerChannelPatch(const DepthwiseParams &params, const int32_t *output_multiplier,
                                  const uint8_t *shift_left, const uint8_t *shift_right,
                                  const RuntimeShape &in_shape, const int8_t *in_data,
                                  const RuntimeShape &f_shape, const int8_t *f_data,
                                  const RuntimeShape &bias_shape, const int32_t *bias_data,
                                  const RuntimeShape &out_shape, int8_t *out_data, int out_y_st,
                                  int out_y_ed, int out_x_st, int out_x_ed, int32_t *accs) {
  // Get parameters.
  const int stride_w                 = params.stride_width;
  const int stride_h                 = params.stride_height;
  const int dilation_w               = params.dilation_width_factor;
  const int dilation_h               = params.dilation_height_factor;
  const int pad_w                    = params.padding_values.width;
  const int pad_h                    = params.padding_values.height;
  const int depth_multiplier         = params.depth_multiplier;
  const int32_t output_offset        = params.output_offset;
  const int8_t output_activation_min = params.quantized_activation_min;
  const int8_t output_activation_max = params.quantized_activation_max;
  const int16_t input_offset         = params.input_offset;

  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  const int batches = MatchingDim(in_shape, 0, out_shape, 0);
  const int out_d   = MatchingDim(f_shape, 3, out_shape, 3);
  const int in_h    = in_shape.Dims(1);
  const int in_w    = in_shape.Dims(2);
  const int in_d    = in_shape.Dims(3);
  const int f_h     = f_shape.Dims(1);
  const int f_w     = f_shape.Dims(2);

  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = out_y_st; out_y < out_y_ed; ++out_y) {
      const int in_y_orig = (out_y * stride_h) - pad_h;
      const int f_y_st    = idiv_ceil(std::max(0, -in_y_orig), dilation_h);
      const int f_y_ed    = std::min(f_h, idiv_ceil(in_h - in_y_orig, dilation_h));
      // Accumulators are at this scope.
      for (int out_x = out_x_st; out_x < out_x_ed; ++out_x) {
        const int in_x_orig   = (out_x * stride_w) - pad_w;
        const int f_x_st      = idiv_ceil(std::max(0, -in_x_orig), dilation_w);
        const int f_x_ed      = std::min(f_w, idiv_ceil(in_w - in_x_orig, dilation_w));
        const int in_index_o2 = Offset(in_shape, batch, in_y_orig + dilation_h * f_y_st,
                                       in_x_orig + dilation_w * f_x_st, 0);
        int in_ch             = 0;
        size_t in_ch_rem      = in_d;
        // TODO(davidgao): Consider moving this loop out. This could allow
        // systems with cache to reduce filter access cost.
        while (in_ch_rem > 0) {
          // Scalable with vlmax.
          const size_t vl = __riscv_vsetvl_e32m8(in_ch_rem);
          for (int m = 0; m < depth_multiplier; ++m) {
            const int out_ch = m + in_ch * depth_multiplier;
            // Initialize ACC
            vint32m8_t acc = __riscv_vmv_v_x_i32m8(0, vl);
            // This pair of ugly for loops are just doing scalar optimization
            // work for the compiler...
            for (int f_y = f_y_st, in_index_o1 = in_index_o2 + in_ch,
                     f_index_o1 = Offset(f_shape, 0, f_y_st, f_x_st, out_ch);
                 f_y < f_y_ed;
                 ++f_y, in_index_o1 += dilation_h * in_w * in_d, f_index_o1 += f_w * out_d) {
              for (int f_x = f_x_st, in_index_inner = in_index_o1, f_index_inner = f_index_o1;
                   f_x < f_x_ed;
                   ++f_x, in_index_inner += dilation_w * in_d, f_index_inner += out_d) {
                const vint8m2_t in_val8 = __riscv_vle8_v_i8m2(&in_data[in_index_inner], vl);
                const vint8m2_t f_val8  = __riscv_vlse8_v_i8m2(
                    &f_data[f_index_inner], sizeof(int8_t) * depth_multiplier, vl);
                vint16m4_t in_val16           = __riscv_vsext_vf2_i16m4(in_val8, vl);
                const vint16m4_t filter_val16 = __riscv_vsext_vf2_i16m4(f_val8, vl);
                // Input offset is applied.
                // Ref kernel does not apply filter offset.
                in_val16 = __riscv_vadd_vx_i16m4(in_val16, input_offset, vl);
                // Multiply-accumulate
                acc = __riscv_vwmacc_vv_i32m8(acc, in_val16, filter_val16, vl);
              }
            }
            // Spill accumulators and postprocess later.
            __riscv_vsse32_v_i32m8(&accs[(out_x - out_x_st) * out_d + out_ch],
                                   sizeof(int32_t) * depth_multiplier, acc, vl);
          }
          in_ch += vl;
          in_ch_rem -= vl;
        }
      }

      PostprocessAcc(accs, bias_data, shift_left, output_multiplier, shift_right, output_offset,
                     output_activation_min, output_activation_max,
                     &out_data[Offset(out_shape, batch, out_y, out_x_st, 0)],
                     /*out_w=*/out_x_ed - out_x_st, /*out_d=*/out_d);
    }
  }
}

void DepthwiseConvPerChannelPatchCenter3x3Reuse6(
    const DepthwiseParams &params, const int32_t *output_multiplier, const uint8_t *shift_left,
    const uint8_t *shift_right, const RuntimeShape &in_shape, const int8_t *in_data,
    const RuntimeShape &f_shape, const int8_t *f_data, const RuntimeShape &bias_shape,
    const int32_t *bias_data, const RuntimeShape &out_shape, int8_t *out_data, int out_y_st,
    int out_y_ed, int out_x_st, int out_x_ed, int32_t *accs) {
  // Get parameters.
  const int stride_w                 = params.stride_width;
  const int stride_h                 = params.stride_height;
  const int dilation_w               = params.dilation_width_factor;
  const int dilation_h               = params.dilation_height_factor;
  const int pad_w                    = params.padding_values.width;
  const int pad_h                    = params.padding_values.height;
  const int depth_multiplier         = params.depth_multiplier;
  const int32_t output_offset        = params.output_offset;
  const int8_t output_activation_min = params.quantized_activation_min;
  const int8_t output_activation_max = params.quantized_activation_max;
  const int16_t input_offset         = params.input_offset;

  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_LE(stride_w, dilation_w);

  const int batches = MatchingDim(in_shape, 0, out_shape, 0);
  const int out_d   = MatchingDim(f_shape, 3, out_shape, 3);
  // const int in_h = in_shape.Dims(1);
  // const int in_w = in_shape.Dims(2);
  const int in_d = in_shape.Dims(3);
  // const int f_h = f_shape.Dims(1);
  // const int f_w = f_shape.Dims(2);
  const int out_patch_h      = out_y_ed - out_y_st;
  const int out_patch_w      = out_x_ed - out_x_st;
  const int32_t acc_shape_[] = {1, out_patch_h, out_patch_w, out_d};
  const tflite::RuntimeShape acc_shape(4, acc_shape_);

  for (int batch = 0; batch < batches; ++batch) {
    // Accumulators in memory are at this scope.
    int in_ch        = 0;
    size_t in_ch_rem = in_d;
    while (in_ch_rem > 0) {
      // Scalable with vlmax.
      const size_t vl = __riscv_vsetvl_e32m4(in_ch_rem);
      for (int m = 0; m < depth_multiplier; ++m) {
        const int out_ch = m + in_ch * depth_multiplier;
        // Load filter
        const vint8m1_t f00_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 0, 0, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f01_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 0, 1, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f02_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 0, 2, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f10_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 1, 0, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f11_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 1, 1, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f12_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 1, 2, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f20_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 2, 0, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f21_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 2, 1, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        const vint8m1_t f22_v8 = __riscv_vlse8_v_i8m1(&f_data[Offset(f_shape, 0, 2, 2, out_ch)],
                                                      sizeof(int8_t) * depth_multiplier, vl);
        for (int out_y = out_y_st; out_y < out_y_ed; ++out_y) {
          const int in_y_orig = (out_y * stride_h) - pad_h;

          int out_x     = out_x_st;
          int in_x_orig = (out_x * stride_w) - pad_w;
          vint8m1_t in00_v8 =
              __riscv_vle8_v_i8m1(&in_data[Offset(in_shape, batch, in_y_orig + 0 * dilation_h,
                                                  in_x_orig + 0 * dilation_w, in_ch)],
                                  vl);
          vint8m1_t in01_v8 =
              __riscv_vle8_v_i8m1(&in_data[Offset(in_shape, batch, in_y_orig + 0 * dilation_h,
                                                  in_x_orig + 1 * dilation_w, in_ch)],
                                  vl);
          vint8m1_t in10_v8 =
              __riscv_vle8_v_i8m1(&in_data[Offset(in_shape, batch, in_y_orig + 1 * dilation_h,
                                                  in_x_orig + 0 * dilation_w, in_ch)],
                                  vl);
          vint8m1_t in11_v8 =
              __riscv_vle8_v_i8m1(&in_data[Offset(in_shape, batch, in_y_orig + 1 * dilation_h,
                                                  in_x_orig + 1 * dilation_w, in_ch)],
                                  vl);
          vint8m1_t in20_v8 =
              __riscv_vle8_v_i8m1(&in_data[Offset(in_shape, batch, in_y_orig + 2 * dilation_h,
                                                  in_x_orig + 0 * dilation_w, in_ch)],
                                  vl);
          vint8m1_t in21_v8 =
              __riscv_vle8_v_i8m1(&in_data[Offset(in_shape, batch, in_y_orig + 2 * dilation_h,
                                                  in_x_orig + 1 * dilation_w, in_ch)],
                                  vl);
          const int8_t *in_ptr0 = &in_data[Offset(in_shape, batch, in_y_orig + 0 * dilation_h,
                                                  in_x_orig + 2 * dilation_w, in_ch)];
          const int8_t *in_ptr1 = &in_data[Offset(in_shape, batch, in_y_orig + 1 * dilation_h,
                                                  in_x_orig + 2 * dilation_w, in_ch)];
          const int8_t *in_ptr2 = &in_data[Offset(in_shape, batch, in_y_orig + 2 * dilation_h,
                                                  in_x_orig + 2 * dilation_w, in_ch)];
          while (out_x < out_x_ed) {
            // Initialize ACC
            vint32m4_t acc;
            // Fighting the compiler who wants to save a reg of 0s
            asm volatile(
                "vsetvli zero, %[vl], e32, m4, ta, ma;"
                "vmv.v.i %[acc], 0;"
                : [acc] "=vr"(acc)
                : [vl] "r"(vl)
                : "vl", "vtype");
            // Load and process input
            {
              // Row 0
              asm("vsetvli zero, %[vl], e16, m2, ta, ma;"
                  "vsext.vf2 v2, %[in0_v8];"
                  "vle8.v v1, %[in_ptr];"  // in2_v8
                  "vsext.vf2 v4, %[f0_v8];"
                  "vadd.vx v2, v2, %[in_offset];"
                  "vsext.vf2 v6, %[in1_v8];"  // Moved
                  "vwmacc.vv %[acc], v2, v4;"
                  "vadd.vx v6, v6, %[in_offset];"
                  "vsext.vf2 v4, %[f1_v8];"
                  "vsext.vf2 v2, v1;"  // Moved
                  "vwmacc.vv %[acc], v6, v4;"
                  "vadd.vx v2, v2, %[in_offset];"
                  "vsext.vf2 v4, %[f2_v8];"
                  "vmv1r.v %[in0_v8], %[in1_v8];"  // Moved
                  "vwmacc.vv %[acc], v2, v4;"
                  "vmv1r.v %[in1_v8], v1;"
                  : [acc] "+vr"(acc), [in0_v8] "+vr"(in00_v8), [in1_v8] "+vr"(in01_v8)
                  : [f0_v8] "vr"(f00_v8), [f1_v8] "vr"(f01_v8), [f2_v8] "vr"(f02_v8),
                    [in_offset] "r"(input_offset), [in_ptr] "A"(*in_ptr0), [vl] "r"(vl)
                  : "v1", "v2", "v3", "v4", "v5", "v6", "v7", "vl", "vtype");
            }
            {
              // Row 1
              asm("vsetvli zero, %[vl], e16, m2, ta, ma;"
                  "vsext.vf2 v2, %[in0_v8];"
                  "vle8.v v1, %[in_ptr];"  // in2_v8
                  "vsext.vf2 v4, %[f0_v8];"
                  "vadd.vx v2, v2, %[in_offset];"
                  "vsext.vf2 v6, %[in1_v8];"  // Moved
                  "vwmacc.vv %[acc], v2, v4;"
                  "vadd.vx v6, v6, %[in_offset];"
                  "vsext.vf2 v4, %[f1_v8];"
                  "vsext.vf2 v2, v1;"  // Moved
                  "vwmacc.vv %[acc], v6, v4;"
                  "vadd.vx v2, v2, %[in_offset];"
                  "vsext.vf2 v4, %[f2_v8];"
                  "vmv1r.v %[in0_v8], %[in1_v8];"  // Moved
                  "vwmacc.vv %[acc], v2, v4;"
                  "vmv1r.v %[in1_v8], v1;"
                  : [acc] "+vr"(acc), [in0_v8] "+vr"(in10_v8), [in1_v8] "+vr"(in11_v8)
                  : [f0_v8] "vr"(f10_v8), [f1_v8] "vr"(f11_v8), [f2_v8] "vr"(f12_v8),
                    [in_offset] "r"(input_offset), [in_ptr] "A"(*in_ptr1), [vl] "r"(vl)
                  : "v1", "v2", "v3", "v4", "v5", "v6", "v7", "vl", "vtype");
            }
            {
              // Row 2
              asm("vsetvli zero, %[vl], e16, m2, ta, ma;"
                  "vsext.vf2 v2, %[in0_v8];"
                  "vle8.v v1, %[in_ptr];"  // in2_v8
                  "vsext.vf2 v4, %[f0_v8];"
                  "vadd.vx v2, v2, %[in_offset];"
                  "vsext.vf2 v6, %[in1_v8];"  // Moved
                  "vwmacc.vv %[acc], v2, v4;"
                  "vadd.vx v6, v6, %[in_offset];"
                  "vsext.vf2 v4, %[f1_v8];"
                  "vsext.vf2 v2, v1;"  // Moved
                  "vwmacc.vv %[acc], v6, v4;"
                  "vadd.vx v2, v2, %[in_offset];"
                  "vsext.vf2 v4, %[f2_v8];"
                  "vmv1r.v %[in0_v8], %[in1_v8];"  // Moved
                  "vwmacc.vv %[acc], v2, v4;"
                  "vmv1r.v %[in1_v8], v1;"
                  : [acc] "+vr"(acc), [in0_v8] "+vr"(in20_v8), [in1_v8] "+vr"(in21_v8)
                  : [f0_v8] "vr"(f20_v8), [f1_v8] "vr"(f21_v8), [f2_v8] "vr"(f22_v8),
                    [in_offset] "r"(input_offset), [in_ptr] "A"(*in_ptr2), [vl] "r"(vl)
                  : "v1", "v2", "v3", "v4", "v5", "v6", "v7", "vl", "vtype");
            }
            // Spill accumulators and postprocess later.
            __riscv_vsse32_v_i32m4(
                &accs[Offset(acc_shape, 0, out_y - out_y_st, out_x - out_x_st, out_ch)],
                sizeof(int32_t) * depth_multiplier, acc, vl);
            // End of iteration
            ++out_x;
            in_x_orig += stride_w;
            in_ptr0 += stride_w * in_d;
            in_ptr1 += stride_w * in_d;
            in_ptr2 += stride_w * in_d;
          }
        }
      }
      in_ch += vl;
      in_ch_rem -= vl;
    }

    for (int out_y = out_y_st; out_y < out_y_ed; ++out_y) {
      PostprocessAcc(&accs[Offset(acc_shape, 0, out_y - out_y_st, 0, 0)], bias_data, shift_left,
                     output_multiplier, shift_right, output_offset, output_activation_min,
                     output_activation_max, &out_data[Offset(out_shape, batch, out_y, out_x_st, 0)],
                     /*out_w=*/out_patch_w, /*out_d=*/out_d);
    }
  }
}
}  // namespace

void DepthwiseConvPerChannel(const DepthwiseParams &params, const int32_t *output_multiplier,
                             const int32_t *output_shift, const RuntimeShape &in_shape,
                             const int8_t *in_data, const RuntimeShape &f_shape,
                             const int8_t *f_data, const RuntimeShape &bias_shape,
                             const int32_t *bias_data, const RuntimeShape &out_shape,
                             int8_t *out_data, int32_t *accs_buf) {
  // Check dimensions of the tensors.
  TFLITE_DCHECK_EQ(in_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(f_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(out_shape.DimensionsCount(), 4);

  const int stride_w         = params.stride_width;
  const int stride_h         = params.stride_height;
  const int dilation_w       = params.dilation_width_factor;
  const int dilation_h       = params.dilation_height_factor;
  const int pad_w            = params.padding_values.width;
  const int pad_h            = params.padding_values.height;
  const int depth_multiplier = params.depth_multiplier;

  const int out_h = out_shape.Dims(1);
  const int out_w = out_shape.Dims(2);
  const int out_d = MatchingDim(f_shape, 3, out_shape, 3);
  const int in_d  = in_shape.Dims(3);
  const int f_h   = f_shape.Dims(1);
  const int f_w   = f_shape.Dims(2);

  TFLITE_DCHECK_EQ(out_d, in_d * depth_multiplier);
  TFLITE_DCHECK_EQ(bias_shape.FlatSize(), out_d);

  // Copy filter and bias to dtcm.
  // Copy filter and bias to dtcm.
  auto f_data_copy = make_aligned_array<int8_t>(16, f_shape.FlatSize(), f_data);
  // TODO(davidgao): if allocation fails, don't copy, use orig
  TFLITE_DCHECK_NE(f_data_copy, nullptr);

  aligned_array<int32_t> bias_data_copy;
  if (bias_data) {
    bias_data_copy = make_aligned_array<int32_t>(16, out_d, bias_data);
    // TODO(davidgao): if allocation fails, don't copy, use orig
    TFLITE_DCHECK_NE(bias_data_copy, nullptr);
  }

  // Shifting from quantization params.
  auto shift_left = make_aligned_array<uint8_t>(16, out_d);
  TFLITE_DCHECK_NE(shift_left, nullptr);
  auto shift_right = make_aligned_array<uint8_t>(16, out_d);
  TFLITE_DCHECK_NE(shift_right, nullptr);
  PrepareShiftParams(shift_left.get(), shift_right.get(), output_shift, out_d);

  // Cut down into sections
  const int out_y_top    = idiv_ceil(pad_h, stride_h);
  const int out_y_bottom = idiv_ceil(out_h + pad_h - f_h * dilation_h, stride_h);
  const int out_x_left   = idiv_ceil(pad_w, stride_w);
  const int out_x_right  = idiv_ceil(out_w + pad_w - f_w * dilation_w, stride_w);

  // Top
  DepthwiseConvPerChannelPatch(params, output_multiplier, shift_left.get(), shift_right.get(),
                               in_shape, in_data, f_shape, f_data_copy.get(), bias_shape,
                               bias_data_copy.get(), out_shape, out_data, 0, out_y_top, 0, out_w,
                               accs_buf);
  // Middle-left
  DepthwiseConvPerChannelPatch(params, output_multiplier, shift_left.get(), shift_right.get(),
                               in_shape, in_data, f_shape, f_data_copy.get(), bias_shape,
                               bias_data_copy.get(), out_shape, out_data, out_y_top, out_y_bottom,
                               0, out_x_left, accs_buf);
  // Center
  do {
    if ((f_h == 3) && (f_w == 3)) {
      if (stride_w == dilation_w) {
        DepthwiseConvPerChannelPatchCenter3x3Reuse6(
            params, output_multiplier, shift_left.get(), shift_right.get(), in_shape, in_data,
            f_shape, f_data_copy.get(), bias_shape, bias_data_copy.get(), out_shape, out_data,
            out_y_top, out_y_bottom, out_x_left, out_x_right, accs_buf);
        break;
      }
      // More variations to be added here
    }
    DepthwiseConvPerChannelPatch(params, output_multiplier, shift_left.get(), shift_right.get(),
                                 in_shape, in_data, f_shape, f_data_copy.get(), bias_shape,
                                 bias_data_copy.get(), out_shape, out_data, out_y_top, out_y_bottom,
                                 out_x_left, out_x_right, accs_buf);
  } while (false);
  // Middle-right
  DepthwiseConvPerChannelPatch(params, output_multiplier, shift_left.get(), shift_right.get(),
                               in_shape, in_data, f_shape, f_data_copy.get(), bias_shape,
                               bias_data_copy.get(), out_shape, out_data, out_y_top, out_y_bottom,
                               out_x_right, out_w, accs_buf);
  // Bottom
  DepthwiseConvPerChannelPatch(params, output_multiplier, shift_left.get(), shift_right.get(),
                               in_shape, in_data, f_shape, f_data_copy.get(), bias_shape,
                               bias_data_copy.get(), out_shape, out_data, out_y_bottom, out_h, 0,
                               out_w, accs_buf);
}

void *DepthwiseConvInit(TfLiteContext *context, const char *buffer, size_t length) {
  TFLITE_DCHECK(context->AllocatePersistentBuffer != nullptr);
  return context->AllocatePersistentBuffer(context, sizeof(OpDataConvCustom));
}

TfLiteStatus DepthwiseConvPrepare(TfLiteContext *context, TfLiteNode *node) {
  TF_LITE_ENSURE_OK(context, tflite::DepthwiseConvPrepare(context, node));

  OpDataConvCustom *data              = static_cast<OpDataConvCustom *>(node->user_data);
  tflite::MicroContext *micro_context = tflite::GetMicroContext(context);
  TfLiteTensor *output = micro_context->AllocateTempOutputTensor(node, kDepthwiseConvOutputTensor);
  TF_LITE_ENSURE(context, output != nullptr);

  const int batches       = output->dims->data[0];
  const int output_height = output->dims->data[1];
  const int output_width  = output->dims->data[2];
  const int output_depth  = output->dims->data[3];

  size_t required_bytes = batches * output_height * output_width * output_depth * sizeof(int32_t);

  TF_LITE_ENSURE_STATUS(
      context->RequestScratchBufferInArena(context, required_bytes, &data->accs_buffer_index));

  micro_context->DeallocateTempTfLiteTensor(output);

  return kTfLiteOk;
}

TfLiteStatus DepthwiseConvEval(TfLiteContext *context, TfLiteNode *node) {
  TFLITE_DCHECK(node->user_data != nullptr);
  TFLITE_DCHECK(node->builtin_data != nullptr);

  const auto &params = *(reinterpret_cast<TfLiteDepthwiseConvParams *>(node->builtin_data));
  const auto &data   = *(static_cast<const OpDataConvCustom *>(node->user_data));

  int32_t *accs_buf =
      static_cast<int32_t *>(context->GetScratchBuffer(context, data.accs_buffer_index));
  TFLITE_DCHECK_NE(accs_buf, nullptr);

  TfLiteEvalTensor *output       = GetEvalOutput(context, node, kDepthwiseConvOutputTensor);
  const TfLiteEvalTensor *input  = GetEvalInput(context, node, kDepthwiseConvInputTensor);
  const TfLiteEvalTensor *filter = GetEvalInput(context, node, kDepthwiseConvWeightsTensor);
  const TfLiteEvalTensor *bias =
      (NumInputs(node) == 3) ? GetEvalInput(context, node, kDepthwiseConvBiasTensor) : nullptr;

  switch (input->type) {  // Already know in/out types are same.
    case kTfLiteInt8: {
      switch (filter->type) {
        case kTfLiteInt8: {
          DepthwiseConvPerChannel(DepthwiseConvParamsQuantized(params, data),
                                  data.per_channel_output_multiplier, data.per_channel_output_shift,
                                  GetTensorShape(input), GetTensorData<int8_t>(input),
                                  GetTensorShape(filter), GetTensorData<int8_t>(filter),
                                  GetTensorShape(bias), GetOptionalTensorData<int32_t>(bias),
                                  GetTensorShape(output), GetTensorData<int8_t>(output), accs_buf);
          break;
        }
        default:
          return tflite::Register_DEPTHWISE_CONV_2D().invoke(context, node);
      }
      break;
    }
    default:
      return tflite::Register_DEPTHWISE_CONV_2D().invoke(context, node);
  }
  return kTfLiteOk;
}

TFLMRegistration Register_DEPTHWISE_CONV_2D() {
  auto registration    = tflite::Register_DEPTHWISE_CONV_2D();
  registration.init    = DepthwiseConvInit;
  registration.prepare = DepthwiseConvPrepare;
  registration.invoke  = DepthwiseConvEval;
  return registration;
}

}  // namespace coralnpu_v2::opt::litert_micro
