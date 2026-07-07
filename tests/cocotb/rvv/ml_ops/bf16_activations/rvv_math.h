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

#ifndef TESTS_COCOTB_RVV_ML_OPS_BF16_ACTIVATIONS_RVV_MATH_H_
#define TESTS_COCOTB_RVV_ML_OPS_BF16_ACTIVATIONS_RVV_MATH_H_

#include <riscv_vector.h>
#include <stddef.h>

#include "tests/cocotb/rvv/ml_ops/gemma_kernels/rvv_common_vec.h"

// Shared RVV helpers for the bf16 activation kernels. Data is raw bf16
// (uint16); math is fp32 vector at LMUL=8 and needs a vector-FP core
// (enableFloat=True / Zve32f)

// bf16 -> fp32: native widening convert via rvv_common_vec
inline vfloat32m8_t RvvLoadBf16AsF32m8(const uint16_t *src, size_t vl) {
  return rvv_load_vec<__bf16>(reinterpret_cast<const __bf16 *>(src), vl);
}

// fp32 -> bf16: native narrowing convert via rvv_common_vec (round-to-nearest-even)
inline void RvvStoreF32AsBf16m8(uint16_t *dst, vfloat32m8_t x, size_t vl) {
  rvv_store_vec<__bf16>(reinterpret_cast<__bf16 *>(dst), x, vl);
}
// exp(x) = 2^i * P(g), y = x*log2(e), i = rint(y), g = y - i, |g| <= 0.5
// Base-2 reduction makes g exact in fp32 (no Cody-Waite term). P is a degree-2
// Remez minimax fit of 2^g on [-0.5, 0.5] (rel err 1.73e-3 < half a bf16 ULP),
// so the bf16 result is within 1 ULP of correctly-rounded exp. Evaluated by
// nested Horner with scalar-operand ops (no vector constant splat).
// Tail: the argument is clamped so 2^i stays finite; x below ~-87.68 gives
// i <= -127, reconstructing 2^i as +0.0 (flush to zero, never subnormal)
namespace rvv_math_internal {
constexpr float kExp2D0 = 1.0004431f;   // 0x3f800e85
constexpr float kExp2D1 = 0.703448f;    // 0x3f34152b
constexpr float kExp2D2 = 0.23842894f;  // 0x3e7426b7
constexpr float kLog2E  = 1.4426950408889634f;
// `log2e_signed` is +-log2(e), constant-folded after inlining; x must be
// pre-clamped so y = x*log2e_signed lands in [-126.96, + 126.96]
inline vfloat32m8_t RvvExp2Core(vfloat32m8_t x, float log2e_signed, size_t vl) {
  vfloat32m8_t y      = __riscv_vfmul_vf_f32m8(x, log2e_signed, vl);
  vint32m8_t i        = __riscv_vfcvt_x_f_v_i32m8(y, vl);  // rint, frm=RNE
  vfloat32m8_t g      = __riscv_vfsub_vv_f32m8(y, __riscv_vfcvt_f_x_v_f32m8(i, vl), vl);
  vfloat32m8_t t      = __riscv_vfmul_vf_f32m8(g, kExp2D2, vl);  // p = (d2*g+d1)*g+d0
  t                   = __riscv_vfadd_vf_f32m8(t, kExp2D1, vl);
  vfloat32m8_t p      = __riscv_vfmul_vv_f32m8(t, g, vl);
  p                   = __riscv_vfadd_vf_f32m8(p, kExp2D0, vl);
  vint32m8_t exp_bits = __riscv_vadd_vx_i32m8(i, 127, vl);
  exp_bits            = __riscv_vsll_vx_i32m8(exp_bits, 23, vl);
  vfloat32m8_t scale  = __riscv_vreinterpret_v_i32m8_f32m8(exp_bits);
  return __riscv_vfmul_vv_f32m8(p, scale, vl);
}
}  // namespace rvv_math_internal
// exp(x) for arbitrary finite x; clamps to [-88, 88]
inline vfloat32m8_t RvvExpF32m8(vfloat32m8_t x, size_t vl) {
  x = __riscv_vfmax_vf_f32m8(x, -88.0f, vl);
  x = __riscv_vfmin_vf_f32m8(x, 88.0f, vl);
  return rvv_math_internal::RvvExp2Core(x, rvv_math_internal::kLog2E, vl);
}
// exp(x) for x <= 0 only: skips the upper clamp (one instruction cheaper)
// PRECONDITION: every active element x <= 0; a positive x > 88 assembles and
// exponent field >= 255 (Inf/NaN)
inline vfloat32m8_t RvvExpNonPosF32m8(vfloat32m8_t x, size_t vl) {
  x = __riscv_vfmax_vf_f32m8(x, -88.0f, vl);
  return rvv_math_internal::RvvExp2Core(x, rvv_math_internal::kLog2E, vl);
}
// exp(-x) for arbitrary finite x: the negation is folded into the reduction
// (y = x * -log2(e)), saving the caller an explicit vfneg. Clamps x to [-88, 88]
inline vfloat32m8_t RvvExpNegF32m8(vfloat32m8_t x, size_t vl) {
  x = __riscv_vfmax_vf_f32m8(x, -88.0f, vl);
  x = __riscv_vfmin_vf_f32m8(x, 88.0f, vl);
  return rvv_math_internal::RvvExp2Core(x, -rvv_math_internal::kLog2E, vl);
}
inline vfloat32m8_t RvvExp2D0Splat(size_t vl) {
  return __riscv_vfmv_v_f_f32m8(rvv_math_internal::kExp2D0, vl);
}
inline vfloat32m8_t RvvExp2CoreFMA(vfloat32m8_t x, float log2e_signed, vfloat32m8_t d0v,
                                   size_t vl) {
  vfloat32m8_t y      = __riscv_vfmul_vf_f32m8(x, log2e_signed, vl);
  vint32m8_t i        = __riscv_vfcvt_x_f_v_i32m8(y, vl);  // rint, frm=RNE
  vfloat32m8_t g      = __riscv_vfsub_vv_f32m8(y, __riscv_vfcvt_f_x_v_f32m8(i, vl), vl);  // exact
  vfloat32m8_t t      = __riscv_vfmul_vf_f32m8(g, rvv_math_internal::kExp2D2, vl);
  t                   = __riscv_vfadd_vf_f32m8(t, rvv_math_internal::kExp2D1, vl);
  vfloat32m8_t p      = __riscv_vfmadd_vv_f32m8(t, g, d0v, vl);  // p = t*g + d0 (fused)
  vint32m8_t exp_bits = __riscv_vadd_vx_i32m8(i, 127, vl);
  exp_bits            = __riscv_vsll_vx_i32m8(exp_bits, 23, vl);
  vfloat32m8_t scale  = __riscv_vreinterpret_v_i32m8_f32m8(exp_bits);
  return __riscv_vfmul_vv_f32m8(p, scale, vl);
}
// exp(-x) using the FMA core; `d0v` is the hoisted RvvExp2D0Splat(). Clamps
// x to [-88, 88] (which clamps the exp argument -x to the same interval).
inline vfloat32m8_t RvvExpNegFMA(vfloat32m8_t x, vfloat32m8_t d0v, size_t vl) {
  x = __riscv_vfmax_vf_f32m8(x, -88.0f, vl);
  x = __riscv_vfmin_vf_f32m8(x, 88.0f, vl);
  return RvvExp2CoreFMA(x, -rvv_math_internal::kLog2E, d0v, vl);
}

// Scalar-FPU mirror of RvvExpNonPosF32m8, bit-for-bit identical (same reduction,
// polynomial, flush-to-zero tail), for the online softmax's scalar rescale.
// The RNE convert is emitted explicitly as fcvt.w.s to match the vector path
// and avoid a libm lrintf call. PRECONDITION: x <= 0 (or -inf)
inline float ScalarExpNonPosF32(float x) {
  using rvv_math_internal::kExp2D0;
  using rvv_math_internal::kExp2D1;
  using rvv_math_internal::kExp2D2;
  if (x < -88.0f)
    x = -88.0f;  // also catches -inf
  const float y = x * rvv_math_internal::kLog2E;
  int32_t i;
  __asm__("fcvt.w.s %0, %1, rne" : "=r"(i) : "f"(y));  // rint, RNE
  const float g          = y - static_cast<float>(i);
  const float p          = (kExp2D2 * g + kExp2D1) * g + kExp2D0;  // same nesting as vector path
  const int32_t exp_bits = (i + 127) << 23;
  float scale;
  __builtin_memcpy(&scale, &exp_bits, sizeof(scale));
  return p * scale;
}
// Reciprocal via vfrec7 (~7-bit) + one Newton-Raphson step y1 = y0 * (2 - d*y0) ->
// ~14-bit, ample for bf16. Cheaper than a full vfdiv, d must be positive-normal
inline vfloat32m8_t RvvRecip7F32m8(vfloat32m8_t d, size_t vl) {
  vfloat32m8_t y         = __riscv_vfrec7_v_f32m8(d, vl);
  vfloat32m8_t dy        = __riscv_vfmul_vv_f32m8(d, y, vl);
  vfloat32m8_t two_minus = __riscv_vfrsub_vf_f32m8(dy, 2.0f, vl);
  return __riscv_vfmul_vv_f32m8(y, two_minus, vl);
}
// Raw vfrec7 estimate, no refinement (~7-bit, one op). The bf16 result can
// reach ~3 ULP (vs ~1 with the Newton step); use only where that is acceptable.
// d must be positive-normal
inline vfloat32m8_t RvvRecip7RawF32m8(vfloat32m8_t d, size_t vl) {
  return __riscv_vfrec7_v_f32m8(d, vl);
}
// Widen an already-loaded raw bf16 vector (u16 bit patterns) to f32 -- the
// convert half of RvvLoadBf16AsF32m8, for callers that also need the raw
// vector in the integer domain (e.g. sign-magnitude max keying below).
inline vfloat32m8_t RvvWidenBf16ToF32m8(vuint16m4_t b, size_t vl) {
  return __riscv_vfwcvtbf16_f_f_v_f32m8(__riscv_vreinterpret_v_u16m4_bf16m4(b), vl);
}
// Integer-domain bf16 max. Sign-magnitude keying makes unsigned integer order
// match float order for every non-NaN bf16 (verified over all 65536 bit patterns;
// +0 keys above -0, matching vfmax), so callers stay bit-identical to a
// vfredmax while skipping the fp32 FRDT reduction. NaN (outside contract)
// would key above +inf. key = x ^ ((x >> arith 15) | 0x8000)
inline vuint16m4_t RvvBf16MaxKeyM4(vuint16m4_t x, size_t vl) {
  vint16m4_t m     = __riscv_vsra_vx_i16m4(__riscv_vreinterpret_v_u16m4_i16m4(x), 15, vl);
  vuint16m4_t mask = __riscv_vor_vx_u16m4(__riscv_vreinterpret_v_i16m4_u16m4(m), 0x8000, vl);
  return __riscv_vxor_vv_u16m4(x, mask, vl);
}
// Reduce keys to the single max key. key(-inf) = 0x007F, so a zero seed is
// below every finite key.
inline uint16_t RvvBf16MaxKeyReduceM4(vuint16m4_t keys, size_t vl) {
  vuint16m1_t r = __riscv_vredmaxu_vs_u16m4_u16m1(keys, __riscv_vmv_v_x_u16m1(0, 1), vl);
  return __riscv_vmv_x_s_u16m1_u16(r);
}
// Same reduce, but seeded with a caller-supplied `seed` (a running max key)
// instead of the constant 0. Returns max(seed, keys). Folding the running-max
// comparison into the reduction seed keeps the seed LOOP-VARIANT, so it is NOT
// hoisted out of the loop and spilled: under register pressure (the online
// softmax's dv accumulator + exp working set fill all four m8 groups) a
// constant seed gets LICM-hoisted then evicted to the stack and reloaded every
// strip; a loop-variant seed is instead rematerialized in-loop as one vmv.s.x.
// For seed = 0 this is identical to RvvBf16MaxKeyReduceM4.
inline uint16_t RvvBf16MaxKeyReduceSeededM4(vuint16m4_t keys, uint16_t seed, size_t vl) {
  vuint16m1_t r = __riscv_vredmaxu_vs_u16m4_u16m1(keys, __riscv_vmv_s_x_u16m1(seed, 1), vl);
  return __riscv_vmv_x_s_u16m1_u16(r);
}
inline uint16_t RvvBf16UnKey(uint16_t k) {
  return (k & 0x8000) ? (uint16_t)(k ^ 0x8000) : (uint16_t)(~k);
}
inline float Bf16BitsToF32(uint16_t b) {
  const uint32_t u = (uint32_t)b << 16;
  float f;
  __builtin_memcpy(&f, &u, sizeof(f));
  return f;
}
// Tree-fold sum of a FULL-WIDTH f32 accumulator (all VLMAX lanes valid; zero
// are fine), then a short reduction over 4 lanes. Cheaper than a flat
// vfredusum over VLMAX. NOTE: this changes summation ORDER, so kernels that
// must stay bit-identical to EACH OTHER must all use this same fold
inline float RvvTreeSumF32m8(vfloat32m8_t acc) {
  vfloat32m4_t s4 =
      __riscv_vfadd_vv_f32m4(__riscv_vget_v_f32m8_f32m4(acc, 0), __riscv_vget_v_f32m8_f32m4(acc, 1),
                             __riscv_vsetvlmax_e32m4());
  vfloat32m2_t s2 =
      __riscv_vfadd_vv_f32m2(__riscv_vget_v_f32m4_f32m2(s4, 0), __riscv_vget_v_f32m4_f32m2(s4, 1),
                             __riscv_vsetvlmax_e32m2());
  const size_t vl4 = __riscv_vsetvlmax_e32m1();
  vfloat32m1_t s1  = __riscv_vfadd_vv_f32m1(__riscv_vget_v_f32m2_f32m1(s2, 0),
                                            __riscv_vget_v_f32m2_f32m1(s2, 1), vl4);
  vfloat32m1_t r   = __riscv_vfredusum_vs_f32m1_f32m1(s1, __riscv_vfmv_v_f_f32m1(0.0f, 1), vl4);
  return __riscv_vfmv_f_s_f32m1_f32(r);
}

#endif  // TESTS_COCOTB_RVV_ML_OPS_BF16_ACTIVATIONS_RVV_MATH_H_