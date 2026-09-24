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

#include <stdint.h>

uint16_t load_src[4] __attribute__((section(".data"))) = {0x00a4, 0x0088, 0x1234, 0x5678};

uint16_t poison[4] __attribute__((section(".data"))) = {0xdead, 0xbeef, 0xdead, 0xbeef};

uint16_t out_a[4] __attribute__((section(".data")))    = {0, 0, 0, 0};
uint16_t out_b[4] __attribute__((section(".data")))    = {0, 0, 0, 0};
uint16_t out_c[4] __attribute__((section(".data")))    = {0, 0, 0, 0};
uint16_t out_ctrl[4] __attribute__((section(".data"))) = {0, 0, 0, 0};

#define SETUP_VSTART2(VD)        \
  ".rept 8\n\t"                  \
  "vle16.v v28, (%[poison])\n\t" \
  ".endr\n\t"                    \
  "li      t0, 0x7fc07fc0\n\t"   \
  "vmv.v.x " VD                  \
  ", t0\n\t"                     \
  "vmv.v.i v1,  0\n\t"           \
  "vmv.v.i v18, 0\n\t"           \
  "vmv.v.i v19, 0\n\t"           \
  ".rept 16\n\t"                 \
  "nop\n\t"                      \
  ".endr\n\t"                    \
  "li      t0, 2\n\t"            \
  "csrw    vstart, t0\n\t"       \
  "addi    t1, zero, 1\n\t"      \
  "addi    t2, zero, 2\n\t"      \
  "addi    t3, zero, 3\n\t"      \
  "addi    t4, zero, 4\n\t"

#define DRAIN    \
  ".rept 16\n\t" \
  "nop\n\t"      \
  ".endr\n\t"

void vstart_dual_dispatch_lsu_test() {
  asm volatile(
      "vsetivli x0, 4, e32, m1, ta, ma\n\t"

      // ----------------------------------------------------------------
      //   lane 0 = vector ALU, lane 1 = scalar, lane 2 = vector load.
      // ----------------------------------------------------------------
      SETUP_VSTART2("v29")
      ".p2align 4\n\t"
      "vxor.vv v1, v19, v18\n\t"    // lane 0: resets vstart to 0
      "addi    t1, t1, 1\n\t"       // lane 1: scalar
      "vle16.v v29, (%[src])\n\t"   // lane 2: must run with vstart == 0
      "nop\n\t"                     // lane 3
      DRAIN
      "vse16.v v29, (%[out_a])\n\t"
      DRAIN

      // ----------------------------------------------------------------
      //   lane 0 = vector ALU, lane 1 = vector load.
      // ----------------------------------------------------------------
      SETUP_VSTART2("v27")
      ".p2align 4\n\t"
      "vxor.vv v1, v19, v18\n\t"    // lane 0: resets vstart to 0
      "vle16.v v27, (%[src])\n\t"   // lane 1: must run with vstart == 0
      "nop\n\t"
      "nop\n\t"
      DRAIN
      "vse16.v v27, (%[out_b])\n\t"
      DRAIN

      // ----------------------------------------------------------------
      //   lane 2 = vector ALU, lane 3 = vector load.
      // ----------------------------------------------------------------
      SETUP_VSTART2("v26")
      ".p2align 4\n\t"
      "nop\n\t"                     // lane 0
      "nop\n\t"                     // lane 1
      "vxor.vv v1, v19, v18\n\t"    // lane 2: resets vstart to 0
      "vle16.v v26, (%[src])\n\t"   // lane 3: must run with vstart == 0
      DRAIN
      "vse16.v v26, (%[out_c])\n\t"
      DRAIN

      // ----------------------------------------------------------------
      // Control: scalar op + vector load co-dispatched. A scalar
      // instruction does NOT reset vstart, so the load must still start at
      // element 2.
      // ----------------------------------------------------------------
      SETUP_VSTART2("v25")
      ".p2align 4\n\t"
      "addi    t1, t1, 1\n\t"       // lane 0: scalar, does NOT reset vstart
      "vle16.v v25, (%[src])\n\t"   // lane 1: must run with vstart == 2
      "nop\n\t"
      "nop\n\t"
      DRAIN
      "vse16.v v25, (%[out_ctrl])\n\t"
      DRAIN
      :
      : [src] "r"(load_src), [poison] "r"(poison), [out_a] "r"(out_a),
        [out_b] "r"(out_b), [out_c] "r"(out_c), [out_ctrl] "r"(out_ctrl)
      : "t0", "t1", "t2", "t3", "t4", "v1", "v18", "v19", "v25", "v26", "v27",
        "v28", "v29", "vl", "vtype", "memory");
}

int main(int argc, char **argv) {
  vstart_dual_dispatch_lsu_test();
  return 0;
}
