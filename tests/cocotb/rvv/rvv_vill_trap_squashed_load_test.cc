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

uint32_t trap_count __attribute__((section(".data")))  = 0;
uint32_t trap_mcause __attribute__((section(".data"))) = 0;
uint32_t trap_mepc __attribute__((section(".data")))   = 0;
uint32_t trap_vstart __attribute__((section(".data"))) = 0;

uint16_t load_src[8] __attribute__((section(".data"), aligned(16))) = {
    0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666, 0x7777, 0x8888};
uint16_t out_reload[8] __attribute__((section(".data"), aligned(16))) = {};
uint16_t out_after[8] __attribute__((section(".data"), aligned(16)))  = {};
uint32_t vstart_final __attribute__((section(".data")))               = 0xff;

}  // extern "C"

// Records the first trap and resumes at `squash_resume`. Clobbers t5, t6.
asm(R"(
  .pushsection .text
  .p2align 2
  .global vill_squash_trap_handler
vill_squash_trap_handler:
  la   t6, trap_count
  lw   t6, 0(t6)
  bnez t6, 1f
  csrr t6, mcause
  sw   t6, trap_mcause, t5
  csrr t6, mepc
  sw   t6, trap_mepc, t5
  csrr t6, vstart
  sw   t6, trap_vstart, t5
1:
  la   t5, trap_count
  lw   t6, 0(t5)
  addi t6, t6, 1
  sw   t6, 0(t5)
  li   t5, 4
  bltu t6, t5, 2f
  ebreak
2:
  la   t6, squash_resume
  csrw mepc, t6
  mret
  .popsection
)");

int main(int argc, char **argv) {
  asm volatile(
      "la   t0, vill_squash_trap_handler \n\t"
      "csrw mtvec, t0 \n\t"

      // v29 = 0x7fc0, then vill=1 (reserved LMUL) and vstart=2.
      "vsetivli x0, 8, e16, m1, ta, ma \n\t"
      "li       t0, 0x7fc07fc0 \n\t"
      "vmv.v.x  v29, t0 \n\t"
      "vmv.v.i  v2, 0 \n\t"
      "vmv.v.i  v3, 0 \n\t"
      "li       t0, 0x4 \n\t"
      "vsetvl   t1, zero, t0 \n\t"
      "li       t0, 2 \n\t"
      "csrw     vstart, t0 \n\t"
      ".rept 16 \n\t"
      "addi     t2, t2, 1 \n\t"
      ".endr \n\t"

      ".p2align 4 \n\t"
      ".global squash_vadd \n\t"
      "squash_vadd: \n\t"
      "vadd.vv   v1, v2, v3 \n\t"     // lane 0: illegal-instruction trap (vill)
      "vl1re16.v v29, (%[src]) \n\t"  // lane 1: squashed by the trap
      "nop \n\t"
      "nop \n\t"
      ".rept 16 \n\t"
      "nop \n\t"
      ".endr \n\t"

      ".global squash_resume \n\t"
      "squash_resume: \n\t"
      // Re-execute the load (vstart is still 2).
      "vl1re16.v v29, (%[src]) \n\t"
      "vs1r.v    v29, (%[reload]) \n\t"
      // Some more vector work after the squash.
      "vsetivli  x0, 8, e16, m1, ta, ma \n\t"
      "li        t0, 0x5a5a5a5a \n\t"
      "vmv.v.x   v30, t0 \n\t"
      "vse16.v   v30, (%[after]) \n\t"
      "csrr      t0, vstart \n\t"
      "sw        t0, 0(%[vs_final]) \n\t"
      :
      : [src] "r"(load_src), [reload] "r"(out_reload), [after] "r"(out_after),
        [vs_final] "r"(&vstart_final)
      : "t0", "t1", "t2", "t5", "t6", "v1", "v2", "v3", "v29", "v30", "vl", "vtype", "memory");
  return 0;
}
