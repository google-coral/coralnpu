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

#include <math.h>
#include <riscv_vector.h>
#include <stddef.h>
#include <stdint.h>

inline vfloat32m8_t rvv_exp_f32m8(vfloat32m8_t x, size_t vl) {
  vfloat32m8_t v_log2e = __riscv_vfmv_v_f_f32m8(1.44269504f, vl);
  vfloat32m8_t v_ln2 = __riscv_vfmv_v_f_f32m8(0.69314718f, vl);
  vfloat32m8_t v_one = __riscv_vfmv_v_f_f32m8(1.0f, vl);
  vfloat32m8_t v_min = __riscv_vfmv_v_f_f32m8(-88.0f, vl);

  x = __riscv_vfmax_vv_f32m8(x, v_min, vl);
  vfloat32m8_t y = __riscv_vfmul_vv_f32m8(x, v_log2e, vl);
  vint32m8_t i_int = __riscv_vfcvt_x_f_v_i32m8(y, vl);
  vfloat32m8_t i_float = __riscv_vfcvt_f_x_v_f32m8(i_int, vl);
  vfloat32m8_t i_ln2 = __riscv_vfmul_vv_f32m8(i_float, v_ln2, vl);
  vfloat32m8_t f = __riscv_vfsub_vv_f32m8(x, i_ln2, vl);

  vfloat32m8_t p;
  vfloat32m8_t c2 = __riscv_vfmv_v_f_f32m8(0.5f, vl);
  vfloat32m8_t c3 = __riscv_vfmv_v_f_f32m8(0.16666667f, vl);
  p = __riscv_vfmacc_vv_f32m8(c2, f, c3, vl);
  p = __riscv_vfmacc_vv_f32m8(v_one, f, p, vl);
  p = __riscv_vfmacc_vv_f32m8(v_one, f, p, vl);

  vint32m8_t bias = __riscv_vmv_v_x_i32m8(127, vl);
  vint32m8_t exp_bits = __riscv_vadd_vv_i32m8(i_int, bias, vl);
  exp_bits = __riscv_vsll_vx_i32m8(exp_bits, 23, vl);
  vfloat32m8_t v_scale = __riscv_vreinterpret_v_i32m8_f32m8(exp_bits);
  return __riscv_vfmul_vv_f32m8(p, v_scale, vl);
}

extern "C" void FlashAttentionRVV(const float* Q, const float* K,
                                  const float* V, float* O, size_t num_heads,
                                  size_t s_len, size_t dim) {
  float scale = 1.0f / sqrtf((float)dim);
  size_t vlmax_m1 = __riscv_vsetvlmax_e32m1();
  size_t vl = __riscv_vsetvl_e32m8(dim);
  auto v_zero = __riscv_vfmv_v_f_f32m1(0.0f, vlmax_m1);

  size_t head_stride = s_len * dim;

  // Outer loop iterating over distinct heads
  for (size_t h = 0; h < num_heads; h++) {
    const float* Q_head = Q + (h * head_stride);
    const float* K_head = K + (h * head_stride);
    const float* V_head = V + (h * head_stride);
    float* O_head = O + (h * head_stride);

    for (size_t q_idx = 0; q_idx < s_len; q_idx++) {
      float S_buf[256];
      const float* q_row = Q_head + (q_idx * dim);

      auto q_vec = __riscv_vle32_v_f32m8(q_row, vl);

      // Rapid Dot Products (Unrolled Loop)
      size_t kv_idx = 0;
      for (; kv_idx <= s_len - 2; kv_idx += 2) {
        auto k_vec0 = __riscv_vle32_v_f32m8(K_head + (kv_idx * dim), vl);
        auto k_vec1 = __riscv_vle32_v_f32m8(K_head + ((kv_idx + 1) * dim), vl);

        auto vacc0 = __riscv_vfmul_vv_f32m8(q_vec, k_vec0, vl);
        auto vacc1 = __riscv_vfmul_vv_f32m8(q_vec, k_vec1, vl);

        float S0 = __riscv_vfmv_f_s_f32m1_f32(
            __riscv_vfredusum_vs_f32m8_f32m1(vacc0, v_zero, vl));
        float S1 = __riscv_vfmv_f_s_f32m1_f32(
            __riscv_vfredusum_vs_f32m8_f32m1(vacc1, v_zero, vl));

        S_buf[kv_idx] = S0 * scale;
        S_buf[kv_idx + 1] = S1 * scale;
      }

      // Tail cleanup for odd lengths
      for (; kv_idx < s_len; kv_idx++) {
        auto k_vec = __riscv_vle32_v_f32m8(K_head + (kv_idx * dim), vl);
        auto vacc = __riscv_vfmul_vv_f32m8(q_vec, k_vec, vl);
        float S = __riscv_vfmv_f_s_f32m1_f32(
            __riscv_vfredusum_vs_f32m8_f32m1(vacc, v_zero, vl));
        S_buf[kv_idx] = S * scale;
      }

      // Vectorized Softmax
      size_t vl_seq = __riscv_vsetvl_e32m8(s_len);
      vfloat32m8_t v_S = __riscv_vle32_v_f32m8(S_buf, vl_seq);

      vfloat32m1_t v_m_scalar = __riscv_vfredmax_vs_f32m8_f32m1(
          v_S, __riscv_vfmv_v_f_f32m1(-INFINITY, vlmax_m1), vl_seq);
      float m = __riscv_vfmv_f_s_f32m1_f32(v_m_scalar);
      v_S = __riscv_vfsub_vf_f32m8(v_S, m, vl_seq);

      vfloat32m8_t v_P = rvv_exp_f32m8(v_S, vl_seq);

      vfloat32m1_t v_d_scalar = __riscv_vfredusum_vs_f32m8_f32m1(
          v_P, __riscv_vfmv_v_f_f32m1(0.0f, vlmax_m1), vl_seq);
      float d_tally = __riscv_vfmv_f_s_f32m1_f32(v_d_scalar);
      v_P = __riscv_vfdiv_vf_f32m8(v_P, d_tally, vl_seq);
      __riscv_vse32_v_f32m8(S_buf, v_P, vl_seq);

      // Register Accumulation
      auto v_o = __riscv_vfmv_v_f_f32m8(0.0f, vl);
      for (size_t kv_idx = 0; kv_idx < s_len; kv_idx++) {
        float P_val = S_buf[kv_idx];
        if (P_val == 0.0f) continue;

        auto v_v = __riscv_vle32_v_f32m8(V_head + (kv_idx * dim), vl);
        v_o = __riscv_vfmacc_vf_f32m8(v_o, P_val, v_v, vl);
      }

      // Single final write to SRAM per row
      __riscv_vse32_v_f32m8(O_head + (q_idx * dim), v_o, vl);
    }
  }
}
