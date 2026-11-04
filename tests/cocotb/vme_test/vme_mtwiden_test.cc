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

uint32_t trap_count                 = 0;
uint32_t last_mcause                = 0;
uint32_t last_mtval                 = 0;
uint32_t unconfigured_rd_after_trap = 0;
uint32_t unconfigured_younger_count = 0;

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
  uint32_t mepc_val;
  asm volatile("csrr %0, mepc" : "=r"(mepc_val));
  mepc_val += 4;
  asm volatile("csrw mepc, %0" : : "r"(mepc_val));
}

// Test sequence: configure mtype/vtype, tn, tm, tk, then execute vtzero,
// followed by standard RVV widening MACs (vwmaccu.vv / vwmaccu.vx, which share
// funct6=0b111100 with OP-VE matmul) under mtwiden=0.
// Frontend configuration instructions must not be dispatched to backend, and
// standard RVV widening MACs must not trap when mtwiden=0.
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
      ".word 0x882877D7 \n"                   // msettk x15, x16
      ".word 0x43E06057 \n"                   // vtzero mt0
      "vsetvli x11, x10, e16, m2, ta, ma \n"  // clears mtype (mtwiden=0)
      "vmv.v.i v4, 0 \n"                      // initialize v4..v5
      "vsetvli x11, x10, e8, m1, ta, ma \n"   // mtwiden=0, SEW=8, LMUL=1
      "vmv.v.i v2, 2 \n"
      "vmv.v.i v8, 3 \n"
      ".word 0xF2812257 \n"  // vwmaccu.vv v4, v2, v8 (OP-V 0x57, funct6=111100, funct3=010)
      ".word 0xF2856257 \n"  // vwmaccu.vx v4, x10, v8 (OP-V 0x57, funct6=111100, funct3=110)
      :
      :
      : "x6", "x9", "x10", "x11", "x13", "x14", "x15", "x16", "v2", "v4", "v5", "v8", "vl",
        "vtype");
}

// msettm when mtwiden=0 (unconfigured, vill=0) raises illegal instruction trap
// without modifying rd or executing younger scalar instructions in the same packet.
VME_SUBTEST(msettm_unconfigured) {
  uint32_t rd_probe      = 0x13579BDFu;
  uint32_t younger_probe = 0;
  asm volatile(
      ".balign 16 \n"
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      "li x14, 4 \n"
      ".insn r 0b1010111, 0b111, 0b1000100, %[rd_probe], x14, x1 \n"
      "addi %[younger_probe], %[younger_probe], 1 \n"
      : [rd_probe] "+r"(rd_probe), [younger_probe] "+r"(younger_probe)
      :
      : "x10", "x14", "vl", "vtype");
  unconfigured_rd_after_trap = rd_probe;
  unconfigured_younger_count = younger_probe;
}

// msettk when mtwiden=0 (unconfigured, vill=0) raises illegal instruction trap
// without modifying rd or executing younger scalar instructions in the same packet.
VME_SUBTEST(msettk_unconfigured) {
  uint32_t rd_probe      = 0x2468ACE0u;
  uint32_t younger_probe = 0;
  asm volatile(
      ".balign 16 \n"
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      "li x16, 1 \n"
      ".insn r 0b1010111, 0b111, 0b1000100, %[rd_probe], x16, x2 \n"
      "addi %[younger_probe], %[younger_probe], 1 \n"
      : [rd_probe] "+r"(rd_probe), [younger_probe] "+r"(younger_probe)
      :
      : "x10", "x16", "vl", "vtype");
  unconfigured_rd_after_trap = rd_probe;
  unconfigured_younger_count = younger_probe;
}

// msettm when vill=1 and mtwiden=0 (after msetmtype with TEW > ELEN and msettn)
// raises illegal instruction trap without modifying rd or executing younger instructions.
VME_SUBTEST(vill1_msettm_unconfigured) {
  uint32_t rd_probe      = 4;
  uint32_t younger_probe = 0;
  asm volatile(
      "li x6, 0x4002 \n"
      "li x9, 0x010 \n"
      ".word 0x84937057 \n"  // msetmtype x6, x9 (TEW=64 > ELEN=32 -> vill=1, mtype=0)
      "li x10, 4 \n"
      ".balign 16 \n"
      ".word 0x880575D7 \n"  // msettn x11, x10 (vill=1 -> x11=0, vl=0)
      "li x14, 4 \n"
      ".insn r 0b1010111, 0b111, 0b1000100, %[rd_probe], x14, x1 \n"
      "addi %[younger_probe], %[younger_probe], 1 \n"
      : [rd_probe] "+r"(rd_probe), [younger_probe] "+r"(younger_probe)
      :
      : "x6", "x9", "x10", "x11", "x14", "vl", "vtype");
  unconfigured_rd_after_trap = rd_probe;
  unconfigured_younger_count = younger_probe;
}

// msettk when vill=1 and mtwiden=0 (after msetmtype with TEW > ELEN and msettn)
// raises illegal instruction trap without modifying rd or executing younger instructions.
VME_SUBTEST(vill1_msettk_unconfigured) {
  uint32_t rd_probe      = 7;
  uint32_t younger_probe = 0;
  asm volatile(
      "li x6, 0x4002 \n"
      "li x9, 0x010 \n"
      ".word 0x84937057 \n"  // msetmtype x6, x9 (TEW=64 > ELEN=32 -> vill=1, mtype=0)
      "li x10, 4 \n"
      ".balign 16 \n"
      ".word 0x880575D7 \n"  // msettn x11, x10 (vill=1 -> x11=0, vl=0)
      "li x16, 1 \n"
      ".insn r 0b1010111, 0b111, 0b1000100, %[rd_probe], x16, x2 \n"
      "addi %[younger_probe], %[younger_probe], 1 \n"
      : [rd_probe] "+r"(rd_probe), [younger_probe] "+r"(younger_probe)
      :
      : "x6", "x9", "x10", "x11", "x16", "vl", "vtype");
  unconfigured_rd_after_trap = rd_probe;
  unconfigured_younger_count = younger_probe;
}

// vtzero when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtzero_unconfigured) {
  uint32_t younger_probe = 0;
  asm volatile(
      ".balign 16 \n"
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".word 0x43E06057 \n"                   // vtzero mt0
      "addi %[younger_probe], %[younger_probe], 1 \n"
      : [younger_probe] "+r"(younger_probe)
      :
      : "x10", "vl", "vtype");
  unconfigured_younger_count = younger_probe;
}

// vtmmu.tvv when mtwiden=0 (unconfigured) raises illegal instruction trap with OP-VE (0x77) mtval
VME_SUBTEST(vtmmu_unconfigured) {
  uint32_t younger_probe = 0;
  asm volatile(
      ".balign 16 \n"
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".word 0xF2880077 \n"                   // vtmmu.tvv mt0, v8, v16 (opcode 0x77)
      "addi %[younger_probe], %[younger_probe], 1 \n"
      : [younger_probe] "+r"(younger_probe)
      :
      : "x10", "vl", "vtype");
  unconfigured_younger_count = younger_probe;
}

// vtle8 when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtle_unconfigured) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  asm volatile(
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b0000111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      :
      : [addr] "r"(addr), [tss] "r"(tss)
      : "x10", "vl", "vtype");
}

// vtse8 when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtse_unconfigured) {
  uint32_t addr = 0x1000;
  uint32_t tss  = 0;
  asm volatile(
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b0100111, 0b111, 0b0001001, zero, %[addr], %[tss] \n"
      :
      : [addr] "r"(addr), [tss] "r"(tss)
      : "x10", "vl", "vtype");
}

// vtmv.v.t when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtmv_v_t_unconfigured) {
  uint32_t tss = 0;
  asm volatile(
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b1010111, 0b110, 0b0100001, x8, %[tss], x31 \n"
      :
      : [tss] "r"(tss)
      : "x10", "vl", "vtype");
}

// vtmv.t.v when mtwiden=0 (unconfigured) raises illegal instruction trap
VME_SUBTEST(vtmv_t_v_unconfigured) {
  uint32_t tss = 0;
  asm volatile(
      "vsetvli x10, zero, e8, m1, ta, ma \n"  // clears mtype (mtwiden=0)
      ".insn r 0b1010111, 0b110, 0b0101111, x0, %[tss], x8 \n"
      :
      : [tss] "r"(tss)
      : "x10", "vl", "vtype");
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
