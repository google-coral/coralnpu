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

uint32_t vfwcvt_res[8] __attribute__((section(".data")))  = {0};
uint32_t vfncvt_res[8] __attribute__((section(".data")))  = {0};
uint32_t vfwmacc_res[8] __attribute__((section(".data"))) = {0};

int main() {
  // Test vfwcvtbf16.s.f.vv v8, v1
  // Source: v1 (BF16), Dest: v8 (FP32)
  // 1.5f (0x3fc0), 2.5f (0x4020), -1.0f (0xbf80), 0.0f (0x0000)
  uint32_t src_bf16[4] = {0x40203fc0, 0x0000bf80, 0, 0};

  asm volatile(
      "vsetvli t0, %[vl], e16, m1, ta, ma;"
      "vle16.v v1, (%[src]);"
      "vfwcvtbf16.f.f.v v8, v1;"
      "vse32.v v8, (%[dst]);"
      :
      : [src] "r"(src_bf16), [dst] "r"(vfwcvt_res), [vl] "r"(4)
      : "t0", "v1", "v8", "memory");

  // Test vfncvtbf16.s.f.vv v1, v8
  // Source: v8 (FP32), Dest: v1 (BF16)
  asm volatile(
      "vsetvli t0, %[vl], e16, m1, ta, ma;"
      "vle32.v v8, (%[src]);"
      "vfncvtbf16.f.f.w v1, v8;"
      "vse16.v v1, (%[dst]);"
      :
      : [src] "r"(vfwcvt_res), [dst] "r"(vfncvt_res), [vl] "r"(4)
      : "t0", "v1", "v8", "memory");

  // Test vfwmaccbf16.v.v.v v8, v1, v2
  // v8 = v8 + v1 * v2
  uint32_t src2_bf16[4] = {0x40004000, 0x40004000, 0, 0};
  asm volatile(
      "vsetvli t0, %[vl], e16, m1, ta, ma;"
      "vle16.v v1, (%[src1]);"
      "vle16.v v2, (%[src2]);"
      "vle32.v v8, (%[acc]);"
      "vfwmaccbf16.vv v8, v1, v2;"
      "vse32.v v8, (%[dst]);"
      :
      : [src1] "r"(src_bf16), [src2] "r"(src2_bf16), [acc] "r"(vfwcvt_res), [dst] "r"(vfwmacc_res),
        [vl] "r"(4)
      : "t0", "v1", "v2", "v8", "memory");

  return 0;
}
