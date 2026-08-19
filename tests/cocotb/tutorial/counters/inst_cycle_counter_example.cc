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

#include "sw/utils/utils.h"
uint32_t cycle_count_lo;
uint32_t cycle_count_hi;
uint32_t inst_count_lo;
uint32_t inst_count_hi;

int main(void) {
  cycle_counter_reset();
  uint64_t cycle_start = mcycle_read();
  for (int i = 0; i <= 100; i++) {
    asm volatile("nop");
  }
  uint64_t cycle_end   = mcycle_read();
  uint64_t cycle_count = cycle_end - cycle_start;

  cycle_count_lo = cycle_count & 0xFFFFFFFF;
  cycle_count_hi = cycle_count >> 32;

  instrut_counter_reset();
  uint64_t inst_count_start = minstret_read();
  for (int i = 0; i <= 100; i++) {
    asm volatile("nop");
  }

  uint64_t inst_count_end = minstret_read();
  uint64_t inst_count     = inst_count_end - inst_count_start;
  inst_count_lo           = inst_count & 0xFFFFFFFF;
  inst_count_hi           = inst_count >> 32;
  return 0;
}