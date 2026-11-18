/*
 * Copyright 2026 Google LLC
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

#include <cstddef>
#include <cstdint>

extern "C" uint8_t __heap_start__[];
extern "C" uint8_t __heap_end__[];

__attribute__((used, retain)) extern const uintptr_t kItcmBase = 0x00000000;
__attribute__((used, retain)) extern const size_t kItcmSize    = 8 * 1024;
__attribute__((used, retain)) extern const uintptr_t kExtBase  = 0x20000000;
__attribute__((used, retain)) extern const size_t kExtSize     = 4 * 1024 * 1024;
// Dense external-memory sweep window. Set to kExtSize (4 MB) to sweep all of
// external memory; this is much slower in simulation.
__attribute__((used, retain)) extern const size_t kExtWindow = 4 * 1024;

extern const uint32_t kPatterns[] = {
    0x55555555u,
    0xAAAAAAAAu,
    0xFFFFFFFFu,
    0x00000000u,
};

volatile uint32_t sweep_errors;
volatile uint32_t itcm_checksum;
volatile uintptr_t dtcm_lo;
volatile uintptr_t dtcm_hi;

__attribute__((noinline)) void WriteAndReadRegion(uintptr_t base, size_t len) {
  for (uint32_t pat : kPatterns) {
    for (uintptr_t a = base; a < base + len; a += 4) {
      *reinterpret_cast<volatile uint32_t *>(a) = pat;
    }
    for (uintptr_t a = base; a < base + len; a += 4) {
      if (*reinterpret_cast<volatile uint32_t *>(a) != pat) {
        sweep_errors = sweep_errors + 1;
      }
    }
  }
}

__attribute__((noinline)) void ReadItcm() {
  uint32_t x = 0;
  for (uintptr_t a = kItcmBase; a < kItcmBase + kItcmSize; a += 4) {
    x ^= *reinterpret_cast<volatile uint32_t *>(a);
  }
  itcm_checksum = x;
}

int main() {
  dtcm_lo = (reinterpret_cast<uintptr_t>(__heap_start__) + 3) & ~uintptr_t{3};
  dtcm_hi = reinterpret_cast<uintptr_t>(__heap_end__) & ~uintptr_t{3};
  WriteAndReadRegion(dtcm_lo, dtcm_hi - dtcm_lo);

  WriteAndReadRegion(kExtBase, kExtWindow);
  for (uintptr_t a = kExtBase; a < kExtBase + kExtSize; a += kExtWindow) {
    WriteAndReadRegion(a, 4);
  }

  ReadItcm();

  asm volatile("fence" ::: "memory");
  return 0;
}
