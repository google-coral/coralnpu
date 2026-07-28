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

#include <riscv_vector.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

#include "rvv_common_vec.h"

// -----------------------------------------------------------------------------
// Zero-Spill Vectorized exp(x) approximation for float32 (m8)
// Uses scalar _vf / _vx operands and exact Taylor-Horner polynomial evaluation
// -----------------------------------------------------------------------------
inline vfloat32m8_t rvv_exp_f32m8(vfloat32m8_t x, size_t vl) {
  x                    = __riscv_vfmax_vf_f32m8(x, -88.0f, vl);
  vfloat32m8_t y       = __riscv_vfmul_vf_f32m8(x, 1.4426950408889634f, vl);
  vint32m8_t i_int     = __riscv_vfcvt_x_f_v_i32m8(y, vl);
  vfloat32m8_t i_float = __riscv_vfcvt_f_x_v_f32m8(i_int, vl);
  vfloat32m8_t i_ln2   = __riscv_vfmul_vf_f32m8(i_float, 0.6931471805599453f, vl);
  vfloat32m8_t f       = __riscv_vfsub_vv_f32m8(x, i_ln2, vl);

  vfloat32m8_t v_one   = __riscv_vfmv_v_f_f32m8(1.0f, vl);
  vfloat32m8_t p       = __riscv_vfmul_vf_f32m8(f, 0.16666667f, vl);
  p                    = __riscv_vfadd_vf_f32m8(p, 0.5f, vl);
  p                    = __riscv_vfmacc_vv_f32m8(v_one, f, p, vl);
  p                    = __riscv_vfmacc_vv_f32m8(v_one, f, p, vl);

  vint32m8_t exp_bits  = __riscv_vadd_vx_i32m8(i_int, 127, vl);
  exp_bits             = __riscv_vsll_vx_i32m8(exp_bits, 23, vl);
  vfloat32m8_t v_scale = __riscv_vreinterpret_v_i32m8_f32m8(exp_bits);
  return __riscv_vfmul_vv_f32m8(p, v_scale, vl);
}

// NOTE: CoralNPU / RVV lacks native non-widening BF16 arithmetic instructions
// for elementwise transcendental and normalization operations.
// Therefore, BF16 tensors are widened to FP32 during vector load (vfwcvtbf16_f_f_v_f32m8),
// computed in FP32 vector registers, and narrowed back to BF16 on vector store
// (vfncvtbf16_f_f_w_bf16m4).

template <typename T>
inline void FlashAttentionRVV_impl(size_t Q_heads, size_t KV_heads, size_t Q_len, size_t KV_len,
                                   size_t Dim, const T *__restrict__ Q, const T *__restrict__ K,
                                   const T *__restrict__ V, T *__restrict__ Output) {
  float scale           = 1.0f / std::sqrt(static_cast<float>(Dim));
  vfloat32m1_t vzero_m1 = __riscv_vfmv_v_f_f32m1(0.0f, __riscv_vsetvlmax_e32m1());

  for (size_t qh = 0; qh < Q_heads; ++qh) {
    size_t kv_h     = (KV_heads > 0) ? (qh % KV_heads) : 0;
    const T *k_base = K + kv_h * KV_len * Dim;
    const T *v_base = V + kv_h * KV_len * Dim;

    for (size_t qi = 0; qi < Q_len; ++qi) {
      float S_buf[1024];
      const T *q_row = Q + (qh * Q_len + qi) * Dim;
      T *out_row     = Output + (qh * Q_len + qi) * Dim;

      if (Dim <= __riscv_vsetvlmax_e32m8()) {
        // ---------------------------------------------------------------------
        // FAST REGISTER-PINNED PATH: Dim <= VLMAX
        // ---------------------------------------------------------------------
        size_t vl = __riscv_vsetvl_e32m8(Dim);

        // Pre-scale Query vector ONCE (0 multiplies inside the KV loop!)
        auto q_vec = rvv_load_vec(q_row, vl);
        q_vec      = __riscv_vfmul_vf_f32m8(q_vec, scale, vl);

        // 1. 2x Unrolled Dot Products (k_vec0 in v8..v15, k_vec1 in v16..v23)
        size_t kj = 0;
        for (; kj + 1 < KV_len; kj += 2) {
          const T *k_row0 = k_base + kj * Dim;
          const T *k_row1 = k_base + (kj + 1) * Dim;
          auto vk0        = rvv_load_vec(k_row0, vl);
          auto vk1        = rvv_load_vec(k_row1, vl);
          auto vacc0      = __riscv_vfmul_vv_f32m8(q_vec, vk0, vl);
          auto vacc1      = __riscv_vfmul_vv_f32m8(q_vec, vk1, vl);
          float S0 =
              __riscv_vfmv_f_s_f32m1_f32(__riscv_vfredusum_vs_f32m8_f32m1(vacc0, vzero_m1, vl));
          float S1 =
              __riscv_vfmv_f_s_f32m1_f32(__riscv_vfredusum_vs_f32m8_f32m1(vacc1, vzero_m1, vl));
          S_buf[kj]     = S0;
          S_buf[kj + 1] = S1;
        }
        for (; kj < KV_len; kj++) {
          const T *k_row = k_base + kj * Dim;
          auto vk        = rvv_load_vec(k_row, vl);
          auto vacc      = __riscv_vfmul_vv_f32m8(q_vec, vk, vl);
          float S =
              __riscv_vfmv_f_s_f32m1_f32(__riscv_vfredusum_vs_f32m8_f32m1(vacc, vzero_m1, vl));
          S_buf[kj] = S;
        }

        // 2. Vectorized Softmax over S_buf
        vfloat32m1_t v_max = __riscv_vfmv_v_f_f32m1(-INFINITY, __riscv_vsetvlmax_e32m1());
        for (size_t k = 0; k < KV_len;) {
          size_t vl_s      = __riscv_vsetvl_e32m8(KV_len - k);
          vfloat32m8_t v_S = __riscv_vle32_v_f32m8(S_buf + k, vl_s);
          v_max            = __riscv_vfredmax_vs_f32m8_f32m1(v_S, v_max, vl_s);
          k += vl_s;
        }
        float max_score = __riscv_vfmv_f_s_f32m1_f32(v_max);

        vfloat32m1_t v_sum = __riscv_vfmv_v_f_f32m1(0.0f, __riscv_vsetvlmax_e32m1());
        for (size_t k = 0; k < KV_len;) {
          size_t vl_s      = __riscv_vsetvl_e32m8(KV_len - k);
          vfloat32m8_t v_S = __riscv_vle32_v_f32m8(S_buf + k, vl_s);
          v_S              = __riscv_vfsub_vf_f32m8(v_S, max_score, vl_s);
          vfloat32m8_t v_P = rvv_exp_f32m8(v_S, vl_s);
          __riscv_vse32_v_f32m8(S_buf + k, v_P, vl_s);
          v_sum = __riscv_vfredusum_vs_f32m8_f32m1(v_P, v_sum, vl_s);
          k += vl_s;
        }
        float sum_exp = __riscv_vfmv_f_s_f32m1_f32(v_sum);

        float inv_sum = 1.0f / sum_exp;
        for (size_t k = 0; k < KV_len;) {
          size_t vl_s      = __riscv_vsetvl_e32m8(KV_len - k);
          vfloat32m8_t v_P = __riscv_vle32_v_f32m8(S_buf + k, vl_s);
          v_P              = __riscv_vfmul_vf_f32m8(v_P, inv_sum, vl_s);
          __riscv_vse32_v_f32m8(S_buf + k, v_P, vl_s);
          k += vl_s;
        }

        // 3. 2x Unrolled Pinned Accumulation: vo in v0..v7 across entire KV loop
        auto v_o = __riscv_vfmv_v_f_f32m8(0.0f, vl);
        kj       = 0;
        for (; kj + 1 < KV_len; kj += 2) {
          float p0        = S_buf[kj];
          float p1        = S_buf[kj + 1];
          const T *v_row0 = v_base + kj * Dim;
          const T *v_row1 = v_base + (kj + 1) * Dim;
          auto vv0        = rvv_load_vec(v_row0, vl);
          auto vv1        = rvv_load_vec(v_row1, vl);
          if (p0 != 0.0f)
            v_o = __riscv_vfmacc_vf_f32m8(v_o, p0, vv0, vl);
          if (p1 != 0.0f)
            v_o = __riscv_vfmacc_vf_f32m8(v_o, p1, vv1, vl);
        }
        for (; kj < KV_len; kj++) {
          float p_val = S_buf[kj];
          if (p_val == 0.0f)
            continue;
          const T *v_row = v_base + kj * Dim;
          auto vv        = rvv_load_vec(v_row, vl);
          v_o            = __riscv_vfmacc_vf_f32m8(v_o, p_val, vv, vl);
        }
        // Single write to SRAM per row (0 intermediate SRAM loads/stores)
        rvv_store_vec(out_row, v_o, vl);

      } else {
        // ---------------------------------------------------------------------
        // UNIVERSAL STRIP-MINED PATH: Dim > VLMAX
        // ---------------------------------------------------------------------
        size_t kj = 0;
        for (; kj + 1 < KV_len; kj += 2) {
          const T *k_row0 = k_base + kj * Dim;
          const T *k_row1 = k_base + (kj + 1) * Dim;
          float dot0      = 0.0f;
          float dot1      = 0.0f;
          size_t d        = 0;
          while (d < Dim) {
            size_t vl  = __riscv_vsetvl_e32m8(Dim - d);
            auto vq    = rvv_load_vec(q_row + d, vl);
            auto vk0   = rvv_load_vec(k_row0 + d, vl);
            auto vk1   = rvv_load_vec(k_row1 + d, vl);
            auto vacc0 = __riscv_vfmul_vv_f32m8(vq, vk0, vl);
            auto vacc1 = __riscv_vfmul_vv_f32m8(vq, vk1, vl);
            dot0 +=
                __riscv_vfmv_f_s_f32m1_f32(__riscv_vfredusum_vs_f32m8_f32m1(vacc0, vzero_m1, vl));
            dot1 +=
                __riscv_vfmv_f_s_f32m1_f32(__riscv_vfredusum_vs_f32m8_f32m1(vacc1, vzero_m1, vl));
            d += vl;
          }
          S_buf[kj]     = dot0 * scale;
          S_buf[kj + 1] = dot1 * scale;
        }
        for (; kj < KV_len; kj++) {
          const T *k_row = k_base + kj * Dim;
          float dot      = 0.0f;
          size_t d       = 0;
          while (d < Dim) {
            size_t vl = __riscv_vsetvl_e32m8(Dim - d);
            auto vq   = rvv_load_vec(q_row + d, vl);
            auto vk   = rvv_load_vec(k_row + d, vl);
            auto vacc = __riscv_vfmul_vv_f32m8(vq, vk, vl);
            dot += __riscv_vfmv_f_s_f32m1_f32(__riscv_vfredusum_vs_f32m8_f32m1(vacc, vzero_m1, vl));
            d += vl;
          }
          S_buf[kj] = dot * scale;
        }

        // 3-Pass Vectorized Softmax over S_buf
        vfloat32m1_t v_max = __riscv_vfmv_v_f_f32m1(-INFINITY, __riscv_vsetvlmax_e32m1());
        for (size_t k = 0; k < KV_len;) {
          size_t vl_s      = __riscv_vsetvl_e32m8(KV_len - k);
          vfloat32m8_t v_S = __riscv_vle32_v_f32m8(S_buf + k, vl_s);
          v_max            = __riscv_vfredmax_vs_f32m8_f32m1(v_S, v_max, vl_s);
          k += vl_s;
        }
        float max_score = __riscv_vfmv_f_s_f32m1_f32(v_max);

        vfloat32m1_t v_sum = __riscv_vfmv_v_f_f32m1(0.0f, __riscv_vsetvlmax_e32m1());
        for (size_t k = 0; k < KV_len;) {
          size_t vl_s      = __riscv_vsetvl_e32m8(KV_len - k);
          vfloat32m8_t v_S = __riscv_vle32_v_f32m8(S_buf + k, vl_s);
          v_S              = __riscv_vfsub_vf_f32m8(v_S, max_score, vl_s);
          vfloat32m8_t v_P = rvv_exp_f32m8(v_S, vl_s);
          __riscv_vse32_v_f32m8(S_buf + k, v_P, vl_s);
          v_sum = __riscv_vfredusum_vs_f32m8_f32m1(v_P, v_sum, vl_s);
          k += vl_s;
        }
        float sum_exp = __riscv_vfmv_f_s_f32m1_f32(v_sum);

        float inv_sum = 1.0f / sum_exp;
        for (size_t k = 0; k < KV_len;) {
          size_t vl_s      = __riscv_vsetvl_e32m8(KV_len - k);
          vfloat32m8_t v_P = __riscv_vle32_v_f32m8(S_buf + k, vl_s);
          v_P              = __riscv_vfmul_vf_f32m8(v_P, inv_sum, vl_s);
          __riscv_vse32_v_f32m8(S_buf + k, v_P, vl_s);
          k += vl_s;
        }

        // Loop-Interchanged 2x Unrolled Pinned Accumulator (0 intermediate SRAM stores)
        for (size_t d_start = 0; d_start < Dim;) {
          size_t vl       = __riscv_vsetvl_e32m8(Dim - d_start);
          vfloat32m8_t vo = __riscv_vfmv_v_f_f32m8(0.0f, vl);

          kj = 0;
          for (; kj + 1 < KV_len; kj += 2) {
            float p0        = S_buf[kj];
            float p1        = S_buf[kj + 1];
            const T *v_row0 = v_base + kj * Dim;
            const T *v_row1 = v_base + (kj + 1) * Dim;
            auto vv0        = rvv_load_vec(v_row0 + d_start, vl);
            auto vv1        = rvv_load_vec(v_row1 + d_start, vl);
            if (p0 != 0.0f)
              vo = __riscv_vfmacc_vf_f32m8(vo, p0, vv0, vl);
            if (p1 != 0.0f)
              vo = __riscv_vfmacc_vf_f32m8(vo, p1, vv1, vl);
          }
          for (; kj < KV_len; kj++) {
            float p_val = S_buf[kj];
            if (p_val == 0.0f)
              continue;
            const T *v_row = v_base + kj * Dim;
            auto vv        = rvv_load_vec(v_row + d_start, vl);
            vo             = __riscv_vfmacc_vf_f32m8(vo, p_val, vv, vl);
          }
          rvv_store_vec(out_row + d_start, vo, vl);
          d_start += vl;
        }
      }
    }
  }
}

// =================================================================
// C Entry Points
// =================================================================
extern "C" {

void FlashAttentionRVV(size_t Q_heads, size_t KV_heads, size_t Q_len, size_t KV_len, size_t Dim,
                       const float *Q, const float *K, const float *V, float *Output) {
  FlashAttentionRVV_impl<float>(Q_heads, KV_heads, Q_len, KV_len, Dim, Q, K, V, Output);
}

void FlashAttentionRVV_Bf16(size_t Q_heads, size_t KV_heads, size_t Q_len, size_t KV_len,
                            size_t Dim, const __bf16 *Q, const __bf16 *K, const __bf16 *V,
                            __bf16 *Output) {
  FlashAttentionRVV_impl<__bf16>(Q_heads, KV_heads, Q_len, KV_len, Dim, Q, K, V, Output);
}
}
