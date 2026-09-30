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

uint32_t test_sel __attribute__((section(".data"))) = 1;

// Trap log written by squash_trap_handler: {mcause, mepc, mtval, vstart}.
uint32_t trap_count __attribute__((section(".data")))     = 0;
uint32_t trap_log[8][4] __attribute__((section(".data"))) = {};
uint32_t resume_pc __attribute__((section(".data")))      = 0;
uint32_t snap_ptr __attribute__((section(".data")))       = 0;

uint16_t load_src[8] __attribute__((section(".data"), aligned(16))) = {
    0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666, 0x7777, 0x8888};

// v29 at trap entry, and the result of the re-executed instruction.
uint16_t case_snap[8] __attribute__((section(".data"), aligned(16))) = {};
uint16_t case_out[8] __attribute__((section(".data"), aligned(16)))  = {};
uint32_t vstart_after_trap __attribute__((section(".data")))         = 0xff;
uint32_t vstart_final __attribute__((section(".data")))              = 0xff;

}  // extern "C"

// Resumable trap handler. Logs the trap, snapshots v29 to `snap_ptr` (if
// set) without disturbing vstart, and resumes at `resume_pc`. Clobbers t5,
// t6, a6, a7 only.
asm(R"(
  .pushsection .text
  .p2align 2
  .global squash_trap_handler
squash_trap_handler:
  la   t6, trap_count
  lw   t5, 0(t6)
  li   a7, 8
  bltu t5, a7, 1f
  ebreak
1:
  slli a7, t5, 4
  la   a6, trap_log
  add  a6, a6, a7
  csrr a7, mcause
  sw   a7, 0(a6)
  csrr a7, mepc
  sw   a7, 4(a6)
  csrr a7, mtval
  sw   a7, 8(a6)
  csrr a7, vstart
  sw   a7, 12(a6)
  addi t5, t5, 1
  sw   t5, 0(t6)
  csrw vstart, zero
  la   t6, snap_ptr
  lw   t6, 0(t6)
  beqz t6, 2f
  vs1r.v v29, (t6)
2:
  csrw vstart, a7
  la   t6, resume_pc
  lw   t6, 0(t6)
  csrw mepc, t6
  mret
  .popsection
)");

#define SET_WORD(SYM, LABEL_OR_SYM) \
  "la   t0, " LABEL_OR_SYM          \
  " \n\t"                           \
  "la   t6, " SYM                   \
  " \n\t"                           \
  "sw   t0, 0(t6) \n\t"

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

// Keeps the oldest instruction busy for ~32 cycles (the divider does one
// quotient bit per cycle), so the packet behind it can't retire until well
// after its load has faulted.
#define LONG_DIV             \
  "li   t3, 0x7fffffff \n\t" \
  "li   t4, 3 \n\t"          \
  "div  t3, t3, t4 \n\t"

#define DRAIN     \
  ".rept 16 \n\t" \
  "nop \n\t"      \
  ".endr \n\t"

#define SAVE_VSTART(DST) \
  "csrr t0, vstart \n\t" \
  "sw   t0, 0(" DST ") \n\t"

#define CASE_CLOBBERS                                                                        \
  "t0", "t1", "t2", "t3", "t4", "t5", "t6", "a5", "a6", "a7", "v1", "v2", "v3", "v29", "vl", \
      "vtype", "memory"

// T1: the squashed load reads DTCM.
__attribute__((noinline)) void case_t1() {
  asm volatile(
      SET_WORD("snap_ptr", "case_snap")
      SET_WORD("resume_pc", "t1_resume")
      SETUP_VILL_VSTART2
      ".p2align 4 \n\t"
      ".global t1_vadd \n\t"
      "t1_vadd: \n\t"
      "vadd.vv   v1, v2, v3 \n\t"       // lane 0: traps (vill)
      "vl1re16.v v29, (%[src]) \n\t"    // lane 1: must not run ahead of the trap
      "nop \n\t"
      "nop \n\t"
      DRAIN
      "t1_resume: \n\t"
      SAVE_VSTART("%[vs_trap]")
      "vl1re16.v v29, (%[src]) \n\t"    // re-execute with vstart=2
      "vs1r.v    v29, (%[out]) \n\t"
      SAVE_VSTART("%[vs_final]")
      DRAIN
      :
      : [src] "r"(load_src), [out] "r"(case_out),
        [vs_trap] "r"(&vstart_after_trap), [vs_final] "r"(&vstart_final)
      : CASE_CLOBBERS);
}

// T2: elements [0, 2) of the squashed load fault (0x1ffffffc), elements
// [2, 8) are in external memory (0x20000000).
__attribute__((noinline)) void case_t2() {
  asm volatile(
      SET_WORD("snap_ptr", "case_snap")
      SET_WORD("resume_pc", "t2_resume")
      "li   a5, 0x1ffffffc \n\t"
      SETUP_VILL_VSTART2
      ".p2align 4 \n\t"
      ".global t2_vadd \n\t"
      "t2_vadd: \n\t"
      "vadd.vv   v1, v2, v3 \n\t"       // lane 0: traps (vill)
      "vl1re16.v v29, (a5) \n\t"        // lane 1: must not run ahead of the trap
      "nop \n\t"
      "nop \n\t"
      DRAIN
      "t2_resume: \n\t"
      SAVE_VSTART("%[vs_trap]")
      "vl1re16.v v29, (a5) \n\t"        // re-execute with vstart=2
      "vs1r.v    v29, (%[out]) \n\t"
      SAVE_VSTART("%[vs_final]")
      DRAIN
      :
      : [out] "r"(case_out), [vs_trap] "r"(&vstart_after_trap),
        [vs_final] "r"(&vstart_final)
      : CASE_CLOBBERS);
}

// T3: T2 behind a long div.
__attribute__((noinline)) void case_t3() {
  asm volatile(
      SET_WORD("snap_ptr", "case_snap")
      SET_WORD("resume_pc", "t3_resume")
      "li   a5, 0x1ffffffc \n\t"
      SETUP_VILL_VSTART2
      LONG_DIV
      ".p2align 4 \n\t"
      ".global t3_vadd \n\t"
      "t3_vadd: \n\t"
      "vadd.vv   v1, v2, v3 \n\t"       // lane 0: traps (vill)
      "vl1re16.v v29, (a5) \n\t"        // lane 1: must not run ahead of the trap
      "nop \n\t"
      "nop \n\t"
      DRAIN
      "t3_resume: \n\t"
      SAVE_VSTART("%[vs_trap]")
      "vl1re16.v v29, (a5) \n\t"        // re-execute with vstart=2
      "vs1r.v    v29, (%[out]) \n\t"
      SAVE_VSTART("%[vs_final]")
      DRAIN
      :
      : [out] "r"(case_out), [vs_trap] "r"(&vstart_after_trap),
        [vs_final] "r"(&vstart_final)
      : CASE_CLOBBERS);
}

// T4: the load is older than the vadd. With vstart=2 it starts at element 2
// (0x1ffffffc), which faults.
__attribute__((noinline)) void case_t4() {
  asm volatile(
      SET_WORD("snap_ptr", "case_snap") SET_WORD(
          "resume_pc", "t4_resume") "li   a5, 0x1ffffff8 \n\t" SETUP_VILL_VSTART2 LONG_DIV
                                    ".p2align 4 \n\t"
                                    ".global t4_vle \n\t"
                                    "t4_vle: \n\t"
                                    "vl1re16.v v29, (a5) \n\t"   // lane 0: faults at element 2
                                    "vadd.vv   v1, v2, v3 \n\t"  // lane 1: traps (vill), younger
                                    "nop \n\t"
                                    "nop \n\t" DRAIN "t4_resume: \n\t" SAVE_VSTART(
                                        "%[vs_trap]") "csrw vstart, zero \n\t" DRAIN
      :
      : [vs_trap] "r"(&vstart_after_trap)
      : CASE_CLOBBERS);
}

// T5: the squashed store is a whole-register store, so vill doesn't stop it.
// After the trap, v29 gets a new value and the store is re-executed.
__attribute__((noinline)) void case_t5() {
  asm volatile(
      SET_WORD("snap_ptr", "case_snap")
      SET_WORD("resume_pc", "t5_resume")
      SETUP_VILL_VSTART2
      ".p2align 4 \n\t"
      ".global t5_vadd \n\t"
      "t5_vadd: \n\t"
      "vadd.vv   v1, v2, v3 \n\t"       // lane 0: traps (vill)
      "vs1r.v    v29, (%[out]) \n\t"    // lane 1: must not run ahead of the trap
      "nop \n\t"
      "nop \n\t"
      DRAIN
      "t5_resume: \n\t"
      SAVE_VSTART("%[vs_trap]")
      "csrw vstart, zero \n\t"
      "vl1re16.v v29, (%[src]) \n\t"    // new v29
      "csrw vstart, t0 \n\t"
      "vs1r.v    v29, (%[out]) \n\t"    // re-execute with vstart=2
      SAVE_VSTART("%[vs_final]")
      DRAIN
      :
      : [src] "r"(load_src), [out] "r"(case_out),
        [vs_trap] "r"(&vstart_after_trap), [vs_final] "r"(&vstart_final)
      : CASE_CLOBBERS);
}

// T6: elements [0, 4) are the last 8 bytes of DTCM, element 4 is past the end
// and faults. The div keeps the load from being the oldest instruction when
// the fault arrives. It must be reported with vstart=4 (vstart was 0).
__attribute__((noinline)) void case_t6() {
  asm volatile(
      SET_WORD("snap_ptr", "case_snap")
      SET_WORD("resume_pc", "t6_resume")
      "la   a5, __stack_end__ \n\t"
      "addi a5, a5, -8 \n\t"
      "vsetivli x0, 8, e16, m1, ta, ma \n\t"
      "csrw vstart, zero \n\t"
      DRAIN
      LONG_DIV
      ".p2align 4 \n\t"
      ".global t6_vle \n\t"
      "t6_vle: \n\t"
      "vl1re16.v v29, (a5) \n\t"        // faults at element 4
      "nop \n\t"
      "nop \n\t"
      "nop \n\t"
      DRAIN
      "t6_resume: \n\t"
      SAVE_VSTART("%[vs_trap]")
      "csrw vstart, zero \n\t"
      DRAIN
      :
      : [vs_trap] "r"(&vstart_after_trap)
      : CASE_CLOBBERS);
}

int main(int argc, char **argv) {
  // Probe: the address just below external memory must fault, or T2-T4
  // don't test anything.
  asm volatile(
      "la   t0, squash_trap_handler \n\t"
      "csrw mtvec, t0 \n\t"
      SET_WORD("resume_pc", "probe_resume")
      "li   t0, 0x1ffffffc \n\t"
      ".global probe_insn \n\t"
      "probe_insn: \n\t"
      "lw   t1, 0(t0) \n\t"
      "probe_resume: \n\t"
      DRAIN
      :
      :
      : "t0", "t1", "t5", "t6", "a6", "a7", "memory");

  switch (test_sel) {
    case 1:
      case_t1();
      break;
    case 2:
      case_t2();
      break;
    case 3:
      case_t3();
      break;
    case 4:
      case_t4();
      break;
    case 5:
      case_t5();
      break;
    case 6:
      case_t6();
      break;
    default:
      break;
  }
  return 0;
}
