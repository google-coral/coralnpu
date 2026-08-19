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

// Max sizes for Gemma 3 270M tests: 4 heads * 256 seq_len * 640 dim = 655360
constexpr size_t kTotalElements = 4 * 256 * 640;

float q_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
float k_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
float v_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain, aligned(16)));
float o_buf[kTotalElements] __attribute__((section(".ddr_data"), used, retain, aligned(16)));

extern "C" {
uint32_t active_num_heads __attribute__((section(".data"), used, retain))    = 4;
uint32_t active_num_kv_heads __attribute__((section(".data"), used, retain)) = 1;
uint32_t active_seq_len __attribute__((section(".data"), used, retain))      = 256;
uint32_t active_q_seq_len __attribute__((section(".data"), used, retain))    = 1;
uint32_t active_kv_seq_len __attribute__((section(".data"), used, retain))   = 256;
uint32_t active_dim __attribute__((section(".data"), used, retain))          = 256;

uint32_t cycle_count __attribute__((section(".data"), used, retain)) = 0;
}

extern "C" void FlashAttentionRVV(size_t q_heads, size_t kv_heads, size_t q_seq_len,
                                  size_t kv_seq_len, size_t dim, const float *Q, const float *K,
                                  const float *V, float *O);

int main(int argc, char **argv) {
  uint32_t start_cycles = mcycle_read();

  FlashAttentionRVV(active_num_heads, active_num_kv_heads, active_q_seq_len, active_kv_seq_len,
                    active_dim, q_buf, k_buf, v_buf, o_buf);

  uint32_t end_cycles = mcycle_read();
  cycle_count         = end_cycles - start_cycles;

  return 0;
}