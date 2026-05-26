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

// This test is used for baseline vector power analysis.
// It runs a continuous loop of NOPs to measure the baseline power consumption
// of the core when not executing meaningful instructions, providing a reference
// for active power measurements.

#include <cstdint>

void run_nops() {
  uint32_t mcontext0_write_value = 1;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  // Loop 100 times, each time running 512 nops
  for (int i = 0; i < 100; ++i) {
    asm volatile(
      ".rept 512 \n\t"
      "nop \n\t"
      ".endr"
    );
  }

  mcontext0_write_value = 0;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));
}

int main() {
  run_nops();
  return 0;
}
