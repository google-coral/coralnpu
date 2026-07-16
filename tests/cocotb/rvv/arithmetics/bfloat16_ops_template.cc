/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <riscv_vector.h>

#include <cstddef>
#include <cstdint>

#define __ATTRIBUTE_IN_DTCM__ __attribute__((section(".data"))) __attribute__((aligned(16)))

{DEFINES}

#ifndef NUM_ELEMENTS
#define NUM_ELEMENTS 64
#endif

uint16_t in_buf_1[NUM_ELEMENTS * 2] __ATTRIBUTE_IN_DTCM__;
uint16_t in_buf_2[NUM_ELEMENTS * 2] __ATTRIBUTE_IN_DTCM__;
uint16_t in_indices[NUM_ELEMENTS] __ATTRIBUTE_IN_DTCM__;
uint16_t out_buf[NUM_ELEMENTS * 2] __ATTRIBUTE_IN_DTCM__;
uint32_t out_buf_f32[NUM_ELEMENTS] __ATTRIBUTE_IN_DTCM__;

void test_bfloat16_kernel(const uint16_t *p1, const uint16_t *p2, const uint16_t *p_idx,
                          uint16_t *pd, float *pd_f32, size_t n_elem) {
  size_t vl;

  // clang-format off

#if defined(TEST_STRIDED)
  size_t step = 2;
#else
  size_t step = 1;
#endif

#if defined(TEST_INDEXED)
  const uint16_t* p1_base = p1;
  const uint16_t* p2_base = p2;
  uint16_t* pd_base = pd;
#endif

#if defined(TEST_MAC_VF)
  __bf16 scalar_val = *(const __bf16*)p2;
#endif
  size_t n = n_elem;
  while (n > 0) {
    vl = __riscv_vsetvl_e16{LMUL}(n);

#if defined(TEST_MAC_VV)
    // 1. Vector-Vector Widening Multiply-Accumulate (Zvfbfwma)
    vbfloat16{LMUL}_t v1 = __riscv_vle16_v_bf16{LMUL}((const __bf16*)p1, vl);
    vbfloat16{LMUL}_t v2 = __riscv_vle16_v_bf16{LMUL}((const __bf16*)p2, vl);
    vfloat32{W_LMUL}_t acc = __riscv_vle32_v_f32{W_LMUL}(pd_f32, vl);
    vfloat32{W_LMUL}_t fres = __riscv_vfwmaccbf16_vv_f32{W_LMUL}(acc, v1, v2, vl);
    __riscv_vse32_v_f32{W_LMUL}(pd_f32, fres, vl);

#elif defined(TEST_MAC_VF)
    // 2. Vector-Scalar Widening Multiply-Accumulate (Zvfbfwma)
    vbfloat16{LMUL}_t v1 = __riscv_vle16_v_bf16{LMUL}((const __bf16*)p1, vl);
    vfloat32{W_LMUL}_t acc = __riscv_vle32_v_f32{W_LMUL}(pd_f32, vl);
    vfloat32{W_LMUL}_t fres = __riscv_vfwmaccbf16_vf_f32{W_LMUL}(acc, scalar_val, v1, vl);
    __riscv_vse32_v_f32{W_LMUL}(pd_f32, fres, vl);

#elif defined(TEST_PIPELINE)
    // 3. End-to-End Pipeline: Unit Load -> Reinterpret -> Widen -> FP32 Arithmetic -> Narrow -> Reinterpret -> Store
    vuint16{LMUL}_t u1 = __riscv_vle16_v_u16{LMUL}(p1, vl);
    vuint16{LMUL}_t u2 = __riscv_vle16_v_u16{LMUL}(p2, vl);
    vbfloat16{LMUL}_t v1 = __riscv_vreinterpret_v_u16{LMUL}_bf16{LMUL}(u1);
    vbfloat16{LMUL}_t v2 = __riscv_vreinterpret_v_u16{LMUL}_bf16{LMUL}(u2);

    vfloat32{W_LMUL}_t f1 = __riscv_vfwcvtbf16_f_f_v_f32{W_LMUL}(v1, vl);
    vfloat32{W_LMUL}_t f2 = __riscv_vfwcvtbf16_f_f_v_f32{W_LMUL}(v2, vl);

    vfloat32{W_LMUL}_t f_mul = __riscv_vfmul_vv_f32{W_LMUL}(f1, f2, vl);
    vfloat32{W_LMUL}_t f_add = __riscv_vfadd_vv_f32{W_LMUL}(f_mul, f1, vl);

    vbfloat16{LMUL}_t res_bf16 = __riscv_vfncvtbf16_f_f_w_bf16{LMUL}(f_add, vl);
    vuint16{LMUL}_t res_u16 = __riscv_vreinterpret_v_bf16{LMUL}_u16{LMUL}(res_bf16);
    __riscv_vse16_v_u16{LMUL}(pd, res_u16, vl);

#elif defined(TEST_STRIDED)
    // 4. Strided Load & Store (vlse16 / vsse16)
    ptrdiff_t stride_bytes = 2 * sizeof(__bf16); // Stride of 2 elements (4 bytes)
    vbfloat16{LMUL}_t v1 = __riscv_vlse16_v_bf16{LMUL}((const __bf16*)p1, stride_bytes, vl);
    vbfloat16{LMUL}_t v2 = __riscv_vlse16_v_bf16{LMUL}((const __bf16*)p2, stride_bytes, vl);

    vfloat32{W_LMUL}_t f1 = __riscv_vfwcvtbf16_f_f_v_f32{W_LMUL}(v1, vl);
    vfloat32{W_LMUL}_t f2 = __riscv_vfwcvtbf16_f_f_v_f32{W_LMUL}(v2, vl);
    vfloat32{W_LMUL}_t fres = __riscv_vfmul_vv_f32{W_LMUL}(f1, f2, vl);

    vbfloat16{LMUL}_t res_bf16 = __riscv_vfncvtbf16_f_f_w_bf16{LMUL}(fres, vl);
    __riscv_vsse16_v_bf16{LMUL}(( __bf16*)pd, stride_bytes, res_bf16, vl);

#elif defined(TEST_INDEXED)
    // 5. Indexed Gather & Scatter Load/Store (vluxei16 / vsuxei16)
    vuint16{LMUL}_t offsets = __riscv_vle16_v_u16{LMUL}(p_idx, vl);
    vbfloat16{LMUL}_t v1 = __riscv_vluxei16_v_bf16{LMUL}((const __bf16*)p1_base, offsets, vl);
    vbfloat16{LMUL}_t v2 = __riscv_vluxei16_v_bf16{LMUL}((const __bf16*)p2_base, offsets, vl);

    vfloat32{W_LMUL}_t f1 = __riscv_vfwcvtbf16_f_f_v_f32{W_LMUL}(v1, vl);
    vfloat32{W_LMUL}_t f2 = __riscv_vfwcvtbf16_f_f_v_f32{W_LMUL}(v2, vl);
    vfloat32{W_LMUL}_t fres = __riscv_vfmul_vv_f32{W_LMUL}(f1, f2, vl);
    vbfloat16{LMUL}_t res_bf16 = __riscv_vfncvtbf16_f_f_w_bf16{LMUL}(fres, vl);

    __riscv_vsuxei16_v_bf16{LMUL}(( __bf16*)pd_base, offsets, res_bf16, vl);
#endif
    // keeping the pointer increment separate for readability.
    p1 += (step * vl);
    p2 += (step * vl);
    p_idx += vl;
    pd += (step * vl);
#if defined(TEST_MAC_VV) || defined(TEST_MAC_VF)
    pd_f32 += vl;
#endif
    n -= vl;
  }
}

int main(int argc, char** argv) {
  test_bfloat16_kernel(in_buf_1, in_buf_2, in_indices, out_buf, (float*)out_buf_f32, NUM_ELEMENTS);
  return 0;
}
