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

extern "C" {
void isr_wrapper(void);
__attribute__((naked)) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mepc \n"
      "addi t0, t0, 4 \n"  // Skip the trapping instruction
      "csrw mepc, t0 \n"
      "csrr t0, mcause \n"
      "li t1, 2 \n"  // mcause = 2 is illegal instruction exception
      "beq t0, t1, 0f \n"
      "ebreak \n"  // Cause simulation error if mcause is not 2
      "0: \n"
      "li t0, 1 \n"
      "la t1, trap_occurred \n"
      "sw t0, 0(t1) \n"  // Set trap_occurred = 1
      "mret \n");
}
}  // extern "C"

#define STRINGIFY(x) #x
#define TOSTRING(x)  STRINGIFY(x)

int main(int argc, char **argv) {
  // Set trap vector
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_wrapper)));

  // Configure vector state (required before executing vector instructions)
  // vsetvli zero, zero, e32, m1, ta, ma
  uint32_t avl = 4;
  asm volatile("vsetvli zero, %0, e32, m1, ta, ma" ::"r"(avl));

  trap_occurred = 0;
  // Execute unimplemented widening float instruction
  asm volatile(TOSTRING(TRAP_OP) " v2, v4, v6");

  // Spin until trap is handled. If no trap, we hang here (causing cocotb timeout).
  while (trap_occurred == 0) {
  }

  // Clean halt
  asm volatile(".word 0x08000073");  // mpause
  return 0;
}
