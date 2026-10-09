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

VmeMsetResult vme_results[VME_MAX_CASES] __attribute__((section(".data"))) = {};
uint32_t vme_msetmtypei_result __attribute__((section(".data")))           = 0;

int main(int argc, char **argv) {
  // Each row sets mtype + vtype via msetmtype, then exercises msettn/m/k with
  // the per-row operand and snapshots mtype after the m/k updates.
  for (uint32_t i = 0; i < vme_num_cases; i++) {
    vme_msetmtype(vme_inputs[i].mtype_value, vme_inputs[i].vtype_value);
    vme_results[i].mtype_after_msetmtype = vme_read_mtype();

    vme_results[i].rd_after_msettn = vme_msettn(vme_inputs[i].msettn_avl);

    vme_results[i].rd_after_msettm    = vme_msettm(vme_inputs[i].msettm_arg);
    vme_results[i].mtype_after_msettm = vme_read_mtype();

    vme_results[i].rd_after_msettk    = vme_msettk(vme_inputs[i].msettk_arg);
    vme_results[i].mtype_after_msettk = vme_read_mtype();
  }

  // The msetmtypei variant has all operands encoded as immediates, so it can't
  // be parameterized from memory. Run the single hard-coded version and snap
  // its mtype readback so the harness can still verify the encoding path.
  vme_msetmtypei_mtwiden3_sew8();
  vme_msetmtypei_result = vme_read_mtype();

  return 0;
}
