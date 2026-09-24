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

extern "C" {

typedef void (*test_func_t)(void);

uint32_t trap_count     = 0;
uint32_t last_mcause    = 0;
uint32_t last_mtval     = 0;
uint32_t mstatus_val[8] = {0};

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
  asm volatile(".word 0x08000073");  // mpause (halt)
}

// mstatus.MS == Off tests: attempts to execute any instruction that accesses
// matrix tile state or vtdiscard must raise an illegal instruction trap (mcause=2).

// vtle8 when mstatus.MS == Off (must trap)
__attribute__((used, retain)) void ms_off_vtle(void) {
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
__attribute__((used, retain)) void ms_off_vtse(void) {
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
__attribute__((used, retain)) void ms_off_vtzero(void) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      ".word 0x43E06057 \n"  // vtzero mt0
      ::
          : "t0");
}

// vtmv.v.t when mstatus.MS == Off (must trap)
__attribute__((used, retain)) void ms_off_vtmv_v_t(void) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "li a0, 0 \n"
      ".word 0x43FA6257 \n"  // vtmv.v.t v4, a0 (funct6=010000, vs2=11111, rs1=a0, funct3=110,
                             // rd=v4)
      ::
          : "t0", "a0");
}

// vtmv.t.v when mstatus.MS == Off (must trap)
__attribute__((used, retain)) void ms_off_vtmv_t_v(void) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      "li a0, 0 \n"
      ".word 0x5C456057 \n"  // vtmv.t.v a0, v4 (funct6=010111, vs2=v4, rs1=a0, funct3=110, rd=x0)
      ::
          : "t0", "a0");
}

// vtmmu when mstatus.MS == Off (must trap)
__attribute__((used, retain)) void ms_off_vtmmu(void) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      ".word 0xF3040077 \n"  // vtmmu.tvv mt0, v16, v8 (funct6=111100, vm=1, funct3=000,
                             // opcode=0x77)
      ::
          : "t0");
}

// vtdiscard when mstatus.MS == Off (must trap)
__attribute__((used, retain)) void ms_off_vtdiscard(void) {
  asm volatile(
      "li t0, (3 << 29) \n"
      "csrc mstatus, t0 \n"  // mstatus.MS = Off (00)
      ".word 0x43C06057 \n"  // vtdiscard (funct6=010000, vs2=11100, rs1=0, funct3=110, rd=0)
      ::
          : "t0");
}

// vtdiscard when vill == 1 (must trap as illegal instruction)
__attribute__((used, retain)) void vill1_vtdiscard(void) {
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e64, m1, ta, ma \n"  // Invalid SEW on 32-bit core sets vill=1
      ".word 0x43C06057 \n"                              // vtdiscard
      : [vl_discard] "=&r"(vl_discard)
      :
      : "vl", "vtype");
}

// Configuration instructions (mset*) do NOT access tile state and must execute
// successfully even when mstatus.MS == Off.
__attribute__((used, retain)) void ms_off_mset_allowed(void) {
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

// Verify mstatus.MS transitions:
// 1. Initial reset/power-on state (MS=Initial 01, SD=0)
// 2. Tile-modifying instruction (vtzero) transitions MS to Dirty (11), setting SD=1
// 3. WARL write setting MS=Clean (10), clearing SD=0
// 4. vtdiscard transitions MS to Initial (01), SD=0
// 5. WARL write setting MS=Off (00), SD=0
__attribute__((used, retain)) void mstatus_ms_transitions(void) {
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

  // Step 1: Execute vtzero -> should transition MS to Dirty (11), SD to 1
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
}

test_func_t test_fn = ms_off_vtle;

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %[isr]" ::[isr] "r"((uint32_t)(&isr_handler)));

  trap_count  = 0;
  last_mcause = 0;

  if (test_fn != nullptr) {
    test_fn();
  }

  return 0;
}

}  // extern "C"
