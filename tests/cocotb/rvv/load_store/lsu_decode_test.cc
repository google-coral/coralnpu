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

#include <riscv_vector.h>
#include <stdint.h>

#include "tests/cocotb/rvv/load_store/rvv_lsu_test_utils.h"

extern "C" {
int32_t fault_count   = 0;
uint32_t fault_mcause = 0;
uint32_t fault_mepc   = 0;
uint32_t fault_mtval  = 0;
uint32_t fault_vstart = 0;

extern rvv_test_func_t test_fn;

__attribute__((interrupt)) void coralnpu_exception_handler() {
  asm volatile(
      "csrr %[mcause], mcause \n"
      "csrr %[mepc], mepc \n"
      "csrr %[mtval], mtval \n"
      "csrr %[vstart], vstart \n"
      : [mcause] "=r"(fault_mcause), [mepc] "=r"(fault_mepc), [mtval] "=r"(fault_mtval),
        [vstart] "=r"(fault_vstart));

  fault_count += 1;

  if (test_fn != nullptr) {
    asm volatile("ebreak");
    while (1) {
    }
  }

  uint32_t next_mepc = fault_mepc + 4;
  asm volatile(
      "csrw vstart, zero \n"
      "csrw mepc, %[mepc] \n"
      :
      : [mepc] "r"(next_mepc));
}

// Indexed load with unsupported offset EEW=64 (width=111, mew=0, mop=01)
RVV_SUBTEST(vluxei64_v) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0000011, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Indexed store with unsupported offset EEW=64 (width=111, mew=0, mop=01)
RVV_SUBTEST(vsuxei64_v) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0000011, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Indexed load with offset EMUL = (16/8)*8 = 16 > 8 (SEW=8, LMUL=8, EEW_index=16)
RVV_SUBTEST(vluxei16_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m8, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0000011, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Indexed store with offset EMUL = (16/8)*8 = 16 > 8 (SEW=8, LMUL=8, EEW_index=16)
RVV_SUBTEST(vsuxei16_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m8, ta, ma \n"
      ".insn r 0b0100111, 0b101, 0b0000011, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Ordered indexed load with offset EMUL = (32/8)*4 = 16 > 8 (SEW=8, LMUL=4, EEW_index=32)
RVV_SUBTEST(vloxei32_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m4, ta, ma \n"
      ".insn r 0b0000111, 0b110, 0b0000111, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Ordered indexed store with offset EMUL = (32/16)*8 = 16 > 8 (SEW=16, LMUL=8, EEW_index=32)
RVV_SUBTEST(vsoxei32_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e16, m8, ta, ma \n"
      ".insn r 0b0100111, 0b110, 0b0000111, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Mask load encoding with unsupported width=101 (EEW=16, umop=01011)
RVV_SUBTEST(vlm_invalid_eew16) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0000001, x8, %[addr], x11 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Mask store encoding with unsupported width=101 (EEW=16, umop=01011)
RVV_SUBTEST(vsm_invalid_eew16) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b101, 0b0000001, x8, %[addr], x11 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register load encoding with unsupported width=111 (EEW=64, umop=01000)
RVV_SUBTEST(vl1re64_v) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b111, 0b0000001, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register store encoding with unsupported width=101 (EEW=16, umop=01000)
RVV_SUBTEST(vs1r_invalid_eew16) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b101, 0b0000001, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register store encoding with unsupported width=110 (EEW=32, umop=01000)
RVV_SUBTEST(vs1r_invalid_eew32) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b110, 0b0000001, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register store encoding with unsupported width=111 (EEW=64, umop=01000)
RVV_SUBTEST(vs1r_invalid_eew64) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b111, 0b0000001, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register load encoding with unsupported nf=010 (NREG=3, umop=01000)
RVV_SUBTEST(vl3re8_invalid_nf) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0100001, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register store encoding with unsupported nf=010 (NREG=3, umop=01000)
RVV_SUBTEST(vs3r_invalid_nf) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b000, 0b0100001, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register load encoding with unaligned vd=v1 for nf=001 (NREG=2, umop=01000)
RVV_SUBTEST(vl2re16_unaligned_vd) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0010001, x1, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register store encoding with unaligned vs3=v2 for nf=011 (NREG=4, umop=01000)
RVV_SUBTEST(vs4r_unaligned_vs3) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b000, 0b0110001, x2, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register load encoding with invalid vm=0 (masked, umop=01000)
RVV_SUBTEST(vl1re8_masked_vm0) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0000000, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Whole-register store encoding with invalid vm=0 (masked, umop=01000)
RVV_SUBTEST(vs1r_masked_vm0) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b000, 0b0000000, x8, %[addr], x8 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Fault-only-first encoding on store opcode (umop=10000)
RVV_SUBTEST(vsbff_invalid_store_ff) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0100111, 0b000, 0b0000001, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Unit-stride load with data EMUL = (16/8)*8 = 16 > 8 (SEW=8, LMUL=8, EEW=16)
RVV_SUBTEST(vle16_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m8, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0000001, x8, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Unit-stride store with data EMUL = (16/8)*8 = 16 > 8 (SEW=8, LMUL=8, EEW=16)
RVV_SUBTEST(vse16_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m8, ta, ma \n"
      ".insn r 0b0100111, 0b101, 0b0000001, x8, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Strided load with data EMUL = (32/8)*4 = 16 > 8 (SEW=8, LMUL=4, EEW=32)
RVV_SUBTEST(vlse32_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m4, ta, ma \n"
      ".insn r 0b0000111, 0b110, 0b0000101, x8, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Strided store with data EMUL = (32/8)*4 = 16 > 8 (SEW=8, LMUL=4, EEW=32)
RVV_SUBTEST(vsse32_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m4, ta, ma \n"
      ".insn r 0b0100111, 0b110, 0b0000101, x8, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Segment load with NFIELDS*EMUL = 2*8 = 16 > 8 (SEW=8, LMUL=4, EEW=16, nf=1)
RVV_SUBTEST(vlseg2e16_emul_over_8) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m4, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0010001, x8, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Unit-stride load with data EMUL = (8/32)*(1/2) = 1/8 < 1/4 (SEW=32, LMUL=1/2, EEW=8)
RVV_SUBTEST(vle8_emul_under_mf4) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e32, mf2, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0000001, x8, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Indexed load with offset EMUL = (8/32)*(1/2) = 1/8 < 1/4 (SEW=32, LMUL=1/2, EEW_index=8)
RVV_SUBTEST(vluxei8_emul_under_mf4) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e32, mf2, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0000011, x8, %[addr], x16 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Unit-stride load with unaligned vd=v1 when EMUL=2 (SEW=8, LMUL=1, EEW=16)
RVV_SUBTEST(vle16_unaligned_vd) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0000001, x1, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Indexed load with unaligned vs2=v1 when EMUL_index=2 (SEW=8, LMUL=1, EEW_index=16)
RVV_SUBTEST(vluxei16_unaligned_vs2) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0000011, x8, %[addr], x1 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Segment load wrapping past v31: vd=v30, NFIELDS=4, EMUL=1 -> 30 + 4 = 34 > 32
RVV_SUBTEST(vlseg4e8_vd_wrap) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0110001, x30, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Masked unit-stride load with vd=v0 (overlaps mask register v0.t)
RVV_SUBTEST(vle8_masked_vd_v0) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0000000, x0, %[addr], x0 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Narrowing indexed load with illegal overlap: SEW=8, LMUL=1, EEW_index=16, vd=v5 in vs2=[v4,v5]
RVV_SUBTEST(vluxei16_narrow_overlap) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b101, 0b0000011, x5, %[addr], x4 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Widening indexed load with illegal low overlap: SEW=16, LMUL=2, EEW_index=8, vs2=v4 in vd=[v4,v5]
RVV_SUBTEST(vluxei8_widen_low_overlap) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e16, m2, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0000011, x4, %[addr], x4 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Widening indexed load with fractional EMUL_index < 1 overlap: SEW=16, LMUL=1/2, EEW_index=8,
// vd=v4, vs2=v4
RVV_SUBTEST(vluxei8_widen_frac_overlap) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e16, mf2, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0000011, x4, %[addr], x4 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

// Segment indexed load with overlap: SEW=8, LMUL=1, nf=1 (NFIELDS=2), vd=[v4,v5], vs2=v5
RVV_SUBTEST(vluxseg2ei8_overlap) {
  uint32_t addr = 0x1000;
  uint32_t vl_discard;
  asm volatile(
      "vsetvli %[vl_discard], zero, e8, m1, ta, ma \n"
      ".insn r 0b0000111, 0b000, 0b0010011, x4, %[addr], x5 \n"
      : [vl_discard] "=&r"(vl_discard)
      : [addr] "r"(addr)
      : "vl", "vtype");
}

rvv_test_func_t test_fn __attribute__((section(".data"))) = nullptr;
}

int main() {
  rvv_run_subtests(test_fn);
  return 0;
}
