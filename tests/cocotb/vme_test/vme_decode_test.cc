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

uint32_t trap_count  = 0;
uint32_t last_mcause = 0;

__attribute__((interrupt)) void isr_handler(void) {
  uint32_t mcause;
  asm volatile("csrr %0, mcause" : "=r"(mcause));
  last_mcause = mcause;
  if (mcause == 2) {
    trap_count++;
  }
  asm volatile(".word 0x08000073");  // mpause (halt)
}

// vtle64 (nf=0b011: e64 cleanly rejected on 32-bit core)
__attribute__((used, retain)) void vtle64(void) {
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
__attribute__((used, retain)) void vtse64(void) {
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
__attribute__((used, retain)) void vtle_invalid_nf100(void) {
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
__attribute__((used, retain)) void vtse_invalid_nf100(void) {
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
__attribute__((used, retain)) void vtle_invalid_nf111(void) {
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
__attribute__((used, retain)) void vtse_invalid_nf111(void) {
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
__attribute__((used, retain)) void vtle8_masked_vm0(void) {
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
__attribute__((used, retain)) void vtse8_masked_vm0(void) {
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
__attribute__((used, retain)) void vtle8_nonzero_vd_vs3(void) {
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
__attribute__((used, retain)) void vtse8_nonzero_vd_vs3(void) {
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
__attribute__((used, retain)) void vtle8_nonzero_mop10(void) {
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
__attribute__((used, retain)) void vtse8_nonzero_mop01(void) {
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
__attribute__((used, retain)) void mew0_width7_load(void) {
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
__attribute__((used, retain)) void mew0_width7_store(void) {
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
__attribute__((used, retain)) void vill1_load(void) {
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
__attribute__((used, retain)) void vill1_store(void) {
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

test_func_t test_fn = vtle64;

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
