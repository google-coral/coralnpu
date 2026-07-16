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

#include <cstddef>
#include <cstdint>

// BFloat16 MatMul kernel with FP32 accumulator and FP32 output buffer.
// LHS is row-major, RHS is col-major.
extern "C" void MatMulBF16(size_t lhs_rows, size_t inner, size_t rhs_cols, const __bf16 *lhs,
                           const __bf16 *rhs, float *result) {
  size_t vlmax_f32 = __riscv_vsetvlmax_e32m2();

  for (size_t r = 0; r < lhs_rows; ++r) {
    float *result_row = result + (r * rhs_cols);
    for (size_t c = 0; c < rhs_cols; ++c) {
      const __bf16 *lhs_data = lhs + (r * inner);
      const __bf16 *rhs_data = rhs + (c * inner);

      vfloat32m2_t vacc = __riscv_vfmv_v_f_f32m2(0.0f, vlmax_f32);

      size_t k = inner;
      while (k > 0) {
        size_t vl          = __riscv_vsetvl_e16m1(k);
        vbfloat16m1_t vlhs = __riscv_vle16_v_bf16m1(lhs_data, vl);
        lhs_data += vl;
        vbfloat16m1_t vrhs = __riscv_vle16_v_bf16m1(rhs_data, vl);
        rhs_data += vl;

        vacc = __riscv_vfwmaccbf16_vv_f32m2(vacc, vlhs, vrhs, vl);
        k -= vl;
      }

      // Reduction sum of FP32 accumulator into scalar result
      vfloat32m1_t vzero = __riscv_vfmv_v_f_f32m1(0.0f, __riscv_vsetvlmax_e32m1());
      vfloat32m1_t vred  = __riscv_vfredusum_vs_f32m2_f32m1(vacc, vzero, vlmax_f32);

      result_row[c] = __riscv_vfmv_f_s_f32m1_f32(vred);
    }
  }
}