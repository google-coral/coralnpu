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

#define MAX_INPUT_SIZE  16384
#define MAX_WEIGHT_SIZE 4096

extern "C" {
// 与 Gemma Decoder Layer 以及同目录其他算子的 runner 保持一致，将张量放在
// DDR。`.ddr_bss` 只在 DDR 中保留地址空间，不把未初始化的大数组塞进 ELF
// 的可加载数据段；否则 backdoor 装载会尝试一次写入整块零数据。与此同时，
// `.extmem` 与 DDR 的访存延迟不同，独立 RMSNorm cycle
// 不能和完整 Decoder 内部阶段做同条件求和比较。
__bf16 rms_input[MAX_INPUT_SIZE]
    __attribute__((section(".ddr_bss"), used, retain, aligned(16)));
__bf16 rms_weight[MAX_WEIGHT_SIZE]
    __attribute__((section(".ddr_bss"), used, retain, aligned(16)));
__bf16 rms_output[MAX_INPUT_SIZE]
    __attribute__((section(".ddr_bss"), used, retain, aligned(16)));

// Parameters
uint32_t active_seq_len __attribute__((section(".data"), used, retain))     = 1;
uint32_t active_hidden_size __attribute__((section(".data"), used, retain)) = 640;
float active_epsilon __attribute__((section(".data"), used, retain))        = 1e-6f;

uint32_t cycle_count __attribute__((section(".data"), used, retain)) = 0;
}

extern "C" void RmsNormBf16(size_t seq_len, size_t hidden_size, float epsilon, const __bf16 *input,
                            const __bf16 *weight, __bf16 *output);

extern "C" int main() {
  if ((active_seq_len * active_hidden_size) > MAX_INPUT_SIZE ||
      active_hidden_size > MAX_WEIGHT_SIZE) {
    return -1;
  }

  uint32_t start_cycles = mcycle_read();

  RmsNormBf16(active_seq_len, active_hidden_size, active_epsilon, rms_input, rms_weight,
              rms_output);

  uint32_t end_cycles = mcycle_read();
  cycle_count         = end_cycles - start_cycles;

  return 0;
}
