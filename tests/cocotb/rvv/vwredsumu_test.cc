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

#include <stdint.h>

// Mask data: 0x0e30 sets bits 4, 5, 9, 10, 11
static volatile uint8_t mask_data[16] __attribute__((section(".data"), aligned(16))) = {
    0x30, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};

static volatile uint8_t vs2_u8[128] __attribute__((section(".data"), aligned(16)));
static volatile uint16_t vs1_u16[8] __attribute__((section(".data"), aligned(16)));
static volatile uint16_t vd_u16[8] __attribute__((section(".data"), aligned(16)));

static volatile int8_t vs2_i8[128] __attribute__((section(".data"), aligned(16)));
static volatile int16_t vs1_i16[8] __attribute__((section(".data"), aligned(16)));
static volatile int16_t vd_i16[8] __attribute__((section(".data"), aligned(16)));

static volatile uint16_t vs2_u16[64] __attribute__((section(".data"), aligned(16)));
static volatile uint32_t vs1_u32[4] __attribute__((section(".data"), aligned(16)));
static volatile uint32_t vd_u32[4] __attribute__((section(".data"), aligned(16)));

int main(int argc, char **argv) {
  // Test 1: vwredsumu.vs with e8, m8, masked (vl=12)
  // Mask active bits: 4, 5, 9, 10, 11
  // Set elements:
  // vs2[4]=10, vs2[5]=12, vs2[9]=8, vs2[10]=7, vs2[11]=5 -> sum = 42 (0x2a)
  // vs2 inactive element: vs2[0]=100 (should not be added)
  // Initial scalar accumulator in vs1[0] = 0x0100
  // Expected vd[0] = 0x0100 + 42 = 0x012a
  for (int i = 0; i < 128; ++i) {
    vs2_u8[i] = 0;
  }
  vs2_u8[0]  = 100;
  vs2_u8[4]  = 10;
  vs2_u8[5]  = 12;
  vs2_u8[9]  = 8;
  vs2_u8[10] = 7;
  vs2_u8[11] = 5;

  vs1_u16[0] = 0x0100;
  vd_u16[0]  = 0;

  // Load mask into v0
  asm volatile(
      "vsetivli x0, 16, e8, m1, ta, ma\n"
      "vle8.v v0, (%0)\n"
      :
      : "r"(mask_data)
      : "memory");

  // Load vs1 into v16
  asm volatile(
      "vsetivli x0, 8, e16, m1, ta, ma\n"
      "vle16.v v16, (%0)\n"
      :
      : "r"(vs1_u16)
      : "memory");

  // Load vs2 into v24 (m8 group)
  asm volatile(
      "li a0, 128\n"
      "vsetvli x0, a0, e8, m8, ta, ma\n"
      "vle8.v v24, (%0)\n"
      :
      : "r"(vs2_u8)
      : "a0", "memory");

  // Execute masked vwredsumu.vs
  asm volatile(
      "vsetivli zero, 12, e8, m8, ta, mu\n"
      "vwredsumu.vs v10, v24, v16, v0.t\n");

  // Store result vd (v10)
  asm volatile(
      "vsetivli x0, 8, e16, m1, ta, ma\n"
      "vse16.v v10, (%0)\n"
      :
      : "r"(vd_u16)
      : "memory");

  if (vd_u16[0] != 0x012a) {
    asm volatile("ebreak");
    return 1;
  }

  // Test 2: vwredsumu.vs with e8, m8, unmasked (vl=128)
  for (int i = 0; i < 128; ++i) {
    vs2_u8[i] = 1;
  }
  vs1_u16[0] = 0x1200;
  vd_u16[0]  = 0;

  asm volatile(
      "vsetivli x0, 8, e16, m1, ta, ma\n"
      "vle16.v v16, (%0)\n"
      :
      : "r"(vs1_u16)
      : "memory");

  asm volatile(
      "li a0, 128\n"
      "vsetvli x0, a0, e8, m8, ta, ma\n"
      "vle8.v v24, (%0)\n"
      :
      : "r"(vs2_u8)
      : "a0", "memory");

  asm volatile(
      "li a0, 128\n"
      "vsetvli zero, a0, e8, m8, ta, ma\n"
      "vwredsumu.vs v10, v24, v16\n"
      :
      :
      : "a0");

  asm volatile(
      "vsetivli x0, 8, e16, m1, ta, ma\n"
      "vse16.v v10, (%0)\n"
      :
      : "r"(vd_u16)
      : "memory");

  // Expected: 0x1200 + 128 = 0x1280
  if (vd_u16[0] != 0x1280) {
    asm volatile("ebreak");
    return 2;
  }

  // Test 3: vwredsum.vs (signed) with e8, m8 (vl=128)
  for (int i = 0; i < 64; ++i) {
    vs2_i8[i] = -1;
  }
  for (int i = 64; i < 128; ++i) {
    vs2_i8[i] = 2;
  }
  // Sum = 64 * (-1) + 64 * 2 = 64
  vs1_i16[0] = 0x0200;  // 512
  vd_i16[0]  = 0;

  asm volatile(
      "vsetivli x0, 8, e16, m1, ta, ma\n"
      "vle16.v v16, (%0)\n"
      :
      : "r"(vs1_i16)
      : "memory");

  asm volatile(
      "li a0, 128\n"
      "vsetvli x0, a0, e8, m8, ta, ma\n"
      "vle8.v v24, (%0)\n"
      :
      : "r"(vs2_i8)
      : "a0", "memory");

  asm volatile(
      "li a0, 128\n"
      "vsetvli zero, a0, e8, m8, ta, ma\n"
      "vwredsum.vs v10, v24, v16\n"
      :
      :
      : "a0");

  asm volatile(
      "vsetivli x0, 8, e16, m1, ta, ma\n"
      "vse16.v v10, (%0)\n"
      :
      : "r"(vd_i16)
      : "memory");

  // Expected: 512 + 64 = 576 = 0x0240
  if (vd_i16[0] != 0x0240) {
    asm volatile("ebreak");
    return 3;
  }

  // Test 4: vwredsumu.vs with e16, m8 (vl=64, 32-bit destination)
  for (int i = 0; i < 64; ++i) {
    vs2_u16[i] = 10;
  }
  // Sum = 64 * 10 = 640
  vs1_u32[0] = 0x00010000;  // 65536
  vd_u32[0]  = 0;

  asm volatile(
      "vsetivli x0, 4, e32, m1, ta, ma\n"
      "vle32.v v16, (%0)\n"
      :
      : "r"(vs1_u32)
      : "memory");

  asm volatile(
      "li a0, 64\n"
      "vsetvli x0, a0, e16, m8, ta, ma\n"
      "vle16.v v24, (%0)\n"
      :
      : "r"(vs2_u16)
      : "a0", "memory");

  asm volatile(
      "li a0, 64\n"
      "vsetvli zero, a0, e16, m8, ta, ma\n"
      "vwredsumu.vs v10, v24, v16\n"
      :
      :
      : "a0");

  asm volatile(
      "vsetivli x0, 4, e32, m1, ta, ma\n"
      "vse32.v v10, (%0)\n"
      :
      : "r"(vd_u32)
      : "memory");

  // Expected: 0x00010000 + 640 = 0x00010280
  if (vd_u32[0] != 0x00010280) {
    asm volatile("ebreak");
    return 4;
  }

  return 0;
}
