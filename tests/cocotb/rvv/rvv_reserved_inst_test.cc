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

#include <stdint.h>

namespace {

// RVV major opcodes.
constexpr uint32_t kOpLoadFp  = 0x07;
constexpr uint32_t kOpStoreFp = 0x27;
constexpr uint32_t kOpV       = 0x57;

// OP-V funct3 values.
constexpr uint32_t kOpivv = 0b000;
constexpr uint32_t kOpfvv = 0b001;
constexpr uint32_t kOpmvv = 0b010;
constexpr uint32_t kOpivi = 0b011;
constexpr uint32_t kOpivx = 0b100;
constexpr uint32_t kOpmvx = 0b110;

// Load/store width encodings.
constexpr uint32_t kWidth8  = 0b000;
constexpr uint32_t kWidth16 = 0b101;
constexpr uint32_t kWidth32 = 0b110;

// Load/store mop encodings.
constexpr uint32_t kMopUnit      = 0b00;
constexpr uint32_t kMopUnordered = 0b01;
constexpr uint32_t kMopStrided   = 0b10;
constexpr uint32_t kMopOrdered   = 0b11;

// Unit-stride lumop/sumop encodings.
constexpr uint32_t kUmopRegular    = 0b00000;
constexpr uint32_t kUmopWholeReg   = 0b01000;
constexpr uint32_t kUmopMask       = 0b01011;
constexpr uint32_t kUmopFaultFirst = 0b10000;

// OP-V funct6 values.
constexpr uint32_t kF6Vadd           = 0b000000;
constexpr uint32_t kF6Vredsum        = 0b000000;
constexpr uint32_t kF6Vfadd          = 0b000000;
constexpr uint32_t kF6Vrgather       = 0b001100;
constexpr uint32_t kF6VslideupRgei16 = 0b001110;
constexpr uint32_t kF6Vadc           = 0b010000;
constexpr uint32_t kF6Vwrxunary0     = 0b010000;
constexpr uint32_t kF6Vmadc          = 0b010001;
constexpr uint32_t kF6Vxunary0       = 0b010010;
constexpr uint32_t kF6Vmunary0       = 0b010100;
constexpr uint32_t kF6VmergeVmv      = 0b010111;
constexpr uint32_t kF6Vcompress      = 0b010111;
constexpr uint32_t kF6Vmseq          = 0b011000;
constexpr uint32_t kF6Vmand          = 0b011001;
constexpr uint32_t kF6VsmulVmvnrr    = 0b100111;
constexpr uint32_t kF6Vmacc          = 0b101101;
constexpr uint32_t kF6Vnsrl          = 0b101100;
constexpr uint32_t kF6Vnclip         = 0b101111;
constexpr uint32_t kF6Vwredsum       = 0b110001;
constexpr uint32_t kF6Vwadd          = 0b110001;
constexpr uint32_t kF6VwaddW         = 0b110101;
constexpr uint32_t kF6VwsubuW        = 0b110110;
constexpr uint32_t kF6Vfwmaccbf16    = 0b111011;
constexpr uint32_t kF6Vwmaccu        = 0b111100;
constexpr uint32_t kF6Vwmacc         = 0b111101;
constexpr uint32_t kF6Vwmaccus       = 0b111110;
constexpr uint32_t kF6Reserved3f     = 0b111111;

// Fixed ABI register numbers used in explicit binary encodings.
constexpr uint32_t kRegA0 = 10;
constexpr uint32_t kRegA1 = 11;

constexpr uint32_t EncOpV(uint32_t funct6, uint32_t vm, uint32_t vs2, uint32_t vs1, uint32_t funct3,
                          uint32_t vd) {
  return ((funct6 & 0x3fU) << 26) | ((vm & 0x1U) << 25) | ((vs2 & 0x1fU) << 20) |
         ((vs1 & 0x1fU) << 15) | ((funct3 & 0x7U) << 12) | ((vd & 0x1fU) << 7) | kOpV;
}

constexpr uint32_t EncVl(uint32_t nf, uint32_t mew, uint32_t mop, uint32_t vm,
                         uint32_t lumop_or_vs2, uint32_t rs1, uint32_t width, uint32_t vd) {
  return ((nf & 0x7U) << 29) | ((mew & 0x1U) << 28) | ((mop & 0x3U) << 26) | ((vm & 0x1U) << 25) |
         ((lumop_or_vs2 & 0x1fU) << 20) | ((rs1 & 0x1fU) << 15) | ((width & 0x7U) << 12) |
         ((vd & 0x1fU) << 7) | kOpLoadFp;
}

constexpr uint32_t EncVs(uint32_t nf, uint32_t mew, uint32_t mop, uint32_t vm,
                         uint32_t sumop_or_vs2, uint32_t rs1, uint32_t width, uint32_t vs3) {
  return ((nf & 0x7U) << 29) | ((mew & 0x1U) << 28) | ((mop & 0x3U) << 26) | ((vm & 0x1U) << 25) |
         ((sumop_or_vs2 & 0x1fU) << 20) | ((rs1 & 0x1fU) << 15) | ((width & 0x7U) << 12) |
         ((vs3 & 0x1fU) << 7) | kOpStoreFp;
}

// vtype encodings (ta=1, ma=1 -> bits[7:6] = 0b11 = 0xc0).
enum VtypeConfig : uint32_t {
  kE8Mf4  = 0xc6,
  kE8Mf2  = 0xc7,
  kE8M1   = 0xc0,
  kE8M2   = 0xc1,
  kE8M4   = 0xc2,
  kE8M8   = 0xc3,
  kE16Mf2 = 0xcf,
  kE16M1  = 0xc8,
  kE16M2  = 0xc9,
  kE16M4  = 0xca,
  kE32M1  = 0xd0,
  kE32M2  = 0xd1,
  kE32M8  = 0xd3,
};

}  // namespace

struct FailureRecord {
  uint32_t case_id;
  uint32_t expected_trap;
  uint32_t got_trap;
  uint32_t got_mcause;
  uint32_t got_mepc;
  uint32_t expected_pc;
  uint32_t got_mtval;
  uint32_t expected_mtval;
};

constexpr uint32_t kMaxFailures = 96;

extern "C" {

volatile uint32_t trap_count __attribute__((section(".data")))     = 0;
volatile uint32_t trap_mcause __attribute__((section(".data")))    = 0;
volatile uint32_t trap_mepc __attribute__((section(".data")))      = 0;
volatile uint32_t trap_mtval __attribute__((section(".data")))     = 0;
volatile uint32_t trap_resume_pc __attribute__((section(".data"))) = 0;

uint32_t num_cases __attribute__((section(".data")))                                = 0;
uint32_t num_passed __attribute__((section(".data")))                               = 0;
uint32_t num_failures __attribute__((section(".data")))                             = 0;
FailureRecord failures[kMaxFailures] __attribute__((section(".data"), aligned(16))) = {};

uint32_t mem_buf[64] __attribute__((section(".data"), aligned(64)))   = {};
uint32_t check_buf[16] __attribute__((section(".data"), aligned(64))) = {};

}  // extern "C"

// Trap handler saving temporaries on stack, recording trap CSRs, and advancing
// mepc by 4 bytes (or jumping to trap_resume_pc if non-zero).
asm(R"(
  .pushsection .text
  .p2align 2
  .global reserved_inst_trap_handler
reserved_inst_trap_handler:
  addi sp, sp, -16
  sw   t0, 0(sp)
  sw   t1, 4(sp)
  sw   t2, 8(sp)

  la   t0, trap_count
  lw   t1, 0(t0)
  addi t1, t1, 1
  sw   t1, 0(t0)

  csrr t1, mcause
  la   t0, trap_mcause
  sw   t1, 0(t0)

  csrr t1, mepc
  la   t0, trap_mepc
  sw   t1, 0(t0)

  csrr t2, mtval
  la   t0, trap_mtval
  sw   t2, 0(t0)

  la   t0, trap_resume_pc
  lw   t2, 0(t0)
  bnez t2, 1f
  addi t2, t1, 4
1:
  csrw mepc, t2

  lw   t0, 0(sp)
  lw   t1, 4(sp)
  lw   t2, 8(sp)
  addi sp, sp, 16
  mret
  .popsection
)");

namespace {

using StubFn = void (*)();

struct StubCase {
  uint16_t case_id;
  uint8_t vtype;
  uint8_t avl;
  uint8_t expect_trap;
  uint8_t frm;
  uint8_t vstart;
  uint8_t check_mem_unchanged;
  StubFn stub;
  uint32_t inst_word;
};

// Declares and emits an 8-byte stub in ITCM: `<inst_word>; ret`.
#define DECLARE_STUB(ID) extern "C" void Stub##ID();

#define EMIT_STUB(ID, INST_EXPR) \
  asm volatile(                  \
      ".p2align 2 \n\t"          \
      ".global Stub" #ID         \
      " \n"                      \
      "Stub" #ID                 \
      ": \n\t"                   \
      ".word %0 \n\t"            \
      "ret \n\t"                 \
      :                          \
      : "i"(INST_EXPR));

#define FOR_EACH_STUB(V)                                                     \
  /* Group 1: RVV 1.0 §5.2 multi-EEW source and accumulator overlap cases */ \
  V(101, EncVs(0, 0, kMopUnit, 0, kUmopRegular, kRegA0, kWidth8, 0))         \
  V(103, EncVs(0, 0, kMopUnit, 0, kUmopRegular, kRegA0, kWidth16, 0))        \
  V(104, EncVs(0, 0, kMopStrided, 0, kRegA1, kRegA0, kWidth16, 0))           \
  V(105, EncVs(0, 0, kMopUnordered, 0, 4, kRegA0, kWidth8, 0))               \
  V(106, EncVs(0, 0, kMopUnordered, 0, 0, kRegA0, kWidth8, 4))               \
  V(107, EncVl(0, 0, kMopUnordered, 0, 0, kRegA0, kWidth8, 4))               \
  V(108, EncVl(0, 0, kMopOrdered, 0, 0, kRegA0, kWidth16, 4))                \
  V(109, EncOpV(kF6Vwmacc, 1, 9, 10, kOpmvv, 8))                             \
  V(110, EncOpV(kF6Vwmacc, 1, 10, 9, kOpmvv, 8))                             \
  V(111, EncOpV(kF6Vwmaccu, 1, 9, kRegA1, kOpmvx, 8))                        \
  V(112, EncOpV(kF6Vwmaccus, 1, 9, kRegA1, kOpmvx, 8))                       \
  V(113, EncOpV(kF6Vfwmaccbf16, 1, 9, 10, kOpfvv, 8))                        \
  /* Group 2: Additional §5.2 multi-EEW source & fractional-LMUL overlaps */ \
  V(201, EncVs(0, 0, kMopUnordered, 1, 4, kRegA0, kWidth16, 4))              \
  V(202, EncVs(0, 0, kMopOrdered, 1, 5, kRegA0, kWidth8, 4))                 \
  V(203, EncVs(1, 0, kMopUnordered, 1, 4, kRegA0, kWidth16, 4))              \
  V(204, EncOpV(kF6VwaddW, 1, 8, 8, kOpmvv, 4))                              \
  V(205, EncOpV(kF6VwaddW, 1, 8, 9, kOpmvv, 4))                              \
  V(206, EncOpV(kF6VwsubuW, 1, 8, 9, kOpmvv, 4))                             \
  V(207, EncOpV(kF6Vnsrl, 1, 8, 8, kOpivv, 4))                               \
  V(208, EncOpV(kF6Vnsrl, 1, 8, 9, kOpivv, 4))                               \
  V(209, EncOpV(kF6Vnclip, 1, 8, 9, kOpivv, 4))                              \
  V(210, EncOpV(kF6VslideupRgei16, 1, 8, 8, kOpivv, 4))                      \
  V(211, EncOpV(kF6VslideupRgei16, 1, 8, 9, kOpivv, 4))                      \
  V(212, EncOpV(kF6Vcompress, 1, 8, 8, kOpmvv, 4))                           \
  V(213, EncOpV(kF6Vcompress, 1, 8, 9, kOpmvv, 4))                           \
  V(214, EncOpV(kF6Vwredsum, 1, 8, 9, kOpivv, 4))                            \
  V(215, EncOpV(kF6Vadd, 0, 0, 2, kOpivv, 4))                                \
  V(216, EncOpV(kF6Vadd, 0, 2, 0, kOpivv, 4))                                \
  V(217, EncOpV(kF6Vmacc, 0, 2, 0, kOpmvv, 4))                               \
  V(218, EncOpV(kF6Vadc, 0, 0, 2, kOpivv, 4))                                \
  V(219, EncOpV(kF6Vmadc, 0, 0, 4, kOpivv, 2))                               \
  V(220, EncOpV(kF6VmergeVmv, 0, 0, 2, kOpivv, 4))                           \
  V(221, EncOpV(kF6Vmseq, 0, 0, 4, kOpivv, 2))                               \
  V(222, EncOpV(kF6Vredsum, 0, 0, 2, kOpmvv, 4))                             \
  V(223, EncOpV(kF6Vfadd, 0, 0, 2, kOpfvv, 4))                               \
  V(224, EncOpV(kF6Vwadd, 1, 4, 6, kOpmvv, 4))                               \
  V(225, EncOpV(kF6Vxunary0, 1, 4, 0b00110, kOpmvv, 4))                      \
  V(226, EncVl(0, 0, kMopUnordered, 1, 4, kRegA0, kWidth8, 4))               \
  /* Group 3: Reserved encodings previously silently retired as NOPs */      \
  V(301, EncOpV(kF6Vadd, 0, 2, 4, kOpivv, 0))                                \
  V(302, EncVl(0, 0, kMopUnit, 0, kUmopRegular, kRegA0, kWidth8, 0))         \
  V(303, EncVl(0, 0, kMopUnordered, 0, 4, kRegA0, kWidth8, 0))               \
  V(304, EncOpV(kF6Vnsrl, 1, 8, 1, kOpivi, 9))                               \
  V(305, EncOpV(kF6VslideupRgei16, 1, 4, 1, kOpivi, 4))                      \
  V(306, EncOpV(kF6Vrgather, 1, 4, 2, kOpivv, 4))                            \
  V(307, EncOpV(kF6Vrgather, 1, 2, 4, kOpivv, 4))                            \
  V(308, EncOpV(kF6Vmunary0, 1, 4, 0b10000, kOpmvv, 4))                      \
  V(309, EncOpV(kF6Vcompress, 1, 4, 2, kOpmvv, 4))                           \
  V(310, EncOpV(kF6Vmseq, 1, 8, 10, kOpivv, 9))                              \
  V(311, EncOpV(kF6Vadd, 1, 4, 6, kOpivv, 3))                                \
  V(312, EncOpV(kF6Vadd, 1, 3, 6, kOpivv, 4))                                \
  V(313, EncOpV(kF6Vadd, 1, 4, 3, kOpivv, 6))                                \
  V(314, EncVl(0, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 3))        \
  V(315, EncVs(0, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 3))        \
  V(316, EncVl(0, 0, kMopUnordered, 1, 3, kRegA0, kWidth16, 4))              \
  V(317, EncOpV(kF6Vwadd, 1, 8, 12, kOpmvv, 4))                              \
  V(318, EncOpV(kF6Vwadd, 1, 8, 16, kOpmvv, 0))                              \
  V(319, EncOpV(kF6Vxunary0, 1, 8, 0b00110, kOpmvv, 4))                      \
  V(320, EncOpV(kF6Vxunary0, 1, 8, 0b00100, kOpmvv, 4))                      \
  V(321, EncVl(0, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 0))        \
  V(322, EncOpV(kF6Vfadd, 1, 8, 12, kOpfvv, 4))                              \
  V(323, EncOpV(kF6Vfwmaccbf16, 1, 8, 12, kOpfvv, 4))                        \
  V(324, EncOpV(kF6Vfadd, 1, 8, 12, kOpfvv, 4))                              \
  V(325, EncVl(1, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 0))        \
  V(326, EncVl(2, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 30))       \
  V(327, EncVl(1, 0, kMopUnordered, 1, 5, kRegA0, kWidth32, 4))              \
  V(328, EncOpV(kF6Vadc, 1, 4, 6, kOpivv, 8))                                \
  V(329, EncOpV(kF6VmergeVmv, 1, 2, kRegA1, kOpivx, 4))                      \
  V(330, EncOpV(kF6VsmulVmvnrr, 1, 4, 2, kOpivi, 8))                         \
  V(331, EncOpV(kF6VsmulVmvnrr, 1, 4, 1, kOpivi, 1))                         \
  V(332, EncOpV(kF6Vmand, 0, 4, 6, kOpmvv, 2))                               \
  V(333, EncOpV(kF6Vmunary0, 1, 2, 0b10001, kOpmvv, 4))                      \
  V(334, EncVl(0, 0, kMopUnit, 0, kUmopMask, kRegA0, kWidth8, 4))            \
  V(335, EncVs(0, 0, kMopUnit, 1, kUmopFaultFirst, kRegA0, kWidth8, 4))      \
  V(336, EncVs(0, 0, kMopUnit, 1, kUmopWholeReg, kRegA0, kWidth16, 4))       \
  V(337, EncOpV(kF6Reserved3f, 1, 4, 6, kOpivv, 8))                          \
  /* Group 4: Positive controls (architecturally VALID, MUST NOT TRAP) */    \
  V(401, EncOpV(kF6Vwrxunary0, 0, 0, 0b10000, kOpmvv, 12))                   \
  V(402, EncOpV(kF6Vmunary0, 0, 0, 0b00001, kOpmvv, 2))                      \
  V(403, EncOpV(kF6Vmunary0, 0, 0, 0b10000, kOpmvv, 2))                      \
  V(404, EncOpV(kF6Vredsum, 0, 2, 4, kOpmvv, 0))                             \
  V(405, EncOpV(kF6Vmseq, 0, 2, 4, kOpivv, 0))                               \
  V(406, EncOpV(kF6Vmseq, 1, 8, 10, kOpivv, 8))                              \
  V(407, EncOpV(kF6Vwadd, 1, 9, 10, kOpmvv, 8))                              \
  V(408, EncOpV(kF6Vnsrl, 1, 8, 1, kOpivi, 8))                               \
  V(409, EncOpV(kF6VslideupRgei16, 1, 8, 8, kOpivv, 6))                      \
  V(410, EncVs(0, 0, kMopUnordered, 1, 4, kRegA0, kWidth16, 4))              \
  V(411, EncOpV(kF6Vadd, 1, 2, 4, kOpivv, 6))                                \
  V(412, EncOpV(kF6Vadd, 1, 2, 4, kOpivv, 6))

#define DECLARE_STUB_WRAPPER(ID, INST_EXPR) DECLARE_STUB(ID)
FOR_EACH_STUB(DECLARE_STUB_WRAPPER)

extern "C" __attribute__((used, noinline)) void EmitAllStubs(){FOR_EACH_STUB(EMIT_STUB)}

#define CASE_ENTRY(ID, VTYPE, AVL, EXPECT_TRAP, FRM, VSTART, CHK_MEM, INST_EXPR) \
  {ID, VTYPE, AVL, EXPECT_TRAP, FRM, VSTART, CHK_MEM, &Stub##ID, (INST_EXPR)}

// Metadata table stored in DTCM (.data) to preserve ITCM space.
StubCase kStubCases[] __attribute__((section(".data"))) = {
  // Group 1: RVV 1.0 §5.2 multi-EEW source and accumulator overlap cases
  CASE_ENTRY(101, kE8M1, 16, 1, 0, 0, 1,
             EncVs(0, 0, kMopUnit, 0, kUmopRegular, kRegA0, kWidth8, 0)),
  CASE_ENTRY(103, kE16M2, 16, 1, 0, 0, 1,
             EncVs(0, 0, kMopUnit, 0, kUmopRegular, kRegA0, kWidth16, 0)),
  CASE_ENTRY(104, kE16M1, 8, 1, 0, 0, 1, EncVs(0, 0, kMopStrided, 0, kRegA1, kRegA0, kWidth16, 0)),
  CASE_ENTRY(105, kE16M1, 8, 1, 0, 0, 1, EncVs(0, 0, kMopUnordered, 0, 4, kRegA0, kWidth8, 0)),
  CASE_ENTRY(106, kE16M1, 8, 1, 0, 0, 1, EncVs(0, 0, kMopUnordered, 0, 0, kRegA0, kWidth8, 4)),
  CASE_ENTRY(107, kE16M1, 8, 1, 0, 0, 0, EncVl(0, 0, kMopUnordered, 0, 0, kRegA0, kWidth8, 4)),
  CASE_ENTRY(108, kE16M1, 8, 1, 0, 0, 0, EncVl(0, 0, kMopOrdered, 0, 0, kRegA0, kWidth16, 4)),
  CASE_ENTRY(109, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vwmacc, 1, 9, 10, kOpmvv, 8)),
  CASE_ENTRY(110, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vwmacc, 1, 10, 9, kOpmvv, 8)),
  CASE_ENTRY(111, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vwmaccu, 1, 9, kRegA1, kOpmvx, 8)),
  CASE_ENTRY(112, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vwmaccus, 1, 9, kRegA1, kOpmvx, 8)),
  CASE_ENTRY(113, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vfwmaccbf16, 1, 9, 10, kOpfvv, 8)),

  // Group 2: Additional §5.2 multi-EEW source & fractional-LMUL overlap cases
  CASE_ENTRY(201, kE8M1, 16, 1, 0, 0, 1, EncVs(0, 0, kMopUnordered, 1, 4, kRegA0, kWidth16, 4)),
  CASE_ENTRY(202, kE16M2, 16, 1, 0, 0, 1, EncVs(0, 0, kMopOrdered, 1, 5, kRegA0, kWidth8, 4)),
  CASE_ENTRY(203, kE8M1, 16, 1, 0, 0, 1, EncVs(1, 0, kMopUnordered, 1, 4, kRegA0, kWidth16, 4)),
  CASE_ENTRY(204, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6VwaddW, 1, 8, 8, kOpmvv, 4)),
  CASE_ENTRY(205, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6VwaddW, 1, 8, 9, kOpmvv, 4)),
  CASE_ENTRY(206, kE8M1, 16, 1, 0, 0, 0, EncOpV(kF6VwsubuW, 1, 8, 9, kOpmvv, 4)),
  CASE_ENTRY(207, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vnsrl, 1, 8, 8, kOpivv, 4)),
  CASE_ENTRY(208, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vnsrl, 1, 8, 9, kOpivv, 4)),
  CASE_ENTRY(209, kE8M1, 16, 1, 0, 0, 0, EncOpV(kF6Vnclip, 1, 8, 9, kOpivv, 4)),
  CASE_ENTRY(210, kE8M1, 16, 1, 0, 0, 0, EncOpV(kF6VslideupRgei16, 1, 8, 8, kOpivv, 4)),
  CASE_ENTRY(211, kE32M2, 8, 1, 0, 0, 0, EncOpV(kF6VslideupRgei16, 1, 8, 9, kOpivv, 4)),
  CASE_ENTRY(212, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vcompress, 1, 8, 8, kOpmvv, 4)),
  CASE_ENTRY(213, kE16M2, 16, 1, 0, 0, 0, EncOpV(kF6Vcompress, 1, 8, 9, kOpmvv, 4)),
  CASE_ENTRY(214, kE16M2, 16, 1, 0, 0, 0, EncOpV(kF6Vwredsum, 1, 8, 9, kOpivv, 4)),
  CASE_ENTRY(215, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vadd, 0, 0, 2, kOpivv, 4)),
  CASE_ENTRY(216, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vadd, 0, 2, 0, kOpivv, 4)),
  CASE_ENTRY(217, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vmacc, 0, 2, 0, kOpmvv, 4)),
  CASE_ENTRY(218, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vadc, 0, 0, 2, kOpivv, 4)),
  CASE_ENTRY(219, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vmadc, 0, 0, 4, kOpivv, 2)),
  CASE_ENTRY(220, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6VmergeVmv, 0, 0, 2, kOpivv, 4)),
  CASE_ENTRY(221, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vmseq, 0, 0, 4, kOpivv, 2)),
  CASE_ENTRY(222, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vredsum, 0, 0, 2, kOpmvv, 4)),
  CASE_ENTRY(223, kE32M1, 4, 1, 0, 0, 0, EncOpV(kF6Vfadd, 0, 0, 2, kOpfvv, 4)),
  CASE_ENTRY(224, kE8Mf2, 8, 1, 0, 0, 0, EncOpV(kF6Vwadd, 1, 4, 6, kOpmvv, 4)),
  CASE_ENTRY(225, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vxunary0, 1, 4, 0b00110, kOpmvv, 4)),
  CASE_ENTRY(226, kE16Mf2, 4, 1, 0, 0, 0, EncVl(0, 0, kMopUnordered, 1, 4, kRegA0, kWidth8, 4)),

  // Group 3: Reserved encodings previously silently retired as NOPs
  CASE_ENTRY(301, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vadd, 0, 2, 4, kOpivv, 0)),
  CASE_ENTRY(302, kE8M1, 16, 1, 0, 0, 0,
             EncVl(0, 0, kMopUnit, 0, kUmopRegular, kRegA0, kWidth8, 0)),
  CASE_ENTRY(303, kE16M1, 8, 1, 0, 0, 0, EncVl(0, 0, kMopUnordered, 0, 4, kRegA0, kWidth8, 0)),
  CASE_ENTRY(304, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vnsrl, 1, 8, 1, kOpivi, 9)),
  CASE_ENTRY(305, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6VslideupRgei16, 1, 4, 1, kOpivi, 4)),
  CASE_ENTRY(306, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vrgather, 1, 4, 2, kOpivv, 4)),
  CASE_ENTRY(307, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vrgather, 1, 2, 4, kOpivv, 4)),
  CASE_ENTRY(308, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vmunary0, 1, 4, 0b10000, kOpmvv, 4)),
  CASE_ENTRY(309, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vcompress, 1, 4, 2, kOpmvv, 4)),
  CASE_ENTRY(310, kE16M2, 16, 1, 0, 0, 0, EncOpV(kF6Vmseq, 1, 8, 10, kOpivv, 9)),
  CASE_ENTRY(311, kE32M2, 8, 1, 0, 0, 0, EncOpV(kF6Vadd, 1, 4, 6, kOpivv, 3)),
  CASE_ENTRY(312, kE32M2, 8, 1, 0, 0, 0, EncOpV(kF6Vadd, 1, 3, 6, kOpivv, 4)),
  CASE_ENTRY(313, kE32M2, 8, 1, 0, 0, 0, EncOpV(kF6Vadd, 1, 4, 3, kOpivv, 6)),
  CASE_ENTRY(314, kE32M2, 8, 1, 0, 0, 0,
             EncVl(0, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 3)),
  CASE_ENTRY(315, kE32M2, 8, 1, 0, 0, 1,
             EncVs(0, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 3)),
  CASE_ENTRY(316, kE8M1, 16, 1, 0, 0, 0, EncVl(0, 0, kMopUnordered, 1, 3, kRegA0, kWidth16, 4)),
  CASE_ENTRY(317, kE32M1, 4, 1, 0, 0, 0, EncOpV(kF6Vwadd, 1, 8, 12, kOpmvv, 4)),
  CASE_ENTRY(318, kE8M8, 128, 1, 0, 0, 0, EncOpV(kF6Vwadd, 1, 8, 16, kOpmvv, 0)),
  CASE_ENTRY(319, kE8M1, 16, 1, 0, 0, 0, EncOpV(kF6Vxunary0, 1, 8, 0b00110, kOpmvv, 4)),
  CASE_ENTRY(320, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vxunary0, 1, 8, 0b00100, kOpmvv, 4)),
  CASE_ENTRY(321, kE8M4, 64, 1, 0, 0, 0,
             EncVl(0, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 0)),
  CASE_ENTRY(322, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vfadd, 1, 8, 12, kOpfvv, 4)),
  CASE_ENTRY(323, kE32M1, 4, 1, 0, 0, 0, EncOpV(kF6Vfwmaccbf16, 1, 8, 12, kOpfvv, 4)),
  CASE_ENTRY(324, kE32M1, 4, 1, /*frm=*/5, 0, 0, EncOpV(kF6Vfadd, 1, 8, 12, kOpfvv, 4)),
  CASE_ENTRY(325, kE32M8, 32, 1, 0, 0, 0,
             EncVl(1, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 0)),
  CASE_ENTRY(326, kE32M1, 4, 1, 0, 0, 0,
             EncVl(2, 0, kMopUnit, 1, kUmopRegular, kRegA0, kWidth32, 30)),
  CASE_ENTRY(327, kE32M1, 4, 1, 0, 0, 0, EncVl(1, 0, kMopUnordered, 1, 5, kRegA0, kWidth32, 4)),
  CASE_ENTRY(328, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vadc, 1, 4, 6, kOpivv, 8)),
  CASE_ENTRY(329, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6VmergeVmv, 1, 2, kRegA1, kOpivx, 4)),
  CASE_ENTRY(330, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6VsmulVmvnrr, 1, 4, 2, kOpivi, 8)),
  CASE_ENTRY(331, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6VsmulVmvnrr, 1, 4, 1, kOpivi, 1)),
  CASE_ENTRY(332, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vmand, 0, 4, 6, kOpmvv, 2)),
  CASE_ENTRY(333, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Vmunary0, 1, 2, 0b10001, kOpmvv, 4)),
  CASE_ENTRY(334, kE8M1, 16, 1, 0, 0, 0, EncVl(0, 0, kMopUnit, 0, kUmopMask, kRegA0, kWidth8, 4)),
  CASE_ENTRY(335, kE8M1, 16, 1, 0, 0, 1,
             EncVs(0, 0, kMopUnit, 1, kUmopFaultFirst, kRegA0, kWidth8, 4)),
  CASE_ENTRY(336, kE16M1, 8, 1, 0, 0, 1,
             EncVs(0, 0, kMopUnit, 1, kUmopWholeReg, kRegA0, kWidth16, 4)),
  CASE_ENTRY(337, kE16M1, 8, 1, 0, 0, 0, EncOpV(kF6Reserved3f, 1, 4, 6, kOpivv, 8)),

  // Group 4: Positive controls (architecturally VALID, MUST NOT TRAP)
  CASE_ENTRY(401, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6Vwrxunary0, 0, 0, 0b10000, kOpmvv, 12)),
  CASE_ENTRY(402, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6Vmunary0, 0, 0, 0b00001, kOpmvv, 2)),
  CASE_ENTRY(403, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6Vmunary0, 0, 0, 0b10000, kOpmvv, 2)),
  CASE_ENTRY(404, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6Vredsum, 0, 2, 4, kOpmvv, 0)),
  CASE_ENTRY(405, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6Vmseq, 0, 2, 4, kOpivv, 0)),
  CASE_ENTRY(406, kE16M2, 16, 0, 0, 0, 0, EncOpV(kF6Vmseq, 1, 8, 10, kOpivv, 8)),
  CASE_ENTRY(407, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6Vwadd, 1, 9, 10, kOpmvv, 8)),
  CASE_ENTRY(408, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6Vnsrl, 1, 8, 1, kOpivi, 8)),
  CASE_ENTRY(409, kE16M1, 8, 0, 0, 0, 0, EncOpV(kF6VslideupRgei16, 1, 8, 8, kOpivv, 6)),
  CASE_ENTRY(410, kE16M1, 8, 0, 0, 0, 0, EncVs(0, 0, kMopUnordered, 1, 4, kRegA0, kWidth16, 4)),
  CASE_ENTRY(411, kE16M1, /*avl=*/0, 0, 0, 0, 0, EncOpV(kF6Vadd, 1, 2, 4, kOpivv, 6)),
  CASE_ENTRY(412, kE16M1, /*avl=*/2, 0, 0, /*vstart=*/4, 0, EncOpV(kF6Vadd, 1, 2, 4, kOpivv, 6)),
};

void RecordResult(uint32_t case_id, bool ok, uint32_t expected_trap, uint32_t got_trap,
                  uint32_t got_mcause, uint32_t got_mepc, uint32_t expected_pc, uint32_t got_mtval,
                  uint32_t expected_mtval) {
  num_cases++;
  if (ok) {
    num_passed++;
    return;
  }
  uint32_t idx = num_failures++;
  if (idx < kMaxFailures) {
    failures[idx].case_id        = case_id;
    failures[idx].expected_trap  = expected_trap;
    failures[idx].got_trap       = got_trap;
    failures[idx].got_mcause     = got_mcause;
    failures[idx].got_mepc       = got_mepc;
    failures[idx].expected_pc    = expected_pc;
    failures[idx].got_mtval      = got_mtval;
    failures[idx].expected_mtval = expected_mtval;
  }
}

inline void SetVtype(uint32_t vtype_val, uint32_t avl) {
  uint32_t vl_out;
  asm volatile("vsetvl %0, %1, %2" : "=r"(vl_out) : "r"(avl), "r"(vtype_val) : "vl", "vtype");
}

__attribute__((noinline)) void ResetState(uint32_t vtype_val, uint32_t avl, uint32_t frm_val = 0,
                                          uint32_t vstart_val = 0) {
  for (int i = 0; i < 64; ++i) {
    mem_buf[i] = 0xa5a50000U | static_cast<uint32_t>(i);
  }
  for (int i = 0; i < 16; ++i) {
    check_buf[i] = 0;
  }
  // Initialize v0..v31 with deterministic non-zero patterns and zero indices in
  // v2..v5 so legal indexed accesses stay inside mem_buf.
  asm volatile(
      "vsetivli zero, 4, e32, m8, ta, ma \n\t"
      "li t0, 0x11223344 \n\t"
      "vmv.v.x v0, t0 \n\t"
      "li t0, 0x55667788 \n\t"
      "vmv.v.x v8, t0 \n\t"
      "li t0, 0x99aabbcc \n\t"
      "vmv.v.x v16, t0 \n\t"
      "li t0, 0xddeeff01 \n\t"
      "vmv.v.x v24, t0 \n\t"
      "vsetivli zero, 4, e32, m2, ta, ma \n\t"
      "vmv.v.i v2, 0 \n\t"
      "vmv.v.i v4, 0 \n\t"
      :
      :
      : "t0", "vl", "vtype", "memory");
  SetVtype(vtype_val, avl);
  asm volatile("csrw frm, %0 \n\t csrw vstart, %1" : : "r"(frm_val), "r"(vstart_val));
  trap_count     = 0;
  trap_mcause    = 0;
  trap_mepc      = 0;
  trap_mtval     = 0;
  trap_resume_pc = 0;
}

__attribute__((noinline)) void RunStubCase(const StubCase &tc) {
  ResetState(tc.vtype, tc.avl, tc.frm, tc.vstart);
  uintptr_t expected_pc             = reinterpret_cast<uintptr_t>(tc.stub);
  register uintptr_t r_a0 asm("a0") = reinterpret_cast<uintptr_t>(mem_buf);
  register uintptr_t r_a1 asm("a1") = 4;
  register uintptr_t r_t3 asm("t3") = expected_pc;
  asm volatile("jalr ra, %[fn], 0"
               : "+r"(r_a0), "+r"(r_a1)
               : [fn] "r"(r_t3)
               : "ra", "t0", "t1", "t2", "t4", "t5", "t6", "a2", "a3", "a4", "a5", "a6", "a7",
                 "memory");

  uint32_t got_trap   = trap_count;
  uint32_t got_mcause = trap_mcause;
  uint32_t got_mepc   = trap_mepc;
  uint32_t got_mtval  = trap_mtval;
  bool ok             = false;
  if (tc.expect_trap) {
    ok = (got_trap == 1) && (got_mcause == 2) && (got_mepc == static_cast<uint32_t>(expected_pc)) &&
         (got_mtval == tc.inst_word);
    if (tc.check_mem_unchanged && mem_buf[0] != 0xa5a50000U) {
      ok = false;
    }
  } else {
    ok = (got_trap == 0);
  }
  RecordResult(tc.case_id, ok, tc.expect_trap, got_trap, got_mcause, got_mepc,
               static_cast<uint32_t>(expected_pc), got_mtval, tc.inst_word);
}

}  // namespace

int main() {
  asm volatile(
      "la t0, reserved_inst_trap_handler \n\t"
      "csrw mtvec, t0 \n\t"
      :
      :
      : "t0");

  for (unsigned i = 0; i < sizeof(kStubCases) / sizeof(kStubCases[0]); ++i) {
    RunStubCase(kStubCases[i]);
  }

  // =========================================================================
  // Group 5: Multi-lane co-dispatch, back-to-back vset+ALU, and ROB loop PCs
  // =========================================================================

  // 501: Same-packet vsetivli (e32,m1) + vwadd.vv (illegal at e32) in
  // RvvFrontEnd when configInvalid == true in Decode.
  {
    ResetState(kE8M1, 16);
    constexpr uint32_t kBadVwadd =
        EncOpV(kF6Vwadd, /*vm=*/1, /*vs2=*/8, /*vs1=*/12, kOpmvv, /*vd=*/4);
    uintptr_t expected_pc = 0;
    uintptr_t resume_pc   = 0;
    asm volatile(
        "la %[res_out], 2f \n\t"
        "la t0, trap_resume_pc \n\t"
        "sw %[res_out], 0(t0) \n\t"
        "la %[pc_out], 1f \n\t"
        ".p2align 4 \n\t"
        "vsetivli zero, 4, e32, m1, ta, ma \n\t"
        "1: \n\t"
        ".word %[inst] \n\t"
        "nop \n\t"
        "nop \n\t"
        "2: \n\t"
        : [pc_out] "=&r"(expected_pc), [res_out] "=&r"(resume_pc)
        : [inst] "i"(kBadVwadd)
        : "t0", "vl", "vtype", "memory");
    bool ok = (trap_count == 1) && (trap_mcause == 2) &&
              (trap_mepc == static_cast<uint32_t>(expected_pc)) && (trap_mtval == kBadVwadd);
    RecordResult(501, ok, 1, trap_count, trap_mcause, trap_mepc, static_cast<uint32_t>(expected_pc),
                 trap_mtval, kBadVwadd);
  }

  // 502: Same-packet reserved ALU op (vwmacc.vv v8, v10, v9 at e16,m1) in
  // lane 0 co-dispatched with vl1re16.v in lane 1 -- must trap cleanly without
  // hanging LSU/RVV or clobbering v16.
  {
    ResetState(kE16M1, 8);
    constexpr uint32_t kBadVwmacc =
        EncOpV(kF6Vwmacc, /*vm=*/1, /*vs2=*/9, /*vs1=*/10, kOpmvv, /*vd=*/8);
    uintptr_t expected_pc             = 0;
    uintptr_t resume_pc               = 0;
    register uintptr_t r_a0 asm("a0") = reinterpret_cast<uintptr_t>(mem_buf);
    asm volatile(
        "la %[res_out], 2f \n\t"
        "la t0, trap_resume_pc \n\t"
        "sw %[res_out], 0(t0) \n\t"
        "la %[pc_out], 1f \n\t"
        ".rept 8 \n\t nop \n\t .endr \n\t"
        ".p2align 4 \n\t"
        "1: \n\t"
        ".word %[inst] \n\t"
        "vl1re16.v v16, (a0) \n\t"
        "nop \n\t"
        "nop \n\t"
        "2: \n\t"
        "vsetivli zero, 4, e32, m1, ta, ma \n\t"
        "vse32.v v16, (%[chk]) \n\t"
        : [pc_out] "=&r"(expected_pc), [res_out] "=&r"(resume_pc)
        : [inst] "i"(kBadVwmacc), "r"(r_a0), [chk] "r"(check_buf)
        : "t0", "vl", "vtype", "memory");
    bool ok = (trap_count == 1) && (trap_mcause == 2) &&
              (trap_mepc == static_cast<uint32_t>(expected_pc)) && (trap_mtval == kBadVwmacc) &&
              (check_buf[0] == 0x99aabbccU);
    RecordResult(502, ok, 1, trap_count, trap_mcause, trap_mepc, static_cast<uint32_t>(expected_pc),
                 trap_mtval, kBadVwmacc);
  }

  // 503: 2-iteration loop on RvvFrontEnd dynamic trap path:
  // Iteration 1 (e16,m1): valid vwadd.vv v4, v8, v12 behind a 32-cycle scalar
  // div so Iteration 1's vwadd is still in RetirementBuffer when Iteration 2
  // executes vsetivli (e32,m1) + vwadd.vv at the SAME PC. Iteration 1's result
  // must commit before Iteration 2 traps.
  {
    ResetState(kE16M1, 8);
    constexpr uint32_t kLoopVwadd =
        EncOpV(kF6Vwadd, /*vm=*/1, /*vs2=*/8, /*vs1=*/12, kOpmvv, /*vd=*/4);
    uintptr_t expected_pc = 0;
    uintptr_t resume_pc   = 0;
    asm volatile(
        "vsetivli zero, 8, e16, m1, ta, ma \n\t"
        "vmv.v.i v8, 3 \n\t"
        "vmv.v.i v12, 4 \n\t"
        "la %[res_out], 4f \n\t"
        "la t0, trap_resume_pc \n\t"
        "sw %[res_out], 0(t0) \n\t"
        "la %[pc_out], 3f \n\t"
        "li t1, 2 \n\t"
        "1: \n\t"
        "li t2, 1 \n\t"
        "beq t1, t2, 2f \n\t"
        "li t3, 0x7fffffff \n\t"
        "li t4, 3 \n\t"
        "div t3, t3, t4 \n\t"
        "vsetivli zero, 8, e16, m1, ta, ma \n\t"
        "j 3f \n\t"
        "2: \n\t"
        "vsetivli zero, 4, e32, m1, ta, ma \n\t"
        "3: \n\t"
        ".word %[inst] \n\t"
        "addi t1, t1, -1 \n\t"
        "bnez t1, 1b \n\t"
        "4: \n\t"
        "vsetivli zero, 4, e32, m1, ta, ma \n\t"
        "vse32.v v4, (%[chk]) \n\t"
        : [pc_out] "=&r"(expected_pc), [res_out] "=&r"(resume_pc)
        : [inst] "i"(kLoopVwadd), [chk] "r"(check_buf)
        : "t0", "t1", "t2", "t3", "t4", "vl", "vtype", "memory");
    bool ok = (trap_count == 1) && (trap_mcause == 2) &&
              (trap_mepc == static_cast<uint32_t>(expected_pc)) && (trap_mtval == kLoopVwadd) &&
              (check_buf[0] == 7U);
    RecordResult(503, ok, 1, trap_count, trap_mcause, trap_mepc, static_cast<uint32_t>(expected_pc),
                 trap_mtval, kLoopVwadd);
  }

  // 504: 2-iteration loop on Decode.scala dynamic trap path:
  // Iteration 1 (e32,m1): valid vle32.v v4, (a0) behind a 32-cycle scalar div.
  // Iteration 2 sets e8,m4 (retires through RvvFrontEnd while div is still in
  // RetirementBuffer) and reaches the SAME PC vle32.v in Decode with
  // configInvalid == false and !retirement_buffer_empty. Iteration 1's load
  // must commit cleanly (v4 == mem_buf[0]) before Iteration 2 traps.
  {
    ResetState(kE32M1, 4);
    constexpr uint32_t kLoopVle32 =
        EncVl(0, 0, kMopUnit, /*vm=*/1, kUmopRegular, kRegA0, kWidth32, /*vd=*/4);
    uintptr_t expected_pc             = 0;
    uintptr_t resume_pc               = 0;
    register uintptr_t r_a0 asm("a0") = reinterpret_cast<uintptr_t>(mem_buf);
    asm volatile(
        "la %[res_out], 4f \n\t"
        "la t0, trap_resume_pc \n\t"
        "sw %[res_out], 0(t0) \n\t"
        "la %[pc_out], 3f \n\t"
        "li t1, 2 \n\t"
        "1: \n\t"
        "li t2, 1 \n\t"
        "beq t1, t2, 2f \n\t"
        "li t3, 0x7fffffff \n\t"
        "li t4, 3 \n\t"
        "div t3, t3, t4 \n\t"
        "vsetivli zero, 4, e32, m1, ta, ma \n\t"
        "j 3f \n\t"
        "2: \n\t"
        "vsetivli zero, 16, e8, m4, ta, ma \n\t"
        ".rept 4 \n\t nop \n\t .endr \n\t"
        "3: \n\t"
        ".word %[inst] \n\t"
        "addi t1, t1, -1 \n\t"
        "bnez t1, 1b \n\t"
        "4: \n\t"
        "vsetivli zero, 4, e32, m1, ta, ma \n\t"
        "vse32.v v4, (%[chk]) \n\t"
        : [pc_out] "=&r"(expected_pc), [res_out] "=&r"(resume_pc)
        : [inst] "i"(kLoopVle32), "r"(r_a0), [chk] "r"(check_buf)
        : "t0", "t1", "t2", "t3", "t4", "vl", "vtype", "memory");
    bool ok = (trap_count == 1) && (trap_mcause == 2) &&
              (trap_mepc == static_cast<uint32_t>(expected_pc)) && (trap_mtval == kLoopVle32) &&
              (check_buf[0] == 0xa5a50000U);
    RecordResult(504, ok, 1, trap_count, trap_mcause, trap_mepc, static_cast<uint32_t>(expected_pc),
                 trap_mtval, kLoopVle32);
  }

  return 0;
}
