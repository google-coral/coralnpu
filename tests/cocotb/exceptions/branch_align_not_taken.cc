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
// A conditional branch that is not taken must not trap, so any trap fails.
__attribute__((naked, aligned(4))) void isr_wrapper(void) { asm volatile("ebreak \n"); }
}  // extern "C"

int main(int argc, char **argv) {
  asm volatile("csrw mtvec, %0" ::"rK"((uint32_t)(&isr_wrapper)));

  // Each branch has a misaligned target (offset +2 or -2) and is not taken.
  asm volatile(
      "li a4, 1 \n"
      "li a5, 2 \n"
      "bne zero, zero, .+2 \n"
      "beq a4, a5, .+2 \n"
      "blt a5, a4, .+2 \n"
      "bge a4, a5, .+2 \n"
      "bltu a5, a4, .+2 \n"
      "bgeu a4, a5, .+2 \n"
      "bne zero, zero, .-2 \n"
      "blt a5, a4, .-2 \n"
      :
      :
      : "a4", "a5");

  return 0;
}
