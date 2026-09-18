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
//   vtfmm.tvv  - fp32  x fp32  -> fp32  tile accumulate
// plus vtzero and the register-to-register tile moves vtmv.t.v / vtmv.v.t.
// Tile state is only ever accessed register-to-register (no vtle/vtse tile
// load/store); ordinary vle/vse stage the data between DTCM and the vector
// registers so the cocotb harness can supply inputs and check outputs.
//
// The harness writes the mm_* globals, points `mm_impl` at one of the case
// runners below, and runs to halt once per case (vcpop_test.cc pattern).
//
// Known implementation gaps deliberately not covered here: vtype.altfmt is
// not settable, so the BF16 matmul (vtfmm.alt.tvv) and the signed-B int8
// variants are unreachable; mtype.tk is a 2-bit field, so the spec's KMAX=4
// four-element dot product cannot be configured (tk is 1..3 here).

#include <cstdint>

#include "vme_test_utils.h"

// -----------------------------------------------------------------------------
// Geometry (VLEN=128): TE=16, 16x16 tiles, TEW=32.
// -----------------------------------------------------------------------------
#define TE 16

// vtype values (vma[7] | vta[6] | vsew[5:3] | vlmul[2:0]).
static constexpr uint32_t kVtypeSew8Lmul1  = 0xC0;  // ta/ma, SEW8,  LMUL1
static constexpr uint32_t kVtypeSew32Lmul4 = 0xD2;  // ta/ma, SEW32, LMUL4

// -----------------------------------------------------------------------------
// Zvt instruction words, emitted via .word since they use vector-register
// operands GAS cannot name for these encodings. Fixed register assignment:
//   v4..v7   staging group for tile-row moves
//   v8..     A operand (int8 rows at v8/v10/v12/v14: the spec's 8/KMAX row
//            spacing; fp32 single row spans v8..v11)
//   v16..    B operand (int8 rows at v16/v18/v20/v22; fp32 row v16..v19)
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
// as 16 fp32 values (single row) for the fp case.
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
template <uint32_t TILE>
static void InitAccumulator() {
  ConfigureTileMoves();
  if (mm_init_mode == 0) {
    Vtzero<TILE>();
  } else {
    for (uint32_t i = 0; i < TE; i++) {
      const uint32_t *row = &mm_c_init[i * TE];
      asm volatile("vle32.v v4, (%0)" : : "r"(row) : "v4", "v5", "v6", "v7", "memory");
      VtmvTV(Tss(TILE, i));
    }
  }
}

// Read the accumulator tile back into mm_out, one row per vtmv.v.t.
template <uint32_t TILE>
static void ReadbackTile() {
  ConfigureTileMoves();
  for (uint32_t i = 0; i < TE; i++) {
    uint32_t *row = &mm_out[i * TE];
    VtmvVT(Tss(TILE, i));
    asm volatile("vse32.v v4, (%0)" : : "r"(row) : "memory");
  }
}

template <uint32_t TILE, bool SIGNED_A>
static void RunIntCase() {
  InitAccumulator<TILE>();

  // int8 matmul shape: SEW8/LMUL1, mtwiden=3 (TWIDEN=4). Load all four
  // A/B row slots with vl=16; rows >= tk are masked off by the hardware.
  vme_msetmtype(MtypeValue(/*tm=*/TE, mm_tk, /*mtwiden=*/3), kVtypeSew8Lmul1);
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

  asm volatile(".word %0" : : "i"(ZvtMatmulIntWord(TILE, SIGNED_A)) : "memory");

  ReadbackTile<TILE>();
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

  ReadbackTile<TILE>();
}

extern "C" {
__attribute__((used, retain)) void vtmmu_mt0() { RunIntCase<0, false>(); }
__attribute__((used, retain)) void vtmmu_mt4() { RunIntCase<4, false>(); }
__attribute__((used, retain)) void vtmms_mt0() { RunIntCase<0, true>(); }
__attribute__((used, retain)) void vtfmm_mt0() { RunFpCase<0>(); }
__attribute__((used, retain)) void vtfmm_mt8() { RunFpCase<8>(); }
}

// Case selector, overwritten by the harness before each run.
void (*mm_impl)() __attribute__((section(".data"))) = vtmmu_mt0;

int main(int argc, char **argv) {
  mm_impl();
  return 0;
}
