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

#include <cstdint>

extern "C" void MatMulF(size_t lhs_rows, size_t inner, size_t rhs_cols, const float *lhs,
                        const float *rhs, float *result) {
  // Use an intrinsic to initialize the reduction zero scalar.
  vfloat32m1_t vzero = __riscv_vfmv_v_f_f32m1(0.0f, 1);

  for (size_t r = 0; r < lhs_rows; r++) {
    const float *lhs_data = lhs + (r * inner);
    float *result_row     = result + (r * rhs_cols);
    for (size_t c = 0; c < rhs_cols; c++) {
      const float *rhs_data = rhs + (c * inner);

      // Reset accumulator using intrinsic.
      vfloat32m4_t vacc = __riscv_vfmv_v_f_f32m4(0.0f, __riscv_vsetvlmax_e32m4());

      // Inner dot product loop
      size_t k = 0;
      while (k < inner) {
        size_t vl = __riscv_vsetvl_e32m4(inner - k);
        asm("vsetvli zero, %[vl], e32, m4, tu, ma \n\t"
            "vle32.v  v12, %[lhs_ptr] \n\t"
            "vle32.v  v16, %[rhs_ptr] \n\t"
            "vfmacc.vv %[vacc], v12, v16 \n\t"
            : [vacc] "+vd"(vacc)
            : [vl] "r"(vl), [lhs_ptr] "A"(*(const float(*)[vl])(lhs_data + k)),
              [rhs_ptr] "A"(*(const float(*)[vl])(rhs_data + k))
            : "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "vtype", "vl");

        k += vl;
      }

      // Reduction and Store
      asm("vsetvli zero, zero, e32, m4, ta, ma \n\t"
          "vfredusum.vs v12, %[vacc], %[vzero] \n\t"
          "vsetivli zero, 1, e32, m1, ta, ma \n\t"
          "vse32.v v12, %[res_ptr] \n\t"
          : [vacc] "+vd"(vacc), [res_ptr] "=A"(*(result_row + c))
          : [vzero] "vd"(vzero)
          : "vtype", "vl", "v12");
    }
  }
}
