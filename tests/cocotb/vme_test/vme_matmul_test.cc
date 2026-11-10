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
//   vtmmu.tvv  - uint8  x [u]int8  -> int32 tile accumulate (SEW=8,  TWIDEN=4)
//              - uint16 x [u]int16 -> int32 tile accumulate (SEW=16, TWIDEN=2)
//   vtmms.tvv  - int8   x [u]int8  -> int32 tile accumulate (SEW=8,  TWIDEN=4)
//              - int16  x [u]int16 -> int32 tile accumulate (SEW=16, TWIDEN=2)
//   vtfmm.alt  - bf16   x bf16     -> fp32  tile accumulate
//   vtfmm.tvv  - fp32   x fp32     -> fp32  tile accumulate
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
static constexpr uint32_t kVtypeSew8Lmul1  = 0xC0;   // ta/ma, SEW8,  LMUL1
static constexpr uint32_t kVtypeSew16Lmul2 = 0x0C9;  // ta/ma, SEW16, LMUL2 (altfmt=0)
static constexpr uint32_t kVtypeSew32Lmul4 = 0xD2;   // ta/ma, SEW32, LMUL4
// altfmt[8] | ta/ma, SEW16, LMUL2 (bf16 and int16 signed-B matmul).
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

// INT16 matmul shape: SEW16/LMUL2, mtwiden=2 (TWIDEN=2, KMAX=2).
// Exercises both Half-Low (v8/v16) and Half-Hi (v2/v18, v10/v26) bases.
// PreloadAccumulator / ReadbackTile stage through v4..v7 outside the matmul
// window, so v2..v3 / v6..v7 can safely hold A while the matmul executes.
template <uint32_t TILE, uint32_t VS2, uint32_t VS1, bool SIGNED_A, bool SIGNED_B>
static void RunInt16Case() {
  InitAccumulator<TILE>();

  using HalfTileRow __attribute__((may_alias)) = const uint16_t[TE];
  HalfTileRow &a_row0                          = *reinterpret_cast<HalfTileRow *>(&mm_a[0]);
  HalfTileRow &a_row1                          = *reinterpret_cast<HalfTileRow *>(&mm_a[2 * TE]);
  HalfTileRow &b_row0                          = *reinterpret_cast<HalfTileRow *>(&mm_b[0]);
  HalfTileRow &b_row1                          = *reinterpret_cast<HalfTileRow *>(&mm_b[2 * TE]);

  const uint32_t vtype      = SIGNED_B ? kVtypeSew16Lmul2Altfmt : kVtypeSew16Lmul2;
  const uint32_t mtype_init = MtypeValue(/*tm=*/TE, mm_tk, /*mtwiden=*/2);
  const uint32_t tm_val     = mm_tm;
  const uint32_t tn_val     = mm_tn;
  const uint32_t load_avl   = TE;
  constexpr uint32_t kInsn =
      ZvtWord(0x3C, VS2, VS1, /*funct3=*/0, (TILE << 1) | (SIGNED_A ? 1u : 0u), kZvtOpcodeOpVe);

  // Configure mtype/vtype/tm/vl, load both K-rows of A and B (SEW=16, LMUL=2),
  // set matmul tn, and issue vtmmu.tvv / vtmms.tvv in a single block so
  // incoming vl/vtype dependencies are broken in-block and LMUL=2 vector groups
  // do not cross inline-asm boundaries. Marked volatile because tile
  // accumulator mt<TILE>, mtype, and mstatus.MS cannot be named in constraints.
#define EMIT_INT16_MATMUL(a0_lo, a0_hi, a1_lo, a1_hi, b0_lo, b0_hi, b1_lo, b1_hi)                 \
  asm volatile(                                                                                   \
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[mtype], %[vtype]\n"                             \
      ".insn r 0b1010111, 0b111, 0b1000100, x0, %[tm], x1\n"                                      \
      ".insn r 0b1010111, 0b111, 0b1000100, x0, %[load_avl], x0\n"                                \
      "vle16.v " a0_lo                                                                            \
      ", %[a0]\n"                                                                                 \
      "vle16.v " a1_lo                                                                            \
      ", %[a1]\n"                                                                                 \
      "vle16.v " b0_lo                                                                            \
      ", %[b0]\n"                                                                                 \
      "vle16.v " b1_lo                                                                            \
      ", %[b1]\n"                                                                                 \
      ".insn r 0b1010111, 0b111, 0b1000100, x0, %[tn], x0\n"                                      \
      ".word %[insn]\n"                                                                           \
      :                                                                                           \
      : [mtype] "r"(mtype_init), [vtype] "r"(vtype), [tm] "r"(tm_val), [load_avl] "r"(load_avl),  \
        [tn] "r"(tn_val), [a0] "A"(a_row0), [a1] "A"(a_row1), [b0] "A"(b_row0), [b1] "A"(b_row1), \
        [insn] "i"(kInsn)                                                                         \
      : a0_lo, a0_hi, a1_lo, a1_hi, b0_lo, b0_hi, b1_lo, b1_hi, "vl", "vtype")

  if constexpr (VS2 == 2 && VS1 == 18) {
    EMIT_INT16_MATMUL("v2", "v3", "v6", "v7", "v18", "v19", "v22", "v23");
  } else if constexpr (VS2 == 8 && VS1 == 16) {
    EMIT_INT16_MATMUL("v8", "v9", "v12", "v13", "v16", "v17", "v20", "v21");
  } else if constexpr (VS2 == 10 && VS1 == 26) {
    EMIT_INT16_MATMUL("v10", "v11", "v14", "v15", "v26", "v27", "v30", "v31");
  } else {
    static_assert((VS2 == 2 && VS1 == 18) || (VS2 == 8 && VS1 == 16) || (VS2 == 10 && VS1 == 26),
                  "Unsupported INT16 (VS2, VS1) register pair");
  }
#undef EMIT_INT16_MATMUL

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
__attribute__((used, retain)) void vtmmu_i16_u16u16_mt0() {
  RunInt16Case<0, 8, 16, false, false>();
}
__attribute__((used, retain)) void vtmmu_i16_u16s16_mt4() { RunInt16Case<4, 2, 18, false, true>(); }
__attribute__((used, retain)) void vtmms_i16_s16u16_mt8() {
  RunInt16Case<8, 10, 26, true, false>();
}
__attribute__((used, retain)) void vtmms_i16_s16s16_mt12() {
  RunInt16Case<12, 8, 16, true, true>();
}
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

  // 1e. Int16 matmul inputs (signed/unsigned extrema + Half-Hi v2/v18, v10/v26).
  uint16_t *a_i16 = reinterpret_cast<uint16_t *>(mm_a);
  uint16_t *b_i16 = reinterpret_cast<uint16_t *>(mm_b);
  for (uint32_t i = 0; i < 2 * TE; i++) {
    a_i16[i] = static_cast<uint16_t>((i * 4177u + 0x8123u) & 0xFFFFu);
    b_i16[i] = static_cast<uint16_t>((i * 6311u + 0x9457u) & 0xFFFFu);
  }
  a_i16[0]      = 0xFFFFu;
  a_i16[1]      = 0x8000u;
  a_i16[TE]     = 0xFFFFu;
  a_i16[TE + 1] = 0x7FFFu;
  b_i16[0]      = 0xFFFFu;
  b_i16[1]      = 0x8000u;
  b_i16[TE]     = 0xFFFFu;
  b_i16[TE + 1] = 0x7FFFu;

  mm_init_mode = 0;
  mm_tm        = TE;
  mm_tn        = TE;
  mm_tk        = 2;
  vtmmu_i16_u16u16_mt0();

  mm_init_mode = 1;
  mm_tm        = TE;
  mm_tn        = TE;
  mm_tk        = 1;
  vtmmu_i16_u16u16_mt0();

  mm_init_mode = 1;
  mm_tm        = TE;
  mm_tn        = TE;
  mm_tk        = 2;
  vtmmu_i16_u16s16_mt4();

  mm_init_mode = 1;
  mm_tm        = 11;
  mm_tn        = 13;
  mm_tk        = 2;
  vtmms_i16_s16u16_mt8();

  mm_init_mode = 1;
  mm_tm        = 7;
  mm_tn        = 9;
  mm_tk        = 1;
  vtmms_i16_s16s16_mt12();

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
