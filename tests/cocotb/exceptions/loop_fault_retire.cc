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

extern "C" {
void isr_wrapper(void);
extern const uint32_t loop_body[];
extern const uint32_t loop_jalr[];

__attribute__((naked, aligned(4))) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mcause \n"
      "bnez t0, 1f \n"
      "csrr t0, mepc \n"
      "la t1, loop_jalr \n"
      "bne t0, t1, 1f \n"
      "csrr t0, mtval \n"
      "la t1, loop_body \n"
      "addi t1, t1, 2 \n"
      "bne t0, t1, 1f \n"
      "li t0, 2 \n"
      "bne a1, t0, 1f \n"
      "li t1, 0x20000000 \n"
      "lw t2, 0(t1) \n"
      "bne t2, t0, 1f \n"
      "lw t2, 16(t1) \n"
      "bne t2, t0, 1f \n"
      "lw t2, 32(t1) \n"
      "bne t2, t0, 1f \n"
      "lw t2, 48(t1) \n"
      "bne t2, t0, 1f \n"
      ".word 0x08000073 \n"
      "1: ebreak \n");
}
}  // extern "C"

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_wrapper)));

  volatile uint32_t *ext = reinterpret_cast<volatile uint32_t *>(0x20000000u);
  ext[0]                 = 0;
  ext[4]                 = 0;
  ext[8]                 = 0;
  ext[12]                = 0;
  asm volatile("fence" ::: "memory");

  // Iteration 0 launches a multi-cycle integer division so Iteration 0's jump
  // at loop_jalr remains waiting in instBuffer. Iteration 1 skips the division,
  // queues four external memory stores (each at a distinct PC), and faults on a
  // misaligned jalr at loop_jalr. All four Iteration 1 stores must commit.
  asm volatile(
      "li s0, 0x20000000 \n"
      "li a1, 0 \n"
      "li t3, 0x7fffffff \n"
      "li t4, 3 \n"
      "li t5, 1 \n"
      "la a3, loop_body \n"
      "xori a3, a3, 2 \n"
      ".balign 16 \n"
      ".globl loop_body \n"
      "loop_body: \n"
      "addi a1, a1, 1 \n"
      "beq a1, t5, 0f \n"
      "sw a1, 0(s0) \n"
      "sw a1, 16(s0) \n"
      "sw a1, 32(s0) \n"
      "sw a1, 48(s0) \n"
      "j 1f \n"
      "0: \n"
      "div t6, t3, t4 \n"
      "1: \n"
      "xori a3, a3, 2 \n"
      ".globl loop_jalr \n"
      "loop_jalr: \n"
      "jalr zero, 0(a3) \n"
      "ebreak \n"
      :
      :
      : "s0", "a1", "a3", "t3", "t4", "t5", "t6", "memory");

  return 0;
}
