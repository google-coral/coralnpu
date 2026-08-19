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

// Software interrupt test: verifies CLINT msip and interrupt delivery
// via mtvec.

#include <cstdint>

#define CLINT_BASE 0x02000000u
#define MSIP       (*(volatile uint32_t *)(CLINT_BASE + 0x0000))

volatile int sw_fired = 0;

extern "C" {

// ISR: check mcause == 0x80000003 (machine software interrupt).
// If so, disable interrupt by clearing MSIP and set flag.
void isr_wrapper(void);
__attribute__((naked)) __attribute__((aligned(4))) void isr_wrapper(void) {
  asm volatile(
      // Save t0, t1 on stack
      "addi sp, sp, -8  \n"
      "sw t0, 0(sp)     \n"
      "sw t1, 4(sp)     \n"

      // Check mcause
      "csrr t0, mcause  \n"
      "li t1, 0x80000003\n"  // Machine software interrupt
      "bne t0, t1, 1f   \n"

      // Software interrupt: disable by clearing MSIP
      "li t0, 0x02000000\n"  // MSIP address
      "sw zero, 0(t0)   \n"  // msip = 0

      // Set sw_fired = 1
      "la t0, sw_fired  \n"
      "li t1, 1          \n"
      "sw t1, 0(t0)      \n"
      "j 2f              \n"

      // Wrong cause: set sw_fired = 2
      "1:                \n"
      "la t0, sw_fired  \n"
      "li t1, 2          \n"
      "sw t1, 0(t0)      \n"

      // Restore and return
      "2:                \n"
      "lw t0, 0(sp)     \n"
      "lw t1, 4(sp)     \n"
      "addi sp, sp, 8   \n"
      "mret             \n");
}

}  // extern "C"

int main() {
  // 1. Set mtvec to our handler
  asm volatile("csrw mtvec, %0" ::"r"((uint32_t)(&isr_wrapper)));

  // 2. Enable mie.MSIE (bit 3)
  asm volatile("csrs mie, %0" ::"r"(1u << 3));

  // 3. Enable mstatus.MIE (bit 3) — this arms the interrupt
  asm volatile("csrs mstatus, %0" ::"r"(1u << 3));

  // 4. Spin-wait for the ISR to set sw_fired.
  // The interrupt will be triggered externally by writing to MSIP.
  for (volatile int i = 0; i < 100000; i = i + 1) {
    if (sw_fired)
      break;
  }

  return !(sw_fired == 1);
}
