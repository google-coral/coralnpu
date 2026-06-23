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
//
// Smoke test for the VME (Zvt) non-tile state and mset* configuration
// instructions. The cocotb harness writes a table of input operands into
// `vme_inputs` before execution starts; this program iterates over the table,
// runs msetmtype/msettn/msettm/msettk on each row, and records the resulting
// mtype CSR snapshot and rd writebacks into the matching `vme_results` row.
// The harness also reads `vme_msetmtypei_result` to verify the single,
// immediate-encoded msetmtypei variant.

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

// -----------------------------------------------------------------------------
// Input table (written by the cocotb harness) and result table (read back).
// -----------------------------------------------------------------------------

// Maximum number of (input, result) rows the harness may exercise. Sized
// generously; the harness writes exactly the rows it wants and the program
// iterates `vme_num_cases` of them.
#define VME_MAX_CASES 8

struct VmeMsetCase {
  uint32_t mtype_value;  // msetmtype rs1
  uint32_t vtype_value;  // msetmtype rs2
  uint32_t msettn_avl;   // msettn   rs1
  uint32_t msettm_arg;   // msettm   rs1
  uint32_t msettk_arg;   // msettk   rs1
};

struct VmeMsetResult {
  uint32_t mtype_after_msetmtype;
  uint32_t rd_after_msettn;
  uint32_t rd_after_msettm;
  uint32_t mtype_after_msettm;
  uint32_t rd_after_msettk;
  uint32_t mtype_after_msettk;
};

// Volatile so the compiler does not constant-fold the zero initializer back
// in (the cocotb harness writes these slots before execute_from).
volatile uint32_t vme_num_cases __attribute__((section(".data")))                = 0;
volatile VmeMsetCase vme_inputs[VME_MAX_CASES] __attribute__((section(".data"))) = {};

VmeMsetResult vme_results[VME_MAX_CASES] __attribute__((section(".data"))) = {};
uint32_t vme_msetmtypei_result __attribute__((section(".data")))           = 0;

int main(int argc, char **argv) {
  // Each row sets mtype + vtype via msetmtype, then exercises msettn/m/k with
  // the per-row operand and snapshots mtype after the m/k updates.
  for (uint32_t i = 0; i < vme_num_cases; i++) {
    vme_msetmtype(vme_inputs[i].mtype_value, vme_inputs[i].vtype_value);
    vme_results[i].mtype_after_msetmtype = vme_read_mtype();

    vme_results[i].rd_after_msettn = vme_msettn(vme_inputs[i].msettn_avl);

    vme_results[i].rd_after_msettm    = vme_msettm(vme_inputs[i].msettm_arg);
    vme_results[i].mtype_after_msettm = vme_read_mtype();

    vme_results[i].rd_after_msettk    = vme_msettk(vme_inputs[i].msettk_arg);
    vme_results[i].mtype_after_msettk = vme_read_mtype();
  }

  // The msetmtypei variant has all operands encoded as immediates, so it can't
  // be parameterized from memory. Run the single hard-coded version and snap
  // its mtype readback so the harness can still verify the encoding path.
  vme_msetmtypei_mtwiden3_sew8();
  vme_msetmtypei_result = vme_read_mtype();

  return 0;
}
