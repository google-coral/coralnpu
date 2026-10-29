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
constexpr size_t lut_size = 30000;
// Double sized so we can check trailing regions are not read/written.
constexpr size_t buf_size = 256;
}  // namespace

size_t vl __attribute__((section(".data"))) = 16;
// Indices are always unsigned.
RvvSeededIndex<uint32_t, buf_size, uint8_t> index_buf __attribute__((section(".data")));
// These instructions don't differentiate signed/unsigned so we only need to
// test one. The types come from intrinsic level.
RvvSeededInput<uint8_t, lut_size> in_buf __attribute__((section(".data")));
uint8_t out_buf[buf_size] __attribute__((section(".data")));

extern "C" {
// Unordered, segment 2
RVV_SUBTEST(vluxseg2ei32_v_u8mf4x2) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vluxseg2ei32_v_u8mf4x2(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x2_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x2_u8mf4(data, 1), vl);
}

RVV_SUBTEST(vluxseg2ei32_v_u8mf2x2) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vluxseg2ei32_v_u8mf2x2(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x2_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x2_u8mf2(data, 1), vl);
}

RVV_SUBTEST(vluxseg2ei32_v_u8m1x2) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vluxseg2ei32_v_u8m1x2(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x2_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x2_u8m1(data, 1), vl);
}

RVV_SUBTEST(vluxseg2ei32_v_u8m2x2) {
  auto indices = __riscv_vle32_v_u32m8(index_buf, vl);
  auto data = __riscv_vluxseg2ei32_v_u8m2x2(in_buf, indices, vl);
  __riscv_vse8_v_u8m2(out_buf, __riscv_vget_v_u8m2x2_u8m2(data, 0), vl);
  __riscv_vse8_v_u8m2(out_buf + vl, __riscv_vget_v_u8m2x2_u8m2(data, 1), vl);
}

// // Unordered, segment 3
RVV_SUBTEST(vluxseg3ei32_v_u8mf4x3) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vluxseg3ei32_v_u8mf4x3(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x3_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x3_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x3_u8mf4(data, 2),
                       vl);
}

RVV_SUBTEST(vluxseg3ei32_v_u8mf2x3) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vluxseg3ei32_v_u8mf2x3(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x3_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x3_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x3_u8mf2(data, 2),
                       vl);
}

RVV_SUBTEST(vluxseg3ei32_v_u8m1x3) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vluxseg3ei32_v_u8m1x3(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x3_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x3_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x3_u8m1(data, 2),
                      vl);
}

RVV_SUBTEST(vluxseg3ei32_v_u8m2x3) {
  auto indices = __riscv_vle32_v_u32m8(index_buf, vl);
  auto data = __riscv_vluxseg3ei32_v_u8m2x3(in_buf, indices, vl);
  __riscv_vse8_v_u8m2(out_buf, __riscv_vget_v_u8m2x3_u8m2(data, 0), vl);
  __riscv_vse8_v_u8m2(out_buf + vl, __riscv_vget_v_u8m2x3_u8m2(data, 1), vl);
  __riscv_vse8_v_u8m2(out_buf + vl * 2, __riscv_vget_v_u8m2x3_u8m2(data, 2),
                      vl);
}

// Unordered, segment 4
RVV_SUBTEST(vluxseg4ei32_v_u8mf4x4) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vluxseg4ei32_v_u8mf4x4(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x4_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x4_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x4_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x4_u8mf4(data, 3),
                       vl);
}

RVV_SUBTEST(vluxseg4ei32_v_u8mf2x4) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vluxseg4ei32_v_u8mf2x4(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x4_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x4_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x4_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x4_u8mf2(data, 3),
                       vl);
}

RVV_SUBTEST(vluxseg4ei32_v_u8m1x4) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vluxseg4ei32_v_u8m1x4(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x4_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x4_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x4_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x4_u8m1(data, 3),
                      vl);
}

RVV_SUBTEST(vluxseg4ei32_v_u8m2x4) {
  auto indices = __riscv_vle32_v_u32m8(index_buf, vl);
  auto data = __riscv_vluxseg4ei32_v_u8m2x4(in_buf, indices, vl);
  __riscv_vse8_v_u8m2(out_buf, __riscv_vget_v_u8m2x4_u8m2(data, 0), vl);
  __riscv_vse8_v_u8m2(out_buf + vl, __riscv_vget_v_u8m2x4_u8m2(data, 1), vl);
  __riscv_vse8_v_u8m2(out_buf + vl * 2, __riscv_vget_v_u8m2x4_u8m2(data, 2),
                      vl);
  __riscv_vse8_v_u8m2(out_buf + vl * 3, __riscv_vget_v_u8m2x4_u8m2(data, 3),
                      vl);
}

// Unordered, segment 5
RVV_SUBTEST(vluxseg5ei32_v_u8mf4x5) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vluxseg5ei32_v_u8mf4x5(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x5_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x5_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x5_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x5_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x5_u8mf4(data, 4),
                       vl);
}

RVV_SUBTEST(vluxseg5ei32_v_u8mf2x5) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vluxseg5ei32_v_u8mf2x5(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x5_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x5_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x5_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x5_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x5_u8mf2(data, 4),
                       vl);
}

RVV_SUBTEST(vluxseg5ei32_v_u8m1x5) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vluxseg5ei32_v_u8m1x5(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x5_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x5_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x5_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x5_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x5_u8m1(data, 4),
                      vl);
}

// Unordered, segment 6
RVV_SUBTEST(vluxseg6ei32_v_u8mf4x6) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vluxseg6ei32_v_u8mf4x6(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x6_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x6_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x6_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x6_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x6_u8mf4(data, 4),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 5, __riscv_vget_v_u8mf4x6_u8mf4(data, 5),
                       vl);
}

RVV_SUBTEST(vluxseg6ei32_v_u8mf2x6) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vluxseg6ei32_v_u8mf2x6(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x6_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x6_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x6_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x6_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x6_u8mf2(data, 4),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 5, __riscv_vget_v_u8mf2x6_u8mf2(data, 5),
                       vl);
}

RVV_SUBTEST(vluxseg6ei32_v_u8m1x6) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vluxseg6ei32_v_u8m1x6(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x6_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x6_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x6_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x6_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x6_u8m1(data, 4),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 5, __riscv_vget_v_u8m1x6_u8m1(data, 5),
                      vl);
}

// Unordered, segment 7
RVV_SUBTEST(vluxseg7ei32_v_u8mf4x7) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vluxseg7ei32_v_u8mf4x7(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x7_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x7_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x7_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x7_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x7_u8mf4(data, 4),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 5, __riscv_vget_v_u8mf4x7_u8mf4(data, 5),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 6, __riscv_vget_v_u8mf4x7_u8mf4(data, 6),
                       vl);
}

RVV_SUBTEST(vluxseg7ei32_v_u8mf2x7) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vluxseg7ei32_v_u8mf2x7(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x7_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x7_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x7_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x7_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x7_u8mf2(data, 4),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 5, __riscv_vget_v_u8mf2x7_u8mf2(data, 5),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 6, __riscv_vget_v_u8mf2x7_u8mf2(data, 6),
                       vl);
}

RVV_SUBTEST(vluxseg7ei32_v_u8m1x7) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vluxseg7ei32_v_u8m1x7(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x7_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x7_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x7_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x7_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x7_u8m1(data, 4),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 5, __riscv_vget_v_u8m1x7_u8m1(data, 5),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 6, __riscv_vget_v_u8m1x7_u8m1(data, 6),
                      vl);
}

// Unordered, segment 8
RVV_SUBTEST(vluxseg8ei32_v_u8mf4x8) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vluxseg8ei32_v_u8mf4x8(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x8_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x8_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x8_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x8_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x8_u8mf4(data, 4),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 5, __riscv_vget_v_u8mf4x8_u8mf4(data, 5),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 6, __riscv_vget_v_u8mf4x8_u8mf4(data, 6),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 7, __riscv_vget_v_u8mf4x8_u8mf4(data, 7),
                       vl);
}

RVV_SUBTEST(vluxseg8ei32_v_u8mf2x8) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vluxseg8ei32_v_u8mf2x8(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x8_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x8_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x8_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x8_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x8_u8mf2(data, 4),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 5, __riscv_vget_v_u8mf2x8_u8mf2(data, 5),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 6, __riscv_vget_v_u8mf2x8_u8mf2(data, 6),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 7, __riscv_vget_v_u8mf2x8_u8mf2(data, 7),
                       vl);
}

RVV_SUBTEST(vluxseg8ei32_v_u8m1x8) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vluxseg8ei32_v_u8m1x8(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x8_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x8_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x8_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x8_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x8_u8m1(data, 4),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 5, __riscv_vget_v_u8m1x8_u8m1(data, 5),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 6, __riscv_vget_v_u8m1x8_u8m1(data, 6),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 7, __riscv_vget_v_u8m1x8_u8m1(data, 7),
                      vl);
}

// Ordered, segment 2
RVV_SUBTEST(vloxseg2ei32_v_u8mf4x2) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vloxseg2ei32_v_u8mf4x2(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x2_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x2_u8mf4(data, 1), vl);
}

RVV_SUBTEST(vloxseg2ei32_v_u8mf2x2) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vloxseg2ei32_v_u8mf2x2(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x2_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x2_u8mf2(data, 1), vl);
}

RVV_SUBTEST(vloxseg2ei32_v_u8m1x2) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vloxseg2ei32_v_u8m1x2(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x2_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x2_u8m1(data, 1), vl);
}

RVV_SUBTEST(vloxseg2ei32_v_u8m2x2) {
  auto indices = __riscv_vle32_v_u32m8(index_buf, vl);
  auto data = __riscv_vloxseg2ei32_v_u8m2x2(in_buf, indices, vl);
  __riscv_vse8_v_u8m2(out_buf, __riscv_vget_v_u8m2x2_u8m2(data, 0), vl);
  __riscv_vse8_v_u8m2(out_buf + vl, __riscv_vget_v_u8m2x2_u8m2(data, 1), vl);
}

// // Ordered, segment 3
RVV_SUBTEST(vloxseg3ei32_v_u8mf4x3) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vloxseg3ei32_v_u8mf4x3(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x3_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x3_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x3_u8mf4(data, 2),
                       vl);
}

RVV_SUBTEST(vloxseg3ei32_v_u8mf2x3) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vloxseg3ei32_v_u8mf2x3(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x3_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x3_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x3_u8mf2(data, 2),
                       vl);
}

RVV_SUBTEST(vloxseg3ei32_v_u8m1x3) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vloxseg3ei32_v_u8m1x3(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x3_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x3_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x3_u8m1(data, 2),
                      vl);
}

RVV_SUBTEST(vloxseg3ei32_v_u8m2x3) {
  auto indices = __riscv_vle32_v_u32m8(index_buf, vl);
  auto data = __riscv_vloxseg3ei32_v_u8m2x3(in_buf, indices, vl);
  __riscv_vse8_v_u8m2(out_buf, __riscv_vget_v_u8m2x3_u8m2(data, 0), vl);
  __riscv_vse8_v_u8m2(out_buf + vl, __riscv_vget_v_u8m2x3_u8m2(data, 1), vl);
  __riscv_vse8_v_u8m2(out_buf + vl * 2, __riscv_vget_v_u8m2x3_u8m2(data, 2),
                      vl);
}

// Ordered, segment 4
RVV_SUBTEST(vloxseg4ei32_v_u8mf4x4) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vloxseg4ei32_v_u8mf4x4(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x4_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x4_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x4_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x4_u8mf4(data, 3),
                       vl);
}

RVV_SUBTEST(vloxseg4ei32_v_u8mf2x4) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vloxseg4ei32_v_u8mf2x4(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x4_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x4_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x4_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x4_u8mf2(data, 3),
                       vl);
}

RVV_SUBTEST(vloxseg4ei32_v_u8m1x4) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vloxseg4ei32_v_u8m1x4(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x4_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x4_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x4_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x4_u8m1(data, 3),
                      vl);
}

RVV_SUBTEST(vloxseg4ei32_v_u8m2x4) {
  auto indices = __riscv_vle32_v_u32m8(index_buf, vl);
  auto data = __riscv_vloxseg4ei32_v_u8m2x4(in_buf, indices, vl);
  __riscv_vse8_v_u8m2(out_buf, __riscv_vget_v_u8m2x4_u8m2(data, 0), vl);
  __riscv_vse8_v_u8m2(out_buf + vl, __riscv_vget_v_u8m2x4_u8m2(data, 1), vl);
  __riscv_vse8_v_u8m2(out_buf + vl * 2, __riscv_vget_v_u8m2x4_u8m2(data, 2),
                      vl);
  __riscv_vse8_v_u8m2(out_buf + vl * 3, __riscv_vget_v_u8m2x4_u8m2(data, 3),
                      vl);
}

// Ordered, segment 5
RVV_SUBTEST(vloxseg5ei32_v_u8mf4x5) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vloxseg5ei32_v_u8mf4x5(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x5_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x5_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x5_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x5_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x5_u8mf4(data, 4),
                       vl);
}

RVV_SUBTEST(vloxseg5ei32_v_u8mf2x5) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vloxseg5ei32_v_u8mf2x5(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x5_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x5_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x5_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x5_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x5_u8mf2(data, 4),
                       vl);
}

RVV_SUBTEST(vloxseg5ei32_v_u8m1x5) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vloxseg5ei32_v_u8m1x5(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x5_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x5_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x5_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x5_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x5_u8m1(data, 4),
                      vl);
}

// Ordered, segment 6
RVV_SUBTEST(vloxseg6ei32_v_u8mf4x6) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vloxseg6ei32_v_u8mf4x6(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x6_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x6_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x6_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x6_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x6_u8mf4(data, 4),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 5, __riscv_vget_v_u8mf4x6_u8mf4(data, 5),
                       vl);
}

RVV_SUBTEST(vloxseg6ei32_v_u8mf2x6) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vloxseg6ei32_v_u8mf2x6(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x6_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x6_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x6_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x6_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x6_u8mf2(data, 4),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 5, __riscv_vget_v_u8mf2x6_u8mf2(data, 5),
                       vl);
}

RVV_SUBTEST(vloxseg6ei32_v_u8m1x6) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vloxseg6ei32_v_u8m1x6(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x6_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x6_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x6_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x6_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x6_u8m1(data, 4),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 5, __riscv_vget_v_u8m1x6_u8m1(data, 5),
                      vl);
}

// Ordered, segment 7
RVV_SUBTEST(vloxseg7ei32_v_u8mf4x7) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vloxseg7ei32_v_u8mf4x7(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x7_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x7_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x7_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x7_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x7_u8mf4(data, 4),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 5, __riscv_vget_v_u8mf4x7_u8mf4(data, 5),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 6, __riscv_vget_v_u8mf4x7_u8mf4(data, 6),
                       vl);
}

RVV_SUBTEST(vloxseg7ei32_v_u8mf2x7) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vloxseg7ei32_v_u8mf2x7(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x7_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x7_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x7_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x7_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x7_u8mf2(data, 4),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 5, __riscv_vget_v_u8mf2x7_u8mf2(data, 5),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 6, __riscv_vget_v_u8mf2x7_u8mf2(data, 6),
                       vl);
}

RVV_SUBTEST(vloxseg7ei32_v_u8m1x7) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vloxseg7ei32_v_u8m1x7(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x7_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x7_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x7_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x7_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x7_u8m1(data, 4),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 5, __riscv_vget_v_u8m1x7_u8m1(data, 5),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 6, __riscv_vget_v_u8m1x7_u8m1(data, 6),
                      vl);
}

// Ordered, segment 8
RVV_SUBTEST(vloxseg8ei32_v_u8mf4x8) {
  auto indices = __riscv_vle32_v_u32m1(index_buf, vl);
  auto data = __riscv_vloxseg8ei32_v_u8mf4x8(in_buf, indices, vl);
  __riscv_vse8_v_u8mf4(out_buf, __riscv_vget_v_u8mf4x8_u8mf4(data, 0), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl, __riscv_vget_v_u8mf4x8_u8mf4(data, 1), vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 2, __riscv_vget_v_u8mf4x8_u8mf4(data, 2),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 3, __riscv_vget_v_u8mf4x8_u8mf4(data, 3),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 4, __riscv_vget_v_u8mf4x8_u8mf4(data, 4),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 5, __riscv_vget_v_u8mf4x8_u8mf4(data, 5),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 6, __riscv_vget_v_u8mf4x8_u8mf4(data, 6),
                       vl);
  __riscv_vse8_v_u8mf4(out_buf + vl * 7, __riscv_vget_v_u8mf4x8_u8mf4(data, 7),
                       vl);
}

RVV_SUBTEST(vloxseg8ei32_v_u8mf2x8) {
  auto indices = __riscv_vle32_v_u32m2(index_buf, vl);
  auto data = __riscv_vloxseg8ei32_v_u8mf2x8(in_buf, indices, vl);
  __riscv_vse8_v_u8mf2(out_buf, __riscv_vget_v_u8mf2x8_u8mf2(data, 0), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl, __riscv_vget_v_u8mf2x8_u8mf2(data, 1), vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 2, __riscv_vget_v_u8mf2x8_u8mf2(data, 2),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 3, __riscv_vget_v_u8mf2x8_u8mf2(data, 3),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 4, __riscv_vget_v_u8mf2x8_u8mf2(data, 4),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 5, __riscv_vget_v_u8mf2x8_u8mf2(data, 5),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 6, __riscv_vget_v_u8mf2x8_u8mf2(data, 6),
                       vl);
  __riscv_vse8_v_u8mf2(out_buf + vl * 7, __riscv_vget_v_u8mf2x8_u8mf2(data, 7),
                       vl);
}

RVV_SUBTEST(vloxseg8ei32_v_u8m1x8) {
  auto indices = __riscv_vle32_v_u32m4(index_buf, vl);
  auto data = __riscv_vloxseg8ei32_v_u8m1x8(in_buf, indices, vl);
  __riscv_vse8_v_u8m1(out_buf, __riscv_vget_v_u8m1x8_u8m1(data, 0), vl);
  __riscv_vse8_v_u8m1(out_buf + vl, __riscv_vget_v_u8m1x8_u8m1(data, 1), vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 2, __riscv_vget_v_u8m1x8_u8m1(data, 2),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 3, __riscv_vget_v_u8m1x8_u8m1(data, 3),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 4, __riscv_vget_v_u8m1x8_u8m1(data, 4),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 5, __riscv_vget_v_u8m1x8_u8m1(data, 5),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 6, __riscv_vget_v_u8m1x8_u8m1(data, 6),
                      vl);
  __riscv_vse8_v_u8m1(out_buf + vl * 7, __riscv_vget_v_u8m1x8_u8m1(data, 7),
                      vl);
}
}

rvv_test_func_t impl __attribute__((section(".data"))) = nullptr;

int main(int argc, char** argv) {
  rvv_run_subtests(impl, out_buf);
  return 0;
}
