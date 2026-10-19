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

#include <cstdint>

#include "vme_test_utils.h"

#define VME_MAX_ALTFMT_CASES 8

struct VmeAltfmtCase {
  uint32_t mtype_value;  // msetmtype rs1
  uint32_t vtype_value;  // msetmtype rs2
};

struct VmeAltfmtResult {
  uint32_t mtype_readback;
  uint32_t vtype_readback;
};

volatile uint32_t vme_altfmt_num_cases __attribute__((section(".data"))) = 8;
volatile VmeAltfmtCase vme_altfmt_inputs[VME_MAX_ALTFMT_CASES] __attribute__((section(".data"))) = {
    {0x4042, 0x108},  // altfmt=1 with valid mtwiden=2 (sew=16) -> mtype=0x4042, vtype=0x1C9
    {0x4042, 0x008},  // altfmt=0 with valid mtwiden=2 (sew=16) -> mtype=0x4042, vtype=0x0C9
    {0x4083, 0x108},  // vill=1 (sew=16, mtwiden=3 -> TEW=64>32) -> mtype=0, vtype=0x80000000
    {0x0000, 0x108},  // unconfigured (mtwiden=0) preserves altfmt -> mtype=0, vtype=0x108
};
VmeAltfmtResult vme_altfmt_results[VME_MAX_ALTFMT_CASES] __attribute__((section(".data"))) = {};

int main(int argc, char **argv) {
  // Cases 0-3: Table-driven msetmtype configuration and CSR readback.
  for (uint32_t i = 0; i < 4; i++) {
    uint32_t mtype_in = vme_altfmt_inputs[i].mtype_value;
    uint32_t vtype_in = vme_altfmt_inputs[i].vtype_value;
    uint32_t mt_out, vt_out;
    asm volatile(
        ".insn r 0b1010111, 0b111, 0b1000010, x0, %[mtype_in], %[vtype_in]\n"  // msetmtype
        "csrr %[mt_out], 0xC23\n"                                              // csrr mtype
        "csrr %[vt_out], vtype\n"
        : [mt_out] "=&r"(mt_out), [vt_out] "=r"(vt_out)
        : [mtype_in] "r"(mtype_in), [vtype_in] "r"(vtype_in)
        : "vl", "vtype");
    vme_altfmt_results[i].mtype_readback = mt_out;
    vme_altfmt_results[i].vtype_readback = vt_out;
  }

  // Case 4: Context save/restore of vill=1 state via csrr + msetmtype.
  // First trigger vill=1 via an unsupported TEW=64 configuration, save mtype
  // and vtype with csrr, clobber CSRs with a valid configuration, and restore
  // the saved context with msetmtype.
  {
    uint32_t vill_mtype  = 0x4083;
    uint32_t valid_mtype = 0x4042;
    uint32_t vtype_in    = 0x108;
    uint32_t saved_mt, saved_vt, mt_out, vt_out;
    asm volatile(
        ".insn r 0b1010111, 0b111, 0b1000010, x0, %[vill_mtype], %[vtype_in]\n"   // msetmtype
                                                                                  // (vill=1)
        "csrr %[saved_mt], 0xC23\n"                                               // save mtype
        "csrr %[saved_vt], vtype\n"                                               // save vtype
        ".insn r 0b1010111, 0b111, 0b1000010, x0, %[valid_mtype], %[vtype_in]\n"  // clobber with
                                                                                  // valid
        ".insn r 0b1010111, 0b111, 0b1000010, x0, %[saved_mt], %[saved_vt]\n"     // restore via
                                                                                  // msetmtype
        "csrr %[mt_out], 0xC23\n"
        "csrr %[vt_out], vtype\n"
        : [saved_mt] "=&r"(saved_mt), [saved_vt] "=&r"(saved_vt), [mt_out] "=&r"(mt_out),
          [vt_out] "=r"(vt_out)
        : [vill_mtype] "r"(vill_mtype), [valid_mtype] "r"(valid_mtype), [vtype_in] "r"(vtype_in)
        : "vl", "vtype");
    vme_altfmt_results[4].mtype_readback = mt_out;
    vme_altfmt_results[4].vtype_readback = vt_out;
  }

  // Case 5: Context save/restore of altfmt=1 state via csrr + vsetvl.
  // Configure valid altfmt=1 (sew=16), save vtype and vl with csrr, execute a
  // standard vsetvli that changes vtype (clearing altfmt), and restore the
  // saved vtype and vl using vsetvl.
  {
    uint32_t valid_mtype = 0x4042;
    uint32_t vtype_in    = 0x108;
    uint32_t saved_vt, saved_vl, mt_out, vt_out;
    asm volatile(
        ".insn r 0b1010111, 0b111, 0b1000010, x0, %[valid_mtype], %[vtype_in]\n"  // msetmtype
        "csrr %[saved_vt], vtype\n"                                               // save vtype
        "csrr %[saved_vl], vl\n"                                                  // save vl
        "vsetvli zero, zero, e32, m1, ta, ma\n"                                   // clobber vtype
        "vsetvl zero, %[saved_vl], %[saved_vt]\n"  // restore via vsetvl
        "csrr %[mt_out], 0xC23\n"
        "csrr %[vt_out], vtype\n"
        : [saved_vt] "=&r"(saved_vt), [saved_vl] "=&r"(saved_vl), [mt_out] "=&r"(mt_out),
          [vt_out] "=r"(vt_out)
        : [valid_mtype] "r"(valid_mtype), [vtype_in] "r"(vtype_in)
        : "vl", "vtype");
    vme_altfmt_results[5].mtype_readback = mt_out;
    vme_altfmt_results[5].vtype_readback = vt_out;
  }

  // Case 6: vsetvli with zimm[8] (altfmt=1) set (zimm11 = 0x1C9: altfmt=1,
  // vma=1, vta=1, vsew=16, vlmul=2). First clear altfmt with e32, m1, then
  // execute vsetvli zero, a0, 0x1c9.
  {
    uint32_t avl = 8;
    uint32_t mt_out, vt_out;
    asm volatile(
        "vsetvli zero, zero, e32, m1, ta, ma\n"
        ".insn i 0x57, 0x7, x0, %[avl], 0x1c9\n"
        "csrr %[mt_out], 0xC23\n"
        "csrr %[vt_out], vtype\n"
        : [mt_out] "=&r"(mt_out), [vt_out] "=r"(vt_out)
        : [avl] "r"(avl)
        : "vl", "vtype");
    vme_altfmt_results[6].mtype_readback = mt_out;
    vme_altfmt_results[6].vtype_readback = vt_out;
  }

  // Case 7: vsetivli with zimm[8] (altfmt=1) set (uimm5 = 8, zimm10 = 0x1C9:
  // altfmt=1, vma=1, vta=1, vsew=16, vlmul=2). First clear altfmt with e32, m1,
  // then execute vsetivli zero, 8, 0x1c9 (encoding 0xdc947057).
  {
    uint32_t mt_out, vt_out;
    asm volatile(
        "vsetvli zero, zero, e32, m1, ta, ma\n"
        ".word 0xdc947057\n"
        "csrr %[mt_out], 0xC23\n"
        "csrr %[vt_out], vtype\n"
        : [mt_out] "=&r"(mt_out), [vt_out] "=r"(vt_out)
        :
        : "vl", "vtype");
    vme_altfmt_results[7].mtype_readback = mt_out;
    vme_altfmt_results[7].vtype_readback = vt_out;
  }

  return 0;
}
