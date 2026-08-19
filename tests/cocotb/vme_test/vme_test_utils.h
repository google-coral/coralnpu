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

#ifndef TESTS_COCOTB_VME_TEST_VME_TEST_UTILS_H_
#define TESTS_COCOTB_VME_TEST_VME_TEST_UTILS_H_

#include <cstdint>

// -----------------------------------------------------------------------------
// VME instruction wrappers
//
// The toolchain does not know about the Zvt mset* opcodes, so each helper emits
// the encoding via GAS' `.insn r` directive. Tagged always_inline so the named
// register-variable bindings (`asm("a0")`, `asm("t0")`) take effect at the call
// site rather than across a real function boundary.
//
// All mset* share: opcode = 0b1010111, funct3 = 0b111. Bit 31 = 1 (the high
// bit of funct7) distinguishes them from vsetvl/vsetvli/vsetivli.
// -----------------------------------------------------------------------------

// msetmtype rs1, rs2  (rd = x0)
//   mtype <- rs1; vtype <- rs2 (vsetvl semantics); vl <- 0.
// Encoding: funct7=0b1000001, funct3=0b111, opcode=0b1010111.
static inline __attribute__((always_inline)) void vme_msetmtype(uint32_t mtype_value,
                                                                uint32_t vtype_value) {
  register uint32_t a0_arg asm("a0") = mtype_value;
  register uint32_t a1_arg asm("a1") = vtype_value;
  asm volatile(".insn r 0b1010111, 0b111, 0b1000001, x0, a0, a1" : : "r"(a0_arg), "r"(a1_arg));
}

// msettn rd, rs1
//   vl <- min(rs1, LMUL*EVE, ETE);  rd <- vl
// Encoding: funct7=0b1000010; sub-funct (rs2 field) = 0 (msettn).
static inline __attribute__((always_inline)) uint32_t vme_msettn(uint32_t avl) {
  register uint32_t a0_arg asm("a0") = avl;
  register uint32_t t0_out asm("t0");
  asm volatile(".insn r 0b1010111, 0b111, 0b1000010, t0, a0, x0" : "=r"(t0_out) : "r"(a0_arg));
  return t0_out;
}

// msettm rd, rs1
//   mtype.tm <- min(rs1, LMUL*EVE, ETE);  rd <- tm
// Encoding: funct7=0b1000010; sub-funct (rs2 field) = 1 (msettm).
static inline __attribute__((always_inline)) uint32_t vme_msettm(uint32_t new_tm) {
  register uint32_t a0_arg asm("a0") = new_tm;
  register uint32_t t0_out asm("t0");
  asm volatile(".insn r 0b1010111, 0b111, 0b1000010, t0, a0, x1" : "=r"(t0_out) : "r"(a0_arg));
  return t0_out;
}

// msettk rd, rs1
//   mtype.tk <- min(rs1, KMAX);  rd <- tk
// Encoding: funct7=0b1000010; sub-funct (rs2 field) = 2 (msettk).
static inline __attribute__((always_inline)) uint32_t vme_msettk(uint32_t new_tk) {
  register uint32_t a0_arg asm("a0") = new_tk;
  register uint32_t t0_out asm("t0");
  asm volatile(".insn r 0b1010111, 0b111, 0b1000010, t0, a0, x2" : "=r"(t0_out) : "r"(a0_arg));
  return t0_out;
}

// msetmtypei mtype_imm=3 (mtwiden=3), vsew=0 (SEW8), rd=x0.
//
// Both immediates are encoded inside the instruction word, so this helper is
// specialized to the single (mtype_imm, vsew) combination used by the test.
// Layout (via .insn r): rs2 holds {vsew[1:0], sub_funct=0b011}, rs1 holds
// mtype_imm[4:0]. For vsew=0 and mtype_imm=3 both are x3 (0b00011).
static inline __attribute__((always_inline)) void vme_msetmtypei_mtwiden3_sew8(void) {
  asm volatile(".insn r 0b1010111, 0b111, 0b1000010, x0, x3, x3" ::: "memory");
}

// mtype CSR (0xC23) read helper. Spec layout: tm[23:10] | tk[6:5] | mtwiden[1:0].
static inline __attribute__((always_inline)) uint32_t vme_read_mtype(void) {
  uint32_t out;
  asm volatile("csrr %0, 0xC23" : "=r"(out));
  return out;
}

// mtype value: tm[23:10] | tk[6:5] | mtwiden[1:0].
static constexpr uint32_t MtypeValue(uint32_t tm, uint32_t tk, uint32_t mtwiden) {
  return ((tm & 0x3FFF) << 10) | ((tk & 0x3) << 5) | (mtwiden & 0x3);
}

#endif  // TESTS_COCOTB_VME_TEST_VME_TEST_UTILS_H_
