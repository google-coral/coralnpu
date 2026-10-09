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
//
// Test program for the VME (Zvt) matrix arithmetic instructions:
//   vtmmu.tvv  - uint8 x uint8 -> int32 tile accumulate
//   vtmms.tvv  - int8  x uint8 -> int32 tile accumulate
//   vtfmm.alt  - bf16  x bf16  -> fp32  tile accumulate
//   vtfmm.tvv  - fp32  x fp32  -> fp32  tile accumulate
// plus vtzero and the register-to-register tile moves vtmv.t.v / vtmv.v.t.
// Tile state is only ever accessed register-to-register (no vtle/vtse tile
// load/store); ordinary vle/vse stage the data between DTCM and the vector
// registers so the cocotb harness can supply inputs and check outputs.
//
// The harness writes the mm_* globals, points `mm_impl` at one of the case
// runners below, and runs to halt once per case (vcpop_test.cc pattern).

#include <cstdint>

#include "vme_test_utils.h"

// -----------------------------------------------------------------------------
// Geometry (VLEN=128): TE=16, 16x16 tiles, TEW=32.
// -----------------------------------------------------------------------------
#define TE 16

// vtype values (vma[7] | vta[6] | vsew[5:3] | vlmul[2:0]).
static constexpr uint32_t kVtypeSew8Lmul1  = 0xC0;  // ta/ma, SEW8,  LMUL1
static constexpr uint32_t kVtypeSew32Lmul4 = 0xD2;  // ta/ma, SEW32, LMUL4
// altfmt[8] | ta/ma, SEW16, LMUL2 (bf16 matmul).
static constexpr uint32_t kVtypeSew16Lmul2Altfmt = 0x1C9;

// -----------------------------------------------------------------------------
// Zvt instruction words, emitted via .word since they use vector-register
// operands GAS cannot name for these encodings. Fixed register assignment:
//   v4..v7   staging group for tile-row moves
//   v8..     A operand (int8 rows at v8/v10/v12/v14: the spec's 8/KMAX row
//            spacing; fp32 single row spans v8..v11)
//   v16..    B operand (int8 rows at v16/v18/v20/v22; fp32 row v16..v19)
//            bf16 rows (LMUL2) at v8/v12 (A) and v16/v20 (B)
//   a0       tile subset specifier (TSS) scalar for the moves
//
// Instructions:
// - Matrix arithmetic (vtmmu, vtmms, vtfmm) uses opcode OP-VE (0x77).
// - Tile configuration, moves, and vtzero use opcode OP-V (0x57).
// -----------------------------------------------------------------------------

// TSS: tile[30:27] | pattern[26:24] (0=row) | index[23:0].
static inline uint32_t Tss(uint32_t tile, uint32_t row) { return (tile << 27) | row; }

template <uint32_t TILE>
static inline __attribute__((always_inline)) void Vtzero() {
  asm volatile(".word %0" : : "i"(ZvtVtzeroWord(TILE)) : "memory");
}

// Move v4..v7 (16 x fp32/int32 elements) into tile row `tss`.
static inline __attribute__((always_inline)) void VtmvTV(uint32_t tss) {
  register uint32_t a0_arg asm("a0") = tss;
  asm volatile(".word %0" : : "i"(kZvtVtmvTVWord), "r"(a0_arg) : "memory");
}

// Move tile row `tss` into v4..v7.
static inline __attribute__((always_inline)) void VtmvVT(uint32_t tss) {
  register uint32_t a0_arg asm("a0") = tss;
  asm volatile(".word %0" : : "i"(kZvtVtmvVTWord), "r"(a0_arg) : "v4", "v5", "v6", "v7", "memory");
}

// -----------------------------------------------------------------------------
// Harness-visible state (all in .data so the bench can write it over AXI).
// -----------------------------------------------------------------------------

// A and B operands: 4 rows x 16 bytes for int8; the same 64 bytes reinterpreted
// as 2 rows x 16 bf16 values for bf16, or 16 fp32 values (single row) for fp32.
uint8_t mm_a[4 * TE] __attribute__((section(".data"), aligned(16)));
uint8_t mm_b[4 * TE] __attribute__((section(".data"), aligned(16)));
// Accumulator preload and result readback, row-major 16x16 x 32-bit.
uint32_t mm_c_init[TE * TE] __attribute__((section(".data"), aligned(16)));
uint32_t mm_out[TE * TE] __attribute__((section(".data"), aligned(16)));
// Matmul dimensions and accumulator init mode (0 = vtzero, 1 = preload
// mm_c_init through vtmv.t.v).
volatile uint32_t mm_tm __attribute__((section(".data")))        = TE;
volatile uint32_t mm_tn __attribute__((section(".data")))        = TE;
volatile uint32_t mm_tk __attribute__((section(".data")))        = 1;
volatile uint32_t mm_init_mode __attribute__((section(".data"))) = 0;

// -----------------------------------------------------------------------------
// Case runners.
// -----------------------------------------------------------------------------

// Configure SEW32/LMUL4 (the tile-move shape: one 16x32b row per vtmv) with
// full-tile tm/tn so moves and vtzero cover the whole accumulator.
static inline __attribute__((always_inline)) void ConfigureTileMoves() {
  vme_msetmtype(MtypeValue(/*tm=*/TE, /*tk=*/1, /*mtwiden=*/1), kVtypeSew32Lmul4);
  (void)vme_msettn(TE);
}

// Initialize accumulator tile: vtzero or per-row preload from mm_c_init.
__attribute__((noinline)) static void PreloadAccumulator(uint32_t tile) {
  for (uint32_t i = 0; i < TE; i++) {
    const uint32_t *row = &mm_c_init[i * TE];
    asm volatile("vle32.v v4, (%0)" : : "r"(row) : "v4", "v5", "v6", "v7", "memory");
    VtmvTV(Tss(tile, i));
  }
}

template <uint32_t TILE>
static void InitAccumulator() {
  ConfigureTileMoves();
  if (mm_init_mode == 0) {
    Vtzero<TILE>();
  } else {
    PreloadAccumulator(TILE);
  }
}

// Read the accumulator tile back into mm_out, one row per vtmv.v.t.
__attribute__((noinline)) static void ReadbackTile(uint32_t tile) {
  ConfigureTileMoves();
  for (uint32_t i = 0; i < TE; i++) {
    uint32_t *row = &mm_out[i * TE];
    VtmvVT(Tss(tile, i));
    asm volatile("vse32.v v4, (%0)" : : "r"(row) : "memory");
  }
}

__attribute__((noinline)) static void LoadIntOperands(uint32_t vtype) {
  vme_msetmtype(MtypeValue(/*tm=*/TE, mm_tk, /*mtwiden=*/3), vtype);
  (void)vme_msettm(mm_tm);
  (void)vme_msettn(TE);
  asm volatile(
      "vle8.v v8,  (%0)\n"
      "vle8.v v10, (%1)\n"
      "vle8.v v12, (%2)\n"
      "vle8.v v14, (%3)\n"
      :
      : "r"(&mm_a[0]), "r"(&mm_a[TE]), "r"(&mm_a[2 * TE]), "r"(&mm_a[3 * TE])
      : "v8", "v10", "v12", "v14", "memory");
  asm volatile(
      "vle8.v v16, (%0)\n"
      "vle8.v v18, (%1)\n"
      "vle8.v v20, (%2)\n"
      "vle8.v v22, (%3)\n"
      :
      : "r"(&mm_b[0]), "r"(&mm_b[TE]), "r"(&mm_b[2 * TE]), "r"(&mm_b[3 * TE])
      : "v16", "v18", "v20", "v22", "memory");
  (void)vme_msettn(mm_tn);
}

template <uint32_t TILE, bool SIGNED_A>
static void RunIntCase(uint32_t vtype = kVtypeSew8Lmul1) {
  InitAccumulator<TILE>();
  LoadIntOperands(vtype);
  asm volatile(".word %0" : : "i"(ZvtMatmulIntWord(TILE, SIGNED_A)) : "memory");
  ReadbackTile(TILE);
}

template <uint32_t TILE>
static void RunBf16Case() {
  InitAccumulator<TILE>();

  // bf16 matmul shape: SEW16/LMUL2 + altfmt, mtwiden=2 (TWIDEN=2). Load both
  // A/B row slots with vl=16; rows >= tk are masked off by the hardware.
  vme_msetmtype(MtypeValue(/*tm=*/TE, mm_tk, /*mtwiden=*/2), kVtypeSew16Lmul2Altfmt);
  (void)vme_msettm(mm_tm);
  (void)vme_msettn(TE);
  asm volatile(
      "vle16.v v8,  (%0)\n"
      "vle16.v v12, (%1)\n"
      :
      : "r"(&mm_a[0]), "r"(&mm_a[2 * TE])
      : "v8", "v9", "v12", "v13", "memory");
  asm volatile(
      "vle16.v v16, (%0)\n"
      "vle16.v v20, (%1)\n"
      :
      : "r"(&mm_b[0]), "r"(&mm_b[2 * TE])
      : "v16", "v17", "v20", "v21", "memory");
  (void)vme_msettn(mm_tn);

  asm volatile(".word %0" : : "i"(ZvtMatmulFpWord(TILE, /*alt=*/true)) : "memory");

  ReadbackTile(TILE);
}

template <uint32_t TILE>
static void RunFpCase() {
  InitAccumulator<TILE>();

  // fp32 matmul shape: SEW32/LMUL4, mtwiden=1, tk=1. A and B are each one
  // 16-element row spanning a 4-register group.
  vme_msetmtype(MtypeValue(mm_tm, /*tk=*/1, /*mtwiden=*/1), kVtypeSew32Lmul4);
  (void)vme_msettn(TE);
  asm volatile(
      "vle32.v v8,  (%0)\n"
      "vle32.v v16, (%1)\n"
      :
      : "r"(&mm_a[0]), "r"(&mm_b[0])
      : "v8", "v9", "v10", "v11", "v16", "v17", "v18", "v19", "memory");
  (void)vme_msettn(mm_tn);

  asm volatile(".word %0" : : "i"(ZvtMatmulFpWord(TILE)) : "memory");

  ReadbackTile(TILE);
}

extern "C" {
__attribute__((used, retain)) void vtmmu_mt0() { RunIntCase<0, false>(); }
__attribute__((used, retain)) void vtmmu_mt4() { RunIntCase<4, false>(); }
__attribute__((used, retain)) void vtmms_mt0() { RunIntCase<0, true>(); }
__attribute__((used, retain)) void vtfmm_bf16_mt0() { RunBf16Case<0>(); }
__attribute__((used, retain)) void vtfmm_bf16_mt8() { RunBf16Case<8>(); }
__attribute__((used, retain)) void vtfmm_mt0() { RunFpCase<0>(); }
__attribute__((used, retain)) void vtfmm_mt8() { RunFpCase<8>(); }
}

// Case selector, overwritten by the cocotb harness before each run.
// When null (standalone UVM co-simulation), main() executes the full suite.
void (*volatile mm_impl)() __attribute__((section(".data"))) = nullptr;

__attribute__((noinline, optimize("Os"))) static void RunStandaloneSuite() {
  // 1. Int8 matmul inputs (includes values >= 128 to exercise signed vs unsigned).
  for (uint32_t i = 0; i < 4 * TE; i++) {
    mm_a[i] = static_cast<uint8_t>((i * 29 + 0x83) & 0xFF);
    mm_b[i] = static_cast<uint8_t>((i * 43 + 0x95) & 0xFF);
  }
  for (uint32_t i = 0; i < TE * TE; i++) {
    mm_c_init[i] = 1000u + i * 7u;
  }

  // 1a. vtmmu_mt0 with full tile and tk=4 (KMAX=4).
  mm_init_mode = 0;
  mm_tm        = TE;
  mm_tn        = TE;
  mm_tk        = 4;
  vtmmu_mt0();

  // 1b. vtmmu_mt4 with preload (vtmv.t.v) and tk=2.
  mm_init_mode = 1;
  mm_tm        = TE;
  mm_tn        = TE;
  mm_tk        = 2;
  vtmmu_mt4();

  // 1c. vtmms_mt0 with preload, signed A, and partial tail (tm=5, tn=7, tk=3).
  mm_init_mode = 1;
  mm_tm        = 5;
  mm_tn        = 7;
  mm_tk        = 3;
  vtmms_mt0();

  // 1d. vtmmu and vtmms with altfmt=1 (uint8 x int8 and int8 x int8).
  mm_init_mode = 1;
  mm_tm        = 12;
  mm_tn        = 10;
  mm_tk        = 4;
  RunIntCase<0, false>(kVtypeSew8Lmul1 | 0x100u);
  RunIntCase<4, true>(kVtypeSew8Lmul1 | 0x100u);

  // 2. BF16 matmul inputs: exact normal BF16 values with positive/negative signs.
  uint16_t *a_bf16 = reinterpret_cast<uint16_t *>(mm_a);
  uint16_t *b_bf16 = reinterpret_cast<uint16_t *>(mm_b);
  for (uint32_t i = 0; i < 2 * TE; i++) {
    uint16_t sign_a = (i & 1u) ? 0x8000u : 0x0000u;
    uint16_t sign_b = (i & 2u) ? 0x8000u : 0x0000u;
    a_bf16[i]       = static_cast<uint16_t>(sign_a | 0x3F80u | ((i & 7u) << 4));
    b_bf16[i]       = static_cast<uint16_t>(sign_b | 0x3F80u | (((i * 3u) & 7u) << 4));
  }
  for (uint32_t i = 0; i < TE * TE; i++) {
    mm_c_init[i] = 0x40000000u | ((i & 15u) << 19);
  }

  // 2a. vtfmm_bf16_mt0 full tile, tk=2.
  mm_init_mode = 0;
  mm_tm        = TE;
  mm_tn        = TE;
  mm_tk        = 2;
  vtfmm_bf16_mt0();

  // 2b. vtfmm_bf16_mt8 with preload and partial tail (tm=9, tn=11, tk=1).
  mm_init_mode = 1;
  mm_tm        = 9;
  mm_tn        = 11;
  mm_tk        = 1;
  vtfmm_bf16_mt8();

  // 3. FP32 matmul inputs: exact normal FP32 values with positive/negative signs.
  uint32_t *a_f32 = reinterpret_cast<uint32_t *>(mm_a);
  uint32_t *b_f32 = reinterpret_cast<uint32_t *>(mm_b);
  for (uint32_t i = 0; i < TE; i++) {
    uint32_t sign_a = (i & 2u) ? 0x80000000u : 0x00000000u;
    uint32_t sign_b = (i & 1u) ? 0x80000000u : 0x00000000u;
    a_f32[i]        = sign_a | 0x3F800000u | ((i & 7u) << 20);
    b_f32[i]        = sign_b | 0x3F800000u | (((i * 5u) & 7u) << 20);
  }

  // 3a. vtfmm_mt0 full tile.
  mm_init_mode = 0;
  mm_tm        = TE;
  mm_tn        = TE;
  mm_tk        = 1;
  vtfmm_mt0();

  // 3b. vtfmm_mt8 with preload and partial tail (tm=9, tn=11).
  mm_init_mode = 1;
  mm_tm        = 9;
  mm_tn        = 11;
  mm_tk        = 1;
  vtfmm_mt8();
}

int main(int argc, char **argv) {
  if (mm_impl != nullptr) {
    mm_impl();
  } else {
    RunStandaloneSuite();
  }
  return 0;
}
