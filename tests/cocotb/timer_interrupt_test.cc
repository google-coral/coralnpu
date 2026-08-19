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

// Timer interrupt test: verifies CLINT mtime/mtimecmp and interrupt delivery
// via mtvec. Runs on the CoralNPUChiselSubsystem which has the CLINT at
// 0x02000000.

#include <cstdint>

#define CLINT_BASE  0x02000000u
#define MTIMECMP_LO (*(volatile uint32_t *)(CLINT_BASE + 0x4000))
#define MTIMECMP_HI (*(volatile uint32_t *)(CLINT_BASE + 0x4004))
#define MTIME_LO    (*(volatile uint32_t *)(CLINT_BASE + 0xBFF8))
#define MTIME_HI    (*(volatile uint32_t *)(CLINT_BASE + 0xBFFC))

volatile int timer_fired = 0;

extern "C" {

// ISR: check mcause == 0x80000007 (machine timer interrupt).
// If so, disable timer (set mtimecmp to max) and set flag.
// Otherwise, set flag to 2 (wrong cause).
void isr_wrapper(void);
__attribute__((naked)) void isr_wrapper(void) {
  asm volatile(
      // Save all caller-saved registers (ra, t0-t6, a0-a7)
      "addi sp, sp, -64 \n"
      "sw ra,  0(sp)    \n"
      "sw t0,  4(sp)    \n"
      "sw t1,  8(sp)    \n"
      "sw t2,  12(sp)   \n"
      "sw t3,  16(sp)   \n"
      "sw t4,  20(sp)   \n"
      "sw t5,  24(sp)   \n"
      "sw t6,  28(sp)   \n"
      "sw a0,  32(sp)   \n"
      "sw a1,  36(sp)   \n"
      "sw a2,  40(sp)   \n"
      "sw a3,  44(sp)   \n"
      "sw a4,  48(sp)   \n"
      "sw a5,  52(sp)   \n"
      "sw a6,  56(sp)   \n"
      "sw a7,  60(sp)   \n"

      // Check mcause
      "csrr t0, mcause  \n"
      "li t1, 0x80000007\n"  // Machine timer interrupt
      "bne t0, t1, 1f   \n"

      // Timer interrupt: disable by setting mtimecmp to max
      "li t0, 0x02004000\n"   // MTIMECMP_LO address
      "li t1, -1         \n"  // 0xFFFFFFFF
      "sw t1, 0(t0)     \n"   // mtimecmp_lo = 0xFFFFFFFF
      "sw t1, 4(t0)     \n"   // mtimecmp_hi = 0xFFFFFFFF

      // Set timer_fired = 1
      "la t0, timer_fired\n"
      "li t1, 1          \n"
      "sw t1, 0(t0)      \n"
      "j 2f              \n"

      // Wrong cause: set timer_fired = 2
      "1:                \n"
      "la t0, timer_fired\n"
      "li t1, 2          \n"
      "sw t1, 0(t0)      \n"

      // Restore and return
      "2:                \n"
      "lw ra,  0(sp)    \n"
      "lw t0,  4(sp)    \n"
      "lw t1,  8(sp)    \n"
      "lw t2,  12(sp)   \n"
      "lw t3,  16(sp)   \n"
      "lw t4,  20(sp)   \n"
      "lw t5,  24(sp)   \n"
      "lw t6,  28(sp)   \n"
      "lw a0,  32(sp)   \n"
      "lw a1,  36(sp)   \n"
      "lw a2,  40(sp)   \n"
      "lw a3,  44(sp)   \n"
      "lw a4,  48(sp)   \n"
      "lw a5,  52(sp)   \n"
      "lw a6,  56(sp)   \n"
      "lw a7,  60(sp)   \n"
      "addi sp, sp, 64  \n"
      "mret             \n");
}

}  // extern "C"

int main() {
  // 1. Set mtvec to our handler
  asm volatile("csrw mtvec, %0" ::"r"((uint32_t)(&isr_wrapper)));

  // 2. Enable mie.MTIE (bit 7)
  asm volatile("csrs mie, %0" ::"r"(1u << 7));

  // 3. Read current mtime and set mtimecmp = mtime + 100
  uint32_t mtime_lo  = MTIME_LO;
  uint32_t mtime_hi  = MTIME_HI;
  uint32_t target_lo = mtime_lo + 100;
  uint32_t target_hi = mtime_hi;
  if (target_lo < mtime_lo) {
    target_hi += 1;  // handle carry
  }
  // 3-step write to avoid spurious interrupts (RISC-V spec)
  MTIMECMP_LO = 0xFFFFFFFF;
  MTIMECMP_HI = target_hi;
  MTIMECMP_LO = target_lo;

  // 4. Enable mstatus.MIE (bit 3) — this arms the interrupt
  asm volatile("csrs mstatus, %0" ::"r"(1u << 3));

  // 5. Spin-wait for the ISR to set timer_fired
  for (volatile int i = 0; i < 10000; i = i + 1) {
    if (timer_fired)
      break;
  }

  return !(timer_fired == 1);
}
