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

uint8_t input_data8[1024] __attribute__((section(".data")));
uint8_t output_data8[1024] __attribute__((section(".data")));
uint8_t output_stride_store8[1024] __attribute__((section(".data")));
uint16_t input_data16[1024] __attribute__((section(".data")));
uint16_t output_data16[1024] __attribute__((section(".data")));
uint16_t output_stride_store16[1024] __attribute__((section(".data")));
uint32_t input_data32[1024] __attribute__((section(".data")));
uint32_t output_data32[1024] __attribute__((section(".data")));
uint32_t output_stride_store32[1024] __attribute__((section(".data")));
ptrdiff_t input_stride __attribute__((section(".data")));
uint8_t input_mask[32] __attribute__((section(".data")));
size_t n = 8;

#define CREATE_VSTRIDE_MASK_FN(data_bits, data_lmul, mask_bits)                                      \
  __attribute__((used, retain)) void vstride_mask_u##data_bits##data_lmul() {                        \
    size_t vl = __riscv_vsetvl_e##data_bits##data_lmul(n);                                           \
    auto mask = __riscv_vlm_v_b##mask_bits((const uint8_t *)input_mask, vl);                         \
    auto op   = __riscv_vlse##data_bits##_v_u##data_bits##data_lmul##_m(mask, input_data##data_bits, \
                                                                        input_stride, vl);           \
    __riscv_vse##data_bits##_v_u##data_bits##data_lmul(output_data##data_bits, op, vl);              \
    __riscv_vsse##data_bits##_v_u##data_bits##data_lmul##_m(mask, output_stride_store##data_bits,    \
                                                            input_stride, op, vl);                   \
  }

extern "C" {
// vstride_mask
CREATE_VSTRIDE_MASK_FN(8, mf4, 32)
CREATE_VSTRIDE_MASK_FN(8, mf2, 16)
CREATE_VSTRIDE_MASK_FN(8, m1, 8)
CREATE_VSTRIDE_MASK_FN(8, m2, 4)
CREATE_VSTRIDE_MASK_FN(8, m4, 2)
CREATE_VSTRIDE_MASK_FN(8, m8, 1)

CREATE_VSTRIDE_MASK_FN(16, mf2, 32)
CREATE_VSTRIDE_MASK_FN(16, m1, 16)
CREATE_VSTRIDE_MASK_FN(16, m2, 8)
CREATE_VSTRIDE_MASK_FN(16, m4, 4)
CREATE_VSTRIDE_MASK_FN(16, m8, 2)

CREATE_VSTRIDE_MASK_FN(32, m1, 32)
CREATE_VSTRIDE_MASK_FN(32, m2, 16)
CREATE_VSTRIDE_MASK_FN(32, m4, 8)
CREATE_VSTRIDE_MASK_FN(32, m8, 4)
}

void (*rvv_stride_mask)() __attribute__((section(".data"))) = &vstride_mask_u16m1;

int main(int argc, char **argv) {
  rvv_stride_mask();
  return 0;
}