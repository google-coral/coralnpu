// Copyright 2025 Google LLC
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

#include <cstdint>

// GCC throws an array-bounds warning with optimizations enabled.
// Disable them for this translation unit.
#pragma GCC optimize("O0")

extern "C" {
void isr_wrapper(void);
__attribute__((naked)) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mepc \n"
      "addi t0, t0, 4 \n"
      "csrw mepc, t0 \n"
      "csrr t0, mcause \n"
      "li t1, 7 \n"
      "beq t0, t1, 0f \n"
      "csrr t0, mtval \n"
      "li t1, 0x4 \n"
      "beq t0, t1, 0f \n"
      "ebreak \n"
      "0: .word 0x08000073 \n");
}

}  // extern "C"

int main(int argc, char **argv) {
  // Store Fault (internal)
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_wrapper)));
  volatile uint32_t *store_bad_addr = (uint32_t *)4L;
  *store_bad_addr                   = 0xdeadbeef;
  asm volatile("ebreak");

  return 0;
}
