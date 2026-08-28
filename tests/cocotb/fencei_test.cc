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

#define EXTBSS __attribute__((section(".extbss")))

volatile uint32_t code_area[16] EXTBSS;

uint32_t result1    = 0;
uint32_t result2    = 0;
uint32_t result_smc = 0;

typedef uint32_t (*func_t)();
typedef uint32_t (*func_smc_t)(volatile uint32_t *target_ptr);

int main() {
  // --------------------------------------------------------------------------
  // Test 1: In-flight self-modifying code in DDR (.extbss).
  // The code running in DDR modifies an instruction immediately ahead of PC,
  // which is already prefetched into the fetch buffer.
  // FENCE.I is required to flush the prefetch buffer and re-fetch from DDR.
  // --------------------------------------------------------------------------
  code_area[0] = 0x00050593;  // mv   a1, a0 (a1 = target pointer &code_area[5])
  code_area[1] = 0x00a00513;  // addi a0, zero, 10
  code_area[2] = 0x0085a283;  // lw   t0, 8(a1) (loads 0x01450513 from code_area[7])
  code_area[3] = 0x0055a023;  // sw   t0, 0(a1) (stores to code_area[5])
  code_area[4] = 0x0000100f;  // fence.i
  code_area[5] = 0x06450513;  // addi a0, a0, 100 (target to be overwritten)
  code_area[6] = 0x00008067;  // ret
  code_area[7] = 0x01450513;  // data: addi a0, a0, 20

  asm volatile("fence.i");
  func_smc_t fn_smc = reinterpret_cast<func_smc_t>(code_area);
  result_smc        = fn_smc(&code_area[5]);

  // --------------------------------------------------------------------------
  // Test 2: Function-level dynamic patching in DDR (.extbss).
  // --------------------------------------------------------------------------
  func_t fn = reinterpret_cast<func_t>(code_area);

  // 1. Initial routine: return 42
  code_area[0] = 0x02a00513;  // addi a0, zero, 42
  code_area[1] = 0x00008067;  // ret
  asm volatile("fence.i");
  result1 = fn();

  // 2. Overwrite routine: return 99
  code_area[0] = 0x06300513;  // addi a0, zero, 99
  code_area[1] = 0x00008067;  // ret
  asm volatile("fence.i");
  result2 = fn();

  return 0;
}
