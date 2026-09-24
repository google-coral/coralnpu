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
      // Setup operands for msetmtype
      // x6 (mtype): tm=16 (bit 14=1), tk=2 (bit 6:5=2), mtwiden=2 (bit 1:0=2) => 0x4042
      // x9 (vtype): altfmt=1 (bit 8=1), SEW=16 (bits 5:3=1), LMUL=1 (bits 2:0=0) => 0x108
      "lui   x6, 0x4 \n"
      "addi  x6, x6, 0x42 \n"     // x6 = 0x00004042
      "addi  x9, zero, 0x108 \n"  // x9 = 0x00000108
      ".word 0x82937057 \n"       // msetmtype x6, x9

      // Set tn/vl = 4
      "addi  x10, zero, 4 \n"
      ".word 0x840575D7 \n"  // msettn x11, x10

      // Set tm = 4
      "addi  x14, zero, 4 \n"
      ".word 0x841776D7 \n"  // msettm x13, x14

      // Set tk = 2
      "addi  x16, zero, 2 \n"
      ".word 0x842877D7 \n"  // msettk x15, x16

      // vtzero mt0
      ".word 0x43E06057 \n"  // vtzero mt0

      // Vector operand setup
      ".word 0x5E00B057 \n"  // vmv.v.i v0, 1
      ".word 0x5E00B257 \n"  // vmv.v.i v4, 1
      ".word 0x5E0FB157 \n"  // vmv.v.i v2, -1
      ".word 0x5E0FB357 \n"  // vmv.v.i v6, -1

      // First matrix multiply
      ".word 0xF2010077 \n"  // vtmmu.tvv mt0, v0, v2

      // Second vector operand update
      ".word 0x5E013057 \n"  // vmv.v.i v0, 2
      ".word 0x5E01B257 \n"  // vmv.v.i v4, 3

      // Second matrix multiply
      ".word 0xF2010077 \n"  // vtmmu.tvv mt0, v0, v2

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
