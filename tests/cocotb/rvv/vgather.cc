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

uint8_t input_value8[64] __attribute__((section(".data")));
uint8_t input_index8[64] __attribute__((section(".data")));
uint8_t output_value8[64] __attribute__((section(".data")));

uint16_t input_value16[64] __attribute__((section(".data")));
uint16_t input_index16[64] __attribute__((section(".data")));
uint16_t output_value16[64] __attribute__((section(".data")));
size_t n = 8;

#define CREATE_VGATHER_FN(data_bits, data_lmul, index_bits, index_lmul)                         \
  __attribute__((used,                                                                          \
                 retain)) void vgather_d##data_bits##data_lmul##_i##index_bits##index_lmul() {  \
    size_t vl = __riscv_vsetvl_e##data_bits##data_lmul(n);                                      \
    auto vec  = __riscv_vle##data_bits##_v_u##data_bits##data_lmul(input_value##data_bits, vl); \
    auto index =                                                                                \
        __riscv_vle##index_bits##_v_u##index_bits##index_lmul(input_index##index_bits, vl);     \
    auto op = __riscv_vrgather_vv_u##data_bits##data_lmul(vec, index, vl);                      \
    __riscv_vse##data_bits##_v_u##data_bits##data_lmul(output_value##data_bits, op, vl);        \
  }

extern "C" {
// vgather
CREATE_VGATHER_FN(8, mf2, 8, mf2)
CREATE_VGATHER_FN(8, m1, 8, m1)
CREATE_VGATHER_FN(8, m2, 8, m2)
CREATE_VGATHER_FN(8, m4, 8, m4)
CREATE_VGATHER_FN(8, m8, 8, m8)
CREATE_VGATHER_FN(16, mf2, 16, mf2)
CREATE_VGATHER_FN(16, m1, 16, m1)
CREATE_VGATHER_FN(16, m2, 16, m2)
CREATE_VGATHER_FN(16, m4, 16, m4)
CREATE_VGATHER_FN(16, m8, 16, m8)
}

void (*rvv_shuffle)() __attribute__((section(".data"))) = &vgather_d16m1_i16m1;

int main(int argc, char **argv) {
  rvv_shuffle();
  return 0;
}