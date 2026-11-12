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

#include <cstdint>

volatile uint32_t trap_occurred = 0;
volatile uint32_t dtcm_word     = 0x55aa1234u;

extern "C" {
void isr_wrapper(void);
__attribute__((naked, aligned(4))) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mepc \n"
      "addi t0, t0, 4 \n"
      "csrw mepc, t0 \n"
      "csrr t0, mcause \n"
      "li t1, 5 \n"
      "bne t0, t1, 1f \n"
      "csrr t0, mtval \n"
      "li t1, 0xA0000000 \n"
      "bne t0, t1, 1f \n"
      "li t0, 1 \n"
      "la t1, trap_occurred \n"
      "sw t0, 0(t1) \n"
      "mret \n"
      "1: ebreak \n");
}
}  // extern "C"

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_wrapper)));

  // Non-faulting scalar load into x0 must retire cleanly.
  asm volatile("lw zero, 0(%0)" ::"r"(&dtcm_word) : "memory");

  // Faulting scalar load into x0 must flush LSU on trap retirement so subsequent
  // loads and stores inside the trap handler and after mret succeed.
  asm volatile(
      "lw zero, 0(%0) \n"
      "nop \n"
      "nop \n"
      "nop \n"
      "nop \n"
      :
      : "r"(0xA0000000u)
      : "t0", "t1", "memory");

  while (trap_occurred == 0u) {
  }

  if (dtcm_word != 0x55aa1234u) {
    return 1;
  }

  dtcm_word = 0xcafebabeu;
  if (dtcm_word != 0xcafebabeu) {
    return 2;
  }

  return 0;
}
