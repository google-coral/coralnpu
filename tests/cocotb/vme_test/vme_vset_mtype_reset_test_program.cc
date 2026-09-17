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
// Directed test verifying that vector configuration instructions
// (vsetvl, vsetvli, vsetivli) clear the mtype CSR to zero per
// matrix extension specification.

#include <cstdint>

#include "vme_test_utils.h"

struct VmeResetMtypeResult {
  uint32_t mtype_configured;
  uint32_t mtype_after_vset;
  uint32_t vtype_after_vset;
  uint32_t vl_after_vset;
};

// Results recorded for:
// 0: vsetvli
// 1: vsetivli
// 2: vsetvl
VmeResetMtypeResult vme_vset_results[3] __attribute__((section(".data"))) = {};

int main(int argc, char **argv) {
  // 1. Configure matrix state with non-zero mtype:
  //    tm = 8, tk = 2, mtwiden = 3 -> mtype = 0x2063
  //    vtype = SEW8, LMUL1
  vme_msetmtype(0x2063, 0x00);
  (void)vme_msettm(8);
  (void)vme_msettk(2);
  vme_vset_results[0].mtype_configured = vme_read_mtype();

  // Execute vsetvli x10, x0, e8, m1, ta, ma
  // (encoding: 0x0C007557 -> rd=x10, rs1=x0, e8, m1, ta, ma)
  uint32_t vl_0;
  asm volatile("vsetvli %0, x0, e8, m1, ta, ma" : "=r"(vl_0));
  vme_vset_results[0].vl_after_vset    = vl_0;
  vme_vset_results[0].mtype_after_vset = vme_read_mtype();
  uint32_t vt_0;
  asm volatile("csrr %0, vtype" : "=r"(vt_0));
  vme_vset_results[0].vtype_after_vset = vt_0;

  // 2. Re-configure matrix state with non-zero mtype
  vme_msetmtype(0x2063, 0x00);
  (void)vme_msettm(8);
  (void)vme_msettk(2);
  vme_vset_results[1].mtype_configured = vme_read_mtype();

  // Execute vsetivli x10, 4, e8, m1, ta, ma
  uint32_t vl_1;
  asm volatile("vsetivli %0, 4, e8, m1, ta, ma" : "=r"(vl_1));
  vme_vset_results[1].vl_after_vset    = vl_1;
  vme_vset_results[1].mtype_after_vset = vme_read_mtype();
  uint32_t vt_1;
  asm volatile("csrr %0, vtype" : "=r"(vt_1));
  vme_vset_results[1].vtype_after_vset = vt_1;

  // 3. Re-configure matrix state with non-zero mtype
  vme_msetmtype(0x2063, 0x00);
  (void)vme_msettm(8);
  (void)vme_msettk(2);
  vme_vset_results[2].mtype_configured = vme_read_mtype();

  // Execute vsetvl x10, x11, x12
  // where x11 (avl) = 16, x12 (vtype) = e8, m1, ta, ma (0xC0)
  uint32_t avl_in   = 16;
  uint32_t vtype_in = 0xC0;
  uint32_t vl_2;
  asm volatile("vsetvl %0, %1, %2" : "=r"(vl_2) : "r"(avl_in), "r"(vtype_in));
  vme_vset_results[2].vl_after_vset    = vl_2;
  vme_vset_results[2].mtype_after_vset = vme_read_mtype();
  uint32_t vt_2;
  asm volatile("csrr %0, vtype" : "=r"(vt_2));
  vme_vset_results[2].vtype_after_vset = vt_2;

  return 0;
}
