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

extern "C" {
extern uint8_t __data_start__[];
extern uint8_t __boot_hart[];

// Helper to perform address arithmetic relative to __data_start__ without triggering
// compiler -Warray-bounds warnings when forming addresses below __data_start__.
static inline uint8_t *data_start_offset(intptr_t offset) {
  return reinterpret_cast<uint8_t *>(reinterpret_cast<uintptr_t>(__data_start__) + offset);
}

int32_t fault_count   = 0;
uint32_t fault_mcause = 0;
uint32_t fault_mepc   = 0;
uint32_t fault_mtval  = 0;
uint32_t fault_vstart = 0;

uint8_t buffer[4096] __attribute__((section(".data")));
uint8_t *in_ptr __attribute__((section(".data")))  = &(buffer[0]);
uint8_t *out_ptr __attribute__((section(".data"))) = &(buffer[0]);
size_t vl __attribute__((section(".data")))        = 32;

void coralnpu_exception_handler() {
  asm volatile(
      "csrr %[mcause], mcause \n"
      "csrr %[mepc], mepc \n"
      "csrr %[mtval], mtval \n"
      "csrr %[vstart], vstart \n"
      : [mcause] "=r"(fault_mcause), [mepc] "=r"(fault_mepc), [mtval] "=r"(fault_mtval),
        [vstart] "=r"(fault_vstart));

  fault_count += 1;

  asm volatile("ebreak");
  while (1) {
  }
}

// Note on `asm volatile`:
// All faulting inline assembly blocks below are explicitly qualified with
// `volatile` because they perform memory accesses intended to fault, branch to
// trap handlers, or read/write hardware CSRs (e.g. vstart, mcause, mepc, mtval).
// These architectural side effects cannot be bound to standard C output
// constraints; `volatile` prevents compiler dead-code elimination, hoisting, or
// instruction reordering across the fault boundaries.

// 1. Scalar store fault preserves preset non-zero vstart
__attribute__((used, retain)) void run_scalar_fault_preserves_vstart() {
  asm volatile(
      "csrw vstart, %[preset_vstart] \n"
      ".globl faulting_insn_scalar \n"
      "faulting_insn_scalar: \n"
      "sw %[val], 0(%[bad_addr]) \n"
      :
      : [preset_vstart] "r"(3), [val] "r"(0xdeadbeef), [bad_addr] "r"(data_start_offset(-4)));
}

// 2. Vector Store fault with Vector Store at RS head (Vector -> Vector RS flush)
__attribute__((used, retain)) void run_unit_stride_fault_rs_flush() {
  uint32_t a = 12345678, b = 7, div_res;
  vuint8m4_t v = __riscv_vmv_v_x_u8m4(0, 32);
  asm volatile(
      "div %[div_res], %[a], %[b] \n"
      "vsetvli zero, %[vl], e8, m4, ta, ma \n"
      ".globl faulting_insn_unit \n"
      "faulting_insn_unit: \n"
      "vse8.v %[v], 0(%[bad_addr1]) \n"
      "vse8.v %[v], 0(%[bad_addr2]) \n"
      : [div_res] "=&r"(div_res)
      : [v] "vr"(v), [a] "r"(a), [b] "r"(b), [bad_addr1] "r"(data_start_offset(-4)),
        [bad_addr2] "r"((uint8_t *)0xA0000000), [vl] "r"(vl)
      : "vl", "vtype");
}

// 3. Negative-stride vector store crossing DTCM to ITCM boundary (mid-vector vstart fault)
__attribute__((used, retain)) void run_negative_stride_mid_vstart_fault() {
  vuint8m1_t v = __riscv_vle8_v_u8m1(in_ptr, vl);
  // Base is at __data_start__ + 8 (DTCM), stride is -4 bytes.
  // Element 0: __data_start__ + 8 (DTCM - valid)
  // Element 1: __data_start__ + 4 (DTCM - valid)
  // Element 2: __data_start__ + 0 (DTCM - valid)
  // Element 3: __data_start__ - 4 (ITCM - store access fault!) -> vstart = 3
  asm volatile(
      "vsetvli zero, %[vl], e8, m1, ta, ma \n"
      ".globl faulting_insn_neg_stride \n"
      "faulting_insn_neg_stride: \n"
      "vsse8.v %[v], (%[base]), %[stride] \n"
      :
      : [v] "vr"(v), [base] "r"(data_start_offset(8)), [stride] "r"(-4), [vl] "r"(8)
      : "vl", "vtype");
}

// 4. Indexed vector store fault mid-vector (vstart = 5)
__attribute__((used, retain)) void run_indexed_mid_vstart_fault() {
  vuint8m1_t v = __riscv_vle8_v_u8m1(in_ptr, 8);
  // Index array with elements 0..4 pointing to valid buffer offsets, and element 5 pointing to
  // 0xA0000000
  uint32_t indices[8] __attribute__((aligned(16))) = {
      0, 1, 2, 3, 4, (uint32_t)(0xA0000000 - (uintptr_t)buffer), 6, 7};
  vuint32m4_t vindex = __riscv_vle32_v_u32m4(indices, 8);
  asm volatile(
      "vsetvli zero, %[vl], e8, m1, ta, ma \n"
      ".globl faulting_insn_indexed \n"
      "faulting_insn_indexed: \n"
      "vsuxei32.v %[v], (%[base]), %[vindex] \n"
      :
      : [v] "vr"(v), [base] "r"(buffer), [vindex] "vr"(vindex), [vl] "r"(8)
      : "vl", "vtype");
}

// 5. Segment store with NF=3 and negative stride (mid-vector vstart fault with NF=3 division)
__attribute__((used, retain)) void run_seg3_negative_stride_mid_vstart_fault() {
  vuint8m1_t v0 = __riscv_vle8_v_u8m1(in_ptr, vl);
  // Base is at __data_start__ + 18 (DTCM), stride is -6 bytes.
  // Element 0: __data_start__ + 18 (DTCM - valid)
  // Element 1: __data_start__ + 12 (DTCM - valid)
  // Element 2: __data_start__ + 6 (DTCM - valid)
  // Element 3: __data_start__ + 0 (DTCM - valid: fields 0,1,2 at +0, +1, +2)
  // Element 4: __data_start__ - 6 (ITCM - store access fault!) -> vstart = 4
  asm volatile(
      "vsetvli zero, %[vl], e8, m1, ta, ma \n"
      ".globl faulting_insn_seg3 \n"
      "faulting_insn_seg3: \n"
      "vssseg3e8.v %[v0], (%[base]), %[stride] \n"
      :
      : [v0] "vr"(v0), [base] "r"(data_start_offset(18)), [stride] "r"(-6), [vl] "r"(8)
      : "vl", "vtype");
}

// 6. Segment store with NF=5 and negative stride (mid-vector vstart fault with NF=5 division)
__attribute__((used, retain)) void run_seg5_negative_stride_mid_vstart_fault() {
  vuint8m1_t v0 = __riscv_vle8_v_u8m1(in_ptr, vl);
  // Base is at __data_start__ + 20 (DTCM), stride is -10 bytes.
  // Element 0: __data_start__ + 20 (DTCM - valid)
  // Element 1: __data_start__ + 10 (DTCM - valid)
  // Element 2: __data_start__ + 0 (DTCM - valid: fields 0..4 at +0..+4)
  // Element 3: __data_start__ - 10 (ITCM - store access fault!) -> vstart = 3
  asm volatile(
      "vsetvli zero, %[vl], e8, m1, ta, ma \n"
      ".globl faulting_insn_seg5 \n"
      "faulting_insn_seg5: \n"
      "vssseg5e8.v %[v0], (%[base]), %[stride] \n"
      :
      : [v0] "vr"(v0), [base] "r"(data_start_offset(20)), [stride] "r"(-10), [vl] "r"(8)
      : "vl", "vtype");
}

// 7. Vector Load fault with Scalar Store at RS head (Vector -> Scalar RS flush)
__attribute__((used, retain)) void run_vector_load_fault_rs_flush() {
  uint32_t a = 12345678, b = 7, div_res;
  vuint8m4_t v;
  asm volatile(
      "div %[div_res], %[a], %[b] \n"
      "vsetvli zero, %[vl], e8, m4, ta, ma \n"
      ".globl faulting_insn_load \n"
      "faulting_insn_load: \n"
      "vle8.v %[v], 0(%[bad_addr1]) \n"
      "sw %[val], 0(%[bad_addr2]) \n"
      : [div_res] "=&r"(div_res), [v] "=vr"(v)
      : [a] "r"(a), [b] "r"(b), [val] "r"(0xdeadbeef), [bad_addr1] "r"((uint8_t *)0xA0000000),
        [bad_addr2] "r"((uint8_t *)0xA0000000), [vl] "r"(vl)
      : "vl", "vtype");
}

// 8. Scalar Store fault with Vector Store at RS head (Scalar -> Vector RS flush)
__attribute__((used, retain)) void run_scalar_mixed_fault_rs_flush() {
  uint32_t a = 12345678, b = 7, div_res;
  vuint8m4_t v = __riscv_vmv_v_x_u8m4(0, 32);
  asm volatile(
      "div %[div_res], %[a], %[b] \n"
      "vsetvli zero, %[vl], e8, m4, ta, ma \n"
      ".globl faulting_insn_scalar_mixed \n"
      "faulting_insn_scalar_mixed: \n"
      "sw %[val], 0(%[bad_addr1]) \n"
      "vse8.v %[v], 0(%[bad_addr2]) \n"
      : [div_res] "=&r"(div_res)
      : [v] "vr"(v), [a] "r"(a), [b] "r"(b), [val] "r"(0xdeadbeef),
        [bad_addr1] "r"(data_start_offset(-4)), [bad_addr2] "r"(data_start_offset(-8)), [vl] "r"(vl)
      : "vl", "vtype");
}

// 9. Scalar Store fault with Scalar Store at RS head (Scalar -> Scalar RS flush)
__attribute__((used, retain)) void run_scalar_to_scalar_fault_rs_flush() {
  uint32_t a = 12345678, b = 7, div_res;
  asm volatile(
      "div %[div_res], %[a], %[b] \n"
      ".globl faulting_insn_scalar_scalar \n"
      "faulting_insn_scalar_scalar: \n"
      "sw %[val], 0(%[bad_addr1]) \n"
      "sw %[val], 0(%[bad_addr2]) \n"
      : [div_res] "=&r"(div_res)
      : [a] "r"(a), [b] "r"(b), [val] "r"(0xdeadbeef), [bad_addr1] "r"(data_start_offset(-4)),
        [bad_addr2] "r"(data_start_offset(-8)));
}

void (*test_fn)() __attribute__((section(".data"))) = &run_scalar_fault_preserves_vstart;
}

int main() {
  test_fn();
  return 0;
}
