// Copyright 2025 Google LLC
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

#include <bit>
#include <cstdint>

uint32_t faulted __attribute__((section(".data"))) = 0;
uint32_t mcause __attribute__((section(".data")))  = 0;
uint32_t mtval __attribute__((section(".data")))   = 0;
uint32_t frm __attribute__((section(".data")))     = 0;
uint32_t result __attribute__((section(".data")))  = 0;

// Fault handler to log fault
extern "C" {
void coralnpu_exception_handler() {
  faulted = 1;
  uint32_t local_mcause;
  asm volatile("csrr %0, mcause" : "=r"(local_mcause));
  mcause = local_mcause;
  uint32_t local_mtval;
  asm volatile("csrr %0, mtval" : "=r"(local_mtval));
  mtval = local_mtval;

  asm volatile("ebreak");
  while (1) {
  }
}
}

int main() {
  faulted   = 0;
  mcause    = 0;
  float a   = 2.0f;
  float pi  = 3.14159265359f;
  float sgn = 0.0f;
  float sq  = 0.0f;
  float res = 0.0f;

  // Set FRM CSR from the global variable.
  // Non-FRM instructions (fsgnj.s) remain valid regardless of frm, whereas
  // dynamic-rounding instructions (fsqrt.s, fmul.s) must raise mcause = 2 when
  // frm holds a reserved value (5..7).
  asm volatile(
      "csrw frm, %[frm];"
      "fsgnj.s %[sgn], %[a], %[pi];"
      "fsqrt.s %[sq], %[sgn], dyn;"
      "fmul.s %[res], %[sq], %[pi], dyn;"
      : [sgn] "=&f"(sgn), [sq] "=&f"(sq), [res] "=f"(res)
      : [frm] "r"(frm), [a] "f"(a), [pi] "f"(pi));

  // Store result
  result = std::bit_cast<std::uint32_t>(res);

  return 0;
}
