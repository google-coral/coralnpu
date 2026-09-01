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

// MSTATUS Bit Field Definitions for RV32:
// Bit 31:    SD   (State Dirty = (FS == 3) || (VS == 3))
// Bits 14:13: FS   (Floating-point Status: 00=Off, 01=Initial, 10=Clean, 11=Dirty)
// Bits 12:11: MPP  (Machine Previous Privilege: 11 for M-mode)
// Bits 10:9:  VS   (Vector Status: 00=Off, 01=Initial, 10=Clean, 11=Dirty)
// Bit 7:     MPIE (Machine Previous Interrupt Enable)
// Bit 3:     MIE  (Machine Interrupt Enable)

constexpr uint32_t kMstatusReset          = 0x00003a00U;  // FS=1, MPP=3, VS=1, SD=0
constexpr uint32_t kMstatusClean          = 0x00005c00U;  // FS=2, MPP=3, VS=2, SD=0
constexpr uint32_t kMstatusFsCleanFsDirty = 0x80007c00U;  // SD=1, FS=3, MPP=3, VS=2
constexpr uint32_t kMstatusCleanVsDirty   = 0x80005e00U;  // SD=1, FS=2, MPP=3, VS=3
constexpr uint32_t kMstatusFsDirty        = 0x80007a00U;  // SD=1, FS=3, MPP=3, VS=1
constexpr uint32_t kMstatusVsDirty        = 0x80003e00U;  // SD=1, FS=1, MPP=3, VS=3
constexpr uint32_t kMstatusBothDirty      = 0x80007e00U;  // SD=1, FS=3, MPP=3, VS=3

uint32_t status_initial __attribute__((section(".data")))       = 0;
uint32_t status_f_insn __attribute__((section(".data")))        = 0;
uint32_t status_f_cleared __attribute__((section(".data")))     = 0;
uint32_t status_f_csr __attribute__((section(".data")))         = 0;
uint32_t status_v_insn __attribute__((section(".data")))        = 0;
uint32_t status_v_cleared __attribute__((section(".data")))     = 0;
uint32_t status_v_csr __attribute__((section(".data")))         = 0;
uint32_t status_both __attribute__((section(".data")))          = 0;
uint32_t status_partial_v __attribute__((section(".data")))     = 0;
uint32_t status_partial_f __attribute__((section(".data")))     = 0;
uint32_t status_clean __attribute__((section(".data")))         = 0;
uint32_t status_clean_f_dirty __attribute__((section(".data"))) = 0;
uint32_t status_clean_v_dirty __attribute__((section(".data"))) = 0;
uint32_t status_final __attribute__((section(".data")))         = 0;

static inline uint32_t read_mstatus() {
  uint32_t val;
  asm volatile("csrr %0, mstatus" : "=r"(val));
  return val;
}

static inline void write_mstatus(uint32_t val) { asm volatile("csrw mstatus, %0" : : "r"(val)); }

static inline void assert_eq(uint32_t actual, uint32_t expected) {
  if (actual != expected) {
    asm volatile("ebreak");
    while (1) {
    }
  }
}

int main() {
  // 1. Initial State Check:
  // After reset (or startup), mstatus must be 0x00003a00.
  // In case CRT modified FP/Vector registers during startup, write initial value back.
  write_mstatus(kMstatusReset);
  status_initial = read_mstatus();
  assert_eq(status_initial, kMstatusReset);

  // 2. FS Dirtying via Floating-Point Instruction:
  // Executing an FP instruction must dirty FS (FS -> 3) and set SD (SD -> 1).
  asm volatile("fmv.w.x ft0, zero");
  status_f_insn = read_mstatus();
  assert_eq(status_f_insn, kMstatusFsDirty);

  // 3. Clear FS back to Initial (01) by writing mstatus:
  write_mstatus(kMstatusReset);
  status_f_cleared = read_mstatus();
  assert_eq(status_f_cleared, kMstatusReset);

  // 4. FS Dirtying via Floating-Point CSR Write:
  // Writing to fflags / frm / fcsr must dirty FS and set SD.
  asm volatile("csrw fflags, zero");
  status_f_csr = read_mstatus();
  assert_eq(status_f_csr, kMstatusFsDirty);

  // Clear FS back to Initial:
  write_mstatus(kMstatusReset);
  assert_eq(read_mstatus(), kMstatusReset);

  // 5. VS Dirtying via Vector Instruction / Configuration:
  // Executing vsetvli or vector instruction must dirty VS (VS -> 3) and set SD (SD -> 1).
  asm volatile("vsetvli zero, zero, e32, m1, ta, ma");
  status_v_insn = read_mstatus();
  assert_eq(status_v_insn, kMstatusVsDirty);

  // 6. Clear VS back to Initial (01) by writing mstatus:
  write_mstatus(kMstatusReset);
  status_v_cleared = read_mstatus();
  assert_eq(status_v_cleared, kMstatusReset);

  // 7. VS Dirtying via Vector CSR Write:
  // Writing to vstart / vxrm / vxsat must dirty VS and set SD.
  asm volatile("csrw vstart, zero");
  status_v_csr = read_mstatus();
  assert_eq(status_v_csr, kMstatusVsDirty);

  // Clear VS back to Initial:
  write_mstatus(kMstatusReset);
  assert_eq(read_mstatus(), kMstatusReset);

  // 8. Both FS and VS Dirty:
  // Execute both an FP instruction and a Vector instruction.
  asm volatile("fmv.w.x ft0, zero");
  asm volatile("vsetvli zero, zero, e32, m1, ta, ma");
  status_both = read_mstatus();
  assert_eq(status_both, kMstatusBothDirty);

  // 9. Partial Clearing:
  // Write FS=01, VS=11 (0x00003e00) -> SD must remain 1 because VS is 3.
  write_mstatus(0x00003e00U);
  status_partial_v = read_mstatus();
  assert_eq(status_partial_v, kMstatusVsDirty);

  // Write FS=11, VS=01 (0x00007a00) -> SD must remain 1 because FS is 3.
  write_mstatus(0x00007a00U);
  status_partial_f = read_mstatus();
  assert_eq(status_partial_f, kMstatusFsDirty);

  // 10. Clean State (FS=10, VS=10, 0x00005c00):
  // Writing Clean state (SD=0).
  write_mstatus(kMstatusClean);
  status_clean = read_mstatus();
  assert_eq(status_clean, kMstatusClean);

  // 11. Clean -> Dirty transition on FP instruction:
  // Executing FP instruction must transition FS from Clean (2) to Dirty (3), SD becomes 1.
  asm volatile("fmv.w.x ft0, zero");
  status_clean_f_dirty = read_mstatus();
  assert_eq(status_clean_f_dirty, kMstatusFsCleanFsDirty);

  // Set Clean again:
  write_mstatus(kMstatusClean);
  assert_eq(read_mstatus(), kMstatusClean);

  // 12. Clean -> Dirty transition on Vector instruction:
  // Executing Vector instruction must transition VS from Clean (2) to Dirty (3), SD becomes 1.
  asm volatile("vsetvli zero, zero, e32, m1, ta, ma");
  status_clean_v_dirty = read_mstatus();
  assert_eq(status_clean_v_dirty, kMstatusCleanVsDirty);

  // Restore back to Initial:
  write_mstatus(kMstatusReset);
  status_final = read_mstatus();
  assert_eq(status_final, kMstatusReset);

  return 0;
}
