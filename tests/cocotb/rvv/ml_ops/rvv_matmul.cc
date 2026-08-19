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
#include <stdint.h>

// Assume rhs is column major.
extern "C" void MatMul(size_t lhs_rows, size_t inner, size_t rhs_cols, const int8_t *lhs,
                       const int8_t *rhs, int32_t *result) {
  size_t vlmax = __riscv_vsetvl_e8m2(inner);

  for (size_t r = 0; r < lhs_rows; r++) {
    int32_t* result_row = result + (r * rhs_cols);

    for (size_t c = 0; c < rhs_cols; c++) {
      const int8_t *lhs_row = lhs + (r * inner);
      const int8_t *rhs_col = rhs + (c * inner);
      vint32m8_t vacc       = __riscv_vmv_v_x_i32m8(0, vlmax);
      vint32m1_t vzero      = __riscv_vmv_v_x_i32m1(0, 1);
      size_t k              = inner;
      while (k) {
        size_t vl = __riscv_vsetvl_e8m2(k);

        vint8m2_t vrhs    = __riscv_vle8_v_i8m2(rhs_col, vl);
        vint16m4_t vrhs16 = __riscv_vwadd_vx_i16m4(vrhs, 0, vl);
        rhs_col += vl;

        vint8m2_t vlhs    = __riscv_vle8_v_i8m2(lhs_row, vl);
        vint16m4_t vlhs16 = __riscv_vwadd_vx_i16m4(vlhs, 0, vl);
        lhs_row += vl;

        vacc = __riscv_vwmacc_vv_i32m8(vacc, vlhs16, vrhs16, vl);
        k -= vl;
      }

      vint32m1_t vres = __riscv_vredsum_vs_i32m8_i32m1(vacc, vzero, vlmax);
      __riscv_vse32_v_i32m1(result_row + c, vres, 1);
    }
  }
}
