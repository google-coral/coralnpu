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

// main keeps the expected mepc in a4 and the expected mtval in a3, and counts
// the traps taken in a2.
__attribute__((naked, aligned(4))) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mcause \n"
      "bnez t0, 1f \n"
      "csrr t0, mepc \n"
      "bne t0, a4, 1f \n"
      // mtval holds the misaligned branch target.
      "csrr t1, mtval \n"
      "bne t1, a3, 1f \n"
      // The instruction after the branch must not have executed.
      "bnez a5, 1f \n"
      // The store before the first branch must have reached memory.
      "li t1, 0x20000000 \n"
      "lw t2, 0(t1) \n"
      "li t1, 0x55 \n"
      "bne t2, t1, 1f \n"
      "addi a2, a2, 1 \n"
      // Resume after the instruction that follows the branch.
      "addi t0, t0, 8 \n"
      "csrw mepc, t0 \n"
      "mret \n"
      "1: ebreak \n");
}
}  // extern "C"

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_wrapper)));

  volatile uint32_t *ext = reinterpret_cast<volatile uint32_t *>(0x20000000u);
  ext[0]                 = 0;
  asm volatile("fence" ::: "memory");

  // A taken conditional branch with a misaligned target must trap with an
  // instruction-address-misaligned exception. The first branch jumps forward
  // (offset +2); the second jumps backward (offset -2), which the fetch stage
  // would otherwise predict as taken.
  asm volatile(
      "li a0, 0x20000000 \n"
      "li a1, 0x55 \n"
      "li a2, 0 \n"
      "li a5, 0 \n"
      "sw a1, 0(a0) \n"
      "la a4, 2f \n"
      "addi a3, a4, 2 \n"
      "2: beq zero, zero, .+2 \n"
      "li a5, 1 \n"
      "la a4, 3f \n"
      "addi a3, a4, -2 \n"
      "3: bge zero, zero, .-2 \n"
      "li a5, 1 \n"
      "li t0, 2 \n"
      "beq a2, t0, 4f \n"
      "ebreak \n"
      "4: \n"
      :
      :
      : "a0", "a1", "a2", "a3", "a4", "a5", "t0", "memory");

  return 0;
}
