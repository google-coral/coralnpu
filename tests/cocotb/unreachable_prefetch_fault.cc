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

#include <stdint.h>

int32_t iaf_count   = 0;
int32_t other_count = 0;

extern "C" {
void coralnpu_exception_handler() {
  uint32_t mcause;
  asm volatile("csrr %[mcause], mcause;" : [mcause] "=r"(mcause));
  if (mcause == 0x1) {
    iaf_count += 1;
  } else {
    other_count += 1;
  }
  asm volatile("ebreak");
  while (1) {
  }
}

__attribute__((used, retain, noreturn)) void mpause() {
  asm volatile(
      ".word 0x08000073;"
      "j -0x1000;");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void ecall() {
  asm volatile(
      "ecall;"
      "j -0x1000;");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void ebreak() {
  asm volatile(
      "ebreak;"
      "j -0x1000;");
  while (true) {
  }
}

__attribute__((used, retain)) void jalr() {
  asm volatile(
      "1:"
      "auipc a0, %%pcrel_hi(2f);"  // +0x1000
      "addi a0, a0, %%pcrel_lo(1b);"
      "jr a0;"
      "j -0x1000;"
      "2:"
      "nop;" ::[ff0] "r"(0xff0)
      : "a0");
}

__attribute__((used, retain)) void branch_forward() {
  asm volatile(
      "li a0, 0;"
      "beqz a0, 1f;"
      "j -0x1000;"
      "1:"
      "nop;" ::
          : "a0");
}

__attribute__((used, retain)) void branch_backward() {
  asm volatile(
      // Control flow: j->2->beqz->1->j->3
      "j 2f;"
      "1:"
      "j 3f;"
      "2:"
      "li a0, 0;"
      "beqz a0, 1b;"
      "j -0x1000;"
      "3:"
      "nop;" ::
          : "a0");
}

__attribute__((used, retain, noreturn)) void vill1() {
  // This behaves as illegal instructions when vector is disabled
  asm volatile(
      "vsetvl zero, %[vl], %[vtype];"
      "vadd.vi v0, v0, 0;"
      "j -0x1000;" ::[vl] "r"(1),
      [vtype] "r"(0x80000000)  // vill set
      : "a0", "v0");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void vill2() {
  // This behaves as illegal instructions when vector is disabled
  asm volatile(
      "vsetvl zero, %[vl], %[vtype];"
      "vadd.vi v0, v0, 0;"
      "j -0x1000;" ::[vl] "r"(1),
      [vtype] "r"(0x00000004)  // reserved lmul
      : "a0", "v0");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void unimp() {
  asm volatile(
      "unimp;"
      "j -0x1000;");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void wfi() {
  asm volatile(
      "li t0, 0x800;"
      "csrs mie, t0;"
      "wfi;"
      "j -0x1000;");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void load() {
  asm volatile(
      "lb a0, %[addr];"
      "j -0x1000;" ::[addr] "m"(*(const uint8_t *)0xFFFFFFFF)
      : "a0");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void store() {
  asm volatile(
      "sb a0, %[addr];"
      "j -0x1000;" ::[addr] "m"(*(const uint8_t *)0xFFFFFFFF));
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void csrr() {
  asm volatile(
      "csrr a0, 0xfff;"
      "j -0x1000;" ::
          : "a0");
  while (true) {
  }
}

__attribute__((used, retain, noreturn)) void csrw() {
  asm volatile(
      "csrw 0xfff, a0;"
      "j -0x1000;");
  while (true) {
  }
}
}

void (*impl)() __attribute__((section(".data"))) = mpause;

int main(int argc, char **argv) {
  impl();

  return 0;
}
