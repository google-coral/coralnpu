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

extern "C" {

// Either A or B must be quantized symmetrically. -128 may appear on one side,
// but not both. Otherwise this implementation will overflow and produce
// incorrect results.
void rvv_gemv_int8(const int8_t *__restrict__ A, const int8_t *__restrict__ B,
                   int32_t *__restrict__ C, size_t K, size_t N) {
  size_t n = 0;
  // N main
  const size_t vlmax_e8m4  = __riscv_vsetvlmax_e8m4();
  const size_t vlmax_e32m8 = __riscv_vsetvlmax_e32m8();
  for (; n + vlmax_e8m4 <= N; n += vlmax_e8m4) {
    const int8_t *lhs_ptr        = A;
    const int8_t *rhs_ptr_scatch = B + n;
    int32_t *acc_ptr             = C + n;

    vint32m8_t acc1, acc2;
    // Compiler wants to spill and store these. This asm block is the
    // workaround.
    asm("vsetvli zero, zero, e32, m8, ta, ma;"
        "vmv.v.x %[acc1], zero;"
        "vmv.v.x %[acc2], zero;"
        : [acc1] "=vr"(acc1), [acc2] "=vr"(acc2)::"vl", "vtype");

    size_t k = 0;
    // K main
    for (; k + 4 <= K; k += 4) {
      uint32_t lhs_bundle = *(const uint32_t *)(lhs_ptr + k);

      asm("vsetvli zero, %[vl], e8, m4, ta, ma;"
          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmul.vx v8, v4, %[lhs];"
          "srli %[lhs], %[lhs], 8;"

          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmacc.vx v8, %[lhs], v4;"
          "vsetvli zero, %[vl_f2], e16, m4, ta, ma;"
          "vwadd.wv %[acc1], %[acc1], v8;"
          "vwadd.wv %[acc2], %[acc2], v12;"
          "srli %[lhs], %[lhs], 8;"

          "vsetvli zero, %[vl], e8, m4, ta, ma;"
          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmul.vx v8, v4, %[lhs];"
          "srli %[lhs], %[lhs], 8;"

          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmacc.vx v8, %[lhs], v4;"
          "vsetvli zero, %[vl_f2], e16, m4, ta, ma;"
          "vwadd.wv %[acc1], %[acc1], v8;"
          "vwadd.wv %[acc2], %[acc2], v12;"

          : [acc1] "+vr"(acc1), [acc2] "+vr"(acc2), [lhs] "+r"(lhs_bundle),
            [rhs_ptr] "+r"(rhs_ptr_scatch)
          : [n] "r"(N), [vl] "r"(vlmax_e8m4), [vl_f2] "r"(vlmax_e32m8),
            // We're reading 4 rows, marking the entire operand is easier than
            // marking precisely.
            "m"(*(const int8_t(*)[K * N]) B)
          : "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl",
            "vtype");
    }
    // K tail
    for (; k < K; k += 1) {
      int8_t lhs = lhs_ptr[k];

      asm("vsetvli zero, %[vl], e8, m4, ta, ma;"
          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmul.vx v8, v4, %[lhs];"
          "vsetvli zero, %[vl_f2], e16, m4, ta, ma;"
          "vwadd.wv %[acc1], %[acc1], v8;"
          "vwadd.wv %[acc2], %[acc2], v12;"

          : [acc1] "+vr"(acc1), [acc2] "+vr"(acc2), [lhs] "+r"(lhs), [rhs_ptr] "+r"(rhs_ptr_scatch)
          : [n] "r"(N), [vl] "r"(vlmax_e8m4), [vl_f2] "r"(vlmax_e32m8),
            "m"(*(const int8_t(*)[vlmax_e8m4])rhs_ptr_scatch)
          : "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl",
            "vtype");
    }
    __riscv_vse32_v_i32m8(acc_ptr, acc1, vlmax_e32m8);
    __riscv_vse32_v_i32m8(acc_ptr + vlmax_e32m8, acc2, vlmax_e32m8);
  }
  // N tail
  while (n < N) {
    const size_t vl              = __riscv_vsetvl_e8m2(N - n);
    const int8_t *lhs_ptr        = A;
    const int8_t *rhs_ptr_scatch = B + n;
    int32_t *acc_ptr             = C + n;

    vint32m8_t acc;
    // Compiler wants to spill and store these. This asm block is the
    // workaround.
    asm("vsetvli zero, zero, e32, m8, ta, ma;"
        "vmv.v.x %[acc], zero;"
        : [acc] "=vr"(acc)::"vl", "vtype");

    size_t k = 0;
    // K main
    for (; k + 4 <= K; k += 4) {
      uint32_t lhs_bundle = *(const uint32_t *)(lhs_ptr + k);

      // TODO(davidgao): This block can potentially be faster, but this is tail and is
      // not our current focus.
      asm("vsetvli zero, %[vl], e8, m2, ta, ma;"
          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmul.vx v8, v4, %[lhs];"
          "srli %[lhs], %[lhs], 8;"

          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmacc.vx v8, %[lhs], v4;"
          "vsetvli zero, %[vl_f2], e16, m4, ta, ma;"
          "vwadd.wv %[acc], %[acc], v8;"
          "srli %[lhs], %[lhs], 8;"

          "vsetvli zero, %[vl], e8, m2, ta, ma;"
          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmul.vx v8, v4, %[lhs];"
          "srli %[lhs], %[lhs], 8;"

          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmacc.vx v8, %[lhs], v4;"
          "vsetvli zero, %[vl_f2], e16, m4, ta, ma;"
          "vwadd.wv %[acc], %[acc], v8;"

          : [acc] "+vr"(acc), [lhs] "+r"(lhs_bundle), [rhs_ptr] "+r"(rhs_ptr_scatch)
          : [n] "r"(N), [vl] "r"(vlmax_e8m4), [vl_f2] "r"(vlmax_e32m8),
            // We're reading 4 rows, marking the entire operand is easier than
            // marking precisely.
            "m"(*(const int8_t(*)[K * N]) B)
          : "v4", "v5", "v8", "v9", "v10", "v11", "vl", "vtype");
    }
    for (; k < K; k += 1) {
      int8_t lhs = lhs_ptr[k];

      asm("vsetvli zero, %[vl], e8, m2, ta, ma;"
          "vle8.v v4, (%[rhs_ptr]);"
          "add %[rhs_ptr], %[rhs_ptr], %[n];"
          "vwmul.vx v8, v4, %[lhs];"
          "vsetvli zero, %[vl_f2], e16, m4, ta, ma;"
          "vwadd.wv %[acc], %[acc], v8;"

          : [acc] "+vr"(acc), [lhs] "+r"(lhs), [rhs_ptr] "+r"(rhs_ptr_scatch)
          : [n] "r"(N), [vl] "r"(vlmax_e8m4), [vl_f2] "r"(vlmax_e32m8),
            "m"(*(const int8_t(*)[vlmax_e8m4])rhs_ptr_scatch)
          : "v4", "v5", "v8", "v9", "v10", "v11", "vl", "vtype");
    }
    __riscv_vse32_v_i32m8(acc_ptr, acc, vlmax_e32m8);

    n += vl;
  }
}

// Either A or B must be quantized symmetrically. -128 may appear on one side,
// but not both. Otherwise this implementation will overflow and produce
// incorrect results.
void rvv_matmul_int8(const int8_t *__restrict__ A, const int8_t *__restrict__ B,
                     int32_t *__restrict__ C, size_t M, size_t K, size_t N) {
  // We reached very high register pressure and ALU/MUL load with gemv, and it's
  // hard to reach higher mac/s with a dedicated matmul implementation.
  // For now we just call gemv in a loop.
  for (size_t m = 0; m < M; ++m) {
    rvv_gemv_int8(A + m * K, B, C + m * N, K, N);
  }
}

}  // extern "C"
