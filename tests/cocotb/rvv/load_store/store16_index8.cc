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
constexpr size_t scatter_count = 64;
constexpr size_t buf_size = 256;
}  // namespace

size_t vl __attribute__((section(".data"))) = 8;
// Indices are always unsigned.
RvvSeededIndex<uint8_t, scatter_count, uint16_t> index_buf __attribute__((section(".data")));
// These instructions don't differentiate signed/unsigned so we only need to
// test one. The types come from intrinsic level.
RvvSeededInput<uint16_t, scatter_count> in_buf __attribute__((section(".data")));
uint16_t out_buf[buf_size] __attribute__((section(".data")));

extern "C" {
// Unordered
RVV_SUBTEST(vsuxei8_v_u16mf2) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vle16_v_u16mf2(in_buf, vl);
  __riscv_vsuxei8_v_u16mf2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxei8_v_u16m1) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vle16_v_u16m1(in_buf, vl);
  __riscv_vsuxei8_v_u16m1(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxei8_v_u16m2) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vle16_v_u16m2(in_buf, vl);
  __riscv_vsuxei8_v_u16m2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxei8_v_u16m4) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vle16_v_u16m4(in_buf, vl);
  __riscv_vsuxei8_v_u16m4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxei8_v_u16m8) {
  auto indices = __riscv_vle8_v_u8m4(index_buf, vl);
  auto data = __riscv_vle16_v_u16m8(in_buf, vl);
  __riscv_vsuxei8_v_u16m8(out_buf, indices, data, vl);
}

// Ordered
RVV_SUBTEST(vsoxei8_v_u16mf2) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vle16_v_u16mf2(in_buf, vl);
  __riscv_vsoxei8_v_u16mf2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxei8_v_u16m1) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vle16_v_u16m1(in_buf, vl);
  __riscv_vsoxei8_v_u16m1(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxei8_v_u16m2) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vle16_v_u16m2(in_buf, vl);
  __riscv_vsoxei8_v_u16m2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxei8_v_u16m4) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vle16_v_u16m4(in_buf, vl);
  __riscv_vsoxei8_v_u16m4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxei8_v_u16m8) {
  auto indices = __riscv_vle8_v_u8m4(index_buf, vl);
  auto data = __riscv_vle16_v_u16m8(in_buf, vl);
  __riscv_vsoxei8_v_u16m8(out_buf, indices, data, vl);
}
}

rvv_test_func_t impl __attribute__((section(".data"))) = nullptr;

int main(int argc, char** argv) {
  rvv_run_subtests(impl, out_buf);
  return 0;
}
