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

extern "C" {

uint32_t trap_count     = 0;
uint32_t last_mcause    = 0;
uint32_t last_mtval     = 0;
uint32_t mstatus_val[8] = {0};

extern volatile test_func_t test_fn;

__attribute__((interrupt)) void isr_handler(void) {
  uint32_t mcause;
  uint32_t mtval;
  asm volatile("csrr %0, mcause" : "=r"(mcause));
  asm volatile("csrr %0, mtval" : "=r"(mtval));
  last_mcause = mcause;
  last_mtval  = mtval;
  if (mcause == 2) {
    trap_count++;
  }
  if (test_fn != nullptr) {
    asm volatile(".word 0x08000073");  // mpause (halt in cocotb mode)
  }
  uint32_t mepc_val;
  asm volatile("csrr %0, mepc" : "=r"(mepc_val));
  mepc_val += 4;
  asm volatile("csrw mepc, %0" : : "r"(mepc_val));
}

// Verify mstatus.MS transitions:
// 1. Initial reset/power-on state (MS=Initial 01, SD=0)
// 2. Tile-modifying instruction (vtzero) transitions MS to Dirty (11), setting SD=1
// 3. WARL write setting MS=Clean (10), clearing SD=0
// 4. vtdiscard transitions MS to Initial (01), SD=0
// 5. WARL write setting MS=Off (00), SD=0
VME_SUBTEST(mstatus_ms_transitions) {
  uint32_t val;

  // Set FS and VS to Initial (01) in mstatus so SD reflects only MS
  // Note: Since FS/VS WARL legalizes 00 -> 11 Dirty, we must write non-zero (Initial=1 or Clean=2)
  asm volatile(
      "li t0, (1 << 13) | (1 << 9) \n"
      "csrs mstatus, t0 \n"  // Ensure bit 0 of FS/VS is set (Initial 01)
      "li t0, (2 << 13) | (2 << 9) \n"
      "csrc mstatus, t0 \n"  // Clear bit 1 of FS/VS so FS=01, VS=01 (Initial)
      ::
          : "t0");

  // Step 0: Read initial mstatus
  asm volatile("csrr %0, mstatus" : "=r"(val));
  mstatus_val[0] = val;

  // Configure valid vector/matrix context before executing vector/tile instructions
  asm volatile(
      "li x6, 0x4042 \n"
      "li x9, 0x008 \n"
      ".word 0x82937057 \n"  // msetmtype x6, x9
      "li x10, 4 \n"
      ".word 0x840575D7 \n"  // msettn x11, x10
      "li x14, 4 \n"
      ".word 0x841776D7 \n"  // msettm x13, x14
      "li x16, 2 \n"
      ".word 0x842877D7 \n"  // msettk x15, x16
      ::
          : "x6", "x9", "x10", "x11", "x13", "x14", "x15", "x16");

  // Reset VS and FS to Initial (01) before vtzero so we can test that vtzero transitions VS to
  // Dirty
  asm volatile(
      "li t0, (1 << 13) | (1 << 9) \n"
      "csrs mstatus, t0 \n"  // FS bit 0 = 1, VS bit 0 = 1
      "li t0, (2 << 13) | (2 << 9) \n"
      "csrc mstatus, t0 \n"  // FS bit 1 = 0, VS bit 1 = 0 -> Initial (01)
      "nop \n" ::
          : "t0");

  // Step 1: Execute vtzero -> should transition MS to Dirty (11), VS to Dirty (11), SD to 1
  asm volatile(".word 0x43E06057 \n");  // vtzero mt0
  asm volatile("csrr %0, mstatus" : "=r"(val));
  mstatus_val[1] = val;

  // Step 2: Set MS = Clean (10) via CSR write and clear VS dirty
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // Clear MS
      "li t0, (2 << 29) \n"
      "csrs mstatus, t0 \n"  // Set MS = Clean (2)
      "li t0, (1 << 9) \n"
      "csrs mstatus, t0 \n"  // Set VS bit 0 = 1
      "li t0, (2 << 9) \n"
      "csrc mstatus, t0 \n"  // Clear VS bit 1 -> VS = 01 (Initial)
      ::
          : "t0");
  asm volatile("csrr %0, mstatus" : "=r"(val));
  mstatus_val[2] = val;

  // Step 3: Execute vtdiscard -> should transition MS to Initial (01), SD to 0
  asm volatile(".word 0x43C06057 \n");  // vtdiscard
  asm volatile(
      "li t0, (1 << 9) \n"
      "csrs mstatus, t0 \n"  // Set VS bit 0 = 1
      "li t0, (2 << 9) \n"
      "csrc mstatus, t0 \n"  // Clear VS bit 1 -> VS = 01 (Initial)
      ::
          : "t0");
  asm volatile("csrr %0, mstatus" : "=r"(val));
  mstatus_val[3] = val;

  // Step 4: Set MS = Off (00) via CSR write -> SD should be 0
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // Clear MS (Off = 00)
      "li t0, (1 << 9) \n"
      "csrs mstatus, t0 \n"  // Set VS bit 0 = 1
      "li t0, (2 << 9) \n"
      "csrc mstatus, t0 \n"  // Clear VS bit 1 -> VS = 01 (Initial)
      ::
          : "t0");
  asm volatile("csrr %0, mstatus" : "=r"(val));
  mstatus_val[4] = val;

  // Step 5: Verify floating-point tile matrix multiply (vtfmm) sets both FS and VS to Dirty (11)
  // Set configuration for FP32 matmul first (since mset* instructions dirty VS):
  // SEW32, LMUL4, tm=4, tn=4, tk=1
  asm volatile(
      "li x6, 0x4021 \n"
      "li x9, 0x0D2 \n"
      ".word 0x82937057 \n"  // msetmtype x6, x9 (SEW32/LMUL4, mtwiden=1)
      "li x10, 4 \n"
      ".word 0x840575D7 \n"  // msettn x11, x10
      "li x14, 4 \n"
      ".word 0x841776D7 \n"  // msettm x13, x14
      "li x16, 1 \n"
      ".word 0x842877D7 \n"  // msettk x15, x16
      ::
          : "x6", "x9", "x10", "x11", "x13", "x14", "x15", "x16");
  // Re-enable MS (Clean=10) and set FS=Initial (01), VS=Initial (01)
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"
      "li t0, (2 << 29) \n"
      "csrs mstatus, t0 \n"  // MS = Clean (10)
      "li t0, (1 << 13) | (1 << 9) \n"
      "csrs mstatus, t0 \n"  // FS bit 0 = 1, VS bit 0 = 1
      "li t0, (2 << 13) | (2 << 9) \n"
      "csrc mstatus, t0 \n"  // FS bit 1 = 0, VS bit 1 = 0 -> FS = Initial (01), VS = Initial (01)
      "nop \n" ::
          : "t0");
  // Execute vtfmm.tvv mt0, v16, v8 (funct6=111100, vm=1, funct3=001, opcode=0x77)
  asm volatile(".word %0 \n" ::"i"(ZvtMatmulFpWord(0, /*alt=*/false)) : "memory");
  asm volatile("csrr %0, mstatus" : "=r"(val));
  mstatus_val[5] = val;
}

// vtdiscard when vill == 1 (must trap as illegal instruction)
VME_SUBTEST(vill1_vtdiscard) {
  uint32_t vl_discard;
  asm volatile(
      "li t0, (1 << 29) \n"
      "csrs mstatus, t0 \n"                              // Ensure mstatus.MS != Off
      "vsetvli %[vl_discard], zero, e64, m1, ta, ma \n"  // Invalid SEW on 32-bit core sets vill=1
      ".word 0x43C06057 \n"                              // vtdiscard
      : [vl_discard] "=&r"(vl_discard)
      :
      : "t0", "vl", "vtype");
}

// Configuration instructions (mset*) do NOT access tile state and must execute
// successfully even when mstatus.MS == Off.
VME_SUBTEST(ms_off_mset_allowed) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "li x6, 0x4042 \n"
      "li x9, 0x008 \n"
      ".word 0x82937057 \n"  // msetmtype x6, x9
      "li x10, 4 \n"
      ".word 0x840575D7 \n"  // msettn x11, x10
      "li x14, 4 \n"
      ".word 0x841776D7 \n"  // msettm x13, x14
      "li x16, 2 \n"
      ".word 0x842877D7 \n"  // msettk x15, x16
      ::
          : "t0", "x6", "x9", "x10", "x11", "x13", "x14", "x15", "x16", "memory");
}

// mstatus.MS == Off tests: attempts to execute any instruction that accesses
// matrix tile state or vtdiscard must raise an illegal instruction trap (mcause=2).

// vtle8 when mstatus.MS == Off (must trap)
VME_SUBTEST(ms_off_vtle) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "t0", "vl", "vtype");
}

// vtse8 when mstatus.MS == Off (must trap)
VME_SUBTEST(ms_off_vtse) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "t0", "vl", "vtype");
}

// vtzero when mstatus.MS == Off (must trap)
VME_SUBTEST(ms_off_vtzero) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "vsetvli zero, zero, e8, m1, ta, ma \n"
      ".word 0x43E06057 \n"  // vtzero mt0
      ::
          : "t0", "vl", "vtype");
}

// vtmv.v.t when mstatus.MS == Off (must trap)
VME_SUBTEST(ms_off_vtmv_v_t) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "vsetvli zero, zero, e8, m1, ta, ma \n"
      "li a0, 0 \n"
      ".word 0x43FA6257 \n"  // vtmv.v.t v4, a0 (funct6=010000, vs2=11111, rs1=a0, funct3=110,
                             // rd=v4)
      ::
          : "t0", "a0", "vl", "vtype");
}

// vtmv.t.v when mstatus.MS == Off (must trap)
VME_SUBTEST(ms_off_vtmv_t_v) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "vsetvli zero, zero, e8, m1, ta, ma \n"
      "li a0, 0 \n"
      ".word 0x5E456057 \n"  // vtmv.t.v a0, v4 (funct6=010111, vm=1, vs2=v4, rs1=a0, funct3=110,
                             // rd=x0)
      ::
          : "t0", "a0", "vl", "vtype");
}

// vtmmu when mstatus.MS == Off (must trap)
VME_SUBTEST(ms_off_vtmmu) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "vsetvli zero, zero, e8, m1, ta, ma \n"
      ".word 0xF3040077 \n"  // vtmmu.tvv mt0, v16, v8 (funct6=111100, vm=1, funct3=000,
                             // opcode=0x77)
      ::
          : "t0", "vl", "vtype");
}

// vtdiscard when mstatus.MS == Off (must trap)
VME_SUBTEST(ms_off_vtdiscard) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "vsetvli zero, zero, e8, m1, ta, ma \n"
      ".word 0x43C06057 \n"  // vtdiscard (funct6=010000, vs2=11100, rs1=0, funct3=110, rd=0)
      ::
          : "t0", "vl", "vtype");
}

volatile test_func_t test_fn __attribute__((section(".data"))) = nullptr;

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %[isr]" ::[isr] "r"((uint32_t)(&isr_handler)));

  trap_count  = 0;
  last_mcause = 0;

  if (test_fn != nullptr) {
    test_fn();
  } else {
    for (const test_func_t *fn = __start_vme_subtests; fn < __stop_vme_subtests; ++fn) {
      (*fn)();
    }
  }

  return 0;
}

}  // extern "C"
