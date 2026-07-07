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

extern "C" void SigmoidBf16(const uint16_t *in, uint16_t *out, size_t n);
extern "C" void SigmoidBf16_Vfrec7(const uint16_t *in, uint16_t *out, size_t n);
extern "C" void SigmoidBf16_Vfrec7Raw(const uint16_t *in, uint16_t *out, size_t n);

#define MAX_N  8192
#define EXTMEM __attribute__((section(".extmem"))) __attribute__((aligned(16)))

extern "C" {
uint16_t sigmoid_in[MAX_N] EXTMEM;
uint16_t sigmoid_out[MAX_N] EXTMEM;
uint32_t active_n EXTMEM    = 256;
uint32_t kernel_id EXTMEM   = 0;
uint32_t alias EXTMEM       = 0;
uint32_t repeat EXTMEM      = 0;
uint32_t cycle_count EXTMEM = 0;
}

int main() {
  if (active_n > MAX_N)
    return -1;
  const int n = static_cast<int>(active_n);

  const uint16_t *in_ptr = sigmoid_in;
  if (alias != 0) {
    for (int i = 0; i < n; ++i)
      sigmoid_out[i] = sigmoid_in[i];
    in_ptr = sigmoid_out;
  }

  uint32_t start;
  asm volatile("csrr %0, mcycle" : "=r"(start) : : "memory");

  for (uint32_t r = 0; r < repeat; ++r) {
    switch (kernel_id) {
      case 1:
        SigmoidBf16_Vfrec7(in_ptr, sigmoid_out, n);
        break;
      case 2:
        SigmoidBf16_Vfrec7Raw(in_ptr, sigmoid_out, n);
        break;
      default:
        SigmoidBf16(in_ptr, sigmoid_out, n);
        break;
    }
  }

  uint32_t end;
  asm volatile("csrr %0, mcycle" : "=r"(end) : : "memory");
  cycle_count = end - start;
  return 0;
}