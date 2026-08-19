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

#define PLIC_BASE      0x0C000000u
#define PLIC_PRIO(i)   (*(volatile uint32_t *)(PLIC_BASE + 0x000000 + (i) * 4))
#define PLIC_PENDING   (*(volatile uint32_t *)(PLIC_BASE + 0x001000))
#define PLIC_LE        (*(volatile uint32_t *)(PLIC_BASE + 0x001080))
#define PLIC_ENABLE    (*(volatile uint32_t *)(PLIC_BASE + 0x002000))
#define PLIC_THRESHOLD (*(volatile uint32_t *)(PLIC_BASE + 0x200000))
#define PLIC_CLAIM     (*(volatile uint32_t *)(PLIC_BASE + 0x200004))
#define PLIC_COMPLETE  (*(volatile uint32_t *)(PLIC_BASE + 0x200004))

#define UART1_BASE   0x40010000u
#define UART1_PUT(c) (*(volatile uint32_t *)UART1_BASE = (c))

extern "C" {
void print_hex(uint32_t val) {
  for (int i = 7; i >= 0; i--) {
    int nibble = (val >> (i * 4)) & 0xf;
    UART1_PUT(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
  }
  UART1_PUT('\n');
}
}

volatile int last_claimed_id = 0;
volatile int intr_count      = 0;

extern "C" {

void plic_isr_wrapper(void);
__attribute__((naked)) void plic_isr_wrapper(void) {
  asm volatile(
      "addi sp, sp, -32 \n"
      "sw t0, 0(sp)     \n"
      "sw t1, 4(sp)     \n"
      "sw t2, 8(sp)     \n"
      "sw ra, 12(sp)    \n"
      "sw a0, 16(sp)    \n"

      // Check mcause == 0x8000000B (Machine External Interrupt)
      "csrr t0, mcause  \n"
      "li t1, 0x8000000B\n"
      "bne t0, t1, 1f   \n"

      // 1. Claim the interrupt
      "li t0, 0x0C200004\n"   // PLIC_CLAIM address
      "lw t1, 0(t0)      \n"  // t1 = id

      // 2. Store claimed ID
      "la t2, last_claimed_id \n"
      "sw t1, 0(t2)      \n"

      // 3. Increment interrupt count
      "la t2, intr_count \n"
      "lw t0, 0(t2)      \n"
      "addi t0, t0, 1    \n"
      "sw t0, 0(t2)      \n"

      // 4. Log
      "li a0, 'I'        \n"
      "li t0, 0x40010000 \n"  // UART1 address
      "sw a0, 0(t0)      \n"
      "mv a0, t1         \n"
      "jal print_hex     \n"

      // 5. Complete the interrupt
      "li t0, 0x0C200004\n"  // PLIC_COMPLETE address
      "sw t1, 0(t0)      \n"

      "1:                \n"
      "lw t0, 0(sp)     \n"
      "lw t1, 4(sp)     \n"
      "lw t2, 8(sp)     \n"
      "lw ra, 12(sp)    \n"
      "lw a0, 16(sp)    \n"
      "addi sp, sp, 32  \n"
      "mret             \n");
}

}  // extern "C"

int main() {
  asm volatile("csrw mtvec, %0" ::"r"((uint32_t)(&plic_isr_wrapper)));

  PLIC_PRIO(1)   = 5;
  PLIC_PRIO(2)   = 10;
  PLIC_LE        = (1u << 2);  // bit 2 set = edge
  PLIC_ENABLE    = (1u << 1) | (1u << 2);
  PLIC_THRESHOLD = 0;

  asm volatile("csrs mie, %0" ::"r"(1u << 11));
  asm volatile("csrs mstatus, %0" ::"r"(1u << 3));

  UART1_PUT('R');
  UART1_PUT('\n');

  while (intr_count < 2) {
    asm volatile("wfi");
  }

  UART1_PUT('D');
  UART1_PUT('\n');
  return 0;
}
