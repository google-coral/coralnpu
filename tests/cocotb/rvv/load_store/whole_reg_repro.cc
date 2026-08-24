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
#include <stddef.h>
#include <stdint.h>

namespace {
constexpr size_t buf_size = 256;
}

uint8_t src_buffer[buf_size] __attribute__((section(".data"), aligned(16)));
uint8_t dst_buffer[buf_size] __attribute__((section(".data"), aligned(16)));
uint32_t index_buffer[buf_size] __attribute__((section(".data"), aligned(16)));

__attribute__((noinline)) void test_unaligned_whole_reg_load() {
  uint8_t *unaligned_src = src_buffer + 3;
  asm volatile(
      "csrw vstart, zero\n"
      "vsetvli t2, zero, e16, mf2, ta, mu\n"
      "vl2re8.v v22, (%[src])\n"
      "vs2r.v v22, (%[dst])\n"
      :
      : [src] "r"(unaligned_src), [dst] "r"(dst_buffer)
      : "t2", "v22", "v23", "memory");
}

__attribute__((noinline)) void test_vstart_whole_reg_load() {
  // Test vl2re8.v with vstart = 5
  // Elements 0..4 in v22 must remain untouched (0xAA).
  // Elements 5..31 must be loaded from src_buffer + 5.
  asm volatile(
      "csrw vstart, zero\n"
      "li t0, 0xAA\n"
      "vsetvli t2, zero, e8, m2, ta, ma\n"
      "vmv.v.x v22, t0\n"
      "li t1, 5\n"
      "csrw vstart, t1\n"
      "vl2re8.v v22, (%[src])\n"
      "vs2r.v v22, (%[dst])\n"
      :
      : [src] "r"(src_buffer), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v22", "v23", "memory");
}

__attribute__((noinline)) void test_vstart_whole_reg_load_cross_reg() {
  // Test vl2re8.v with vstart = 19 (in 2nd register, v23, item index = 3)
  asm volatile(
      "csrw vstart, zero\n"
      "li t0, 0x55\n"
      "vsetvli t2, zero, e8, m2, ta, ma\n"
      "vmv.v.x v22, t0\n"
      "li t1, 19\n"
      "csrw vstart, t1\n"
      "vl2re8.v v22, (%[src])\n"
      "vs2r.v v22, (%[dst])\n"
      :
      : [src] "r"(src_buffer), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v22", "v23", "memory");
}

__attribute__((noinline)) void test_vstart_ge_evl_whole_reg_load() {
  // When vstart >= evl (e.g. vstart = 32 for vl2re8.v), no elements are written.
  asm volatile(
      "csrw vstart, zero\n"
      "li t0, 0x33\n"
      "vsetvli t2, zero, e8, m2, ta, ma\n"
      "vmv.v.x v22, t0\n"
      "li t1, 32\n"
      "csrw vstart, t1\n"
      "vl2re8.v v22, (%[src])\n"
      "vs2r.v v22, (%[dst])\n"
      :
      : [src] "r"(src_buffer), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v22", "v23", "memory");
}

__attribute__((noinline)) void test_vl4re8_unaligned_vstart() {
  // Test vl4re8.v with unaligned base (src_buffer + 14) and vstart = 7
  uint8_t *unaligned_src = src_buffer + 14;
  asm volatile(
      "csrw vstart, zero\n"
      "li t0, 0x88\n"
      "vsetvli t2, zero, e8, m4, ta, ma\n"
      "vmv.v.x v12, t0\n"
      "li t1, 7\n"
      "csrw vstart, t1\n"
      "vl4re8.v v12, (%[src])\n"
      "vs4r.v v12, (%[dst])\n"
      :
      : [src] "r"(unaligned_src), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v12", "v13", "v14", "v15", "memory");
}

__attribute__((noinline)) void test_vl2re16_vstart() {
  // Test vl2re16.v (evl = 16 elements of 16-bit) with vstart = 3
  asm volatile(
      "csrw vstart, zero\n"
      "li t0, 0x1234\n"
      "vsetvli t2, zero, e16, m2, ta, ma\n"
      "vmv.v.x v16, t0\n"
      "li t1, 3\n"
      "csrw vstart, t1\n"
      "vl2re16.v v16, (%[src])\n"
      "vs2r.v v16, (%[dst])\n"
      :
      : [src] "r"(src_buffer), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v16", "v17", "memory");
}

__attribute__((noinline)) void test_vl2re32_vstart() {
  // Test vl2re32.v (evl = 8 elements of 32-bit) with vstart = 2
  asm volatile(
      "csrw vstart, zero\n"
      "li t0, 0x12345678\n"
      "vsetvli t2, zero, e32, m2, ta, ma\n"
      "vmv.v.x v18, t0\n"
      "li t1, 2\n"
      "csrw vstart, t1\n"
      "vl2re32.v v18, (%[src])\n"
      "vs2r.v v18, (%[dst])\n"
      :
      : [src] "r"(src_buffer), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v18", "v19", "memory");
}

__attribute__((noinline)) void test_vsuxei32_vstart() {
  // Indexed store with vstart = 2
  asm volatile(
      "csrw vstart, zero\n"
      "vsetvli t2, zero, e32, m1, ta, ma\n"
      "vle32.v v12, (%[idx])\n"
      "vsetvli t2, zero, e8, mf4, ta, ma\n"
      "li t0, 0x77\n"
      "vmv.v.x v8, t0\n"
      "li t1, 2\n"
      "csrw vstart, t1\n"
      "vsuxei32.v v8, (%[dst]), v12\n"
      :
      : [idx] "r"(index_buffer), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v8", "v12", "memory");
}

__attribute__((noinline)) void test_vluxei32_vstart() {
  // Indexed load with vstart = 3
  asm volatile(
      "csrw vstart, zero\n"
      "vsetvli t2, zero, e32, m1, ta, ma\n"
      "vle32.v v12, (%[idx])\n"
      "vsetvli t2, zero, e8, mf4, ta, ma\n"
      "li t0, 0x99\n"
      "vmv.v.x v8, t0\n"
      "li t1, 3\n"
      "csrw vstart, t1\n"
      "vluxei32.v v8, (%[src]), v12\n"
      "vs1r.v v8, (%[dst])\n"
      :
      : [idx] "r"(index_buffer), [src] "r"(src_buffer), [dst] "r"(dst_buffer)
      : "t0", "t1", "t2", "v8", "v12", "memory");
}

int main() {
  for (size_t i = 0; i < buf_size; i++) {
    src_buffer[i]   = static_cast<uint8_t>(i + 1);
    dst_buffer[i]   = 0;
    index_buffer[i] = static_cast<uint32_t>(i * 4);
  }

  test_unaligned_whole_reg_load();
  test_vstart_whole_reg_load();
  test_vstart_whole_reg_load_cross_reg();
  test_vstart_ge_evl_whole_reg_load();
  test_vl4re8_unaligned_vstart();
  test_vl2re16_vstart();
  test_vl2re32_vstart();
  test_vsuxei32_vstart();
  test_vluxei32_vstart();

  return 0;
}
