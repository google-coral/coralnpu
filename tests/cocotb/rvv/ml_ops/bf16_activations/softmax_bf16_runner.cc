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

extern "C" bool SoftmaxBf16(const uint16_t *in, uint16_t *out, int n, float *scratch,
                            int scratch_len);
extern "C" bool SoftmaxBf16_Online(const uint16_t *in, uint16_t *out, int n, float *scratch,
                                   int scratch_len);
extern "C" bool SoftmaxBf16_SmallRow(const uint16_t *in, uint16_t *out, size_t n, float *scratch,
                                     size_t scratch_len);

#define MAX_N  8192
#define EXTMEM __attribute__((section(".extmem"))) __attribute__((aligned(16)))

extern "C" {
uint16_t softmax_in[MAX_N] EXTMEM;
uint16_t softmax_out[MAX_N] EXTMEM;
uint32_t active_n EXTMEM           = 256;
uint32_t active_scratch_len EXTMEM = MAX_N;
uint32_t kernel_id EXTMEM          = 0;  // 0: 3-pass, 1: online, 2: small-row
uint32_t alias EXTMEM              = 0;  // 1: test in-place (in == out)
uint32_t softmax_ok EXTMEM         = 0;  // kernel bool return
uint32_t repeat EXTMEM             = 0;
uint32_t cycle_count EXTMEM        = 0;
}

// fp32 scratch for the 3-pass kernel
static float softmax_scratch[MAX_N] __attribute__((section(".noinit")));

int main() {
  if (active_n > MAX_N)
    return -1;
  const int n            = static_cast<int>(active_n);
  const size_t slen      = static_cast<size_t>(active_scratch_len);
  const uint16_t *in_ptr = softmax_in;
  if (alias != 0) {
    for (int i = 0; i < n; ++i)
      softmax_out[i] = softmax_in[i];
    in_ptr = softmax_out;
  }

  uint32_t start;
  asm volatile("csrr %0, mcycle" : "=r"(start) : : "memory");

  bool ok = true;
  for (uint32_t r = 0; r < repeat; ++r) {
    switch (kernel_id) {
      case 1:
        ok = SoftmaxBf16_Online(in_ptr, softmax_out, n, softmax_scratch, slen);
        break;
      case 2:
        ok = SoftmaxBf16_SmallRow(in_ptr, softmax_out, n, softmax_scratch, slen);
        break;
      default:
        ok = SoftmaxBf16(in_ptr, softmax_out, n, softmax_scratch, slen);
        break;
    }
  }
  softmax_ok = ok ? 1u : 0u;

  uint32_t end;
  asm volatile("csrr %0, mcycle" : "=r"(end) : : "memory");
  cycle_count = end - start;
  return 0;
}