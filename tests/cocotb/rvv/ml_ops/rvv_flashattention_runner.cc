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

#include <stddef.h>
#include <stdint.h>

#include "sw/utils/utils.h"

// (64 KB)
constexpr size_t kHeads = 4;
constexpr size_t kSeqLen = 32;
constexpr size_t kDim = 32;
constexpr size_t kTotalElements = kHeads * kSeqLen * kDim;

float q_buf[kTotalElements] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));
float k_buf[kTotalElements] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));
float v_buf[kTotalElements] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));
float o_buf[kTotalElements] __attribute__((section(".data"), used, retain))
__attribute__((aligned(16)));

extern "C" {
volatile uint32_t csr_cycle_count = 0;
}

extern "C" void FlashAttentionRVV(const float* Q, const float* K,
                                  const float* V, float* O, size_t num_heads,
                                  size_t s_len, size_t dim);

int main(int argc, char** argv) {
  uint32_t mcontext0_write_value = 1;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  cycle_counter_reset();
  uint64_t start_cycles = mcycle_read();

  FlashAttentionRVV(q_buf, k_buf, v_buf, o_buf, kHeads, kSeqLen, kDim);

  uint64_t end_cycles = mcycle_read();
  csr_cycle_count = static_cast<uint32_t>(end_cycles - start_cycles);

  mcontext0_write_value = 0;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  return 0;
}
