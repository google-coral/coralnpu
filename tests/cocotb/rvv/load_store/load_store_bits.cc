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

#include <riscv_vector.h>
#include <stdint.h>

#include "tests/cocotb/rvv/load_store/rvv_lsu_test_utils.h"

namespace {
constexpr size_t buf_size = 16;
}

size_t vl __attribute__((section(".data"))) = buf_size;
RvvSeededInput<uint8_t, buf_size> in_buf __attribute__((section(".data")));
uint8_t out_buf[buf_size] __attribute__((section(".data")));

extern "C" {
RVV_SUBTEST(vlm_vsm_v_b1) {
  auto data = __riscv_vlm_v_b1(in_buf, vl);
  __riscv_vsm_v_b1(out_buf, data, vl);
}

RVV_SUBTEST(vlm_vsm_v_b2) {
  auto data = __riscv_vlm_v_b2(in_buf, vl);
  __riscv_vsm_v_b2(out_buf, data, vl);
}

RVV_SUBTEST(vlm_vsm_v_b4) {
  auto data = __riscv_vlm_v_b4(in_buf, vl);
  __riscv_vsm_v_b4(out_buf, data, vl);
}

RVV_SUBTEST(vlm_vsm_v_b8) {
  auto data = __riscv_vlm_v_b8(in_buf, vl);
  __riscv_vsm_v_b8(out_buf, data, vl);
}

RVV_SUBTEST(vlm_vsm_v_b16) {
  auto data = __riscv_vlm_v_b16(in_buf, vl);
  __riscv_vsm_v_b16(out_buf, data, vl);
}

RVV_SUBTEST(vlm_vsm_v_b32) {
  auto data = __riscv_vlm_v_b32(in_buf, vl);
  __riscv_vsm_v_b32(out_buf, data, vl);
}
}

rvv_test_func_t impl __attribute__((section(".data"))) = nullptr;

int main(int argc, char** argv) {
  rvv_run_subtests(impl, out_buf);
  return 0;
}
