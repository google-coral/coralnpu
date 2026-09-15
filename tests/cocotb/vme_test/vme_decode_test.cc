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

uint32_t trap_count  = 0;
uint32_t last_mcause = 0;
uint32_t last_mtval  = 0;

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

// vtle64 (nf=0b011: e64 cleanly rejected on 32-bit core)
VME_SUBTEST(vtle64) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0111001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtse64 (nf=0b011: e64 cleanly rejected on 32-bit core)
VME_SUBTEST(vtse64) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0111001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtle with invalid nf=0b100
VME_SUBTEST(vtle_invalid_nf100) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b1001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtse with invalid nf=0b100
VME_SUBTEST(vtse_invalid_nf100) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b1001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtle with invalid nf=0b111
VME_SUBTEST(vtle_invalid_nf111) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b1111001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtse with invalid nf=0b111
VME_SUBTEST(vtse_invalid_nf111) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b1111001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtle8 with vm=0 (masked tile load is illegal)
VME_SUBTEST(vtle8_masked_vm0) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0001000, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtse8 with vm=0 (masked tile store is illegal)
VME_SUBTEST(vtse8_masked_vm0) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0001000, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtle8 with non-zero vd/vs3 field (bits [11:7] must be zero)
VME_SUBTEST(vtle8_nonzero_vd_vs3) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0001001, t1, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "t1", "vl", "vtype");
}

// vtse8 with non-zero vd/vs3 field (bits [11:7] must be zero)
VME_SUBTEST(vtse8_nonzero_vd_vs3) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0001001, t1, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "t1", "vl", "vtype");
}

// vtle8 with non-zero mop=0b10 (mop must be 0b00 for tile operations)
VME_SUBTEST(vtle8_nonzero_mop10) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0001101, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtse8 with non-zero mop=0b01 (mop must be 0b00 for tile operations)
VME_SUBTEST(vtse8_nonzero_mop01) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0001011, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// mew=0 with width=111 (reserved vector encoding for load)
VME_SUBTEST(mew0_width7_load) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0000001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// mew=0 with width=111 (reserved vector encoding for store)
VME_SUBTEST(mew0_width7_store) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0000001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vill=1 (executing vtle8 when vector configuration is invalid)
VME_SUBTEST(vill1_load) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e64, m1, ta, ma \n"  // Invalid SEW on 32-bit core sets vill=1
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vill=1 (executing vtse8 when vector configuration is invalid)
VME_SUBTEST(vill1_store) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e64, m1, ta, ma \n"  // Invalid SEW on 32-bit core sets vill=1
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// Test sequence: configure mtype/vtype, tn, tm, tk, then execute vtzero.
// Frontend configuration instructions must not be dispatched to backend.
VME_SUBTEST(mset_dimension_config) {
  asm volatile(
      "li x6, 0x4042 \n"
      "li x9, 0x008 \n"
      ".word 0x84937057 \n"  // msetmtype x6, x9
      "li x10, 4 \n"
      ".word 0x880575D7 \n"  // msettn x11, x10
      "li x14, 4 \n"
      ".word 0x881776D7 \n"  // msettm x13, x14
      "li x16, 2 \n"
      ".word 0x882877D7 \n"  // msettk x15, x16
      ".word 0x43E06057 \n"  // vtzero mt0
      ::
          : "x6", "x9", "x10", "x11", "x13", "x14", "x15", "x16", "memory");
}

// OP-VE (0x77) with reserved funct3=0b010 (must trap as illegal instruction)
VME_SUBTEST(opve_invalid_funct3) {
  // Emit custom opcode 0x77 with funct6=111100, funct3=010 (reserved), vm=1
  asm volatile(".word 0xF8002077 \n");
}

// Standard RVV vfwmacc.vv (0x57, funct6=111100, funct3=001) under vill=1.
// Tests that mtval reconstructs opcode 0x57 faithfully without being corrupted to 0x77.
VME_SUBTEST(vfwmacc_vv_vill) {
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e64, m1, ta, ma \n"  // Set vill=1
      ".word 0xF2001057 \n"                              // vfwmacc.vv v0, v0, v0 (opcode 0x57)
      : [vl_discard] "=&r"(vl_discard)
      :
      : "vl", "vtype");
}

// msettm when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(msettm_unconfigured) {
  uint32_t vl_discard;
  uint32_t tm_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b1010111, 0b111, 0b1000100, %[tm_discard], x0, x1 \n"
      : [vl_discard] "=&r"(vl_discard), [tm_discard] "=&r"(tm_discard)
      :
      : "vl", "vtype");
}

// msettk when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(msettk_unconfigured) {
  uint32_t vl_discard;
  uint32_t tk_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b1010111, 0b111, 0b1000100, %[tk_discard], x0, x2 \n"
      : [vl_discard] "=&r"(vl_discard), [tk_discard] "=&r"(tk_discard)
      :
      : "vl", "vtype");
}

// vtle8 when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtle_unconfigured) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtse8 when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtse_unconfigured) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr), [tss] "r"(tss)
      : "vl", "vtype");
}

// vtmv.v.t when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtmv_v_t_unconfigured) {
  uint32_t tss = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [tss] "r"(tss)
      : "vl", "vtype", "v8");
}

// vtmv.t.v when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtmv_t_v_unconfigured) {
  uint32_t tss = 0;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [tss] "r"(tss)
      : "vl", "vtype");
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
