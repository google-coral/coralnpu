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

#define MAX_TEST_CASES 64

struct TestCase {
  uint32_t input;
  uint32_t rounding_mode;  // 0-4 for static modes, 7 for dynamic
  uint32_t output;
  uint32_t fflags;
};

struct FmvTestCase {
  uint32_t input;
  uint32_t fmv_h_x_output;
  uint32_t fmv_h_x_fflags;
  uint32_t fmv_x_h_output;
  uint32_t fmv_x_h_fflags;
  uint32_t fmv_roundtrip_output;
  uint32_t fmv_roundtrip_fflags;
};

TestCase fcvt_s_bf16_cases[MAX_TEST_CASES] __attribute__((section(".data")));
TestCase fcvt_bf16_s_cases[MAX_TEST_CASES] __attribute__((section(".data")));
FmvTestCase fmv_cases[MAX_TEST_CASES] __attribute__((section(".data")));

uint32_t num_fcvt_s_bf16_cases __attribute__((section(".data"))) = 0;
uint32_t num_fcvt_bf16_s_cases __attribute__((section(".data"))) = 0;
uint32_t num_fmv_cases __attribute__((section(".data")))         = 0;

void run_fcvt_s_bf16() {
  for (uint32_t i = 0; i < num_fcvt_s_bf16_cases; i++) {
    uint32_t in = fcvt_s_bf16_cases[i].input;
    uint32_t out;
    uint32_t flags;

    asm volatile(
        // Clear fflags
        "csrw fflags, zero;"
        "fmv.w.x fa1, %[in];"
        "fcvt.s.bf16 fa0, fa1;"
        "fmv.x.w %[out], fa0;"
        "csrr %[flags], fflags;"
        : [out] "=r"(out), [flags] "=r"(flags)
        : [in] "r"(in)
        : "fa0", "fa1");

    fcvt_s_bf16_cases[i].output = out;
    fcvt_s_bf16_cases[i].fflags = flags;
  }
}

void run_fcvt_bf16_s() {
  for (uint32_t i = 0; i < num_fcvt_bf16_s_cases; i++) {
    uint32_t in = fcvt_bf16_s_cases[i].input;
    uint32_t rm = fcvt_bf16_s_cases[i].rounding_mode;
    uint32_t out;
    uint32_t flags;

    asm volatile(
        // Clear fflags
        "csrw fflags, zero;"
        "csrw frm, %[rm];"
        "fmv.w.x fa1, %[in];"
        "fcvt.bf16.s fa0, fa1, dyn;"
        "fmv.x.w %[out], fa0;"
        "csrr %[flags], fflags;"
        : [out] "=r"(out), [flags] "=r"(flags)
        : [in] "r"(in), [rm] "r"(rm)
        : "fa0", "fa1");

    fcvt_bf16_s_cases[i].output = out;
    fcvt_bf16_s_cases[i].fflags = flags;
  }
}

void run_fmv() {
  for (uint32_t i = 0; i < num_fmv_cases; i++) {
    asm volatile(
        // Clear fflags
        "csrw fflags, zero;"
        "fmv.h.x fa0, %[in];"
        "fmv.x.w %[out], fa0;"
        "csrr %[flags], fflags;"
        : [out] "=r"(fmv_cases[i].fmv_h_x_output), [flags] "=r"(fmv_cases[i].fmv_h_x_fflags)
        : [in] "r"(fmv_cases[i].input)
        : "fa0");

    asm volatile(
        // Clear fflags
        "csrw fflags, zero;"
        "fmv.w.x fa0, %[in];"
        "fmv.x.h %[out], fa0;"
        "csrr %[flags], fflags;"
        : [out] "=r"(fmv_cases[i].fmv_x_h_output), [flags] "=r"(fmv_cases[i].fmv_x_h_fflags)
        : [in] "r"(fmv_cases[i].input)
        : "fa0");

    asm volatile(
        // Clear fflags
        "csrw fflags, zero;"
        "fmv.h.x fa0, %[in];"
        "fmv.x.h %[out], fa0;"
        "csrr %[flags], fflags;"
        : [out] "=r"(fmv_cases[i].fmv_roundtrip_output), [flags] "=r"(
                                                             fmv_cases[i].fmv_roundtrip_fflags)
        : [in] "r"(fmv_cases[i].input)
        : "fa0");
  }
}

int main() {
  run_fcvt_s_bf16();
  run_fcvt_bf16_s();
  run_fmv();
  return 0;
}
