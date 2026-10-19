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

// Directed test program verifying mset configuration and matrix multiply sequence:
// 1. msetmtype x6, x9 (with tm=16, tk=2, mtwiden=2, altfmt=1, SEW=16)
// 2. msettn x11, x10 (tn=4)
// 3. msettm x13, x14 (tm=4)
// 4. msettk x15, x16 (tk=2)
// 5. vtzero mt0
// 6. operand setup
// 7. vtmmu.tvv mt0, v0, v2
// 8. operand update
// 9. vtmmu.tvv mt0, v0, v2
// 10. mpause

extern "C" {

__attribute__((noinline)) void run_mset_vtmmu_sequence(void) {
  asm volatile(
      // Part 1: Integer vtmmu.tvv sequence (Zvt §12.1.1.8: SEW=8, TWIDEN=4, KMAX=4)
      // x6 (mtype): tm=16 (bit 14=1), tk=2 (bits 6:5=2), mtwiden=3 (bits 1:0=3) => 0x4043
      // x9 (vtype): altfmt=0, SEW=8 (bits 5:3=0), LMUL=1 (bits 2:0=0) => 0x000
      "lui   x6, 0x4 \n"
      "addi  x6, x6, 0x43 \n"     // x6 = 0x00004043 (tm=16, tk=2, mtwiden=3)
      "addi  x9, zero, 0x000 \n"  // x9 = 0x00000000 (SEW=8)
      ".word 0x84937057 \n"       // msetmtype x6, x9

      // Set tn/vl = 4, tm = 4, tk = 2
      "addi  x10, zero, 4 \n"
      ".word 0x880575D7 \n"  // msettn x11, x10
      "addi  x14, zero, 4 \n"
      ".word 0x881776D7 \n"  // msettm x13, x14
      "addi  x16, zero, 2 \n"
      ".word 0x882877D7 \n"  // msettk x15, x16

      // vtzero mt0
      ".word 0x43E06057 \n"  // vtzero mt0

      // Vector operand setup for SEW=8, KMAX=4 (row spacing = 8/KMAX = 2):
      // A rows in v0, v2; B rows in v8, v10 (vs1 % 8 = 0 < 8/KMAX = 2).
      ".word 0x5E00B057 \n"  // vmv.v.i v0, 1
      ".word 0x5E00B157 \n"  // vmv.v.i v2, 1
      ".word 0x5E013457 \n"  // vmv.v.i v8, 2
      ".word 0x5E01B557 \n"  // vmv.v.i v10, 3

      // First matrix multiply: vtmmu.tvv mt0, v0, v8 (vs2=v0, vs1=v8)
      ".word 0xF2040077 \n"  // vtmmu.tvv mt0, v0, v8

      // Second vector operand update
      ".word 0x5E013057 \n"  // vmv.v.i v0, 2
      ".word 0x5E01B157 \n"  // vmv.v.i v2, 3

      // Second matrix multiply: vtmmu.tvv mt0, v0, v8
      ".word 0xF2040077 \n"  // vtmmu.tvv mt0, v0, v8

      // Read back row 0 of mt0 into v4..v7 (SEW=32, LMUL=4, mtwiden=1)
      "lui   x6, 0x4 \n"
      "addi  x6, x6, 0x21 \n"     // x6 = 0x00004021 (tm=16, tk=1, mtwiden=1)
      "addi  x9, zero, 0x0D2 \n"  // x9 = SEW32, LMUL4, ta, ma
      ".word 0x84937057 \n"       // msetmtype x6, x9
      "addi  x10, zero, 4 \n"
      ".word 0x880575D7 \n"  // msettn x11, x10
      "addi  x10, zero, 0 \n"
      ".word 0x43FA6257 \n"  // vtmv.v.t v4, a0 (row 0 of mt0)

      // Complete
      ".word 0x08000073 \n"  // mpause
      ::
          : "x6", "x9", "x10", "x11", "x13", "x14", "x15", "x16", "memory");
}

int main(int argc, char **argv) {
  run_mset_vtmmu_sequence();
  return 0;
}

}  // extern "C"
