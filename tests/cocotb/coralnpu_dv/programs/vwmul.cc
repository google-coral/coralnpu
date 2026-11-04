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

#define ELEMENT_COUNT 32

volatile int8_t input_a[ELEMENT_COUNT]          = {-1};
volatile int8_t input_b[ELEMENT_COUNT]          = {-1};
volatile int16_t output_products[ELEMENT_COUNT] = {-1};

volatile uint32_t elements_done = 0xFFFFFFFFU;

volatile uint32_t done_flag = 0xFFFFFFFFU;

int main(int argc, char **argv) {
  const int8_t *pa = (const int8_t *)input_a;
  const int8_t *pb = (const int8_t *)input_b;
  int16_t *pout    = (int16_t *)output_products;

  size_t remaining   = ELEMENT_COUNT;
  uint32_t processed = 0;

  while (remaining > 0) {
    size_t vl = __riscv_vsetvl_e8m1(remaining);

    vint8m1_t va = __riscv_vle8_v_i8m1(pa, vl);
    vint8m1_t vb = __riscv_vle8_v_i8m1(pb, vl);

    vint16m2_t vprod = __riscv_vwmul_vv_i16m2(va, vb, vl);

    __riscv_vse16_v_i16m2(pout, vprod, vl);

    pa += vl;
    pb += vl;
    pout += vl;
    remaining -= vl;
    processed += vl;
  }

  elements_done = processed;
  done_flag     = 0xD09EU;
  return 0;
}
