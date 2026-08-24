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

// Tests that whole-register load/store (vl<nf>r.v / vs<nf>r.v) and
// whole-register move (vmv<nr>r.v) instructions execute correctly
// even when the vill bit is set.

#include <riscv_vector.h>
#include <stddef.h>
#include <stdint.h>

namespace {
constexpr size_t kMaxBufSize = 128;  // Up to 8 registers of 16 bytes (VLEN=128)
}

uint32_t faulted     = 0;
uint32_t mcause      = 0;
uint32_t mtval       = 0;
uint32_t test_passed = 0;

uint8_t src_data[kMaxBufSize] __attribute__((section(".data")));
uint8_t dst_data[kMaxBufSize];

extern "C" {
void coralnpu_exception_handler() {
  faulted = 1;
  uint32_t local_mcause;
  asm volatile("csrr %0, mcause" : "=r"(local_mcause));
  mcause = local_mcause;
  uint32_t local_mtval;
  asm volatile("csrr %0, mtval" : "=r"(local_mtval));
  mtval = local_mtval;

  asm volatile(".word 0x08000073");  // mpause (halt)
}
}

int main(int argc, char **argv) {
  const size_t vlenb = __riscv_vlenb();

  // 1. At reset, vill is 1. Test vl1r.v, vmv1r.v, vs1r.v without executing any vset*
  for (size_t i = 0; i < kMaxBufSize; ++i)
    dst_data[i] = 0;
  asm("vl1r.v v0, %[src];"
      "vmv1r.v v1, v0;"
      "vs1r.v v1, %[dst];"
      : [dst] "=m"(*(uint8_t(*)[1 * vlenb]) dst_data)
      : [src] "m"(*(const uint8_t(*)[1 * vlenb]) src_data)
      : "v0", "v1");

  for (size_t i = 0; i < 1 * vlenb; ++i) {
    if (dst_data[i] != src_data[i])
      return 1;
  }

  // 2. Test vl2r.v, vmv2r.v, vs2r.v
  for (size_t i = 0; i < kMaxBufSize; ++i)
    dst_data[i] = 0;
  asm("vl2r.v v2, %[src];"
      "vmv2r.v v4, v2;"
      "vs2r.v v4, %[dst];"
      : [dst] "=m"(*(uint8_t(*)[2 * vlenb]) dst_data)
      : [src] "m"(*(const uint8_t(*)[2 * vlenb]) src_data)
      : "v2", "v3", "v4", "v5");

  for (size_t i = 0; i < 2 * vlenb; ++i) {
    if (dst_data[i] != src_data[i])
      return 1;
  }

  // 3. Test vl4r.v, vmv4r.v, vs4r.v
  for (size_t i = 0; i < kMaxBufSize; ++i)
    dst_data[i] = 0;
  asm("vl4r.v v4, %[src];"
      "vmv4r.v v8, v4;"
      "vs4r.v v8, %[dst];"
      : [dst] "=m"(*(uint8_t(*)[4 * vlenb]) dst_data)
      : [src] "m"(*(const uint8_t(*)[4 * vlenb]) src_data)
      : "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11");

  for (size_t i = 0; i < 4 * vlenb; ++i) {
    if (dst_data[i] != src_data[i])
      return 1;
  }

  // 4. Test vl8r.v, vmv8r.v, vs8r.v
  for (size_t i = 0; i < kMaxBufSize; ++i)
    dst_data[i] = 0;
  asm("vl8r.v v8, %[src];"
      "vmv8r.v v16, v8;"
      "vs8r.v v16, %[dst];"
      : [dst] "=m"(*(uint8_t(*)[8 * vlenb]) dst_data)
      : [src] "m"(*(const uint8_t(*)[8 * vlenb]) src_data)
      : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20",
        "v21", "v22", "v23");

  for (size_t i = 0; i < 8 * vlenb; ++i) {
    if (dst_data[i] != src_data[i])
      return 1;
  }

  // 5. Explicitly set an illegal vtype using vsetvl
  // Reserved LMUL (bits[2:0]=100) sets vill=1.
  uint32_t illegal_vtype = 4;  // LMUL reserved
  asm volatile("vsetvl zero, zero, %[illegal_vtype]" ::[illegal_vtype] "r"(illegal_vtype)
               : "vl", "vtype");

  for (size_t i = 0; i < kMaxBufSize; ++i)
    dst_data[i] = 0;
  asm("vl1r.v v0, %[src];"
      "vmv1r.v v1, v0;"
      "vs1r.v v1, %[dst];"
      : [dst] "=m"(*(uint8_t(*)[1 * vlenb]) dst_data)
      : [src] "m"(*(const uint8_t(*)[1 * vlenb]) src_data)
      : "v0", "v1");

  for (size_t i = 0; i < 1 * vlenb; ++i) {
    if (dst_data[i] != src_data[i])
      return 1;
  }

  test_passed = 1;
  return 0;
}
