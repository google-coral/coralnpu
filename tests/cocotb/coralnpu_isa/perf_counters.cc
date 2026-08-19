/*
 * Copyright 2025 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>

inline uint64_t mcycle_read(void) {
  uint32_t cycle_low    = 0;
  uint32_t cycle_high   = 0;
  uint32_t cycle_high_2 = 0;
  asm volatile(
      "1:"
      "  csrr %0, mcycleh;"  // Read `mcycleh`.
      "  csrr %1, mcycle;"   // Read `mcycle`.
      "  csrr %2, mcycleh;"  // Read `mcycleh` again.
      "  bne  %0, %2, 1b;"
      : "=r"(cycle_high), "=r"(cycle_low), "=r"(cycle_high_2)
      :);
  return static_cast<uint64_t>(cycle_high) << 32 | cycle_low;
}

inline uint64_t minstret_read(void) {
  uint32_t instret_low    = 0;
  uint32_t instret_high   = 0;
  uint32_t instret_high_2 = 0;
  asm volatile(
      "1:"
      "  csrr %0, minstreth;"  // Read `minstreth`.
      "  csrr %1, minstret;"   // Read `minstret`.
      "  csrr %2, minstreth;"
      "bne %0, %2, 1b;"
      : "=r"(instret_high), "=r"(instret_low), "=r"(instret_high_2)
      :);
  return static_cast<uint64_t>(instret_high) << 32 | instret_low;
}

int main(void) {
  // Set the cycle counter to 0x1fffffff0.
  asm volatile(
      " \
        csrwi mcycleh, 1; \
        li a0, 0xfffffff0; \
        csrrw a0, mcycle, a0;"
      : /* no outputs*/
      : /* no inputs */
      : /* clobbers */ "a0");
  uint64_t cycle = mcycle_read();
  for (int i = 0; i < 16; ++i) {
    asm volatile("nop");
  }
  uint64_t cycle2 = mcycle_read();
  uint32_t cycle_lo, cycle_hi, cycle2_lo, cycle2_hi;
  cycle_lo  = cycle & 0xFFFFFFFF;
  cycle2_lo = cycle2 & 0xFFFFFFFF;
  cycle_hi  = cycle >> 32;
  cycle2_hi = cycle2 >> 32;
  if (cycle2_hi == cycle_hi) {
#if !defined(LINK_TCM)
    printf("mcycleh did not increment\r\n");
#endif
    exit(-1);
  }
  if (cycle2_lo > cycle_lo) {
#if !defined(LINK_TCM)
    printf("mcycle did not wrap\r\n");
#endif
    exit(-1);
  }

  asm volatile(
      " \
        csrwi minstreth, 1; \
        li a0, 0xfffffff0; \
        csrrw a0, minstret, a0; "
      :
      :
      : "a0");
  uint64_t instret = minstret_read();
#pragma GCC unroll 16
  for (int i = 0; i < 16; ++i) {
    asm volatile("nop");
  }
  uint64_t instret2 = minstret_read();
  uint32_t instret_lo, instret_hi, instret2_lo, instret2_hi;
  instret_lo  = instret & 0xFFFFFFFF;
  instret2_lo = instret2 & 0xFFFFFFFF;
  instret_hi  = instret >> 32;
  instret2_hi = instret2 >> 32;
  if (instret2_hi == instret_hi) {
#if !defined(LINK_TCM)
    printf("minstreth did not increment\r\n");
#endif
    exit(-1);
  }
  if (instret2_lo > instret_lo) {
#if !defined(LINK_TCM)
    printf("minstret did not wrap\r\n");
#endif
    exit(-1);
  }

  return 0;
}
