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

#include <riscv_vector.h>

#include <cstdint>

// fflags bit masks (per RISC-V specification):
// Bit 0: NX (Inexact)       = 0x01
// Bit 1: UF (Underflow)     = 0x02
// Bit 2: OF (Overflow)      = 0x04
// Bit 3: DZ (DivideByZero)  = 0x08
// Bit 4: NV (InvalidOp)     = 0x10

uint32_t fflags_initial __attribute__((section(".data")))    = 0xDEADBEEF;
uint32_t fflags_divzero __attribute__((section(".data")))    = 0xDEADBEEF;
uint32_t fcsr_divzero __attribute__((section(".data")))      = 0xDEADBEEF;
uint32_t fflags_invalid __attribute__((section(".data")))    = 0xDEADBEEF;
uint32_t fflags_overflow __attribute__((section(".data")))   = 0xDEADBEEF;
uint32_t fflags_underflow __attribute__((section(".data")))  = 0xDEADBEEF;
uint32_t fnmsub_result __attribute__((section(".data")))     = 0xDEADBEEF;
uint32_t fflags_cleared __attribute__((section(".data")))    = 0xDEADBEEF;
uint32_t fflags_hazard[16] __attribute__((section(".data"))) = {0};

float nx_num[4] __attribute__((section(".data"))) = {1.0f, 1.0f, 1.0f, 1.0f};
float nx_den[4] __attribute__((section(".data"))) = {3.0f, 3.0f, 3.0f, 3.0f};
float nx_res[4] __attribute__((section(".data"))) = {0.0f};

float div_num[16] __attribute__((section(".data"))) = {
    1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f};
float div_den[16] __attribute__((section(".data"))) = {
    0.0f, 1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f, 1.0f};
float div_res[16] __attribute__((section(".data"))) = {0.0f};

float sqrt_in[4] __attribute__((section(".data")))  = {-1.0f, 4.0f, 9.0f, 16.0f};
float sqrt_res[4] __attribute__((section(".data"))) = {0.0f};

float of_a[16] __attribute__((section(".data"))) = {
    3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f,
    3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f};
float of_b[16] __attribute__((section(".data"))) = {
    3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f,
    3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f, 3.0e38f};
float of_res[16] __attribute__((section(".data"))) = {0.0f};

#define TEST_CONCURRENT_CSRW(idx, nops_str)                      \
  do {                                                           \
    asm volatile("csrw fflags, %[nv];" : : [nv] "r"(0x10));      \
    asm volatile("vfdiv.vv v12, v4, v8;" nops_str                \
                 "csrw fflags, %[uf];"                           \
                 "vse32.v v12, (%[res]);"                        \
                 :                                               \
                 : [res] "r"(nx_res), [uf] "r"(0x02)             \
                 : "v12", "memory");                             \
    asm volatile("csrr %0, fflags;" : "=r"(fflags_hazard[idx])); \
  } while (0)

int main() {
  uint32_t vl = 4;

  // 1. Initial state: clear fflags and verify it reads 0.
  asm volatile("csrw fflags, zero;");
  asm volatile("csrr %0, fflags;" : "=r"(fflags_initial));

  // 2. Divide by zero: 1.0 / 0.0 -> DZ (0x08).
  asm volatile(
      "vsetvli zero, %[vl], e32, m1, ta, ma;"
      "vle32.v v0, (%[num]);"
      "vle32.v v1, (%[den]);"
      "vfdiv.vv v2, v0, v1;"
      "vse32.v v2, (%[res]);"
      :
      : [vl] "r"(vl), [num] "r"(div_num), [den] "r"(div_den), [res] "r"(div_res)
      : "v0", "v1", "v2", "memory");
  asm volatile("csrr %0, fflags;" : "=r"(fflags_divzero));
  asm volatile("csrr %0, fcsr;" : "=r"(fcsr_divzero));

  // 3. Invalid operation: sqrt(-1.0) -> NV (0x10).
  // Clear fflags first so we can verify NV specifically.
  asm volatile("csrw fflags, zero;");
  asm volatile(
      "vsetvli zero, %[vl], e32, m1, ta, ma;"
      "vle32.v v0, (%[in]);"
      "vfsqrt.v v1, v0;"
      "vse32.v v1, (%[res]);"
      :
      : [vl] "r"(vl), [in] "r"(sqrt_in), [res] "r"(sqrt_res)
      : "v0", "v1", "memory");
  asm volatile("csrr %0, fflags;" : "=r"(fflags_invalid));

  // 4. Overflow & Inexact: 1e38 + 1e38 -> OF (0x04) | NX (0x01) = 0x05.
  asm volatile("csrw fflags, zero;");
  asm volatile(
      "vsetvli zero, %[vl], e32, m1, ta, ma;"
      "vle32.v v0, (%[a]);"
      "vle32.v v1, (%[b]);"
      "vfadd.vv v2, v0, v1;"
      "vse32.v v2, (%[res]);"
      :
      : [vl] "r"(vl), [a] "r"(of_a), [b] "r"(of_b), [res] "r"(of_res)
      : "v0", "v1", "v2", "memory");
  asm volatile("csrr %0, fflags;" : "=r"(fflags_overflow));

  // 5. Underflow & Inexact (subnormal FMA):
  // fnmsub.s fs9, ft10, ft11, ft2, rne -> -(ft10 * ft11) + ft2
  // ft10 = 0x31 (+49 * 2^-149)
  // ft11 = 0x80000011 (-17 * 2^-149)
  // ft2  = 0x11 (+17 * 2^-149)
  // Result is 0x11 with Underflow (0x02) and Inexact (0x01) -> fflags = 0x03.
  asm volatile("csrw fflags, zero;");
  asm volatile(
      "fmv.w.x ft10, %[f30];"
      "fmv.w.x ft11, %[f31];"
      "fmv.w.x ft2,  %[f2];"
      "fnmsub.s fs9, ft10, ft11, ft2, rne;"
      "fmv.x.w  %[res], fs9;"
      : [res] "=r"(fnmsub_result)
      : [f30] "r"(0x31), [f31] "r"(0x80000011), [f2] "r"(0x11)
      : "ft10", "ft11", "ft2", "fs9", "memory");
  asm volatile("csrr %0, fflags;" : "=r"(fflags_underflow));

  // 6. Clear fflags and confirm it can be cleared again.
  asm volatile("csrw fflags, zero;");
  asm volatile("csrr %0, fflags;" : "=r"(fflags_cleared));

  // 7. Test concurrent CSR write to fflags while vector operation is retiring with exception flags.
  // Preload operands into v4 and v8 (e32, m1, vl=4)
  asm volatile(
      "vsetvli zero, %[vl4], e32, m1, ta, ma;"
      "vle32.v v4, (%[num]);"
      "vle32.v v8, (%[den]);"
      :
      : [vl4] "r"(4), [num] "r"(nx_num), [den] "r"(nx_den)
      : "v4", "v8", "memory");

  // We sweep delays 0..15 NOPs between vfdiv.vv and csrw fflags, 0x02.
  TEST_CONCURRENT_CSRW(0, "");
  TEST_CONCURRENT_CSRW(1, "nop;");
  TEST_CONCURRENT_CSRW(2, "nop; nop;");
  TEST_CONCURRENT_CSRW(3, "nop; nop; nop;");
  TEST_CONCURRENT_CSRW(4, "nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(5, "nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(6, "nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(7, "nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(8, "nop; nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(9, "nop; nop; nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(10, "nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(11, "nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(12, "nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(13, "nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(14, "nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;");
  TEST_CONCURRENT_CSRW(
      15, "nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;");

  return 0;
}
