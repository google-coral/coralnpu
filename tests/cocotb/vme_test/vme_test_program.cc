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

// Volatile so the compiler does not constant-fold the zero initializer back
// in (the cocotb harness writes these slots before execute_from).
volatile uint32_t vme_num_cases __attribute__((section(".data")))                = 0;
volatile VmeMsetCase vme_inputs[VME_MAX_CASES] __attribute__((section(".data"))) = {};

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
