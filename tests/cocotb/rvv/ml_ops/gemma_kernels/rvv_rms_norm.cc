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

#include <cmath>

#include "rvv_common_vec.h"

// =================================================================
// Generic RMS Normalization Implementation
//
// NOTE: CoralNPU / RVV lacks native non-widening BF16 arithmetic instructions
// for elementwise transcendental and normalization operations.
// Therefore, BF16 tensors are widened to FP32 during vector load (vfwcvtbf16_f_f_v_f32m8),
// computed in FP32 vector registers, and narrowed back to BF16 on vector store
// (vfncvtbf16_f_f_w_bf16m4).
// =================================================================
template <typename T>
inline void rvv_rms_norm_impl(size_t seq_len, size_t hidden_size, float epsilon,
                              const T *__restrict__ input, const T *__restrict__ weight,
                              T *__restrict__ output) {
  vfloat32m1_t vzero_m1 = __riscv_vfmv_v_f_f32m1(0.0f, __riscv_vsetvlmax_e32m1());
  size_t vlmax_f32      = __riscv_vsetvlmax_e32m8();

  for (size_t s = 0; s < seq_len; ++s) {
    const T *token_in = input + (s * hidden_size);
    T *token_out      = output + (s * hidden_size);

    // -------------------------------------------------------------
    // PASS 1: Calculate Sum of Squares (Reduction in FP32)
    // -------------------------------------------------------------
    vfloat32m8_t vacc = __riscv_vfmv_v_f_f32m8(0.0f, vlmax_f32);

    size_t k       = hidden_size;
    const T *x_ptr = token_in;

    while (k > 0) {
      size_t vl       = __riscv_vsetvl_e32m8(k);
      vfloat32m8_t vx = rvv_load_vec(x_ptr, vl);
      vacc            = __riscv_vfmacc_vv_f32m8(vacc, vx, vx, vl);
      x_ptr += vl;
      k -= vl;
    }

    vfloat32m1_t vred = __riscv_vfredusum_vs_f32m8_f32m1(vacc, vzero_m1, vlmax_f32);
    float sum_squares = __riscv_vfmv_f_s_f32m1_f32(vred);
    float rms         = sum_squares / static_cast<float>(hidden_size);
    float sqrt_val    = std::sqrt(rms + epsilon);
    float inv_rms     = 1.0f / sqrt_val;

    // -------------------------------------------------------------
    // PASS 2: Normalize and Scale with Weights
    // -------------------------------------------------------------
    k              = hidden_size;
    x_ptr          = token_in;
    const T *w_ptr = weight;
    T *out_ptr     = token_out;

    while (k > 0) {
      size_t vl = __riscv_vsetvl_e32m8(k);

      vfloat32m8_t vx = rvv_load_vec(x_ptr, vl);
      vfloat32m8_t vw = rvv_load_vec(w_ptr, vl);

      vfloat32m8_t vx_norm = __riscv_vfmul_vf_f32m8(vx, inv_rms, vl);
      vfloat32m8_t vy      = __riscv_vfmacc_vv_f32m8(vx_norm, vx_norm, vw, vl);

      rvv_store_vec(out_ptr, vy, vl);

      x_ptr += vl;
      w_ptr += vl;
      out_ptr += vl;
      k -= vl;
    }
  }
}

// =================================================================
// C Entry Points
// =================================================================
extern "C" {

void RmsNormF(size_t seq_len, size_t hidden_size, float epsilon, const float *__restrict__ input,
              const float *__restrict__ weight, float *__restrict__ output) {
  rvv_rms_norm_impl<float>(seq_len, hidden_size, epsilon, input, weight, output);
}

void RmsNormBf16(size_t seq_len, size_t hidden_size, float epsilon,
                 const __bf16 *__restrict__ input, const __bf16 *__restrict__ weight,
                 __bf16 *__restrict__ output) {
  rvv_rms_norm_impl<__bf16>(seq_len, hidden_size, epsilon, input, weight, output);
}
}
