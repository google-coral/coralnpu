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

// NOTE: CoralNPU / RVV lacks native non-widening BF16 arithmetic instructions
// for elementwise transcendental and normalization operations.
// Therefore, BF16 tensors are widened to FP32 during vector load (vfwcvtbf16_f_f_v_f32m8),
// computed in FP32 vector registers, and narrowed back to BF16 on vector store
// (vfncvtbf16_f_f_w_bf16m4).

template <typename T>
inline void rvv_tanh_gelu_mul_impl(const T *__restrict__ gate, const T *__restrict__ up,
                                   T *__restrict__ output, size_t total_elements) {
  const float CA = 0.79788456f;   // sqrt(2/pi)
  const float CB = 0.035677408f;  // sqrt(2/pi) * 0.044715
  const float CC = 0.5f;

  size_t k = total_elements;
  const T *gate_ptr = gate;
  const T *up_ptr   = up;
  T *out_ptr        = output;
  size_t vlmax_f32  = __riscv_vsetvlmax_e32m8();

  // Fast path for bulk VLMAX chunks
  while (k >= vlmax_f32) {
    vfloat32m8_t vx  = rvv_load_vec(gate_ptr, vlmax_f32);
    vfloat32m8_t vup = rvv_load_vec(up_ptr, vlmax_f32);

    // -------------------------------------------------------------
    // PASS 1: z = x * (CA + CB * x^2) -- 1 mul + 1 macc
    // -------------------------------------------------------------
    vfloat32m8_t vx2     = __riscv_vfmul_vv_f32m8(vx, vx, vlmax_f32);
    vfloat32m8_t vz_poly = __riscv_vfmv_v_f_f32m8(CA, vlmax_f32);
    vz_poly              = __riscv_vfmacc_vf_f32m8(vz_poly, CB, vx2, vlmax_f32);
    vfloat32m8_t vz      = __riscv_vfmul_vv_f32m8(vx, vz_poly, vlmax_f32);

    // -------------------------------------------------------------
    // PASS 2: Vectorized Tanh Approximation
    // y = clamp(z, -3.0, 3.0)
    // tanh(z) ~= y * (y^2 + 27) / (9y^2 + 27)
    // -------------------------------------------------------------
    vfloat32m8_t vy = __riscv_vfmax_vf_f32m8(vz, -3.0f, vlmax_f32);
    vy              = __riscv_vfmin_vf_f32m8(vy, 3.0f, vlmax_f32);

    vfloat32m8_t vy2 = __riscv_vfmul_vv_f32m8(vy, vy, vlmax_f32);

    // Numerator: y * (y^2 + 27.0)
    vfloat32m8_t v_num_poly = __riscv_vfadd_vf_f32m8(vy2, 27.0f, vlmax_f32);
    vfloat32m8_t v_num      = __riscv_vfmul_vv_f32m8(vy, v_num_poly, vlmax_f32);

    // Denominator: 9*y^2 + 27.0
    vfloat32m8_t v_den = __riscv_vfmul_vf_f32m8(vy2, 9.0f, vlmax_f32);
    v_den              = __riscv_vfadd_vf_f32m8(v_den, 27.0f, vlmax_f32);

    vfloat32m8_t vtanh_z = __riscv_vfdiv_vv_f32m8(v_num, v_den, vlmax_f32);

    // -------------------------------------------------------------
    // PASS 3: Output = 0.5 * x * up * (1 + tanh(z))
    // -------------------------------------------------------------
    vfloat32m8_t vK = __riscv_vfmul_vv_f32m8(vx, vup, vlmax_f32);
    vK              = __riscv_vfmul_vf_f32m8(vK, CC, vlmax_f32);

    vfloat32m8_t vout_f32 = __riscv_vfmacc_vv_f32m8(vK, vK, vtanh_z, vlmax_f32);

    rvv_store_vec(out_ptr, vout_f32, vlmax_f32);

    gate_ptr += vlmax_f32;
    up_ptr += vlmax_f32;
    out_ptr += vlmax_f32;
    k -= vlmax_f32;
  }

  // Dynamic tail loop
  while (k > 0) {
    size_t vl = __riscv_vsetvl_e32m8(k);

    vfloat32m8_t vx  = rvv_load_vec(gate_ptr, vl);
    vfloat32m8_t vup = rvv_load_vec(up_ptr, vl);

    vfloat32m8_t vx2     = __riscv_vfmul_vv_f32m8(vx, vx, vl);
    vfloat32m8_t vz_poly = __riscv_vfmv_v_f_f32m8(CA, vl);
    vz_poly              = __riscv_vfmacc_vf_f32m8(vz_poly, CB, vx2, vl);
    vfloat32m8_t vz      = __riscv_vfmul_vv_f32m8(vx, vz_poly, vl);

    vfloat32m8_t vy = __riscv_vfmax_vf_f32m8(vz, -3.0f, vl);
    vy              = __riscv_vfmin_vf_f32m8(vy, 3.0f, vl);

    vfloat32m8_t vy2 = __riscv_vfmul_vv_f32m8(vy, vy, vl);

    vfloat32m8_t v_num_poly = __riscv_vfadd_vf_f32m8(vy2, 27.0f, vl);
    vfloat32m8_t v_num      = __riscv_vfmul_vv_f32m8(vy, v_num_poly, vl);

    vfloat32m8_t v_den = __riscv_vfmul_vf_f32m8(vy2, 9.0f, vl);
    v_den              = __riscv_vfadd_vf_f32m8(v_den, 27.0f, vl);

    vfloat32m8_t vtanh_z = __riscv_vfdiv_vv_f32m8(v_num, v_den, vl);

    vfloat32m8_t vK = __riscv_vfmul_vv_f32m8(vx, vup, vl);
    vK              = __riscv_vfmul_vf_f32m8(vK, CC, vl);

    vfloat32m8_t vout_f32 = __riscv_vfmacc_vv_f32m8(vK, vK, vtanh_z, vl);

    rvv_store_vec(out_ptr, vout_f32, vl);

    gate_ptr += vl;
    up_ptr += vl;
    out_ptr += vl;
    k -= vl;
  }
}

extern "C" {

void rvv_tanh_gelu_mul_f32(const float *__restrict__ gate, const float *__restrict__ up,
                           float *__restrict__ output, size_t total_elements) {
  rvv_tanh_gelu_mul_impl<float>(gate, up, output, total_elements);
}

void rvv_tanh_gelu_mul_bf16(const __bf16 *__restrict__ gate, const __bf16 *__restrict__ up,
                            __bf16 *__restrict__ output, size_t total_elements) {
  rvv_tanh_gelu_mul_impl<__bf16>(gate, up, output, total_elements);
}
}
