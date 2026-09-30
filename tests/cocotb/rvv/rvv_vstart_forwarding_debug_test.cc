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

extern "C" {

uint32_t test_sel __attribute__((section(".data"))) = 0;

// Control case.
uint16_t load_src[8] __attribute__((section(".data"), aligned(16))) = {
    0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666, 0x7777, 0x8888};
uint16_t ctrl_out[8] __attribute__((section(".data"), aligned(16))) = {};
uint32_t ctrl_vstart __attribute__((section(".data")))              = 0xff;

// Debug-halt cases.
uint16_t dbg_src[4] __attribute__((section(".data")))  = {0x00a4, 0x0088, 0x1234, 0x5678};
uint16_t poison[4] __attribute__((section(".data")))   = {0xdead, 0xbeef, 0xdead, 0xbeef};
uint16_t out_dbg1[4] __attribute__((section(".data"))) = {};
uint16_t out_dbg2[4] __attribute__((section(".data"))) = {};

#define LOOP_ITERS 96
uint32_t loop_iters __attribute__((section(".data")))              = LOOP_ITERS;
uint16_t out_loop[LOOP_ITERS][4] __attribute__((section(".data"))) = {};

}  // extern "C"

// Fill v29 with 0x7fc0, then set vill=1 and vstart=2.
#define SETUP_VILL_VSTART2                              \
  "vsetivli x0, 8, e16, m1, ta, ma \n\t"                \
  "li       t0, 0x7fc07fc0 \n\t"                        \
  "vmv.v.x  v29, t0 \n\t"                               \
  "vmv.v.i  v2, 0 \n\t"                                 \
  "vmv.v.i  v3, 0 \n\t"                                 \
  "li       t0, 0x4 \n\t" /* reserved LMUL -> vill=1 */ \
  "vsetvl   t1, zero, t0 \n\t"                          \
  "li       t0, 2 \n\t"                                 \
  "csrw     vstart, t0 \n\t"                            \
  ".rept 16 \n\t"                                       \
  "addi     t2, t2, 1 \n\t"                             \
  ".endr \n\t"

#define DRAIN     \
  ".rept 16 \n\t" \
  "nop \n\t"      \
  ".endr \n\t"

#define SETUP_VSTART2             \
  ".rept 8 \n\t"                  \
  "vle16.v v28, (%[poison]) \n\t" \
  ".endr \n\t"                    \
  "li      t0, 0x7fc07fc0 \n\t"   \
  "vmv.v.x v29, t0 \n\t"          \
  "vmv.v.i v1,  0 \n\t"           \
  "vmv.v.i v18, 0 \n\t"           \
  "vmv.v.i v19, 0 \n\t"           \
  ".rept 16 \n\t"                 \
  "nop \n\t"                      \
  ".endr \n\t"                    \
  "li      t0, 2 \n\t"            \
  "csrw    vstart, t0 \n\t"       \
  "addi    t1, zero, 1 \n\t"      \
  "addi    t2, zero, 2 \n\t"      \
  "addi    t3, zero, 3 \n\t"      \
  "addi    t4, zero, 4 \n\t"

__attribute__((noinline)) void debug_directed_cases() {
  asm volatile(
      "vsetivli x0, 4, e32, m1, ta, ma \n\t" SETUP_VSTART2
      ".p2align 4 \n\t"
      ".global dbg1_vxor \n\t"
      "dbg1_vxor: \n\t"
      "vxor.vv v1, v19, v18 \n\t"
      ".global dbg1_addi \n\t"
      "dbg1_addi: \n\t"
      "addi    t1, t1, 1 \n\t"
      ".global dbg1_vle \n\t"
      "dbg1_vle: \n\t"
      "vle16.v v29, (%[src]) \n\t"
      "nop \n\t" DRAIN "vse16.v v29, (%[out1]) \n\t" DRAIN

      SETUP_VSTART2
      ".p2align 4 \n\t"
      ".global dbg2_vxor \n\t"
      "dbg2_vxor: \n\t"
      "vxor.vv v1, v19, v18 \n\t"
      ".global dbg2_addi \n\t"
      "dbg2_addi: \n\t"
      "addi    t1, t1, 1 \n\t"
      ".global dbg2_vle \n\t"
      "dbg2_vle: \n\t"
      "vle16.v v29, (%[src]) \n\t"
      ".global dbg2_nop \n\t"
      "dbg2_nop: \n\t"
      "nop \n\t" DRAIN "vse16.v v29, (%[out2]) \n\t" DRAIN
      :
      : [src] "r"(dbg_src), [poison] "r"(poison), [out1] "r"(out_dbg1), [out2] "r"(out_dbg2)
      : "t0", "t1", "t2", "t3", "t4", "v1", "v18", "v19", "v28", "v29", "vl", "vtype", "memory");
}

__attribute__((noinline)) void debug_loop_case() {
  asm volatile(
      "vsetivli x0, 4, e32, m1, ta, ma \n\t"
      "lw   a3, 0(%[iters]) \n\t"
      "mv   a4, %[out] \n\t"
      "1: \n\t"
      ".rept 8 \n\t"
      "vle16.v v28, (%[poison]) \n\t"
      ".endr \n\t"
      "li      t0, 0x7fc07fc0 \n\t"
      "vmv.v.x v29, t0 \n\t"
      "vmv.v.i v1,  0 \n\t"
      "vmv.v.i v18, 0 \n\t"
      "vmv.v.i v19, 0 \n\t"
      ".rept 16 \n\t"
      "nop \n\t"
      ".endr \n\t"
      "li      t0, 2 \n\t"
      ".global loop_csrw \n\t"
      "loop_csrw: \n\t"
      "csrw    vstart, t0 \n\t"
      ".global loop_win_start \n\t"
      "loop_win_start: \n\t"
      ".rept 24 \n\t"
      "addi    t1, t1, 1 \n\t"
      ".endr \n\t"
      ".p2align 4 \n\t"
      ".global loop_vxor \n\t"
      "loop_vxor: \n\t"
      "vxor.vv v1, v19, v18 \n\t"
      "addi    t1, t1, 1 \n\t"
      "vle16.v v29, (%[src]) \n\t"
      "nop \n\t" DRAIN
      "vse16.v v29, (a4) \n\t"
      "addi    a4, a4, 8 \n\t"
      "addi    a3, a3, -1 \n\t"
      "bnez    a3, 1b \n\t" DRAIN
      :
      : [src] "r"(dbg_src), [poison] "r"(poison), [out] "r"(out_loop), [iters] "r"(&loop_iters)
      : "t0", "t1", "a3", "a4", "v1", "v18", "v19", "v28", "v29", "vl", "vtype", "memory");
}

// Control: vill=1, vstart=2, whole-register load with no older RVV
// instruction in the packet. The load must start at element 2.
__attribute__((noinline)) void control_case() {
  asm volatile(SETUP_VILL_VSTART2
               ".p2align 4 \n\t"
               "vl1re16.v v29, (%[src]) \n\t"
               "vs1r.v    v29, (%[out]) \n\t"
               "csrr t0, vstart \n\t"
               "sw   t0, 0(%[vs_final]) \n\t" DRAIN
               :
               : [src] "r"(load_src), [out] "r"(ctrl_out), [vs_final] "r"(&ctrl_vstart)
               : "t0", "t1", "t2", "v2", "v3", "v29", "vl", "vtype", "memory");
}

int main(int argc, char **argv) {
  switch (test_sel) {
    case 0:
      control_case();
      break;
    case 1:
      debug_directed_cases();
      break;
    default:
      debug_loop_case();
      break;
  }
  return 0;
}
