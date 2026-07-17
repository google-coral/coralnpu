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

extern "C" {

// 1D x 2D Decode MatMul (Register-Pinned GeMV with LMUL=8)
void rvv_gemv_1d_f32(const float *__restrict__ A, const float *__restrict__ B,
                     float *__restrict__ C, int K, int N) {
  int c = 0;
  // Main unrolled loop: process 64-element chunks (1 branch per iteration)
  while (c <= N - 64) {
    size_t vl_m8 = __riscv_vsetvl_e32m8(32);

    vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_m8);
    vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_m8);

    const float *rhs_ptr = B + c;
    for (int k = 0; k < K; k++) {
      float a = A[k];

      vfloat32m8_t vb0 = __riscv_vle32_v_f32m8(rhs_ptr, vl_m8);
      vacc0            = __riscv_vfmacc_vf_f32m8(vacc0, a, vb0, vl_m8);
      vfloat32m8_t vb1 = __riscv_vle32_v_f32m8(rhs_ptr + vl_m8, vl_m8);
      vacc1            = __riscv_vfmacc_vf_f32m8(vacc1, a, vb1, vl_m8);
      rhs_ptr += N;
    }

    __riscv_vse32_v_f32m8(C + c, vacc0, vl_m8);
    __riscv_vse32_v_f32m8(C + c + vl_m8, vacc1, vl_m8);

    c += 2 * vl_m8;
  }

  // Tail loop for remaining elements < 64
  while (c < N) {
    size_t vl          = __riscv_vsetvl_e32m4(N - c);
    vfloat32m4_t vacc0 = __riscv_vfmv_v_f_f32m4(0.0f, vl);

    const float *rhs_ptr = B + c;
    for (int k = 0; k < K; k++) {
      float a          = A[k];
      vfloat32m4_t vb0 = __riscv_vle32_v_f32m4(rhs_ptr, vl);
      vacc0            = __riscv_vfmacc_vf_f32m4(vacc0, a, vb0, vl);
      rhs_ptr += N;
    }
    __riscv_vse32_v_f32m4(C + c, vacc0, vl);
    c += vl;
  }
}

// 2D x 2D Prefill MatMul (Tiled MatMul with LMUL=8)
void rvv_tiled_matmul_2d_f32(const float *__restrict__ A, const float *__restrict__ B,
                             float *__restrict__ C, int M, int K, int N) {
  int m = 0;
  while (m <= M - 2) {
    int n = 0;
    while (n <= N - 32) {
      size_t vl_m8 = __riscv_vsetvl_e32m8(32);

      vfloat32m8_t vacc0 = __riscv_vfmv_v_f_f32m8(0.0f, vl_m8);
      vfloat32m8_t vacc1 = __riscv_vfmv_v_f_f32m8(0.0f, vl_m8);

      for (int k = 0; k < K; k++) {
        float a0 = A[(m + 0) * K + k];
        float a1 = A[(m + 1) * K + k];

        vfloat32m8_t vb0 = __riscv_vle32_v_f32m8(B + k * N + n, vl_m8);

        vacc0 = __riscv_vfmacc_vf_f32m8(vacc0, a0, vb0, vl_m8);
        vacc1 = __riscv_vfmacc_vf_f32m8(vacc1, a1, vb0, vl_m8);
      }

      __riscv_vse32_v_f32m8(C + (m + 0) * N + n, vacc0, vl_m8);
      __riscv_vse32_v_f32m8(C + (m + 1) * N + n, vacc1, vl_m8);

      n += vl_m8;
    }

    // Tail columns for row pair
    while (n < N) {
      size_t vl          = __riscv_vsetvl_e32m4(N - n);
      vfloat32m4_t vacc0 = __riscv_vfmv_v_f_f32m4(0.0f, vl);
      vfloat32m4_t vacc1 = __riscv_vfmv_v_f_f32m4(0.0f, vl);

      for (int k = 0; k < K; k++) {
        float a0        = A[(m + 0) * K + k];
        float a1        = A[(m + 1) * K + k];
        vfloat32m4_t vb = __riscv_vle32_v_f32m4(B + k * N + n, vl);
        vacc0           = __riscv_vfmacc_vf_f32m4(vacc0, a0, vb, vl);
        vacc1           = __riscv_vfmacc_vf_f32m4(vacc1, a1, vb, vl);
      }

      __riscv_vse32_v_f32m4(C + (m + 0) * N + n, vacc0, vl);
      __riscv_vse32_v_f32m4(C + (m + 1) * N + n, vacc1, vl);

      n += vl;
    }

    m += 2;
  }

  // Single tail row if M is odd
  while (m < M) {
    int c = 0;
    while (c < N) {
      size_t vl         = __riscv_vsetvl_e32m4(N - c);
      vfloat32m4_t vacc = __riscv_vfmv_v_f_f32m4(0.0f, vl);
      for (int k = 0; k < K; k++) {
        float a         = A[m * K + k];
        vfloat32m4_t vb = __riscv_vle32_v_f32m4(B + k * N + c, vl);
        vacc            = __riscv_vfmacc_vf_f32m4(vacc, a, vb, vl);
      }
      __riscv_vse32_v_f32m4(C + m * N + c, vacc, vl);
      c += vl;
    }
    m++;
  }
}

}  // extern "C"
