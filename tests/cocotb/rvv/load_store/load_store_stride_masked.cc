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

uint32_t input_data[512] __attribute__((section(".data")));
uint32_t output_data[512] __attribute__((section(".data")));
uint32_t output_stride_store[512] __attribute__((section(".data")));
ptrdiff_t input_stride __attribute__((section(".data")));
uint8_t input_mask[32] __attribute__((section(".data")));
size_t n = 10;

void rvv_stride_mask() {
  size_t vl = __riscv_vsetvl_e32m4(n);
  auto mask = __riscv_vlm_v_b8(input_mask, vl);
  auto op   = __riscv_vlse32_v_u32m4_m(mask, input_data, input_stride, vl);
  __riscv_vse32_v_u32m4(output_data, op, vl);
  __riscv_vsse32_v_u32m4_m(mask, output_stride_store, input_stride, op, vl);
}

int main(int argc, char **argv) {
  rvv_stride_mask();
  return 0;
}