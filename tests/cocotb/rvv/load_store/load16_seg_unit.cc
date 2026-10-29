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
// Double sized so we can check trailing regions are not read/written.
constexpr size_t buf_size = 128;
}  // namespace

size_t vl __attribute__((section(".data"))) = 8;
// These instructions don't differentiate signed/unsigned so we only need to
// test one. The types come from intrinsic level.
RvvSeededInput<uint16_t, buf_size> in_buf __attribute__((section(".data")));
uint16_t out_buf[buf_size] __attribute__((section(".data")));

extern "C" {
// Segment 2
RVV_SUBTEST(vlseg2e16_v_u16mf2x2) {
  auto data = __riscv_vlseg2e16_v_u16mf2x2(in_buf, vl);
  __riscv_vse16_v_u16mf2(out_buf, __riscv_vget_v_u16mf2x2_u16mf2(data, 0), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl, __riscv_vget_v_u16mf2x2_u16mf2(data, 1),
                         vl);
}

RVV_SUBTEST(vlseg2e16_v_u16m1x2) {
  auto data = __riscv_vlseg2e16_v_u16m1x2(in_buf, vl);
  __riscv_vse16_v_u16m1(out_buf, __riscv_vget_v_u16m1x2_u16m1(data, 0), vl);
  __riscv_vse16_v_u16m1(out_buf + vl, __riscv_vget_v_u16m1x2_u16m1(data, 1),
                        vl);
}

RVV_SUBTEST(vlseg2e16_v_u16m2x2) {
  auto data = __riscv_vlseg2e16_v_u16m2x2(in_buf, vl);
  __riscv_vse16_v_u16m2(out_buf, __riscv_vget_v_u16m2x2_u16m2(data, 0), vl);
  __riscv_vse16_v_u16m2(out_buf + vl, __riscv_vget_v_u16m2x2_u16m2(data, 1),
                        vl);
}

RVV_SUBTEST(vlseg2e16_v_u16m4x2) {
  auto data = __riscv_vlseg2e16_v_u16m4x2(in_buf, vl);
  __riscv_vse16_v_u16m4(out_buf, __riscv_vget_v_u16m4x2_u16m4(data, 0), vl);
  __riscv_vse16_v_u16m4(out_buf + vl, __riscv_vget_v_u16m4x2_u16m4(data, 1),
                        vl);
}

// Segment 3
RVV_SUBTEST(vlseg3e16_v_u16mf2x3) {
  auto data = __riscv_vlseg3e16_v_u16mf2x3(in_buf, vl);
  __riscv_vse16_v_u16mf2(out_buf, __riscv_vget_v_u16mf2x3_u16mf2(data, 0), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl, __riscv_vget_v_u16mf2x3_u16mf2(data, 1),
                         vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 2,
                         __riscv_vget_v_u16mf2x3_u16mf2(data, 2), vl);
}

RVV_SUBTEST(vlseg3e16_v_u16m1x3) {
  auto data = __riscv_vlseg3e16_v_u16m1x3(in_buf, vl);
  __riscv_vse16_v_u16m1(out_buf, __riscv_vget_v_u16m1x3_u16m1(data, 0), vl);
  __riscv_vse16_v_u16m1(out_buf + vl, __riscv_vget_v_u16m1x3_u16m1(data, 1),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 2, __riscv_vget_v_u16m1x3_u16m1(data, 2),
                        vl);
}

RVV_SUBTEST(vlseg3e16_v_u16m2x3) {
  auto data = __riscv_vlseg3e16_v_u16m2x3(in_buf, vl);
  __riscv_vse16_v_u16m2(out_buf, __riscv_vget_v_u16m2x3_u16m2(data, 0), vl);
  __riscv_vse16_v_u16m2(out_buf + vl, __riscv_vget_v_u16m2x3_u16m2(data, 1),
                        vl);
  __riscv_vse16_v_u16m2(out_buf + vl * 2, __riscv_vget_v_u16m2x3_u16m2(data, 2),
                        vl);
}

// Segment 4
RVV_SUBTEST(vlseg4e16_v_u16mf2x4) {
  auto data = __riscv_vlseg4e16_v_u16mf2x4(in_buf, vl);
  __riscv_vse16_v_u16mf2(out_buf, __riscv_vget_v_u16mf2x4_u16mf2(data, 0), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl, __riscv_vget_v_u16mf2x4_u16mf2(data, 1),
                         vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 2,
                         __riscv_vget_v_u16mf2x4_u16mf2(data, 2), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 3,
                         __riscv_vget_v_u16mf2x4_u16mf2(data, 3), vl);
}

RVV_SUBTEST(vlseg4e16_v_u16m1x4) {
  auto data = __riscv_vlseg4e16_v_u16m1x4(in_buf, vl);
  __riscv_vse16_v_u16m1(out_buf, __riscv_vget_v_u16m1x4_u16m1(data, 0), vl);
  __riscv_vse16_v_u16m1(out_buf + vl, __riscv_vget_v_u16m1x4_u16m1(data, 1),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 2, __riscv_vget_v_u16m1x4_u16m1(data, 2),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 3, __riscv_vget_v_u16m1x4_u16m1(data, 3),
                        vl);
}

RVV_SUBTEST(vlseg4e16_v_u16m2x4) {
  auto data = __riscv_vlseg4e16_v_u16m2x4(in_buf, vl);
  __riscv_vse16_v_u16m2(out_buf, __riscv_vget_v_u16m2x4_u16m2(data, 0), vl);
  __riscv_vse16_v_u16m2(out_buf + vl, __riscv_vget_v_u16m2x4_u16m2(data, 1),
                        vl);
  __riscv_vse16_v_u16m2(out_buf + vl * 2, __riscv_vget_v_u16m2x4_u16m2(data, 2),
                        vl);
  __riscv_vse16_v_u16m2(out_buf + vl * 3, __riscv_vget_v_u16m2x4_u16m2(data, 3),
                        vl);
}

// Segment 5
RVV_SUBTEST(vlseg5e16_v_u16mf2x5) {
  auto data = __riscv_vlseg5e16_v_u16mf2x5(in_buf, vl);
  __riscv_vse16_v_u16mf2(out_buf, __riscv_vget_v_u16mf2x5_u16mf2(data, 0), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl, __riscv_vget_v_u16mf2x5_u16mf2(data, 1),
                         vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 2,
                         __riscv_vget_v_u16mf2x5_u16mf2(data, 2), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 3,
                         __riscv_vget_v_u16mf2x5_u16mf2(data, 3), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 4,
                         __riscv_vget_v_u16mf2x5_u16mf2(data, 4), vl);
}

RVV_SUBTEST(vlseg5e16_v_u16m1x5) {
  auto data = __riscv_vlseg5e16_v_u16m1x5(in_buf, vl);
  __riscv_vse16_v_u16m1(out_buf, __riscv_vget_v_u16m1x5_u16m1(data, 0), vl);
  __riscv_vse16_v_u16m1(out_buf + vl, __riscv_vget_v_u16m1x5_u16m1(data, 1),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 2, __riscv_vget_v_u16m1x5_u16m1(data, 2),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 3, __riscv_vget_v_u16m1x5_u16m1(data, 3),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 4, __riscv_vget_v_u16m1x5_u16m1(data, 4),
                        vl);
}

// Segment 6
RVV_SUBTEST(vlseg6e16_v_u16mf2x6) {
  auto data = __riscv_vlseg6e16_v_u16mf2x6(in_buf, vl);
  __riscv_vse16_v_u16mf2(out_buf, __riscv_vget_v_u16mf2x6_u16mf2(data, 0), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl, __riscv_vget_v_u16mf2x6_u16mf2(data, 1),
                         vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 2,
                         __riscv_vget_v_u16mf2x6_u16mf2(data, 2), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 3,
                         __riscv_vget_v_u16mf2x6_u16mf2(data, 3), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 4,
                         __riscv_vget_v_u16mf2x6_u16mf2(data, 4), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 5,
                         __riscv_vget_v_u16mf2x6_u16mf2(data, 5), vl);
}

RVV_SUBTEST(vlseg6e16_v_u16m1x6) {
  auto data = __riscv_vlseg6e16_v_u16m1x6(in_buf, vl);
  __riscv_vse16_v_u16m1(out_buf, __riscv_vget_v_u16m1x6_u16m1(data, 0), vl);
  __riscv_vse16_v_u16m1(out_buf + vl, __riscv_vget_v_u16m1x6_u16m1(data, 1),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 2, __riscv_vget_v_u16m1x6_u16m1(data, 2),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 3, __riscv_vget_v_u16m1x6_u16m1(data, 3),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 4, __riscv_vget_v_u16m1x6_u16m1(data, 4),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 5, __riscv_vget_v_u16m1x6_u16m1(data, 5),
                        vl);
}

// Segment 7
RVV_SUBTEST(vlseg7e16_v_u16mf2x7) {
  auto data = __riscv_vlseg7e16_v_u16mf2x7(in_buf, vl);
  __riscv_vse16_v_u16mf2(out_buf, __riscv_vget_v_u16mf2x7_u16mf2(data, 0), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl, __riscv_vget_v_u16mf2x7_u16mf2(data, 1),
                         vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 2,
                         __riscv_vget_v_u16mf2x7_u16mf2(data, 2), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 3,
                         __riscv_vget_v_u16mf2x7_u16mf2(data, 3), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 4,
                         __riscv_vget_v_u16mf2x7_u16mf2(data, 4), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 5,
                         __riscv_vget_v_u16mf2x7_u16mf2(data, 5), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 6,
                         __riscv_vget_v_u16mf2x7_u16mf2(data, 6), vl);
}

RVV_SUBTEST(vlseg7e16_v_u16m1x7) {
  auto data = __riscv_vlseg7e16_v_u16m1x7(in_buf, vl);
  __riscv_vse16_v_u16m1(out_buf, __riscv_vget_v_u16m1x7_u16m1(data, 0), vl);
  __riscv_vse16_v_u16m1(out_buf + vl, __riscv_vget_v_u16m1x7_u16m1(data, 1),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 2, __riscv_vget_v_u16m1x7_u16m1(data, 2),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 3, __riscv_vget_v_u16m1x7_u16m1(data, 3),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 4, __riscv_vget_v_u16m1x7_u16m1(data, 4),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 5, __riscv_vget_v_u16m1x7_u16m1(data, 5),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 6, __riscv_vget_v_u16m1x7_u16m1(data, 6),
                        vl);
}

// Segment 8
RVV_SUBTEST(vlseg8e16_v_u16mf2x8) {
  auto data = __riscv_vlseg8e16_v_u16mf2x8(in_buf, vl);
  __riscv_vse16_v_u16mf2(out_buf, __riscv_vget_v_u16mf2x8_u16mf2(data, 0), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl, __riscv_vget_v_u16mf2x8_u16mf2(data, 1),
                         vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 2,
                         __riscv_vget_v_u16mf2x8_u16mf2(data, 2), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 3,
                         __riscv_vget_v_u16mf2x8_u16mf2(data, 3), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 4,
                         __riscv_vget_v_u16mf2x8_u16mf2(data, 4), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 5,
                         __riscv_vget_v_u16mf2x8_u16mf2(data, 5), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 6,
                         __riscv_vget_v_u16mf2x8_u16mf2(data, 6), vl);
  __riscv_vse16_v_u16mf2(out_buf + vl * 7,
                         __riscv_vget_v_u16mf2x8_u16mf2(data, 7), vl);
}

RVV_SUBTEST(vlseg8e16_v_u16m1x8) {
  auto data = __riscv_vlseg8e16_v_u16m1x8(in_buf, vl);
  __riscv_vse16_v_u16m1(out_buf, __riscv_vget_v_u16m1x8_u16m1(data, 0), vl);
  __riscv_vse16_v_u16m1(out_buf + vl, __riscv_vget_v_u16m1x8_u16m1(data, 1),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 2, __riscv_vget_v_u16m1x8_u16m1(data, 2),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 3, __riscv_vget_v_u16m1x8_u16m1(data, 3),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 4, __riscv_vget_v_u16m1x8_u16m1(data, 4),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 5, __riscv_vget_v_u16m1x8_u16m1(data, 5),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 6, __riscv_vget_v_u16m1x8_u16m1(data, 6),
                        vl);
  __riscv_vse16_v_u16m1(out_buf + vl * 7, __riscv_vget_v_u16m1x8_u16m1(data, 7),
                        vl);
}
}

rvv_test_func_t impl __attribute__((section(".data"))) = nullptr;

int main(int argc, char** argv) {
  rvv_run_subtests(impl, out_buf);
  return 0;
}
