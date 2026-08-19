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
#include <stddef.h>
#include <stdint.h>

// LHS is row-major, RHS is col-major.
extern "C" void MatMulF(size_t lhs_rows, size_t inner, size_t rhs_cols, const float *lhs,
                        const float *rhs, float *result) {
  size_t vlmax = __riscv_vsetvlmax_e32m1();

  for (size_t r = 0; r < lhs_rows; ++r) {
    float *result_row = result + (r * rhs_cols);
    for (size_t c = 0; c < rhs_cols; ++c) {
      const float *lhs_data = lhs + (r * inner);
      const float *rhs_data = rhs + (c * inner);

      vfloat32m1_t vzero = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc  = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);

      size_t k = inner;
      while (k) {
        size_t vl              = __riscv_vsetvl_e32m1(k);
        vfloat32m1_t vlhs_data = __riscv_vle32_v_f32m1(lhs_data, vl);
        lhs_data += vl;
        vfloat32m1_t vrhs_data = __riscv_vle32_v_f32m1(rhs_data, vl);
        rhs_data += vl;

        vacc = __riscv_vfmacc_vv_f32m1_tu(vacc, vlhs_data, vrhs_data, vl);
        k -= vl;
      }

      vacc = __riscv_vfredusum_vs_f32m1_f32m1(vacc, vzero, vlmax);
      __riscv_vse32_v_f32m1(result_row + c, vacc, 1);
    }
  }
}
