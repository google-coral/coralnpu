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
// Smoke test for the VME (Zvt) non-tile state and mset* configuration
// instructions. The cocotb harness writes a table of input operands into
// `vme_inputs` before execution starts; this program iterates over the table,
// runs msetmtype/msettn/msettm/msettk on each row, and records the resulting
// mtype CSR snapshot and rd writebacks into the matching `vme_results` row.
// The harness also reads `vme_msetmtypei_result` to verify the single,
// immediate-encoded msetmtypei variant.

#include <cstdint>

#include "vme_test_utils.h"

// -----------------------------------------------------------------------------
// Input table (written by the cocotb harness) and result table (read back).
// -----------------------------------------------------------------------------

// Maximum number of (input, result) rows the harness may exercise. Sized
// generously; the harness writes exactly the rows it wants and the program
// iterates `vme_num_cases` of them.
#define VME_MAX_CASES 8

struct VmeMsetCase {
  uint32_t mtype_value;  // msetmtype rs1
  uint32_t vtype_value;  // msetmtype rs2
  uint32_t msettn_avl;   // msettn   rs1
  uint32_t msettm_arg;   // msettm   rs1
  uint32_t msettk_arg;   // msettk   rs1
};

struct VmeMsetResult {
  uint32_t mtype_after_msetmtype;
  uint32_t rd_after_msettn;
  uint32_t rd_after_msettm;
  uint32_t mtype_after_msettm;
  uint32_t rd_after_msettk;
  uint32_t mtype_after_msettk;
};

// Volatile so the compiler does not constant-fold the initializer back
// in (the cocotb harness overwrites these slots before execute_from).
// Default-initialized with the mset* and clamping cases so standalone UVM
// co-simulation exercises all cases without requiring a cocotb host.
volatile uint32_t vme_num_cases __attribute__((section(".data")))                = 8;
volatile VmeMsetCase vme_inputs[VME_MAX_CASES] __attribute__((section(".data"))) = {
    {MtypeValue(1, 1, 1), 0x00, 16, 5, 2},         // SEW8/LMUL1 basic
    {MtypeValue(3, 2, 2), 0x08, 100, 0x3FFF, 10},  // SEW16/mtwiden=2 derives LMUL2 + clamps
    {0x2021, 0x10, 8, 8, 1},                       // SEW32/mtwiden=1 derives LMUL4, avl=8
    {0x2021, 0x10, 100, 8, 1},                     // SEW32/mtwiden=1 derives LMUL4, avl=100->16
    {0x0000, 0x10, 100, 0, 0},                     // Unconfigured mtwiden=0 -> mtype=0, vlmax=4
    {0x4083, 0x00, 16, 16, 4},                     // SEW8/mtwiden=3, msettk(4)->4
    {0x4083, 0x00, 16, 16, 7},                     // SEW8/mtwiden=3, msettk(7)->clamped to 4
    {0x4083, 0x00, 16, 32, 4},                     // SEW8/mtwiden=3, msettm(32)->clamped to 16
};

VmeMsetResult vme_results[VME_MAX_CASES] __attribute__((section(".data")))     = {};
uint32_t vme_msetmtypei_result __attribute__((section(".data")))               = 0;
uint32_t vme_msetmtypei_vtype_result __attribute__((section(".data")))         = 0;
uint32_t vme_msetmtypei_altfmt1_result __attribute__((section(".data")))       = 0;
uint32_t vme_msetmtypei_altfmt1_vtype_result __attribute__((section(".data"))) = 0;
uint32_t vme_vsetvl_mtype_result __attribute__((section(".data")))             = 0xFFFFFFFF;

struct VmeMsettnMsettypeResult {
  // Issue 1: msetmtype / msetmtypei must not write back vl to XRF.
  uint32_t msetmtype_rd_probe;
  uint32_t msetmtype_vl_csr;
  uint32_t msetmtype_mtype_csr;
  uint32_t msetmtypei_rd_probe;
  uint32_t msetmtypei_vl_csr;
  uint32_t msetmtypei_mtype_csr;

  // Issue 2a: msettn when mtwiden == 0 (SEW8, LMUL1 -> VLMAX = 16).
  uint32_t mtwiden0_rd_x0_rd;
  uint32_t mtwiden0_rd_x0_vl;
  uint32_t mtwiden0_x0_x0_vl_before;
  uint32_t mtwiden0_x0_x0_vl_after;

  // Issue 2b: msettn when mtwiden == 0 (SEW8, LMUL2 -> VLMAX = 32 > ETE = 16).
  uint32_t mtwiden0_lmul2_rs1_24_rd;
  uint32_t mtwiden0_lmul2_rs1_24_vl;
  uint32_t mtwiden0_lmul2_rd_x0_rd;
  uint32_t mtwiden0_lmul2_rd_x0_vl;

  // Issue 2c: msettn when mtwiden != 0 (mtwiden = 1, SEW8 -> LMUL*EVE = 16, ETE = 16).
  uint32_t mtwiden1_rs1_24_rd;
  uint32_t mtwiden1_rs1_24_vl;
  uint32_t mtwiden1_rd_x0_rd;
  uint32_t mtwiden1_rd_x0_vl;
  uint32_t mtwiden1_x0_x0_vl_after;

  // Issue 2d: msettn when mtwiden == 0 and vtype.vill == 1.
  uint32_t mtwiden0_vill_rd;
  uint32_t mtwiden0_vill_vl;
  uint32_t mtwiden0_vill_vtype;
};

volatile uint32_t vme_run_msettn_msettype __attribute__((section(".data")))          = 0;
VmeMsettnMsettypeResult vme_msettn_msettype_result __attribute__((section(".data"))) = {};

int main(int argc, char **argv) {
  if (vme_run_msettn_msettype) {
    // 1. Verify msetmtype and msetmtypei do not write back vl to XRF.
    vme_msetmtype(MtypeValue(8, 2, 1), 0x00);
    (void)vme_msettn(8);
    vme_msettn_msettype_result.msetmtype_rd_probe =
        vme_msetmtype_probe_rd(MtypeValue(4, 1, 1), 0x00, 0xDEADBEEFu);
    vme_msettn_msettype_result.msetmtype_vl_csr    = vme_read_vl();
    vme_msettn_msettype_result.msetmtype_mtype_csr = vme_read_mtype();

    (void)vme_msettn(8);
    vme_msettn_msettype_result.msetmtypei_rd_probe =
        vme_msetmtypei_mtwiden3_sew8_probe_rd(0xCAFEBABEu);
    vme_msettn_msettype_result.msetmtypei_vl_csr    = vme_read_vl();
    vme_msettn_msettype_result.msetmtypei_mtype_csr = vme_read_mtype();

    // 2a. msettn when mtwiden == 0 (SEW8, LMUL1 -> VLMAX = 16).
    vme_msetmtype(0x0000, 0x00);
    vme_msettn_msettype_result.mtwiden0_rd_x0_rd = vme_msettn_rd_x0();
    vme_msettn_msettype_result.mtwiden0_rd_x0_vl = vme_read_vl();

    (void)vme_msettn(7);
    vme_msettn_msettype_result.mtwiden0_x0_x0_vl_before = vme_read_vl();
    vme_msettn_x0_x0();
    vme_msettn_msettype_result.mtwiden0_x0_x0_vl_after = vme_read_vl();

    // 2b. msettn when mtwiden == 0 (SEW8, LMUL2 -> VLMAX = 32 > ETE = 16).
    vme_msetmtype(0x0000, 0x01);
    vme_msettn_msettype_result.mtwiden0_lmul2_rs1_24_rd = vme_msettn(24);
    vme_msettn_msettype_result.mtwiden0_lmul2_rs1_24_vl = vme_read_vl();
    vme_msettn_msettype_result.mtwiden0_lmul2_rd_x0_rd  = vme_msettn_rd_x0();
    vme_msettn_msettype_result.mtwiden0_lmul2_rd_x0_vl  = vme_read_vl();

    // 2c. msettn when mtwiden != 0 (mtwiden = 1, SEW8 -> LMUL*EVE = 16, ETE = 16).
    vme_msetmtype(MtypeValue(16, 1, 1), 0x01);
    vme_msettn_msettype_result.mtwiden1_rs1_24_rd = vme_msettn(24);
    vme_msettn_msettype_result.mtwiden1_rs1_24_vl = vme_read_vl();
    vme_msettn_msettype_result.mtwiden1_rd_x0_rd  = vme_msettn_rd_x0();
    vme_msettn_msettype_result.mtwiden1_rd_x0_vl  = vme_read_vl();

    (void)vme_msettn(9);
    vme_msettn_x0_x0();
    vme_msettn_msettype_result.mtwiden1_x0_x0_vl_after = vme_read_vl();

    // 2d. msettn when mtwiden == 0 and vtype.vill == 1.
    vme_msetmtype(0x0000, 0x38);  // reserved vsew=111 -> vill = 1
    vme_msettn_msettype_result.mtwiden0_vill_rd    = vme_msettn(8);
    vme_msettn_msettype_result.mtwiden0_vill_vl    = vme_read_vl();
    vme_msettn_msettype_result.mtwiden0_vill_vtype = vme_read_vtype();

    return 0;
  }

  // Each row sets mtype + vtype via msetmtype, then exercises msettn/m/k with
  // the per-row operand and snapshots mtype after the m/k updates.
  for (uint32_t i = 0; i < vme_num_cases; i++) {
    vme_msetmtype(vme_inputs[i].mtype_value, vme_inputs[i].vtype_value);
    vme_results[i].mtype_after_msetmtype = vme_read_mtype();

    vme_results[i].rd_after_msettn = vme_msettn(vme_inputs[i].msettn_avl);

    if ((vme_inputs[i].mtype_value & 3) != 0) {
      vme_results[i].rd_after_msettm    = vme_msettm(vme_inputs[i].msettm_arg);
      vme_results[i].mtype_after_msettm = vme_read_mtype();

      vme_results[i].rd_after_msettk    = vme_msettk(vme_inputs[i].msettk_arg);
      vme_results[i].mtype_after_msettk = vme_read_mtype();
    } else {
      vme_results[i].rd_after_msettm    = 0;
      vme_results[i].mtype_after_msettm = 0;
      vme_results[i].rd_after_msettk    = 0;
      vme_results[i].mtype_after_msettk = 0;
    }
  }

  // The msetmtypei variant has all operands encoded as immediates, so it can't
  // be parameterized from memory. Run the single hard-coded version and snap
  // its mtype and vtype readback so the harness can verify the encoding path.
  vme_msetmtypei_mtwiden3_sew8();
  vme_msetmtypei_result       = vme_read_mtype();
  vme_msetmtypei_vtype_result = vme_read_vtype();

  // Test altfmt=1 variant
  vme_msetmtypei_altfmt1_mtwiden3_sew8();
  vme_msetmtypei_altfmt1_result       = vme_read_mtype();
  vme_msetmtypei_altfmt1_vtype_result = vme_read_vtype();

  // Test that vsetvli clears mtype to 0
  uint32_t vl_discard;
  asm volatile("vsetvli %0, zero, e8, m1, ta, ma" : "=r"(vl_discard));
  vme_vsetvl_mtype_result = vme_read_mtype();

  return 0;
}
