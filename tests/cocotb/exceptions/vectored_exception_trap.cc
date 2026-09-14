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
void isr_wrapper(void);
__attribute__((naked, aligned(64))) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mepc \n"
      "addi t0, t0, 4 \n"
      "csrw mepc, t0 \n"
      "csrr t0, mcause \n"
      "li t1, 11 \n"
      "beq t0, t1, 0f \n"
      "ebreak \n"
      "0: .word 0x08000073 \n");
}
}  // extern "C"

int main(int argc, char **argv) {
  // Attempt to write mtvec with MODE = 1 (Vectored mode).
  // Under RISC-V Privileged Architecture Specification (Section 3.1.7),
  // mtvec is a WARL register and MODE only accepts supported modes.
  // Since CoralNPU only supports Direct mode (MODE=0), bits [1:0] must be
  // hardwired to 0.
  uint32_t base_addr = reinterpret_cast<uintptr_t>(&isr_wrapper);
  uint32_t mtvec_val = base_addr | 1;
  asm volatile("csrw mtvec, %0" ::"r"(mtvec_val));

  // Read back mtvec to verify that bits [1:0] were masked to 0.
  // In an unpatched simulator accepting vectored mode, read-back returns
  // base_addr | 1, causing a register writeback mismatch against RTL.
  uint32_t read_back = 0;
  asm volatile("csrr %0, mtvec" : "=r"(read_back));
  if (read_back != base_addr) {
    return 1;
  }

  // Also verify attempting to write MODE = 3 (Reserved) is masked to 0.
  mtvec_val = base_addr | 3;
  asm volatile("csrw mtvec, %0" ::"r"(mtvec_val));
  asm volatile("csrr %0, mtvec" : "=r"(read_back));
  if (read_back != base_addr) {
    return 1;
  }

  // Trigger synchronous exception via ECALL (cause = 11 in M-mode).
  // Traps must jump directly to BASE (isr_wrapper) in Direct mode.
  asm volatile("ecall");

  return 0;
}
