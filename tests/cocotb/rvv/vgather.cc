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

uint16_t input_value[64] __attribute__((section(".data")));
uint16_t input_index[64] __attribute__((section(".data")));
uint16_t output_value[64] __attribute__((section(".data")));
size_t n = 8;

void rvv_shuffle() {
  size_t vl         = __riscv_vsetvl_e16m1(n);
  vuint16m1_t vec   = __riscv_vle16_v_u16m1(input_value, vl);
  vuint16m1_t index = __riscv_vle16_v_u16m1(input_index, vl);
  vuint16m1_t op    = __riscv_vrgatherei16_vv_u16m1(vec, index, vl);
  __riscv_vse16_v_u16m1(output_value, op, vl);
}

int main() {
  rvv_shuffle();
  return 0;
}