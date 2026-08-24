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
#include <stddef.h>
#include <stdint.h>

extern "C" {

typedef void (*test_func_t)(void);

alignas(16) int8_t in_buf[1024] __attribute__((section(".data")));
alignas(16) int8_t out_buf[1024] __attribute__((section(".data")));

uint32_t trap_count  = 0;
uint32_t last_mcause = 0;

__attribute__((interrupt)) void isr_handler(void) {
  trap_count++;
  uint32_t mcause_val;
  asm volatile("csrr %[mcause_val], mcause" : [mcause_val] "=r"(mcause_val));
  last_mcause = mcause_val;

  uint32_t mepc_val;
  asm volatile("csrr %[mepc_val], mepc" : [mepc_val] "=r"(mepc_val));
  mepc_val += 4;
  asm volatile("csrw mepc, %[mepc_val]" ::[mepc_val] "r"(mepc_val));
}

static inline void vme_configure(uint32_t mtwiden, uint32_t sew_code, uint32_t lmul_code) {
  uint32_t mtype   = (16 << 10) | (mtwiden & 0x3);
  uint32_t vtype   = (0xc0) | ((sew_code & 0x7) << 3) | (lmul_code & 0x7);
  uint32_t sixteen = 16;
  asm volatile(
      ".insn r 0b1010111, 0b111, 0b1000001, x0, %[mtype], %[vtype] \n"  // msetmtype
      ".insn r 0b1010111, 0b111, 0b1000010, x0, %[sixteen], x0 \n"      // msettn x0, 16
      :
      : [mtype] "r"(mtype), [vtype] "r"(vtype), [sixteen] "r"(sixteen)
      : "vl", "vtype");
}

// -----------------------------------------------------------------------------
// EEW8 Matrix Transposition (16x16 int8)
// -----------------------------------------------------------------------------

// Load 16 rows from in_buf into Tile 0, store 16 cols from Tile 0 to out_buf
__attribute__((used, retain)) void test_transpose_e8_row_to_col(void) {
  vme_configure(3, 0, 0);
  uint32_t vl_discard;
  asm volatile("vsetvli %[vl_discard], zero, e8, m1, ta, ma"
               : [vl_discard] "=&r"(vl_discard)::"vl", "vtype");
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss      = i;  // pattern = 0 (row), tile = 0, slice = i
    const int8_t *ptr = in_buf + i * 16;
    asm volatile(".insn r 0b0000111, 0b111, 0b0001001, zero, %[ptr], %[tss] \n"  // vtle8
                 :
                 : [ptr] "r"(ptr), [tss] "r"(tss), "m"(*(const int8_t(*)[16])ptr));
  }
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss = (1 << 24) | i;  // pattern = 1 (col), tile = 0, slice = i
    int8_t *ptr  = out_buf + i * 16;
    asm volatile(".insn r 0b0100111, 0b111, 0b0001001, zero, %[ptr], %[tss] \n"  // vtse8
                 : "=m"(*(int8_t(*)[16])ptr)
                 : [ptr] "r"(ptr), [tss] "r"(tss));
  }
}

// Load 16 cols from in_buf into Tile 0, store 16 rows from Tile 0 to out_buf
__attribute__((used, retain)) void test_transpose_e8_col_to_row(void) {
  vme_configure(3, 0, 0);
  uint32_t vl_discard;
  asm volatile("vsetvli %[vl_discard], zero, e8, m1, ta, ma"
               : [vl_discard] "=&r"(vl_discard)::"vl", "vtype");
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss      = (1 << 24) | i;  // pattern = 1 (col), tile = 0, slice = i
    const int8_t *ptr = in_buf + i * 16;
    asm volatile(".insn r 0b0000111, 0b111, 0b0001001, zero, %[ptr], %[tss] \n"  // vtle8
                 :
                 : [ptr] "r"(ptr), [tss] "r"(tss), "m"(*(const int8_t(*)[16])ptr));
  }
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss = i;  // pattern = 0 (row), tile = 0, slice = i
    int8_t *ptr  = out_buf + i * 16;
    asm volatile(".insn r 0b0100111, 0b111, 0b0001001, zero, %[ptr], %[tss] \n"  // vtse8
                 : "=m"(*(int8_t(*)[16])ptr)
                 : [ptr] "r"(ptr), [tss] "r"(tss));
  }
}

// -----------------------------------------------------------------------------
// EEW16 Matrix Transposition (16x16 int16)
// -----------------------------------------------------------------------------

// Load 16 rows from in_buf into Tile 0, store 16 cols from Tile 0 to out_buf
__attribute__((used, retain)) void test_transpose_e16_row_to_col(void) {
  vme_configure(2, 1, 1);
  uint32_t vl_discard;
  asm volatile("vsetvli %[vl_discard], zero, e16, m2, ta, ma"
               : [vl_discard] "=&r"(vl_discard)::"vl", "vtype");
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss       = i;  // pattern = 0 (row), tile = 0, slice = i
    const int16_t *ptr = reinterpret_cast<const int16_t *>(in_buf) + i * 16;
    asm volatile(".insn r 0b0000111, 0b111, 0b0011001, zero, %[ptr], %[tss] \n"  // vtle16
                 :
                 : [ptr] "r"(ptr), [tss] "r"(tss), "m"(*(const int16_t(*)[16])ptr));
  }
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss = (1 << 24) | i;  // pattern = 1 (col), tile = 0, slice = i
    int16_t *ptr = reinterpret_cast<int16_t *>(out_buf) + i * 16;
    asm volatile(".insn r 0b0100111, 0b111, 0b0011001, zero, %[ptr], %[tss] \n"  // vtse16
                 : "=m"(*(int16_t(*)[16])ptr)
                 : [ptr] "r"(ptr), [tss] "r"(tss));
  }
}

// Load 16 cols from in_buf into Tile 0, store 16 rows from Tile 0 to out_buf
__attribute__((used, retain)) void test_transpose_e16_col_to_row(void) {
  vme_configure(2, 1, 1);
  uint32_t vl_discard;
  asm volatile("vsetvli %[vl_discard], zero, e16, m2, ta, ma"
               : [vl_discard] "=&r"(vl_discard)::"vl", "vtype");
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss       = (1 << 24) | i;  // pattern = 1 (col), tile = 0, slice = i
    const int16_t *ptr = reinterpret_cast<const int16_t *>(in_buf) + i * 16;
    asm volatile(".insn r 0b0000111, 0b111, 0b0011001, zero, %[ptr], %[tss] \n"  // vtle16
                 :
                 : [ptr] "r"(ptr), [tss] "r"(tss), "m"(*(const int16_t(*)[16])ptr));
  }
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss = i;  // pattern = 0 (row), tile = 0, slice = i
    int16_t *ptr = reinterpret_cast<int16_t *>(out_buf) + i * 16;
    asm volatile(".insn r 0b0100111, 0b111, 0b0011001, zero, %[ptr], %[tss] \n"  // vtse16
                 : "=m"(*(int16_t(*)[16])ptr)
                 : [ptr] "r"(ptr), [tss] "r"(tss));
  }
}

// -----------------------------------------------------------------------------
// EEW32 Matrix Transposition (16x16 int32)
// -----------------------------------------------------------------------------

// Load 16 rows from in_buf into Tile 0, store 16 cols from Tile 0 to out_buf
__attribute__((used, retain)) void test_transpose_e32_row_to_col(void) {
  vme_configure(1, 2, 2);
  uint32_t vl_discard;
  asm volatile("vsetvli %[vl_discard], zero, e32, m4, ta, ma"
               : [vl_discard] "=&r"(vl_discard)::"vl", "vtype");
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss       = i;  // pattern = 0 (row), tile = 0, slice = i
    const int32_t *ptr = reinterpret_cast<const int32_t *>(in_buf) + i * 16;
    asm volatile(".insn r 0b0000111, 0b111, 0b0101001, zero, %[ptr], %[tss] \n"  // vtle32
                 :
                 : [ptr] "r"(ptr), [tss] "r"(tss), "m"(*(const int32_t(*)[16])ptr));
  }
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss = (1 << 24) | i;  // pattern = 1 (col), tile = 0, slice = i
    int32_t *ptr = reinterpret_cast<int32_t *>(out_buf) + i * 16;
    asm volatile(".insn r 0b0100111, 0b111, 0b0101001, zero, %[ptr], %[tss] \n"  // vtse32
                 : "=m"(*(int32_t(*)[16])ptr)
                 : [ptr] "r"(ptr), [tss] "r"(tss));
  }
}

// Load 16 cols from in_buf into Tile 0, store 16 rows from Tile 0 to out_buf
__attribute__((used, retain)) void test_transpose_e32_col_to_row(void) {
  vme_configure(1, 2, 2);
  uint32_t vl_discard;
  asm volatile("vsetvli %[vl_discard], zero, e32, m4, ta, ma"
               : [vl_discard] "=&r"(vl_discard)::"vl", "vtype");
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss       = (1 << 24) | i;  // pattern = 1 (col), tile = 0, slice = i
    const int32_t *ptr = reinterpret_cast<const int32_t *>(in_buf) + i * 16;
    asm volatile(".insn r 0b0000111, 0b111, 0b0101001, zero, %[ptr], %[tss] \n"  // vtle32
                 :
                 : [ptr] "r"(ptr), [tss] "r"(tss), "m"(*(const int32_t(*)[16])ptr));
  }
  for (uint32_t i = 0; i < 16; ++i) {
    uint32_t tss = i;  // pattern = 0 (row), tile = 0, slice = i
    int32_t *ptr = reinterpret_cast<int32_t *>(out_buf) + i * 16;
    asm volatile(".insn r 0b0100111, 0b111, 0b0101001, zero, %[ptr], %[tss] \n"  // vtse32
                 : "=m"(*(int32_t(*)[16])ptr)
                 : [ptr] "r"(ptr), [tss] "r"(tss));
  }
}

test_func_t test_fn = test_transpose_e8_row_to_col;

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
