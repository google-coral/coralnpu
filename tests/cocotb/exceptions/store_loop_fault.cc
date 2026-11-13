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

volatile uint32_t dtcm_word = 0;

extern "C" {
void isr_wrapper(void);
extern const uint32_t loop_store[];

__attribute__((naked, aligned(4))) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mcause \n"
      "li t1, 7 \n"
      "bne t0, t1, 1f \n"
      "csrr t0, mepc \n"
      "la t1, loop_store \n"
      "bne t0, t1, 1f \n"
      "csrr t0, mtval \n"
      "li t1, 0xA0000000 \n"
      "bne t0, t1, 1f \n"
      // The LSU must accept new stores and loads once the trap has retired.
      "la t1, dtcm_word \n"
      "li t0, 0x5a \n"
      "sw t0, 0(t1) \n"
      "lw t2, 0(t1) \n"
      "bne t2, t0, 1f \n"
      // The two stores before the faulting one must have reached memory.
      "li t1, 0x20000000 \n"
      "li t0, 0x55 \n"
      "lw t2, 0(t1) \n"
      "bne t2, t0, 1f \n"
      "lw t2, 16(t1) \n"
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
  asm volatile("fence" ::: "memory");

  // Three iterations run the store at loop_store. The first two write external
  // memory; the third targets an unmapped address and must trap with a store
  // access fault at loop_store. The slow external stores let all three
  // iterations wait in the retirement buffer at the same PC.
  asm volatile(
      "li a0, 0x20000000 \n"
      "li a3, 0x20000010 \n"
      "li a4, 0xA0000000 \n"
      "li a1, 0x55 \n"
      "li a5, 3 \n"
      ".balign 16 \n"
      ".globl loop_store \n"
      "loop_store: \n"
      "sw a1, 0(a0) \n"
      "mv a0, a3 \n"
      "mv a3, a4 \n"
      "addi a5, a5, -1 \n"
      "bnez a5, loop_store \n"
      "ebreak \n"
      :
      :
      : "a0", "a1", "a3", "a4", "a5", "memory");

  return 0;
}
