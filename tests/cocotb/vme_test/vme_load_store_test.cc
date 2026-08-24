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

#include <cstdint>

extern "C" {

typedef void (*test_func_t)(void);

alignas(16) int8_t in_buf[1024] __attribute__((section(".data")));
alignas(16) int8_t out_buf[1024] __attribute__((section(".data")));

uint32_t trap_count  = 0;
uint32_t last_mcause = 0;

__attribute__((interrupt)) void isr_handler(void) {
  uint32_t mcause;
  asm volatile("csrr %0, mcause" : "=r"(mcause));
  last_mcause = mcause;
  if (mcause == 2) {
    trap_count++;
  }
  asm volatile(".word 0x08000073");  // mpause (halt on unexpected trap)
}

// Note: These tests assume TE = VLEN / 8 (i.e., the tile element count along a
// slice equals the number of 8-bit byte elements in a vector register).
// Therefore, holding a full tile slice requires:
// - EEW8:  LMUL = 1 (vint8m1_t)
// - EEW16: LMUL = 2 (vint16m2_t)
// - EEW32: LMUL = 4 (vint32m4_t)

// -----------------------------------------------------------------------------
// EEW8 (8-bit elements, LMUL=1)
// -----------------------------------------------------------------------------

// vtle8 row (load tile from in_buf, move tile row to vector, store vector to out_buf)
__attribute__((used, retain)) void test_vtle8_row(void) {
  uint32_t mtype   = (16 << 10) | 3;
  uint32_t vtype   = (0xc0) | (0 << 3) | 0;  // e8, m1, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector):
  // Bit 24: pattern (0 = row access, 1 = column access)
  // Bits 30:27: tile index (0 = tile 0)
  // Bits 3:0: slice index (0 = slice 0)
  uint32_t tss = 0;  // Row access
  register vint8m1_t v_out asm("v8");
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"   // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"       // msettn
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[in_buf], %[tss] \n"  // vtle8
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"          // vtmv.v.t (vd=v8)
      : "=vr"(v_out)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [tss] "r"(tss), "m"(*(const int8_t(*)[1024])in_buf)
      : "vl", "vtype");
  size_t vlmax = __riscv_vsetvlmax_e8m1();
  __riscv_vse8_v_i8m1(out_buf, v_out, vlmax);
}

// vtle8 col (load tile from in_buf, move tile col to vector, store vector to out_buf)
__attribute__((used, retain)) void test_vtle8_col(void) {
  uint32_t mtype   = (16 << 10) | 3;
  uint32_t vtype   = (0xc0) | (0 << 3) | 0;  // e8, m1, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 1 for column access
  uint32_t tss = (1 << 24);  // Column access
  register vint8m1_t v_out asm("v8");
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"   // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"       // msettn
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[in_buf], %[tss] \n"  // vtle8
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"          // vtmv.v.t (vd=v8)
      : "=vr"(v_out)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [tss] "r"(tss), "m"(*(const int8_t(*)[1024])in_buf)
      : "vl", "vtype");
  size_t vlmax = __riscv_vsetvlmax_e8m1();
  __riscv_vse8_v_i8m1(out_buf, v_out, vlmax);
}

// vtse8 row (load vector from in_buf, move to tile row, store tile to out_buf)
__attribute__((used, retain)) void test_vtse8_row(void) {
  size_t vl                         = __riscv_vsetvl_e8m1(16);
  register vint8m1_t v_in asm("v8") = __riscv_vle8_v_i8m1(in_buf, vl);
  uint32_t mtype                    = (16 << 10) | 3;
  uint32_t vtype                    = (0xc0) | (0 << 3) | 0;  // e8, m1, ta, ma
  uint32_t sixteen                  = 16;
  // tss (tile slice selector): pattern = 0 for row access
  uint32_t tss = 0;  // Row access
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"            // vtmv.t.v (vs1=v8)
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[out_buf], %[tss] \n"  // vtse8
      : "=m"(*(int8_t(*)[1024])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [out_buf] "r"(out_buf),
        [tss] "r"(tss), "vr"(v_in)
      : "vl", "vtype");
}

// vtse8 col (load vector from in_buf, move to tile col, store tile to out_buf)
__attribute__((used, retain)) void test_vtse8_col(void) {
  size_t vl                         = __riscv_vsetvl_e8m1(16);
  register vint8m1_t v_in asm("v8") = __riscv_vle8_v_i8m1(in_buf, vl);
  uint32_t mtype                    = (16 << 10) | 3;
  uint32_t vtype                    = (0xc0) | (0 << 3) | 0;  // e8, m1, ta, ma
  uint32_t sixteen                  = 16;
  // tss (tile slice selector): pattern = 1 for column access
  uint32_t tss = (1 << 24);  // Column access
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"            // vtmv.t.v (vs1=v8)
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[out_buf], %[tss] \n"  // vtse8
      : "=m"(*(int8_t(*)[1024])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [out_buf] "r"(out_buf),
        [tss] "r"(tss), "vr"(v_in)
      : "vl", "vtype");
}

// -----------------------------------------------------------------------------
// EEW16 (16-bit elements, LMUL=2)
// -----------------------------------------------------------------------------

// vtle16 row (load tile from in_buf, move tile row to vector, store vector to out_buf)
__attribute__((used, retain)) void test_vtle16_row(void) {
  uint32_t mtype   = (16 << 10) | 2;
  uint32_t vtype   = (0xc0) | (1 << 3) | 1;  // e16, m2, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 0 for row access
  uint32_t tss = 0;  // Row access
  register vint16m2_t v_out asm("v8");
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"   // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"       // msettn
      ".insn r 0b0000111, 0b111, 0b0011001, zero, %[in_buf], %[tss] \n"  // vtle16
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"          // vtmv.v.t (vd=v8)
      : "=vr"(v_out)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [tss] "r"(tss), "m"(*(const int16_t(*)[512])in_buf)
      : "vl", "vtype");
  size_t vlmax = __riscv_vsetvlmax_e16m2();
  __riscv_vse16_v_i16m2(reinterpret_cast<int16_t *>(out_buf), v_out, vlmax);
}

// vtle16 col (load tile from in_buf, move tile col to vector, store vector to out_buf)
__attribute__((used, retain)) void test_vtle16_col(void) {
  uint32_t mtype   = (16 << 10) | 2;
  uint32_t vtype   = (0xc0) | (1 << 3) | 1;  // e16, m2, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 1 for column access
  uint32_t tss = (1 << 24);  // Column access
  register vint16m2_t v_out asm("v8");
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"   // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"       // msettn
      ".insn r 0b0000111, 0b111, 0b0011001, zero, %[in_buf], %[tss] \n"  // vtle16
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"          // vtmv.v.t (vd=v8)
      : "=vr"(v_out)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [tss] "r"(tss), "m"(*(const int16_t(*)[512])in_buf)
      : "vl", "vtype");
  size_t vlmax = __riscv_vsetvlmax_e16m2();
  __riscv_vse16_v_i16m2(reinterpret_cast<int16_t *>(out_buf), v_out, vlmax);
}

// vtse16 row (load vector from in_buf, move to tile row, store tile to out_buf)
__attribute__((used, retain)) void test_vtse16_row(void) {
  size_t vl = __riscv_vsetvl_e16m2(16);
  register vint16m2_t v_in asm("v8") =
      __riscv_vle16_v_i16m2(reinterpret_cast<const int16_t *>(in_buf), vl);
  uint32_t mtype   = (16 << 10) | 2;
  uint32_t vtype   = (0xc0) | (1 << 3) | 1;  // e16, m2, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 0 for row access
  uint32_t tss = 0;  // Row access
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"            // vtmv.t.v (vs1=v8)
      ".insn r 0b0100111, 0b111, 0b0011001, zero, %[out_buf], %[tss] \n"  // vtse16
      : "=m"(*(int16_t(*)[512])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [out_buf] "r"(out_buf),
        [tss] "r"(tss), "vr"(v_in)
      : "vl", "vtype");
}

// vtse16 col (load vector from in_buf, move to tile col, store tile to out_buf)
__attribute__((used, retain)) void test_vtse16_col(void) {
  size_t vl = __riscv_vsetvl_e16m2(16);
  register vint16m2_t v_in asm("v8") =
      __riscv_vle16_v_i16m2(reinterpret_cast<const int16_t *>(in_buf), vl);
  uint32_t mtype   = (16 << 10) | 2;
  uint32_t vtype   = (0xc0) | (1 << 3) | 1;  // e16, m2, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 1 for column access
  uint32_t tss = (1 << 24);  // Column access
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"            // vtmv.t.v (vs1=v8)
      ".insn r 0b0100111, 0b111, 0b0011001, zero, %[out_buf], %[tss] \n"  // vtse16
      : "=m"(*(int16_t(*)[512])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [out_buf] "r"(out_buf),
        [tss] "r"(tss), "vr"(v_in)
      : "vl", "vtype");
}

// -----------------------------------------------------------------------------
// EEW32 (32-bit elements, LMUL=4)
// -----------------------------------------------------------------------------

// vtle32 row (load tile from in_buf, move tile row to vector, store vector to out_buf)
__attribute__((used, retain)) void test_vtle32_row(void) {
  uint32_t mtype   = (16 << 10) | 1;
  uint32_t vtype   = (0xc0) | (2 << 3) | 2;  // e32, m4, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 0 for row access
  uint32_t tss = 0;  // Row access
  register vint32m4_t v_out asm("v8");
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"   // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"       // msettn
      ".insn r 0b0000111, 0b111, 0b0101001, zero, %[in_buf], %[tss] \n"  // vtle32
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"          // vtmv.v.t (vd=v8)
      : "=vr"(v_out)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [tss] "r"(tss), "m"(*(const int32_t(*)[256])in_buf)
      : "vl", "vtype");
  size_t vlmax = __riscv_vsetvlmax_e32m4();
  __riscv_vse32_v_i32m4(reinterpret_cast<int32_t *>(out_buf), v_out, vlmax);
}

// vtle32 col (load tile from in_buf, move tile col to vector, store vector to out_buf)
__attribute__((used, retain)) void test_vtle32_col(void) {
  uint32_t mtype   = (16 << 10) | 1;
  uint32_t vtype   = (0xc0) | (2 << 3) | 2;  // e32, m4, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 1 for column access
  uint32_t tss = (1 << 24);  // Column access
  register vint32m4_t v_out asm("v8");
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"   // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"       // msettn
      ".insn r 0b0000111, 0b111, 0b0101001, zero, %[in_buf], %[tss] \n"  // vtle32
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"          // vtmv.v.t (vd=v8)
      : "=vr"(v_out)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [tss] "r"(tss), "m"(*(const int32_t(*)[256])in_buf)
      : "vl", "vtype");
  size_t vlmax = __riscv_vsetvlmax_e32m4();
  __riscv_vse32_v_i32m4(reinterpret_cast<int32_t *>(out_buf), v_out, vlmax);
}

// vtse32 row (load vector from in_buf, move to tile row, store tile to out_buf)
__attribute__((used, retain)) void test_vtse32_row(void) {
  size_t vl = __riscv_vsetvl_e32m4(16);
  register vint32m4_t v_in asm("v8") =
      __riscv_vle32_v_i32m4(reinterpret_cast<const int32_t *>(in_buf), vl);
  uint32_t mtype   = (16 << 10) | 1;
  uint32_t vtype   = (0xc0) | (2 << 3) | 2;  // e32, m4, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 0 for row access
  uint32_t tss = 0;  // Row access
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"            // vtmv.t.v (vs1=v8)
      ".insn r 0b0100111, 0b111, 0b0101001, zero, %[out_buf], %[tss] \n"  // vtse32
      : "=m"(*(int32_t(*)[256])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [out_buf] "r"(out_buf),
        [tss] "r"(tss), "vr"(v_in)
      : "vl", "vtype");
}

// vtse32 col (load vector from in_buf, move to tile col, store tile to out_buf)
__attribute__((used, retain)) void test_vtse32_col(void) {
  size_t vl = __riscv_vsetvl_e32m4(16);
  register vint32m4_t v_in asm("v8") =
      __riscv_vle32_v_i32m4(reinterpret_cast<const int32_t *>(in_buf), vl);
  uint32_t mtype   = (16 << 10) | 1;
  uint32_t vtype   = (0xc0) | (2 << 3) | 2;  // e32, m4, ta, ma
  uint32_t sixteen = 16;
  // tss (tile slice selector): pattern = 1 for column access
  uint32_t tss = (1 << 24);  // Column access
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"            // vtmv.t.v (vs1=v8)
      ".insn r 0b0100111, 0b111, 0b0101001, zero, %[out_buf], %[tss] \n"  // vtse32
      : "=m"(*(int32_t(*)[256])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [out_buf] "r"(out_buf),
        [tss] "r"(tss), "vr"(v_in)
      : "vl", "vtype");
}

// -----------------------------------------------------------------------------
// Roundtrip (Direct Memory <-> Tile, bypassing VRF)
// -----------------------------------------------------------------------------

__attribute__((used, retain)) void test_roundtrip_e8_row(void) {
  uint32_t mtype   = (16 << 10) | 3;
  uint32_t vtype   = (0xc0) | (0 << 3) | 0;  // e8, m1, ta, ma
  uint32_t sixteen = 16;
  uint32_t tss     = 0;  // Row access, tile 0, row 0
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[in_buf], %[tss] \n"   // vtle8
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[out_buf], %[tss] \n"  // vtse8
      : "=m"(*(int8_t(*)[1024])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [out_buf] "r"(out_buf), [tss] "r"(tss), "m"(*(const int8_t(*)[1024])in_buf)
      : "vl", "vtype");
}

__attribute__((used, retain)) void test_roundtrip_e8_col(void) {
  uint32_t mtype   = (16 << 10) | 3;
  uint32_t vtype   = (0xc0) | (0 << 3) | 0;  // e8, m1, ta, ma
  uint32_t sixteen = 16;
  uint32_t tss     = (1 << 24);  // Column access, tile 0, col 0
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[in_buf], %[tss] \n"   // vtle8
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[out_buf], %[tss] \n"  // vtse8
      : "=m"(*(int8_t(*)[1024])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [out_buf] "r"(out_buf), [tss] "r"(tss), "m"(*(const int8_t(*)[1024])in_buf)
      : "vl", "vtype");
}

__attribute__((used, retain)) void test_roundtrip_e16_row(void) {
  uint32_t mtype   = (16 << 10) | 2;
  uint32_t vtype   = (0xc0) | (1 << 3) | 1;  // e16, m2, ta, ma
  uint32_t sixteen = 16;
  uint32_t tss     = 0;  // Row access, tile 0, row 0
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b0000111, 0b111, 0b0011001, zero, %[in_buf], %[tss] \n"   // vtle16
      ".insn r 0b0100111, 0b111, 0b0011001, zero, %[out_buf], %[tss] \n"  // vtse16
      : "=m"(*(int16_t(*)[512])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [out_buf] "r"(out_buf), [tss] "r"(tss), "m"(*(const int16_t(*)[512])in_buf)
      : "vl", "vtype");
}

__attribute__((used, retain)) void test_roundtrip_e16_col(void) {
  uint32_t mtype   = (16 << 10) | 2;
  uint32_t vtype   = (0xc0) | (1 << 3) | 1;  // e16, m2, ta, ma
  uint32_t sixteen = 16;
  uint32_t tss     = (1 << 24);  // Column access, tile 0, col 0
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b0000111, 0b111, 0b0011001, zero, %[in_buf], %[tss] \n"   // vtle16
      ".insn r 0b0100111, 0b111, 0b0011001, zero, %[out_buf], %[tss] \n"  // vtse16
      : "=m"(*(int16_t(*)[512])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [out_buf] "r"(out_buf), [tss] "r"(tss), "m"(*(const int16_t(*)[512])in_buf)
      : "vl", "vtype");
}

__attribute__((used, retain)) void test_roundtrip_e32_row(void) {
  uint32_t mtype   = (16 << 10) | 1;
  uint32_t vtype   = (0xc0) | (2 << 3) | 2;  // e32, m4, ta, ma
  uint32_t sixteen = 16;
  uint32_t tss     = 0;  // Row access, tile 0, row 0
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b0000111, 0b111, 0b0101001, zero, %[in_buf], %[tss] \n"   // vtle32
      ".insn r 0b0100111, 0b111, 0b0101001, zero, %[out_buf], %[tss] \n"  // vtse32
      : "=m"(*(int32_t(*)[256])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [out_buf] "r"(out_buf), [tss] "r"(tss), "m"(*(const int32_t(*)[256])in_buf)
      : "vl", "vtype");
}

__attribute__((used, retain)) void test_roundtrip_e32_col(void) {
  uint32_t mtype   = (16 << 10) | 1;
  uint32_t vtype   = (0xc0) | (2 << 3) | 2;  // e32, m4, ta, ma
  uint32_t sixteen = 16;
  uint32_t tss     = (1 << 24);  // Column access, tile 0, col 0
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"    // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"        // msettn
      ".insn r 0b0000111, 0b111, 0b0101001, zero, %[in_buf], %[tss] \n"   // vtle32
      ".insn r 0b0100111, 0b111, 0b0101001, zero, %[out_buf], %[tss] \n"  // vtse32
      : "=m"(*(int32_t(*)[256])out_buf)
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen), [in_buf] "r"(in_buf),
        [out_buf] "r"(out_buf), [tss] "r"(tss), "m"(*(const int32_t(*)[256])in_buf)
      : "vl", "vtype");
}

test_func_t test_fn = test_vtle8_row;

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %[isr]" ::[isr] "r"((uint32_t)(&isr_handler)));

  trap_count  = 0;
  last_mcause = 0;

  if (test_fn != nullptr) {
    test_fn();
  }

  return 0;
}

}  // extern "C"
