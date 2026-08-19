// Copyright 2025 Google LLC
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

#include <cstdint>

extern "C" {
void isr_wrapper(void);
__attribute__((naked)) void isr_wrapper(void) {
  asm volatile(
      "csrr t0, mepc \n"
      "addi t0, t0, 4 \n"  // Skip the faulting instruction (vse8.v is 4 bytes)
      "csrw mepc, t0 \n"
      "csrr t0, mcause \n"
      "li t1, 7 \n"        // Store access fault
      "bne t0, t1, 1f \n"  // If not store access fault, fail
      "csrr t0, mtval \n"
      "li t1, 0xA0000000 \n"  // Bad address
      "bne t0, t1, 1f \n"     // If not bad address, fail
      ".word 0x08000073 \n"   // mpause (halt) -> Success
      "1: ebreak \n"          // Fail
  );
}

}  // extern "C"

int main(int argc, char **argv) {
  // Store Fault (external) via Vector Store
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_wrapper)));

  size_t vl                     = 16;
  vuint8m1_t vec                = __riscv_vid_v_u8m1(vl);
  unsigned char *store_bad_addr = reinterpret_cast<unsigned char *>(0xA0000000);

  // This should trigger the store access fault
  __riscv_vse8_v_u8m1(store_bad_addr, vec, vl);

  return 0;  // Should not be reached if handled correctly by ISR (which halts)
}
