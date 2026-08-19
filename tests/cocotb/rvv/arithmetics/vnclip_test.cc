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

namespace {
constexpr size_t buf_size = 64;
constexpr uint32_t vxrm = 2;  // TODO(davidgao): test remaining ones
}  // namespace

size_t vl __attribute__((section(".data"))) = 4;
size_t shift_scalar __attribute__((section(".data"))) = 1;
int32_t buf32[buf_size] __attribute__((section(".data")));
int16_t buf16[buf_size] __attribute__((section(".data")));
int8_t buf8[buf_size] __attribute__((section(".data")));
uint16_t buf_shift16[buf_size] __attribute__((section(".data")));
uint8_t buf_shift8[buf_size] __attribute__((section(".data")));

// vxsat test: stores the vxsat CSR value after a saturating operation.
// Expected: 1 after saturation. Bug: returns 0 because vxsat update is dropped.
uint32_t vxsat_result __attribute__((section(".data"))) = 0xDEADBEEF;

extern "C" {
// 32 to 16, vxv
__attribute__((used, retain)) void vnclip_wv_i16mf2() {
  const auto in_v = __riscv_vle32_v_i32m1(buf32, vl);
  const auto shift = __riscv_vle16_v_u16mf2(buf_shift16, vl);
  const auto out_v = __riscv_vnclip_wv_i16mf2(in_v, shift, vxrm, vl);
  __riscv_vse16_v_i16mf2(buf16, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wv_i16m1() {
  const auto in_v = __riscv_vle32_v_i32m2(buf32, vl);
  const auto shift = __riscv_vle16_v_u16m1(buf_shift16, vl);
  const auto out_v = __riscv_vnclip_wv_i16m1(in_v, shift, vxrm, vl);
  __riscv_vse16_v_i16m1(buf16, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wv_i16m2() {
  const auto in_v = __riscv_vle32_v_i32m4(buf32, vl);
  const auto shift = __riscv_vle16_v_u16m2(buf_shift16, vl);
  const auto out_v = __riscv_vnclip_wv_i16m2(in_v, shift, vxrm, vl);
  __riscv_vse16_v_i16m2(buf16, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wv_i16m4() {
  const auto in_v = __riscv_vle32_v_i32m8(buf32, vl);
  const auto shift = __riscv_vle16_v_u16m4(buf_shift16, vl);
  const auto out_v = __riscv_vnclip_wv_i16m4(in_v, shift, vxrm, vl);
  __riscv_vse16_v_i16m4(buf16, out_v, vl);
}

// 32 to 16, vxs
__attribute__((used, retain)) void vnclip_wx_i16mf2() {
  const auto in_v = __riscv_vle32_v_i32m1(buf32, vl);
  const auto out_v = __riscv_vnclip_wx_i16mf2(in_v, shift_scalar, vxrm, vl);
  __riscv_vse16_v_i16mf2(buf16, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wx_i16m1() {
  const auto in_v = __riscv_vle32_v_i32m2(buf32, vl);
  const auto out_v = __riscv_vnclip_wx_i16m1(in_v, shift_scalar, vxrm, vl);
  __riscv_vse16_v_i16m1(buf16, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wx_i16m2() {
  const auto in_v = __riscv_vle32_v_i32m4(buf32, vl);
  const auto out_v = __riscv_vnclip_wx_i16m2(in_v, shift_scalar, vxrm, vl);
  __riscv_vse16_v_i16m2(buf16, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wx_i16m4() {
  const auto in_v = __riscv_vle32_v_i32m8(buf32, vl);
  const auto out_v = __riscv_vnclip_wx_i16m4(in_v, shift_scalar, vxrm, vl);
  __riscv_vse16_v_i16m4(buf16, out_v, vl);
}

// 16 to 8, vxv
__attribute__((used, retain)) void vnclip_wv_i8mf4() {
  const auto in_v = __riscv_vle16_v_i16mf2(buf16, vl);
  const auto shift = __riscv_vle8_v_u8mf4(buf_shift8, vl);
  const auto out_v = __riscv_vnclip_wv_i8mf4(in_v, shift, vxrm, vl);
  __riscv_vse8_v_i8mf4(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wv_i8mf2() {
  const auto in_v = __riscv_vle16_v_i16m1(buf16, vl);
  const auto shift = __riscv_vle8_v_u8mf2(buf_shift8, vl);
  const auto out_v = __riscv_vnclip_wv_i8mf2(in_v, shift, vxrm, vl);
  __riscv_vse8_v_i8mf2(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wv_i8m1() {
  const auto in_v = __riscv_vle16_v_i16m2(buf16, vl);
  const auto shift = __riscv_vle8_v_u8m1(buf_shift8, vl);
  const auto out_v = __riscv_vnclip_wv_i8m1(in_v, shift, vxrm, vl);
  __riscv_vse8_v_i8m1(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wv_i8m2() {
  const auto in_v = __riscv_vle16_v_i16m4(buf16, vl);
  const auto shift = __riscv_vle8_v_u8m2(buf_shift8, vl);
  const auto out_v = __riscv_vnclip_wv_i8m2(in_v, shift, vxrm, vl);
  __riscv_vse8_v_i8m2(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wv_i8m4() {
  const auto in_v = __riscv_vle16_v_i16m8(buf16, vl);
  const auto shift = __riscv_vle8_v_u8m4(buf_shift8, vl);
  const auto out_v = __riscv_vnclip_wv_i8m4(in_v, shift, vxrm, vl);
  __riscv_vse8_v_i8m4(buf8, out_v, vl);
}

// 16 to 8, vxs
__attribute__((used, retain)) void vnclip_wx_i8mf4() {
  const auto in_v = __riscv_vle16_v_i16mf2(buf16, vl);
  const auto out_v = __riscv_vnclip_wx_i8mf4(in_v, shift_scalar, vxrm, vl);
  __riscv_vse8_v_i8mf4(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wx_i8mf2() {
  const auto in_v = __riscv_vle16_v_i16m1(buf16, vl);
  const auto out_v = __riscv_vnclip_wx_i8mf2(in_v, shift_scalar, vxrm, vl);
  __riscv_vse8_v_i8mf2(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wx_i8m1() {
  const auto in_v = __riscv_vle16_v_i16m2(buf16, vl);
  const auto out_v = __riscv_vnclip_wx_i8m1(in_v, shift_scalar, vxrm, vl);
  __riscv_vse8_v_i8m1(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wx_i8m2() {
  const auto in_v = __riscv_vle16_v_i16m4(buf16, vl);
  const auto out_v = __riscv_vnclip_wx_i8m2(in_v, shift_scalar, vxrm, vl);
  __riscv_vse8_v_i8m2(buf8, out_v, vl);
}

__attribute__((used, retain)) void vnclip_wx_i8m4() {
  const auto in_v = __riscv_vle16_v_i16m8(buf16, vl);
  const auto out_v = __riscv_vnclip_wx_i8m4(in_v, shift_scalar, vxrm, vl);
  __riscv_vse8_v_i8m4(buf8, out_v, vl);
}

// Test that vxsat CSR is set after a saturating vnclip operation.
// This test uses MAX_INT32 with shift=0, which must saturate to MAX_INT16.
// Per RISC-V Vector Extension v1.0 Section 3.5, vxsat should be set to 1.
// BUG: vxsat remains 0 because wr_vxsat signals are dead-end wires in RvvCore.
__attribute__((used, retain)) void vnclip_vxsat_check() {
  // Clear vxsat first to ensure clean test
  asm volatile("csrwi vxsat, 0");

  // Use MAX_INT32 with shift=0 to guarantee saturation to int16.
  // 0x7FFFFFFF (2147483647) >> 0 = 2147483647, which saturates to 32767 (0x7FFF).
  buf32[0]       = 0x7FFFFFFF;
  buf_shift16[0] = 0;  // No shift - guaranteed to saturate

  const auto in_v  = __riscv_vle32_v_i32m1(buf32, 1);
  const auto shift = __riscv_vle16_v_u16mf2(buf_shift16, 1);
  const auto out_v = __riscv_vnclip_wv_i16mf2(in_v, shift, vxrm, 1);
  __riscv_vse16_v_i16mf2(buf16, out_v, 1);

  // Read vxsat CSR - should be 1 after saturation occurred
  asm volatile("csrr %0, vxsat" : "=r"(vxsat_result));
}
}

void (*impl)() __attribute__((section(".data"))) = &vnclip_wv_i16m1;

int main(int argc, char** argv) {
  impl();
  return 0;
}
