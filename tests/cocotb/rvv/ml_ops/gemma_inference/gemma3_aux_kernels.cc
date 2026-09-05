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

// Small glue kernels that the existing gemma_kernels/ set does not provide:
// activation quantization, int32 -> fp32 dequantization, RoPE and argmax.
// Each is mirrored bit-for-bit (up to fp32 rounding order) in gemma3_ref.py.

#include <riscv_vector.h>
#include <stddef.h>
#include <stdint.h>

extern "C" {

// Symmetric per-tensor int8 quantization with round-to-nearest-even.
// Values are clamped to [-127, 127]: rvv_gemv_int8 requires that -128 never
// appears on both operands, and weights are quantized to the same range.
// Returns the scale s such that x ~= q * s.
float gemma3_quantize_f32_to_i8(const float *__restrict__ x, int8_t *__restrict__ q, size_t n) {
  size_t vlmax        = __riscv_vsetvlmax_e32m8();
  vfloat32m8_t vmax   = __riscv_vfmv_v_f_f32m8(0.0f, vlmax);
  const float *xp     = x;
  size_t k            = n;
  while (k > 0) {
    size_t vl       = __riscv_vsetvl_e32m8(k);
    vfloat32m8_t vx = __riscv_vle32_v_f32m8(xp, vl);
    vmax            = __riscv_vfmax_vv_f32m8_tu(vmax, vmax, __riscv_vfabs_v_f32m8(vx, vl), vl);
    xp += vl;
    k -= vl;
  }
  vfloat32m1_t vz = __riscv_vfmv_v_f_f32m1(0.0f, __riscv_vsetvlmax_e32m1());
  float amax      = __riscv_vfmv_f_s_f32m1_f32(__riscv_vfredmax_vs_f32m8_f32m1(vmax, vz, vlmax));
  float scale     = (amax > 0.0f) ? (amax / 127.0f) : 1.0f;
  float inv_scale = 1.0f / scale;

  xp = x;
  k  = n;
  while (k > 0) {
    size_t vl       = __riscv_vsetvl_e32m8(k);
    vfloat32m8_t vx = __riscv_vle32_v_f32m8(xp, vl);
    vx              = __riscv_vfmul_vf_f32m8(vx, inv_scale, vl);
    vx              = __riscv_vfmin_vf_f32m8(__riscv_vfmax_vf_f32m8(vx, -127.0f, vl), 127.0f, vl);
    // vfcvt.x.f.v rounds per frm (RNE by default) - matches np.rint in the ref.
    vint32m8_t vi   = __riscv_vfcvt_x_f_v_i32m8(vx, vl);
    vint16m4_t vh   = __riscv_vncvt_x_x_w_i16m4(vi, vl);
    vint8m2_t vb    = __riscv_vncvt_x_x_w_i8m2(vh, vl);
    __riscv_vse8_v_i8m2(q, vb, vl);
    xp += vl;
    q += vl;
    k -= vl;
  }
  return scale;
}

// out[n] = acc[n] * a_scale * w_scale[n]
void gemma3_dequant_i32_to_f32(const int32_t *__restrict__ acc, float a_scale,
                               const float *__restrict__ w_scale, float *__restrict__ out,
                               size_t n) {
  while (n > 0) {
    size_t vl       = __riscv_vsetvl_e32m8(n);
    vint32m8_t vi   = __riscv_vle32_v_i32m8(acc, vl);
    vfloat32m8_t vf = __riscv_vfcvt_f_x_v_f32m8(vi, vl);
    vfloat32m8_t vs = __riscv_vle32_v_f32m8(w_scale, vl);
    vf              = __riscv_vfmul_vf_f32m8(vf, a_scale, vl);
    vf              = __riscv_vfmul_vv_f32m8(vf, vs, vl);
    __riscv_vse32_v_f32m8(out, vf, vl);
    acc += vl;
    w_scale += vl;
    out += vl;
    n -= vl;
  }
}

// HF rotate_half RoPE, in place, on n_heads contiguous heads of head_dim.
// cos/sin hold head_dim/2 entries for this position (the HF tables duplicate
// the halves; we store each frequency once).
//   x1' = x1 * cos - x2 * sin
//   x2' = x2 * cos + x1 * sin        (x1 = x[:d/2], x2 = x[d/2:])
void gemma3_rope_inplace(float *__restrict__ x, size_t n_heads, size_t head_dim,
                         const float *__restrict__ cos_row, const float *__restrict__ sin_row) {
  size_t half = head_dim / 2;
  for (size_t h = 0; h < n_heads; ++h) {
    float *x1 = x + h * head_dim;
    float *x2 = x1 + half;
    size_t k  = half;
    const float *cp = cos_row;
    const float *sp = sin_row;
    while (k > 0) {
      size_t vl        = __riscv_vsetvl_e32m8(k);
      vfloat32m8_t v1  = __riscv_vle32_v_f32m8(x1, vl);
      vfloat32m8_t v2  = __riscv_vle32_v_f32m8(x2, vl);
      vfloat32m8_t vc  = __riscv_vle32_v_f32m8(cp, vl);
      vfloat32m8_t vs  = __riscv_vle32_v_f32m8(sp, vl);
      vfloat32m8_t o1  = __riscv_vfmul_vv_f32m8(v1, vc, vl);
      o1               = __riscv_vfnmsac_vv_f32m8(o1, v2, vs, vl);  // o1 -= v2*vs
      vfloat32m8_t o2  = __riscv_vfmul_vv_f32m8(v2, vc, vl);
      o2               = __riscv_vfmacc_vv_f32m8(o2, v1, vs, vl);   // o2 += v1*vs
      __riscv_vse32_v_f32m8(x1, o1, vl);
      __riscv_vse32_v_f32m8(x2, o2, vl);
      x1 += vl;
      x2 += vl;
      cp += vl;
      sp += vl;
      k -= vl;
    }
  }
}

// First index of the maximum (ties -> lowest index, like np.argmax).
uint32_t gemma3_argmax_f32(const float *x, size_t n) {
  uint32_t best = 0;
  float bv      = x[0];
  for (size_t i = 1; i < n; ++i) {
    if (x[i] > bv) {
      bv   = x[i];
      best = (uint32_t)i;
    }
  }
  return best;
}

}  // extern "C"
