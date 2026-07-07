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

// bf16 numerically-stable softmax over a 1-D array, computed in fp32:
//   m = max(x);  e_j = exp(x_j - m);  y_j = e_j / sum_k e_k.
// Subtracting the max keeps every exp argument <= 0 (so RvvExpNonPosF32m8's
// one-sided clamp is valid) and guarantees no overflow.
//
// Three variants:
// 	- 	SoftmaxBf16			3 passes, needs an fp32 scratch[n]:
//		(1) max, (2) exp into scratch + accumulate sum, (3) normalize
//		One exp evaluation per element.
//	- 	SoftmaxBf16_Online	2 passes, No scratch (flash-attention
//	  	style): a single fused pass tracks the running max and a
//	  	running sum rescaled on the fly, then a second max and a
//		exp to normalize. Trades n extra exp evaluations for O(1)
//		memory; use when scratch is unavailable or n is large.
//	- 	SoftmaxBf16_SmallRow	register-resident, for a short row that
//	  	fits in one e32m8 group (n <= VLMAX). The whole row stays in
//	  	vector registers: 1 load + 1 store, NO scratch, NO re-read, and
//    	one integer key-max + one vfredusum for the entire row (no
//	  	pre-strip reductions). Same math and accuracy as SoftmaxBf16.
// 	  	Returns false for n > VLMAX (dispatch to SoftmaxBf16 for long rows).
//	  	This is the idiom the project's flash-attention kernel uses.
//
// Element-wise combines accumulate into full-width vector accumulators (_tu on
// tail strips) so each kernel does O(1) reductions per call, not one per strip.
// All max reductions run in the bf16 integer domain via sign-magnitude keys;
// sum reductions stay fp32. Bit-identical across variants
//
// Data is raw bf16 (uint16). In-place (out == in) is safe: each strip is read
// before its store and elements never cross strips
#include <riscv_vector.h>
#include <stddef.h>
#include <stdint.h>

#include "tests/cocotb/rvv/ml_ops/bf16_activations/rvv_math.h"

extern "C" {

// 3-pass softmax with fp32 scratch. `scratch` must hold >= n floats;
// if `scratch_len < n` the kernel writes nothing and returns false.
bool SoftmaxBf16(const uint16_t *in, uint16_t *out, size_t n, float *scratch, size_t scratch_len) {
  if (n == 0)
    return true;
  if (scratch_len < n)
    return false;
  const size_t vlmax = __riscv_vsetvlmax_e32m8();

  const size_t n_full = n - (n % vlmax);  // hoisted: loop back-edge is add+bltu

  // Pass 1: max(x) in the bf16 integer domain at e16m8 (64 bf16/strip, no
  // widening converts). Sign-magnitude keys make integer order == float order;
  // bit-identical to an fp32 vfredmax on finite inputs.
  // PRECONDITION: finite inputs; a NaN would key above +inf
  const size_t vlmax16  = __riscv_vsetvlmax_e16m8();
  const size_t n_full16 = n - (n % vlmax16);
  // key(-inf) = 0x007F, so a zero init sits below every finite key.
  vuint16m8_t kacc = __riscv_vmv_v_x_u16m8(0, vlmax16);
  size_t i         = 0;
  for (; i < n_full16; i += vlmax16) {
    vuint16m8_t x    = __riscv_vle16_v_u16m8(in + i, vlmax16);
    vint16m8_t m     = __riscv_vsra_vx_i16m8(__riscv_vreinterpret_v_u16m8_i16m8(x), 15, vlmax16);
    vuint16m8_t mask = __riscv_vor_vx_u16m8(__riscv_vreinterpret_v_i16m8_u16m8(m), 0x8000, vlmax16);
    kacc = __riscv_vmaxu_vv_u16m8(kacc, __riscv_vxor_vv_u16m8(x, mask, vlmax16), vlmax16);
  }
  if (i < n) {
    size_t vl        = __riscv_vsetvl_e16m8(n - i);
    vuint16m8_t x    = __riscv_vle16_v_u16m8(in + i, vl);
    vint16m8_t m     = __riscv_vsra_vx_i16m8(__riscv_vreinterpret_v_u16m8_i16m8(x), 15, vl);
    vuint16m8_t mask = __riscv_vor_vx_u16m8(__riscv_vreinterpret_v_i16m8_u16m8(m), 0x8000, vl);
    kacc = __riscv_vmaxu_vv_u16m8_tu(kacc, kacc, __riscv_vxor_vv_u16m8(x, mask, vl), vl);
  }
  // Fold m8 -> m4, reduce, then un-key the winner in scalar
  const size_t vlmax16m4 = __riscv_vsetvlmax_e16m4();
  vuint16m4_t k4         = __riscv_vmaxu_vv_u16m4(__riscv_vget_v_u16m8_u16m4(kacc, 0),
                                                  __riscv_vget_v_u16m8_u16m4(kacc, 1), vlmax16m4);
  vuint16m1_t kred    = __riscv_vredmaxu_vs_u16m4_u16m1(k4, __riscv_vmv_v_x_u16m1(0, 1), vlmax16m4);
  const uint16_t kmax = __riscv_vmv_x_s_u16m1_u16(kred);
  const uint16_t bmax = (kmax & 0x8000) ? (uint16_t)(kmax ^ 0x8000) : (uint16_t)~kmax;
  const uint32_t max_bits = (uint32_t)bmax << 16;
  float max_val;
  __builtin_memcpy(&max_val, &max_bits, sizeof(max_val));

  // Pass 2: e = exp(x - max) into scratch, accumulate the sum lane-wise
  // (constant-vl main loop + one _tu tail)
  vfloat32m8_t acc_sum = __riscv_vfmv_v_f_f32m8(0.0f, vlmax);
  for (i = 0; i < n_full; i += vlmax) {
    vfloat32m8_t x       = RvvLoadBf16AsF32m8(in + i, vlmax);
    vfloat32m8_t shifted = __riscv_vfsub_vf_f32m8(x, max_val, vlmax);
    vfloat32m8_t e       = RvvExpNonPosF32m8(shifted, vlmax);  // arg <= 0
    __riscv_vse32_v_f32m8(scratch + i, e, vlmax);
    acc_sum = __riscv_vfadd_vv_f32m8(acc_sum, e, vlmax);
  }
  if (i < n) {
    size_t vl            = __riscv_vsetvl_e32m8(n - i);
    vfloat32m8_t x       = RvvLoadBf16AsF32m8(in + i, vl);
    vfloat32m8_t shifted = __riscv_vfsub_vf_f32m8(x, max_val, vl);
    vfloat32m8_t e       = RvvExpNonPosF32m8(shifted, vl);
    __riscv_vse32_v_f32m8(scratch + i, e, vl);
    acc_sum = __riscv_vfadd_vv_f32m8_tu(acc_sum, acc_sum, e, vl);
  }
  // acc_sum is full-width valid (zero-init + _tu tail), so the tree fold is
  // exact over the same values.
  const float inv_sum = 1.0f / RvvTreeSumF32m8(acc_sum);

  // Pass 3: normalize (constant-vl main loop + one tail strip)
  for (i = 0; i < n_full; i += vlmax) {
    vfloat32m8_t e = __riscv_vle32_v_f32m8(scratch + i, vlmax);
    RvvStoreF32AsBf16m8(out + i, __riscv_vfmul_vf_f32m8(e, inv_sum, vlmax), vlmax);
  }
  if (i < n) {
    size_t vl      = __riscv_vsetvl_e32m8(n - i);
    vfloat32m8_t e = __riscv_vle32_v_f32m8(scratch + i, vl);
    RvvStoreF32AsBf16m8(out + i, __riscv_vfmul_vf_f32m8(e, inv_sum, vl), vl);
  }
  return true;
}

// online (flash-attention) softmax, no scratch. The `scratch`
// parameters are accepted for a uniform ABI with kernel_id 0 but unused.
bool SoftmaxBf16_Online(const uint16_t *in, uint16_t *out, size_t n, float *scratch,
                        size_t scratch_len) {
  (void)scratch;
  (void)scratch_len;
  if (n == 0)
    return true;
  const size_t vlmax = __riscv_vsetvlmax_e32m8();

  // Fused pass: running max `m` (scalar) and running denominator as a vector
  // accumulator `dv`. When the max grows, the already-accumulated terms are
  // rescaled by exp(m_old - m_new) via a scalar factor broadcast over dv.
  float m           = -__builtin_inff();
  uint16_t kmax_run = 0;  // below every finite key; key(-inf) = 0x007F
  vfloat32m8_t dv   = __riscv_vfmv_v_f_f32m8(0.0f, vlmax);
  for (size_t i = 0; i < n;) {
    size_t vl       = __riscv_vsetvl_e32m8(n - i);
    vuint16m4_t raw = __riscv_vle16_v_u16m4(in + i, vl);
    // Chunk max as an integer key; the running max is compared as a key and
    // un-keyed only when it grows. Bit-identical to the fp32 path
    const uint16_t kchunk = RvvBf16MaxKeyReduceSeededM4(RvvBf16MaxKeyM4(raw, vl), kmax_run, vl);
    if (kchunk > kmax_run) {
      const float chunk_max = Bf16BitsToF32(RvvBf16UnKey(kchunk));
      const float corr      = ScalarExpNonPosF32(m - chunk_max);  // m-chunk_max <= 0
      dv                    = __riscv_vfmul_vf_f32m8(dv, corr, vlmax);
      m                     = chunk_max;
      kmax_run              = kchunk;
    }
    vfloat32m8_t x       = RvvWidenBf16ToF32m8(raw, vl);
    vfloat32m8_t shifted = __riscv_vfsub_vf_f32m8(x, m, vl);
    vfloat32m8_t e       = RvvExpNonPosF32m8(shifted, vl);  // arg <= 0
    dv                   = __riscv_vfadd_vv_f32m8_tu(dv, dv, e, vl);
    i += vl;
  }
  // dv is full-width valid (zero-init, full-lane rescales, _tu adds).
  const float inv = 1.0f / RvvTreeSumF32m8(dv);

  // Normalizing pass: recompute exp(x - m) and scale.
  for (size_t i = 0; i < n;) {
    size_t vl            = __riscv_vsetvl_e32m8(n - i);
    vfloat32m8_t x       = RvvLoadBf16AsF32m8(in + i, vl);
    vfloat32m8_t shifted = __riscv_vfsub_vf_f32m8(x, m, vl);
    vfloat32m8_t e       = RvvExpNonPosF32m8(shifted, vl);
    vfloat32m8_t y       = __riscv_vfmul_vf_f32m8(e, inv, vl);
    RvvStoreF32AsBf16m8(out + i, y, vl);
    i += vl;
  }
  return true;
}

// register-resident softmax for a short row that fits one e32m8 group (n <= VLMAX).
// The whole row stays in registers: one load, one store, no scratch, no re-read,
// one key-max + one vfredusum. Numerically identical to SoftmaxBf16. Returns
// false for n > VLMAX. The `scratch` parameters are accepted for a uniform ABI
// with kernel_id 0 but unused.
bool SoftmaxBf16_SmallRow(const uint16_t *in, uint16_t *out, size_t n, float *scratch,
                          size_t scratch_len) {
  (void)scratch;
  (void)scratch_len;
  if (n == 0)
    return true;
  const size_t vlmax = __riscv_vsetvlmax_e32m8();
  if (n > vlmax)
    return false;  // row must fit in one group
  size_t vl       = __riscv_vsetvl_e32m8(n);
  vuint16m4_t raw = __riscv_vle16_v_u16m4(in, vl);  // single load, stays resident
  // Max over the whole row via integer keys (bit-identical to SoftmaxBf16)
  const uint16_t kmax = RvvBf16MaxKeyReduceM4(RvvBf16MaxKeyM4(raw, vl), vl);
  const float m       = Bf16BitsToF32(RvvBf16UnKey(kmax));
  vfloat32m8_t x      = RvvWidenBf16ToF32m8(raw, vl);
  // exp(x - m), entirely in registers (arg <= 0)
  vfloat32m8_t e = RvvExpNonPosF32m8(__riscv_vfsub_vf_f32m8(x, m, vl), vl);
  // Sum via the same tree fold as kid0 (bit-identity contract). e's tail
  // lanes are garbage, so copy the active lanes over a zero background first
  // (e >= +0, so e + 0.0 is bit-exact); the result equals kid0's acc_sum
  // for the same n lane-for-lane, so the identical fold gives identical bits.
  vfloat32m8_t sacc = __riscv_vfmv_v_f_f32m8(0.0f, vlmax);
  sacc              = __riscv_vfadd_vf_f32m8_tu(sacc, e, 0.0f, vl);
  const float inv   = 1.0f / RvvTreeSumF32m8(sacc);
  // normalize in registers, single store
  RvvStoreF32AsBf16m8(out, __riscv_vfmul_vf_f32m8(e, inv, vl), vl);
  return true;
}

}  // extern "C"
