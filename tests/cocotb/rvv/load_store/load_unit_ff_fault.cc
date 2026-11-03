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

volatile uint32_t fault_count __attribute__((section(".data")))  = 0;
volatile uint32_t fault_mcause __attribute__((section(".data"))) = 0;
volatile uint32_t fault_mepc __attribute__((section(".data")))   = 0;
volatile uint32_t fault_mtval __attribute__((section(".data")))  = 0;
volatile uint32_t fault_vstart __attribute__((section(".data"))) = 0;

uint32_t req_vl __attribute__((section(".data")))      = 16;
uint32_t req_vtype __attribute__((section(".data")))   = 0;
uint32_t req_vstart __attribute__((section(".data")))  = 0;
uint32_t load_filler __attribute__((section(".data"))) = 0x5a5a5a5au;
uint32_t load_addr __attribute__((section(".data")))   = 0;
uint32_t post_vl __attribute__((section(".data")))     = 0;
uint32_t post_vstart __attribute__((section(".data"))) = 0;
uint32_t dep_vl __attribute__((section(".data")))      = 0;

alignas(16) uint8_t mask_data[16] __attribute__((section(".data")));
alignas(16) uint8_t dtcm_top_snap[16] __attribute__((section(".data")));
alignas(16) uint8_t store_data[256] __attribute__((section(".data")));
alignas(16) uint8_t dep_data[256] __attribute__((section(".data")));

// Recoverable trap handler: records CSRs and skips the faulting 4-byte
// instruction via mret so callers can inspect post-trap vl/vd state.
__attribute__((interrupt)) void ff_trap_handler(void) {
  uint32_t mcause, mepc, mtval, vstart;
  asm volatile(
      "csrr %[mcause], mcause\n"
      "csrr %[mepc], mepc\n"
      "csrr %[mtval], mtval\n"
      "csrr %[vstart], vstart\n"
      : [mcause] "=r"(mcause), [mepc] "=r"(mepc), [mtval] "=r"(mtval), [vstart] "=r"(vstart));
  fault_mcause = mcause;
  fault_mepc   = mepc;
  fault_mtval  = mtval;
  fault_vstart = vstart;
  fault_count  = fault_count + 1;
  mepc += 4;
  asm volatile("csrw mepc, %0" : : "r"(mepc));
}

// Helper: dump full 8-register group v8..v15 (128B) and v16..v23 (128B) using whole-reg stores
// so we observe the exact architectural VRF contents without disturbing vl/vtype!
static inline __attribute__((always_inline)) void dump_v8_and_v16() {
  asm volatile(
      "vs8r.v v8, (%[s0])\n"
      "vs8r.v v16, (%[s1])\n"
      :
      : [s0] "r"(store_data), [s1] "r"(dep_data)
      : "memory");
}

// Pre-fill v8..v15 with load_filler and v16..v23 with 0xA5 bytes, then restore req_vl/req_vtype.
#define SETUP_VRF_AND_VTYPE()                                                                  \
  asm volatile(                                                                                \
      "vsetvli zero, zero, e32, m8, ta, ma\n"                                                  \
      "li t0, -1\n"                                                                            \
      "vsetvli zero, t0, e32, m8, ta, ma\n"                                                    \
      "vmv.v.x v8, %[filler]\n"                                                                \
      "li t0, 0x33333333\n"                                                                    \
      "vmv.v.x v16, t0\n"                                                                      \
      "vlm.v v0, (%[mask_ptr])\n"                                                              \
      "vsetvl zero, %[vl], %[vtype]\n"                                                         \
      "csrw vstart, %[vstart]\n"                                                               \
      :                                                                                        \
      : [filler] "r"(load_filler), [mask_ptr] "r"(mask_data), [vl] "r"(req_vl),                \
        [vtype] "r"(req_vtype), [vstart] "r"(req_vstart)                                       \
      : "t0", "v0", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", \
        "v19", "v20", "v21", "v22", "v23", "vl", "vtype", "memory")

// Immediately after vle*ff.v (NO intervening vsetvl!), issue vadd.vi v16, v8, 1
// to verify younger RVV instructions see the reduced vl (interlock check!),
// then read post_vl and post_vstart.
#define RECORD_POST_STATE()                                                \
  asm volatile(                                                            \
      "vadd.vi v16, v8, 1\n"                                               \
      "csrr %[p_vl], vl\n"                                                 \
      "csrr %[p_vs], vstart\n"                                             \
      : [p_vl] "=r"(post_vl), [p_vs] "=r"(post_vstart)                     \
      :                                                                    \
      : "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "memory"); \
  dump_v8_and_v16()

__attribute__((used, retain)) void test_vle8ff_unmasked() {
  SETUP_VRF_AND_VTYPE();
  asm volatile("vle8ff.v v8, (%[addr])\n"
               :
               : [addr] "r"(load_addr)
               : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "memory");
  RECORD_POST_STATE();
}

__attribute__((used, retain)) void test_vle16ff_unmasked() {
  SETUP_VRF_AND_VTYPE();
  asm volatile("vle16ff.v v8, (%[addr])\n"
               :
               : [addr] "r"(load_addr)
               : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "memory");
  RECORD_POST_STATE();
}

__attribute__((used, retain)) void test_vle32ff_unmasked() {
  SETUP_VRF_AND_VTYPE();
  asm volatile("vle32ff.v v8, (%[addr])\n"
               :
               : [addr] "r"(load_addr)
               : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "memory");
  RECORD_POST_STATE();
}

__attribute__((used, retain)) void test_vle8ff_masked() {
  SETUP_VRF_AND_VTYPE();
  asm volatile("vle8ff.v v8, (%[addr]), v0.t\n"
               :
               : [addr] "r"(load_addr)
               : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "memory");
  RECORD_POST_STATE();
}

__attribute__((used, retain)) void test_vle16ff_masked() {
  SETUP_VRF_AND_VTYPE();
  asm volatile("vle16ff.v v8, (%[addr]), v0.t\n"
               :
               : [addr] "r"(load_addr)
               : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "memory");
  RECORD_POST_STATE();
}

__attribute__((used, retain)) void test_vlseg2e16ff_unmasked() {
  SETUP_VRF_AND_VTYPE();
  asm volatile("vlseg2e16ff.v v8, (%[addr])\n"
               :
               : [addr] "r"(load_addr)
               : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "memory");
  RECORD_POST_STATE();
}

__attribute__((used, retain)) void test_vlseg3e32ff_unmasked() {
  SETUP_VRF_AND_VTYPE();
  asm volatile("vlseg3e32ff.v v8, (%[addr])\n"
               :
               : [addr] "r"(load_addr)
               : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", "memory");
  RECORD_POST_STATE();
}

void (*impl)() __attribute__((section(".data"))) = &test_vle8ff_unmasked;

int main() {
  fault_count  = 0;
  fault_mcause = 0;
  fault_mepc   = 0;
  fault_mtval  = 0;
  fault_vstart = 0;
  asm volatile("csrw mtvec, %[h]" : : [h] "r"((uintptr_t)(&ff_trap_handler)));
  const volatile uint8_t *dtcm_top = reinterpret_cast<const volatile uint8_t *>(0x00017ff0u);
  for (int i = 0; i < 16; ++i) {
    dtcm_top_snap[i] = dtcm_top[i];
  }
  impl();
  return 0;
}

}  // extern "C"
