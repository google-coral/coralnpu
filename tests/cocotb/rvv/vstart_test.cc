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

uint32_t vstart __attribute__((section(".data"))) = 0;
uint16_t data_input[128] __attribute__((section(".data")));
uint16_t reg[128] __attribute__((section(".data")));

size_t n = 8;

uint32_t vstart_after_op1 __attribute__((section(".data"))) = 0xDEADBEEF;
uint32_t vstart_after_op2 __attribute__((section(".data"))) = 0xDEADBEEF;

void vstart_test() {
  size_t vl;
  vuint16m1_t vec_1, vec_2;
  vuint16m1_t op_1, op_2;
  uint32_t local_vstart = vstart;
  uint32_t csrr_vstart1 = 0;
  uint32_t csrr_vstart2 = 0;
  typedef uint16_t array_t[n];
  asm volatile(
      "vsetvli %[vl], %[n], e16, m1, ta, ma \n\t"
      // load regs
      "vle16.v %[vec_1], %[in_mem1] \n\t"
      "vle16.v %[vec_2], %[in_mem2] \n\t"
      // using vstart #1
      "csrw vstart, %[local_vstart] \n\t"
      "vadd.vv %[op_1], %[vec_1], %[vec_2] \n\t"
      // read vstart after op_1 completes
      "csrr %[csrr_vstart1], vstart \n\t"
      // nops
      ".rept 1850 \n\t"
      "nop \n\t"
      ".endr \n\t"
      "vadd.vv %[op_2], %[vec_1], %[vec_2] \n\t"
      // read vstart after op_2 completes
      "csrr %[csrr_vstart2], vstart \n\t"
      // store
      "vse16.v %[vec_1], %[out_mem0] \n\t"
      "vse16.v %[vec_2], %[out_mem18] \n\t"
      "vse16.v %[op_1], %[out_mem36] \n\t"
      "vse16.v %[op_2], %[out_mem54] \n\t"
      : [vl] "=&r"(vl), [vec_1] "=&vr"(vec_1), [vec_2] "=&vr"(vec_2), [op_1] "=&vr"(op_1),
        [op_2] "=&vr"(op_2), [csrr_vstart1] "=&r"(csrr_vstart1), [csrr_vstart2] "=&r"(csrr_vstart2),
        [out_mem0] "=A"(*(array_t *)(reg)), [out_mem18] "=A"(*(array_t *)(reg + 18)),
        [out_mem36] "=A"(*(array_t *)(reg + 36)), [out_mem54] "=A"(*(array_t *)(reg + 54))

      : [n] "r"(n), [local_vstart] "r"(local_vstart), [in_mem1] "A"(*(array_t *)(data_input + 8)),
        [in_mem2] "A"(*(array_t *)(data_input + 16))

      : "vtype", "vl", "memory");
  vstart_after_op1 = csrr_vstart1;
  vstart_after_op2 = csrr_vstart2;
}

int main(int argc, char **argv) {
  vstart_test();
  return 0;
}