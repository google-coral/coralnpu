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

// Max sizes for Gemma 3 270M tests: 4 heads * 512 seq_len * 256 dim = 524288
constexpr size_t kTotalElements = 4 * 512 * 256;

float q_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain))
__attribute__((aligned(16)));
float k_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain))
__attribute__((aligned(16)));
float v_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain))
__attribute__((aligned(16)));
float o_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain))
__attribute__((aligned(16)));

extern "C" {
volatile uint32_t active_num_heads    = 4;
volatile uint32_t active_num_kv_heads = 4;
volatile uint32_t active_seq_len      = 256;
volatile uint32_t active_q_seq_len    = 256;
volatile uint32_t active_kv_seq_len   = 256;
volatile uint32_t active_dim          = 256;

volatile uint32_t csr_cycle_count = 0;
}

extern "C" void FlashAttentionRVV(const float *Q, const float *K, const float *V, float *O,
                                  size_t q_heads, size_t kv_heads, size_t q_seq_len,
                                  size_t kv_seq_len, size_t dim);

int main(int argc, char** argv) {
  uint32_t mcontext0_write_value = 1;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  cycle_counter_reset();
  uint64_t start_cycles = mcycle_read();

  size_t q_len  = active_q_seq_len != 0 ? active_q_seq_len : active_seq_len;
  size_t kv_len = active_kv_seq_len != 0 ? active_kv_seq_len : active_seq_len;

  FlashAttentionRVV(q_buf, k_buf, v_buf, o_buf, active_num_heads, active_num_kv_heads, q_len,
                    kv_len, active_dim);

  uint64_t end_cycles = mcycle_read();
  csr_cycle_count = static_cast<uint32_t>(end_cycles - start_cycles);

  mcontext0_write_value = 0;
  asm volatile("csrw 0x7C0, %0" : : "r"(mcontext0_write_value));

  return 0;
}