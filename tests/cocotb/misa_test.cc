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

struct MisaTestResults {
  uint32_t initial_misa;
  uint32_t write_zero_read;
  uint32_t write_all_ones_read;
  uint32_t write_toggle_v_read;
  uint32_t write_toggle_f_read;
  uint32_t write_toggle_x_read;
  uint32_t write_patterns_read[6];
  uint32_t csrrs_set_all_read;
  uint32_t csrrc_clear_all_read;
  uint32_t faulted;
  uint32_t mcause;
  uint32_t mtval;
};

volatile MisaTestResults results __attribute__((section(".data"))) = {};

extern "C" {
void coralnpu_exception_handler() {
  results.faulted = 1;
  uint32_t local_mcause;
  asm volatile("csrr %0, mcause" : "=r"(local_mcause));
  results.mcause = local_mcause;
  uint32_t local_mtval;
  asm volatile("csrr %0, mtval" : "=r"(local_mtval));
  results.mtval = local_mtval;

  asm volatile("ebreak");
  while (1) {
  }
}
}

static const uint32_t kPatterns[6] = {
    0x55555555, 0xAAAAAAAA, 0x12345678, 0x87654321,
    0xC0000000,  // MXL=3 (reserved)
    0x3C000000,  // Reserved bits [29:26]
};

int main() {
  uint32_t val;

  // 1. Initial read of MISA
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.initial_misa = val;

  // 2. Write all zeros (WARL test: writes must not corrupt legal value)
  asm volatile("csrw misa, %0" : : "r"(0x00000000) : "memory");
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.write_zero_read = val;

  // 3. Write all ones (WARL test: writes must not set unsupported extensions or reserved bits)
  asm volatile("csrw misa, %0" : : "r"(0xFFFFFFFF) : "memory");
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.write_all_ones_read = val;

  // 4. Try explicitly toggling individual extension bits: V (bit 21), F (bit 5), X (bit 23)
  asm volatile("csrw misa, %0" : : "r"(results.initial_misa ^ (1u << 21)) : "memory");
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.write_toggle_v_read = val;

  asm volatile("csrw misa, %0" : : "r"(results.initial_misa ^ (1u << 5)) : "memory");
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.write_toggle_f_read = val;

  asm volatile("csrw misa, %0" : : "r"(results.initial_misa ^ (1u << 23)) : "memory");
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.write_toggle_x_read = val;

  // 5. Test arbitrary bit patterns
  for (int i = 0; i < 6; ++i) {
    uint32_t pat = kPatterns[i];
    asm volatile("csrw misa, %0" : : "r"(pat) : "memory");
    asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
    results.write_patterns_read[i] = val;
  }

  // 6. CSRRS (CSR set bits) with all 1s mask
  uint32_t csrrs_old;
  asm volatile("csrrs %0, misa, %1" : "=r"(csrrs_old) : "r"(0xFFFFFFFF) : "memory");
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.csrrs_set_all_read = val;

  // 7. CSRRC (CSR clear bits) with all 1s mask
  uint32_t csrrc_old;
  asm volatile("csrrc %0, misa, %1" : "=r"(csrrc_old) : "r"(0xFFFFFFFF) : "memory");
  asm volatile("csrr %0, misa" : "=r"(val) : : "memory");
  results.csrrc_clear_all_read = val;

  return 0;
}
