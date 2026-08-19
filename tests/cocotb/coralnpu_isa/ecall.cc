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

static volatile uint32_t isr_ok = 0;

extern "C" {

void isr_wrapper(void);
__attribute__((naked)) void isr_wrapper() {
  asm volatile(
      "csrr t0, mepc \n"
      "addi t0, t0, 4 \n"
      "csrw mepc, t0 \n"
      "csrr t0, mcause \n"
      "li t1, 11 \n"
      "bne t0, t1, 0f \n"
      "lw t0, 0(%[isr_ok]) \n"
      "addi t0, t0, 1 \n"
      "sw t0, 0(%[isr_ok]) \n"
      "0: mret \n"
      : /* outputs */
      : /* inputs */[isr_ok] "r"(&isr_ok));
}

void bad_isr(void);
__attribute__((naked)) void bad_isr() { asm volatile("ebreak \n"); }

__attribute__((naked, aligned(256))) void isr_vector_table() {
  asm volatile(
      "j isr_wrapper \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n"
      "j bad_isr \n");
}

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_vector_table)));
  asm volatile("ecall");
  if (isr_ok == 0) {
    asm volatile("ebreak");
  }

  return 0;
}
}
