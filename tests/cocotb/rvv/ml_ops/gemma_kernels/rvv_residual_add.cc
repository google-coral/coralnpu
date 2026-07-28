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

#include "rvv_common_vec.h"

// NOTE: CoralNPU / RVV lacks native non-widening BF16 arithmetic instructions
// for elementwise transcendental and normalization operations.
// Therefore, BF16 tensors are widened to FP32 during vector load (vfwcvtbf16_f_f_v_f32m8),
// computed in FP32 vector registers, and narrowed back to BF16 on vector store
// (vfncvtbf16_f_f_w_bf16m4).

template <typename T>
inline void rvv_residual_add_impl(const T *__restrict__ A, const T *__restrict__ B,
                                  T *__restrict__ Y, size_t total_elements) {
  size_t i      = 0;
  size_t vl_max = __riscv_vsetvlmax_e32m8();

  // Fast path: Process 2x VLMAX chunks with unrolled pipelined loads
  while (total_elements - i >= 2 * vl_max) {
    vfloat32m8_t va1 = rvv_load_vec(&A[i], vl_max);
    vfloat32m8_t vb1 = rvv_load_vec(&B[i], vl_max);

    vfloat32m8_t va2 = rvv_load_vec(&A[i + vl_max], vl_max);
    vfloat32m8_t vb2 = rvv_load_vec(&B[i + vl_max], vl_max);

    vfloat32m8_t vy1 = __riscv_vfadd_vv_f32m8(va1, vb1, vl_max);
    vfloat32m8_t vy2 = __riscv_vfadd_vv_f32m8(va2, vb2, vl_max);

    rvv_store_vec(&Y[i], vy1, vl_max);
    rvv_store_vec(&Y[i + vl_max], vy2, vl_max);

    i += 2 * vl_max;
  }

  // Tail loop for remaining elements
  while (i < total_elements) {
    size_t vl = __riscv_vsetvl_e32m8(total_elements - i);
    vfloat32m8_t va = rvv_load_vec(&A[i], vl);
    vfloat32m8_t vb = rvv_load_vec(&B[i], vl);

    vfloat32m8_t vy = __riscv_vfadd_vv_f32m8(va, vb, vl);

    rvv_store_vec(&Y[i], vy, vl);

    i += vl;
  }
}

extern "C" {

void rvv_residual_add_f32(const float *__restrict__ A, const float *__restrict__ B,
                          float *__restrict__ Y, size_t total_elements) {
  rvv_residual_add_impl<float>(A, B, Y, total_elements);
}

void rvv_residual_add_bf16(const __bf16 *__restrict__ A, const __bf16 *__restrict__ B,
                           __bf16 *__restrict__ Y, size_t total_elements) {
  rvv_residual_add_impl<__bf16>(A, B, Y, total_elements);
}
}
