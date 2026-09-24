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

#ifndef TESTS_COCOTB_RVV_ML_OPS_GEMMA_KERNELS_RVV_COMMON_VEC_H_
#define TESTS_COCOTB_RVV_ML_OPS_GEMMA_KERNELS_RVV_COMMON_VEC_H_

#include <riscv_vector.h>

#include <cstddef>

// =================================================================
// Unified RVV Data Pipeline Abstractions (FP32 & BFloat16)
//
// NOTE: CoralNPU / RVV lacks native non-widening BF16 arithmetic instructions
// for elementwise transcendental and normalization operations.
// Therefore, BF16 tensors are widened to FP32 during vector load (vfwcvtbf16_f_f_v_f32m8),
// computed in FP32 vector registers, and narrowed back to BF16 on vector store
// (vfncvtbf16_f_f_w_bf16m4).
// =================================================================

template <typename T>
inline vfloat32m8_t rvv_load_vec(const T *ptr, size_t vl);

template <>
inline vfloat32m8_t rvv_load_vec<float>(const float *ptr, size_t vl) {
  return __riscv_vle32_v_f32m8(ptr, vl);
}

template <>
inline vfloat32m8_t rvv_load_vec<__bf16>(const __bf16 *ptr, size_t vl) {
  vbfloat16m4_t v_bf16 = __riscv_vle16_v_bf16m4(ptr, vl);
  return __riscv_vfwcvtbf16_f_f_v_f32m8(v_bf16, vl);
}

template <typename T>
inline void rvv_store_vec(T *ptr, vfloat32m8_t v, size_t vl);

template <>
inline void rvv_store_vec<float>(float *ptr, vfloat32m8_t v, size_t vl) {
  __riscv_vse32_v_f32m8(ptr, v, vl);
}

template <>
inline void rvv_store_vec<__bf16>(__bf16 *ptr, vfloat32m8_t v, size_t vl) {
  vbfloat16m4_t v_bf16 = __riscv_vfncvtbf16_f_f_w_bf16m4(v, vl);
  __riscv_vse16_v_bf16m4(ptr, v_bf16, vl);
}

// LMUL=4 variants for kernels with enough simultaneously-live vectors to
// otherwise force whole-register spills at LMUL=8.
template <typename T>
inline vfloat32m4_t rvv_load_vec_m4(const T *ptr, size_t vl);

template <>
inline vfloat32m4_t rvv_load_vec_m4<float>(const float *ptr, size_t vl) {
  return __riscv_vle32_v_f32m4(ptr, vl);
}

template <>
inline vfloat32m4_t rvv_load_vec_m4<__bf16>(const __bf16 *ptr, size_t vl) {
  vbfloat16m2_t v_bf16 = __riscv_vle16_v_bf16m2(ptr, vl);
  return __riscv_vfwcvtbf16_f_f_v_f32m4(v_bf16, vl);
}

template <typename T>
inline void rvv_store_vec_m4(T *ptr, vfloat32m4_t v, size_t vl);

template <>
inline void rvv_store_vec_m4<float>(float *ptr, vfloat32m4_t v, size_t vl) {
  __riscv_vse32_v_f32m4(ptr, v, vl);
}

template <>
inline void rvv_store_vec_m4<__bf16>(__bf16 *ptr, vfloat32m4_t v, size_t vl) {
  vbfloat16m2_t v_bf16 = __riscv_vfncvtbf16_f_f_w_bf16m2(v, vl);
  __riscv_vse16_v_bf16m2(ptr, v_bf16, vl);
}

#endif  // TESTS_COCOTB_RVV_ML_OPS_GEMMA_KERNELS_RVV_COMMON_VEC_H_
