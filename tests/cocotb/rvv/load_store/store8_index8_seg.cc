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
constexpr size_t scatter_count = 128;
// Double sized so we can check trailing regions are not written.
constexpr size_t buf_size = 512;
}  // namespace

size_t vl __attribute__((section(".data"))) = 16;
// Indices are always unsigned.
RvvSeededIndex<uint8_t, scatter_count, uint8_t> index_buf __attribute__((section(".data")));
// These instructions don't differentiate signed/unsigned so we only need to
// test one. The types come from intrinsic level.
RvvSeededInput<uint8_t, scatter_count> in_buf __attribute__((section(".data")));
uint8_t out_buf[buf_size] __attribute__((section(".data")));

extern "C" {
// Unordered, segment 2
RVV_SUBTEST(vsuxseg2ei8_v_u8mf4x2) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x2(__riscv_vle8_v_u8mf4(in_buf, vl),
                                        __riscv_vle8_v_u8mf4(in_buf + vl, vl));
  __riscv_vsuxseg2ei8_v_u8mf4x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg2ei8_v_u8mf2x2) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x2(__riscv_vle8_v_u8mf2(in_buf, vl),
                                        __riscv_vle8_v_u8mf2(in_buf + vl, vl));
  __riscv_vsuxseg2ei8_v_u8mf2x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg2ei8_v_u8m1x2) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x2(__riscv_vle8_v_u8m1(in_buf, vl),
                                       __riscv_vle8_v_u8m1(in_buf + vl, vl));
  __riscv_vsuxseg2ei8_v_u8m1x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg2ei8_v_u8m2x2) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m2x2(__riscv_vle8_v_u8m2(in_buf, vl),
                                       __riscv_vle8_v_u8m2(in_buf + vl, vl));
  __riscv_vsuxseg2ei8_v_u8m2x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg2ei8_v_u8m4x2) {
  auto indices = __riscv_vle8_v_u8m4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m4x2(__riscv_vle8_v_u8m4(in_buf, vl),
                                       __riscv_vle8_v_u8m4(in_buf + vl, vl));
  __riscv_vsuxseg2ei8_v_u8m4x2(out_buf, indices, data, vl);
}

// Unordered, segment 3
RVV_SUBTEST(vsuxseg3ei8_v_u8mf4x3) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x3(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl));
  __riscv_vsuxseg3ei8_v_u8mf4x3(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg3ei8_v_u8mf2x3) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x3(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl));
  __riscv_vsuxseg3ei8_v_u8mf2x3(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg3ei8_v_u8m1x3) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x3(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl));
  __riscv_vsuxseg3ei8_v_u8m1x3(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg3ei8_v_u8m2x3) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m2x3(
      __riscv_vle8_v_u8m2(in_buf, vl), __riscv_vle8_v_u8m2(in_buf + vl, vl),
      __riscv_vle8_v_u8m2(in_buf + vl * 2, vl));
  __riscv_vsuxseg3ei8_v_u8m2x3(out_buf, indices, data, vl);
}

// Unordered, segment 4
RVV_SUBTEST(vsuxseg4ei8_v_u8mf4x4) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x4(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl));
  __riscv_vsuxseg4ei8_v_u8mf4x4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg4ei8_v_u8mf2x4) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x4(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl));
  __riscv_vsuxseg4ei8_v_u8mf2x4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg4ei8_v_u8m1x4) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x4(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl));
  __riscv_vsuxseg4ei8_v_u8m1x4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg4ei8_v_u8m2x4) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m2x4(
      __riscv_vle8_v_u8m2(in_buf, vl), __riscv_vle8_v_u8m2(in_buf + vl, vl),
      __riscv_vle8_v_u8m2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m2(in_buf + vl * 3, vl));
  __riscv_vsuxseg4ei8_v_u8m2x4(out_buf, indices, data, vl);
}

// Unordered, segment 5
RVV_SUBTEST(vsuxseg5ei8_v_u8mf4x5) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x5(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl));
  __riscv_vsuxseg5ei8_v_u8mf4x5(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg5ei8_v_u8mf2x5) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x5(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl));
  __riscv_vsuxseg5ei8_v_u8mf2x5(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg5ei8_v_u8m1x5) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x5(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl));
  __riscv_vsuxseg5ei8_v_u8m1x5(out_buf, indices, data, vl);
}

// Unordered, segment 6
RVV_SUBTEST(vsuxseg6ei8_v_u8mf4x6) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x6(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 5, vl));
  __riscv_vsuxseg6ei8_v_u8mf4x6(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg6ei8_v_u8mf2x6) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x6(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 5, vl));
  __riscv_vsuxseg6ei8_v_u8mf2x6(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg6ei8_v_u8m1x6) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x6(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 5, vl));
  __riscv_vsuxseg6ei8_v_u8m1x6(out_buf, indices, data, vl);
}

// Unordered, segment 7
RVV_SUBTEST(vsuxseg7ei8_v_u8mf4x7) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x7(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 6, vl));
  __riscv_vsuxseg7ei8_v_u8mf4x7(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg7ei8_v_u8mf2x7) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x7(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 6, vl));
  __riscv_vsuxseg7ei8_v_u8mf2x7(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg7ei8_v_u8m1x7) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x7(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 6, vl));
  __riscv_vsuxseg7ei8_v_u8m1x7(out_buf, indices, data, vl);
}

// Unordered, segment 8
RVV_SUBTEST(vsuxseg8ei8_v_u8mf4x8) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x8(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 6, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 7, vl));
  __riscv_vsuxseg8ei8_v_u8mf4x8(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg8ei8_v_u8mf2x8) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x8(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 6, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 7, vl));
  __riscv_vsuxseg8ei8_v_u8mf2x8(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsuxseg8ei8_v_u8m1x8) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x8(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 6, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 7, vl));
  __riscv_vsuxseg8ei8_v_u8m1x8(out_buf, indices, data, vl);
}

// Ordered, segment 2
RVV_SUBTEST(vsoxseg2ei8_v_u8mf4x2) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x2(__riscv_vle8_v_u8mf4(in_buf, vl),
                                        __riscv_vle8_v_u8mf4(in_buf + vl, vl));
  __riscv_vsoxseg2ei8_v_u8mf4x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg2ei8_v_u8mf2x2) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x2(__riscv_vle8_v_u8mf2(in_buf, vl),
                                        __riscv_vle8_v_u8mf2(in_buf + vl, vl));
  __riscv_vsoxseg2ei8_v_u8mf2x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg2ei8_v_u8m1x2) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x2(__riscv_vle8_v_u8m1(in_buf, vl),
                                       __riscv_vle8_v_u8m1(in_buf + vl, vl));
  __riscv_vsoxseg2ei8_v_u8m1x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg2ei8_v_u8m2x2) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m2x2(__riscv_vle8_v_u8m2(in_buf, vl),
                                       __riscv_vle8_v_u8m2(in_buf + vl, vl));
  __riscv_vsoxseg2ei8_v_u8m2x2(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg2ei8_v_u8m4x2) {
  auto indices = __riscv_vle8_v_u8m4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m4x2(__riscv_vle8_v_u8m4(in_buf, vl),
                                       __riscv_vle8_v_u8m4(in_buf + vl, vl));
  __riscv_vsoxseg2ei8_v_u8m4x2(out_buf, indices, data, vl);
}

// Ordered, segment 3
RVV_SUBTEST(vsoxseg3ei8_v_u8mf4x3) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x3(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl));
  __riscv_vsoxseg3ei8_v_u8mf4x3(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg3ei8_v_u8mf2x3) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x3(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl));
  __riscv_vsoxseg3ei8_v_u8mf2x3(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg3ei8_v_u8m1x3) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x3(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl));
  __riscv_vsoxseg3ei8_v_u8m1x3(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg3ei8_v_u8m2x3) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m2x3(
      __riscv_vle8_v_u8m2(in_buf, vl), __riscv_vle8_v_u8m2(in_buf + vl, vl),
      __riscv_vle8_v_u8m2(in_buf + vl * 2, vl));
  __riscv_vsoxseg3ei8_v_u8m2x3(out_buf, indices, data, vl);
}

// Ordered, segment 4
RVV_SUBTEST(vsoxseg4ei8_v_u8mf4x4) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x4(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl));
  __riscv_vsoxseg4ei8_v_u8mf4x4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg4ei8_v_u8mf2x4) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x4(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl));
  __riscv_vsoxseg4ei8_v_u8mf2x4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg4ei8_v_u8m1x4) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x4(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl));
  __riscv_vsoxseg4ei8_v_u8m1x4(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg4ei8_v_u8m2x4) {
  auto indices = __riscv_vle8_v_u8m2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m2x4(
      __riscv_vle8_v_u8m2(in_buf, vl), __riscv_vle8_v_u8m2(in_buf + vl, vl),
      __riscv_vle8_v_u8m2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m2(in_buf + vl * 3, vl));
  __riscv_vsoxseg4ei8_v_u8m2x4(out_buf, indices, data, vl);
}

// Ordered, segment 5
RVV_SUBTEST(vsoxseg5ei8_v_u8mf4x5) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x5(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl));
  __riscv_vsoxseg5ei8_v_u8mf4x5(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg5ei8_v_u8mf2x5) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x5(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl));
  __riscv_vsoxseg5ei8_v_u8mf2x5(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg5ei8_v_u8m1x5) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x5(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl));
  __riscv_vsoxseg5ei8_v_u8m1x5(out_buf, indices, data, vl);
}

// Ordered, segment 6
RVV_SUBTEST(vsoxseg6ei8_v_u8mf4x6) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x6(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 5, vl));
  __riscv_vsoxseg6ei8_v_u8mf4x6(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg6ei8_v_u8mf2x6) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x6(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 5, vl));
  __riscv_vsoxseg6ei8_v_u8mf2x6(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg6ei8_v_u8m1x6) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x6(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 5, vl));
  __riscv_vsoxseg6ei8_v_u8m1x6(out_buf, indices, data, vl);
}

// Ordered, segment 7
RVV_SUBTEST(vsoxseg7ei8_v_u8mf4x7) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x7(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 6, vl));
  __riscv_vsoxseg7ei8_v_u8mf4x7(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg7ei8_v_u8mf2x7) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x7(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 6, vl));
  __riscv_vsoxseg7ei8_v_u8mf2x7(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg7ei8_v_u8m1x7) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x7(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 6, vl));
  __riscv_vsoxseg7ei8_v_u8m1x7(out_buf, indices, data, vl);
}

// Ordered, segment 8
RVV_SUBTEST(vsoxseg8ei8_v_u8mf4x8) {
  auto indices = __riscv_vle8_v_u8mf4(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf4x8(
      __riscv_vle8_v_u8mf4(in_buf, vl), __riscv_vle8_v_u8mf4(in_buf + vl, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 6, vl),
      __riscv_vle8_v_u8mf4(in_buf + vl * 7, vl));
  __riscv_vsoxseg8ei8_v_u8mf4x8(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg8ei8_v_u8mf2x8) {
  auto indices = __riscv_vle8_v_u8mf2(index_buf, vl);
  auto data = __riscv_vcreate_v_u8mf2x8(
      __riscv_vle8_v_u8mf2(in_buf, vl), __riscv_vle8_v_u8mf2(in_buf + vl, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 6, vl),
      __riscv_vle8_v_u8mf2(in_buf + vl * 7, vl));
  __riscv_vsoxseg8ei8_v_u8mf2x8(out_buf, indices, data, vl);
}

RVV_SUBTEST(vsoxseg8ei8_v_u8m1x8) {
  auto indices = __riscv_vle8_v_u8m1(index_buf, vl);
  auto data = __riscv_vcreate_v_u8m1x8(
      __riscv_vle8_v_u8m1(in_buf, vl), __riscv_vle8_v_u8m1(in_buf + vl, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 2, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 3, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 4, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 5, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 6, vl),
      __riscv_vle8_v_u8m1(in_buf + vl * 7, vl));
  __riscv_vsoxseg8ei8_v_u8m1x8(out_buf, indices, data, vl);
}
}

rvv_test_func_t impl __attribute__((section(".data"))) = nullptr;

int main(int argc, char** argv) {
  rvv_run_subtests(impl, out_buf);
  return 0;
}
