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

constexpr size_t kLhsRows = 16;
constexpr size_t kRhsCols = 16;
constexpr size_t kInner = 48;

float lhs_input[kLhsRows * kInner]
    __attribute__((section(".data"), used, retain))
    __attribute__((aligned(16)));
float rhs_input[kInner * kRhsCols]
    __attribute__((section(".data"), used, retain))
    __attribute__((aligned(16)));
float result_output[kLhsRows * kRhsCols]
    __attribute__((section(".data"), used, retain))
    __attribute__((aligned(16)));

// LHS is row-major, RHS is col-major.
void MatMulF(size_t lhs_rows, size_t inner, size_t rhs_cols, const float* lhs,
             const float* rhs, float* result) {
  size_t vlmax = __riscv_vsetvlmax_e32m1();

  for (size_t r = 0; r < lhs_rows; r += 4) {
    for (size_t c = 0; c < rhs_cols; c += 4) {
      const float* lhs_data_0 = lhs + (r * inner);
      const float* lhs_data_1 = lhs + ((r + 1) * inner);
      const float* lhs_data_2 = lhs + ((r + 2) * inner);
      const float* lhs_data_3 = lhs + ((r + 3) * inner);
      const float* rhs_data_0 = rhs + (c * inner);
      const float* rhs_data_1 = rhs + ((c + 1) * inner);
      const float* rhs_data_2 = rhs + ((c + 2) * inner);
      const float* rhs_data_3 = rhs + ((c + 3) * inner);

      vfloat32m1_t vzero = __riscv_vfmv_v_f_f32m1(0.0f, 1);
      vfloat32m1_t vacc_00 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_01 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_02 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_03 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);

      vfloat32m1_t vacc_10 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_11 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_12 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_13 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);

      vfloat32m1_t vacc_20 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_21 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_22 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_23 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);

      vfloat32m1_t vacc_30 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_31 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_32 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);
      vfloat32m1_t vacc_33 = __riscv_vfmv_v_f_f32m1(0.0f, vlmax);

      size_t k = inner;
      while (k) {
        // Sub-iteration 1
        size_t vl = __riscv_vsetvl_e32m1(k);
        vfloat32m1_t vlhs_0 = __riscv_vle32_v_f32m1(lhs_data_0, vl);
        vfloat32m1_t vlhs_1 = __riscv_vle32_v_f32m1(lhs_data_1, vl);
        vfloat32m1_t vlhs_2 = __riscv_vle32_v_f32m1(lhs_data_2, vl);
        vfloat32m1_t vlhs_3 = __riscv_vle32_v_f32m1(lhs_data_3, vl);

        vfloat32m1_t vrhs_0 = __riscv_vle32_v_f32m1(rhs_data_0, vl);
        vfloat32m1_t vrhs_1 = __riscv_vle32_v_f32m1(rhs_data_1, vl);
        vfloat32m1_t vrhs_2 = __riscv_vle32_v_f32m1(rhs_data_2, vl);
        vfloat32m1_t vrhs_3 = __riscv_vle32_v_f32m1(rhs_data_3, vl);

        vacc_00 = __riscv_vfmacc_vv_f32m1_tu(vacc_00, vlhs_0, vrhs_0, vl);
        vacc_01 = __riscv_vfmacc_vv_f32m1_tu(vacc_01, vlhs_0, vrhs_1, vl);
        vacc_02 = __riscv_vfmacc_vv_f32m1_tu(vacc_02, vlhs_0, vrhs_2, vl);
        vacc_03 = __riscv_vfmacc_vv_f32m1_tu(vacc_03, vlhs_0, vrhs_3, vl);

        vacc_10 = __riscv_vfmacc_vv_f32m1_tu(vacc_10, vlhs_1, vrhs_0, vl);
        vacc_11 = __riscv_vfmacc_vv_f32m1_tu(vacc_11, vlhs_1, vrhs_1, vl);
        vacc_12 = __riscv_vfmacc_vv_f32m1_tu(vacc_12, vlhs_1, vrhs_2, vl);
        vacc_13 = __riscv_vfmacc_vv_f32m1_tu(vacc_13, vlhs_1, vrhs_3, vl);

        vacc_20 = __riscv_vfmacc_vv_f32m1_tu(vacc_20, vlhs_2, vrhs_0, vl);
        vacc_21 = __riscv_vfmacc_vv_f32m1_tu(vacc_21, vlhs_2, vrhs_1, vl);
        vacc_22 = __riscv_vfmacc_vv_f32m1_tu(vacc_22, vlhs_2, vrhs_2, vl);
        vacc_23 = __riscv_vfmacc_vv_f32m1_tu(vacc_23, vlhs_2, vrhs_3, vl);

        vacc_30 = __riscv_vfmacc_vv_f32m1_tu(vacc_30, vlhs_3, vrhs_0, vl);
        vacc_31 = __riscv_vfmacc_vv_f32m1_tu(vacc_31, vlhs_3, vrhs_1, vl);
        vacc_32 = __riscv_vfmacc_vv_f32m1_tu(vacc_32, vlhs_3, vrhs_2, vl);
        vacc_33 = __riscv_vfmacc_vv_f32m1_tu(vacc_33, vlhs_3, vrhs_3, vl);

        lhs_data_0 += vl; lhs_data_1 += vl; lhs_data_2 += vl; lhs_data_3 += vl;
        rhs_data_0 += vl; rhs_data_1 += vl; rhs_data_2 += vl; rhs_data_3 += vl;
        k -= vl;

        if (k == 0) break;

        // Sub-iteration 2
        vl = __riscv_vsetvl_e32m1(k);
        vlhs_0 = __riscv_vle32_v_f32m1(lhs_data_0, vl);
        vlhs_1 = __riscv_vle32_v_f32m1(lhs_data_1, vl);
        vlhs_2 = __riscv_vle32_v_f32m1(lhs_data_2, vl);
        vlhs_3 = __riscv_vle32_v_f32m1(lhs_data_3, vl);
        vrhs_0 = __riscv_vle32_v_f32m1(rhs_data_0, vl);
        vrhs_1 = __riscv_vle32_v_f32m1(rhs_data_1, vl);
        vrhs_2 = __riscv_vle32_v_f32m1(rhs_data_2, vl);
        vrhs_3 = __riscv_vle32_v_f32m1(rhs_data_3, vl);

        vacc_00 = __riscv_vfmacc_vv_f32m1_tu(vacc_00, vlhs_0, vrhs_0, vl);
        vacc_01 = __riscv_vfmacc_vv_f32m1_tu(vacc_01, vlhs_0, vrhs_1, vl);
        vacc_02 = __riscv_vfmacc_vv_f32m1_tu(vacc_02, vlhs_0, vrhs_2, vl);
        vacc_03 = __riscv_vfmacc_vv_f32m1_tu(vacc_03, vlhs_0, vrhs_3, vl);

        vacc_10 = __riscv_vfmacc_vv_f32m1_tu(vacc_10, vlhs_1, vrhs_0, vl);
        vacc_11 = __riscv_vfmacc_vv_f32m1_tu(vacc_11, vlhs_1, vrhs_1, vl);
        vacc_12 = __riscv_vfmacc_vv_f32m1_tu(vacc_12, vlhs_1, vrhs_2, vl);
        vacc_13 = __riscv_vfmacc_vv_f32m1_tu(vacc_13, vlhs_1, vrhs_3, vl);

        vacc_20 = __riscv_vfmacc_vv_f32m1_tu(vacc_20, vlhs_2, vrhs_0, vl);
        vacc_21 = __riscv_vfmacc_vv_f32m1_tu(vacc_21, vlhs_2, vrhs_1, vl);
        vacc_22 = __riscv_vfmacc_vv_f32m1_tu(vacc_22, vlhs_2, vrhs_2, vl);
        vacc_23 = __riscv_vfmacc_vv_f32m1_tu(vacc_23, vlhs_2, vrhs_3, vl);

        vacc_30 = __riscv_vfmacc_vv_f32m1_tu(vacc_30, vlhs_3, vrhs_0, vl);
        vacc_31 = __riscv_vfmacc_vv_f32m1_tu(vacc_31, vlhs_3, vrhs_1, vl);
        vacc_32 = __riscv_vfmacc_vv_f32m1_tu(vacc_32, vlhs_3, vrhs_2, vl);
        vacc_33 = __riscv_vfmacc_vv_f32m1_tu(vacc_33, vlhs_3, vrhs_3, vl);

        lhs_data_0 += vl; lhs_data_1 += vl; lhs_data_2 += vl; lhs_data_3 += vl;
        rhs_data_0 += vl; rhs_data_1 += vl; rhs_data_2 += vl; rhs_data_3 += vl;
        k -= vl;

        if (k == 0) break;

        // Sub-iteration 3
        vl = __riscv_vsetvl_e32m1(k);
        vlhs_0 = __riscv_vle32_v_f32m1(lhs_data_0, vl);
        vlhs_1 = __riscv_vle32_v_f32m1(lhs_data_1, vl);
        vlhs_2 = __riscv_vle32_v_f32m1(lhs_data_2, vl);
        vlhs_3 = __riscv_vle32_v_f32m1(lhs_data_3, vl);
        vrhs_0 = __riscv_vle32_v_f32m1(rhs_data_0, vl);
        vrhs_1 = __riscv_vle32_v_f32m1(rhs_data_1, vl);
        vrhs_2 = __riscv_vle32_v_f32m1(rhs_data_2, vl);
        vrhs_3 = __riscv_vle32_v_f32m1(rhs_data_3, vl);

        vacc_00 = __riscv_vfmacc_vv_f32m1_tu(vacc_00, vlhs_0, vrhs_0, vl);
        vacc_01 = __riscv_vfmacc_vv_f32m1_tu(vacc_01, vlhs_0, vrhs_1, vl);
        vacc_02 = __riscv_vfmacc_vv_f32m1_tu(vacc_02, vlhs_0, vrhs_2, vl);
        vacc_03 = __riscv_vfmacc_vv_f32m1_tu(vacc_03, vlhs_0, vrhs_3, vl);

        vacc_10 = __riscv_vfmacc_vv_f32m1_tu(vacc_10, vlhs_1, vrhs_0, vl);
        vacc_11 = __riscv_vfmacc_vv_f32m1_tu(vacc_11, vlhs_1, vrhs_1, vl);
        vacc_12 = __riscv_vfmacc_vv_f32m1_tu(vacc_12, vlhs_1, vrhs_2, vl);
        vacc_13 = __riscv_vfmacc_vv_f32m1_tu(vacc_13, vlhs_1, vrhs_3, vl);

        vacc_20 = __riscv_vfmacc_vv_f32m1_tu(vacc_20, vlhs_2, vrhs_0, vl);
        vacc_21 = __riscv_vfmacc_vv_f32m1_tu(vacc_21, vlhs_2, vrhs_1, vl);
        vacc_22 = __riscv_vfmacc_vv_f32m1_tu(vacc_22, vlhs_2, vrhs_2, vl);
        vacc_23 = __riscv_vfmacc_vv_f32m1_tu(vacc_23, vlhs_2, vrhs_3, vl);

        vacc_30 = __riscv_vfmacc_vv_f32m1_tu(vacc_30, vlhs_3, vrhs_0, vl);
        vacc_31 = __riscv_vfmacc_vv_f32m1_tu(vacc_31, vlhs_3, vrhs_1, vl);
        vacc_32 = __riscv_vfmacc_vv_f32m1_tu(vacc_32, vlhs_3, vrhs_2, vl);
        vacc_33 = __riscv_vfmacc_vv_f32m1_tu(vacc_33, vlhs_3, vrhs_3, vl);

        lhs_data_0 += vl; lhs_data_1 += vl; lhs_data_2 += vl; lhs_data_3 += vl;
        rhs_data_0 += vl; rhs_data_1 += vl; rhs_data_2 += vl; rhs_data_3 += vl;
        k -= vl;

        if (k == 0) break;

        // Sub-iteration 4
        vl = __riscv_vsetvl_e32m1(k);
        vlhs_0 = __riscv_vle32_v_f32m1(lhs_data_0, vl);
        vlhs_1 = __riscv_vle32_v_f32m1(lhs_data_1, vl);
        vlhs_2 = __riscv_vle32_v_f32m1(lhs_data_2, vl);
        vlhs_3 = __riscv_vle32_v_f32m1(lhs_data_3, vl);
        vrhs_0 = __riscv_vle32_v_f32m1(rhs_data_0, vl);
        vrhs_1 = __riscv_vle32_v_f32m1(rhs_data_1, vl);
        vrhs_2 = __riscv_vle32_v_f32m1(rhs_data_2, vl);
        vrhs_3 = __riscv_vle32_v_f32m1(rhs_data_3, vl);

        vacc_00 = __riscv_vfmacc_vv_f32m1_tu(vacc_00, vlhs_0, vrhs_0, vl);
        vacc_01 = __riscv_vfmacc_vv_f32m1_tu(vacc_01, vlhs_0, vrhs_1, vl);
        vacc_02 = __riscv_vfmacc_vv_f32m1_tu(vacc_02, vlhs_0, vrhs_2, vl);
        vacc_03 = __riscv_vfmacc_vv_f32m1_tu(vacc_03, vlhs_0, vrhs_3, vl);

        vacc_10 = __riscv_vfmacc_vv_f32m1_tu(vacc_10, vlhs_1, vrhs_0, vl);
        vacc_11 = __riscv_vfmacc_vv_f32m1_tu(vacc_11, vlhs_1, vrhs_1, vl);
        vacc_12 = __riscv_vfmacc_vv_f32m1_tu(vacc_12, vlhs_1, vrhs_2, vl);
        vacc_13 = __riscv_vfmacc_vv_f32m1_tu(vacc_13, vlhs_1, vrhs_3, vl);

        vacc_20 = __riscv_vfmacc_vv_f32m1_tu(vacc_20, vlhs_2, vrhs_0, vl);
        vacc_21 = __riscv_vfmacc_vv_f32m1_tu(vacc_21, vlhs_2, vrhs_1, vl);
        vacc_22 = __riscv_vfmacc_vv_f32m1_tu(vacc_22, vlhs_2, vrhs_2, vl);
        vacc_23 = __riscv_vfmacc_vv_f32m1_tu(vacc_23, vlhs_2, vrhs_3, vl);

        vacc_30 = __riscv_vfmacc_vv_f32m1_tu(vacc_30, vlhs_3, vrhs_0, vl);
        vacc_31 = __riscv_vfmacc_vv_f32m1_tu(vacc_31, vlhs_3, vrhs_1, vl);
        vacc_32 = __riscv_vfmacc_vv_f32m1_tu(vacc_32, vlhs_3, vrhs_2, vl);
        vacc_33 = __riscv_vfmacc_vv_f32m1_tu(vacc_33, vlhs_3, vrhs_3, vl);

        lhs_data_0 += vl; lhs_data_1 += vl; lhs_data_2 += vl; lhs_data_3 += vl;
        rhs_data_0 += vl; rhs_data_1 += vl; rhs_data_2 += vl; rhs_data_3 += vl;
        k -= vl;
      }

      vfloat32m1_t vres_00 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_00, vzero, vlmax);
      vfloat32m1_t vres_01 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_01, vzero, vlmax);
      vfloat32m1_t vres_02 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_02, vzero, vlmax);
      vfloat32m1_t vres_03 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_03, vzero, vlmax);

      vfloat32m1_t vres_10 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_10, vzero, vlmax);
      vfloat32m1_t vres_11 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_11, vzero, vlmax);
      vfloat32m1_t vres_12 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_12, vzero, vlmax);
      vfloat32m1_t vres_13 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_13, vzero, vlmax);

      vfloat32m1_t vres_20 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_20, vzero, vlmax);
      vfloat32m1_t vres_21 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_21, vzero, vlmax);
      vfloat32m1_t vres_22 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_22, vzero, vlmax);
      vfloat32m1_t vres_23 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_23, vzero, vlmax);

      vfloat32m1_t vres_30 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_30, vzero, vlmax);
      vfloat32m1_t vres_31 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_31, vzero, vlmax);
      vfloat32m1_t vres_32 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_32, vzero, vlmax);
      vfloat32m1_t vres_33 = __riscv_vfredusum_vs_f32m1_f32m1(vacc_33, vzero, vlmax);

      __riscv_vse32_v_f32m1(result + r * rhs_cols + c, vres_00, 1);
      __riscv_vse32_v_f32m1(result + r * rhs_cols + c + 1, vres_01, 1);
      __riscv_vse32_v_f32m1(result + r * rhs_cols + c + 2, vres_02, 1);
      __riscv_vse32_v_f32m1(result + r * rhs_cols + c + 3, vres_03, 1);

      __riscv_vse32_v_f32m1(result + (r + 1) * rhs_cols + c, vres_10, 1);
      __riscv_vse32_v_f32m1(result + (r + 1) * rhs_cols + c + 1, vres_11, 1);
      __riscv_vse32_v_f32m1(result + (r + 1) * rhs_cols + c + 2, vres_12, 1);
      __riscv_vse32_v_f32m1(result + (r + 1) * rhs_cols + c + 3, vres_13, 1);

      __riscv_vse32_v_f32m1(result + (r + 2) * rhs_cols + c, vres_20, 1);
      __riscv_vse32_v_f32m1(result + (r + 2) * rhs_cols + c + 1, vres_21, 1);
      __riscv_vse32_v_f32m1(result + (r + 2) * rhs_cols + c + 2, vres_22, 1);
      __riscv_vse32_v_f32m1(result + (r + 2) * rhs_cols + c + 3, vres_23, 1);

      __riscv_vse32_v_f32m1(result + (r + 3) * rhs_cols + c, vres_30, 1);
      __riscv_vse32_v_f32m1(result + (r + 3) * rhs_cols + c + 1, vres_31, 1);
      __riscv_vse32_v_f32m1(result + (r + 3) * rhs_cols + c + 2, vres_32, 1);
      __riscv_vse32_v_f32m1(result + (r + 3) * rhs_cols + c + 3, vres_33, 1);
    }
  }
}

int main(int argc, char** argv) {
  uint32_t mcontext0_write_value = 1;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  MatMulF(kLhsRows, kInner, kRhsCols, lhs_input, rhs_input, result_output);

  mcontext0_write_value = 0;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  return 0;
}
