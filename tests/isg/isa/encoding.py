# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""RISC-V 32-bit instruction field extraction and destination classification.

Destination register files are classified from the encoding (major opcode plus
a few sub-fields), not from mnemonics. The RISC-V encoding groups instructions
by destination register file, so a fixed set of rules covers every instruction
in a major opcode space, including instructions added to the alphabet later
(for example the several hundred RVV opcodes). Unrecognized major opcodes raise
an error, so a new opcode space fails loudly instead of skipping the checks.
"""

from typing import Optional

GPR = "gpr"
FPR = "fpr"
VPR = "vpr"

# Major opcodes (bits [6:0]).
OP_LOAD = 0x03
OP_LOAD_FP = 0x07  # scalar FP loads and vector loads
OP_MISC_MEM = 0x0F
OP_IMM = 0x13
OP_AUIPC = 0x17
OP_STORE = 0x23
OP_STORE_FP = 0x27  # scalar FP stores and vector stores
OP_OP = 0x33
OP_LUI = 0x37
OP_MADD = 0x43
OP_MSUB = 0x47
OP_NMSUB = 0x4B
OP_NMADD = 0x4F
OP_FP = 0x53
OP_V = 0x57
OP_BRANCH = 0x63
OP_JALR = 0x67
OP_JAL = 0x6F
OP_SYSTEM = 0x73

_GPR_MAJORS = {OP_LOAD, OP_IMM, OP_AUIPC, OP_OP, OP_LUI, OP_JALR, OP_JAL}
_NO_DEST_MAJORS = {OP_STORE, OP_STORE_FP, OP_BRANCH, OP_MISC_MEM}
_FPR_MAJORS = {OP_MADD, OP_MSUB, OP_NMSUB, OP_NMADD}

# LOAD-FP width field (funct3) values that select scalar FP loads
# (flh, flw, fld, flq). Other widths are vector loads.
_SCALAR_FP_LOAD_WIDTHS = {0b001, 0b010, 0b011, 0b100}

# OP-FP funct7[6:2] values whose result is written to a GPR:
# fcmp (feq/flt/fle), fcvt.w[u].*, fmv.x.* / fclass.*.
_OP_FP_GPR_FUNCT5 = {0b10100, 0b11000, 0b11100}

# OP-V funct3 values.
_OPFVV = 0b001
_OPMVV = 0b010
_OPCFG = 0b111
# funct6 of VWXUNARY0 (vmv.x.s, vcpop.m, vfirst.m) under OPMVV and
# VWFUNARY0 (vfmv.f.s) under OPFVV.
_VXUNARY0 = 0b010000

# Bitfield shifts and extraction masks.
OPCODE_MASK = 0x7F
REG_MASK = 0x1F
RD_SHIFT = 7
FUNCT3_SHIFT = 12
FUNCT3_MASK = 0x7
RS1_SHIFT = 15
RS2_SHIFT = 20
FUNCT7_SHIFT = 25
FUNCT6_SHIFT = 26

# Immediate decoding shifts, widths, and masks.
IMM_I_SHIFT = 20
IMM_I_BITS = 12

IMM_S_HIGH_SHIFT = 25
IMM_S_HIGH_POS = 5
IMM_S_BITS = 12

IMM_B_SIGN_SHIFT = 31
IMM_B_SIGN_POS = 12
IMM_B_BIT11_SHIFT = 7
IMM_B_BIT11_POS = 11
IMM_B_MID_SHIFT = 25
IMM_B_MID_MASK = 0x3F
IMM_B_MID_POS = 5
IMM_B_LOW_SHIFT = 8
IMM_B_LOW_MASK = 0xF
IMM_B_BITS = 13

IMM_J_SIGN_SHIFT = 31
IMM_J_SIGN_POS = 20
IMM_J_BYTE1_SHIFT = 12
IMM_J_BYTE1_MASK = 0xFF
IMM_J_BYTE1_POS = 12
IMM_J_BIT11_SHIFT = 20
IMM_J_BIT11_POS = 11
IMM_J_MID_SHIFT = 21
IMM_J_MID_MASK = 0x3FF
IMM_J_BITS = 21

BASE_32BIT_MASK = 0x3
BASE_32BIT_MATCH = 0x3


def opcode(w: int) -> int:
    """Extracts bits [6:0] of a 32-bit instruction word."""
    return w & OPCODE_MASK


def rd(w: int) -> int:
    """Extracts the destination register field (rd, bits [11:7])."""
    return (w >> RD_SHIFT) & REG_MASK


def funct3(w: int) -> int:
    """Extracts the 3-bit sub-function code (funct3, bits [14:12])."""
    return (w >> FUNCT3_SHIFT) & FUNCT3_MASK


def rs1(w: int) -> int:
    """Extracts the first source register field (rs1, bits [19:15])."""
    return (w >> RS1_SHIFT) & REG_MASK


def rs2(w: int) -> int:
    """Extracts the second source register field (rs2, bits [24:20])."""
    return (w >> RS2_SHIFT) & REG_MASK


def funct7(w: int) -> int:
    """Extracts the 7-bit sub-function code (funct7, bits [31:25])."""
    return w >> FUNCT7_SHIFT


def funct6(w: int) -> int:
    """Extracts the 6-bit vector sub-function code (funct6, bits [31:26])."""
    return w >> FUNCT6_SHIFT


def sext(value: int, bits: int) -> int:
    """Sign-extends a signed integer from the given bit width."""
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def imm_i(w: int) -> int:
    """Decodes and sign-extends an I-type 12-bit immediate."""
    return sext(w >> IMM_I_SHIFT, IMM_I_BITS)


def imm_s(w: int) -> int:
    """Decodes and sign-extends an S-type 12-bit store offset."""
    val = ((w >> IMM_S_HIGH_SHIFT) << IMM_S_HIGH_POS) | ((w >> RD_SHIFT)
                                                         & REG_MASK)
    return sext(val, IMM_S_BITS)


def imm_b(w: int) -> int:
    """Decodes and sign-extends a B-type 13-bit branch offset."""
    imm = ((((w >> IMM_B_SIGN_SHIFT) & 1) << IMM_B_SIGN_POS)
           | (((w >> IMM_B_BIT11_SHIFT) & 1) << IMM_B_BIT11_POS)
           | (((w >> IMM_B_MID_SHIFT) & IMM_B_MID_MASK) << IMM_B_MID_POS)
           | (((w >> IMM_B_LOW_SHIFT) & IMM_B_LOW_MASK) << 1))
    return sext(imm, IMM_B_BITS)


def imm_j(w: int) -> int:
    """Decodes and sign-extends a J-type 21-bit jump offset."""
    imm = ((((w >> IMM_J_SIGN_SHIFT) & 1) << IMM_J_SIGN_POS)
           | (((w >> IMM_J_BYTE1_SHIFT) & IMM_J_BYTE1_MASK) << IMM_J_BYTE1_POS)
           | (((w >> IMM_J_BIT11_SHIFT) & 1) << IMM_J_BIT11_POS)
           | (((w >> IMM_J_MID_SHIFT) & IMM_J_MID_MASK) << 1))
    return sext(imm, IMM_J_BITS)


def is_32bit(w: int) -> bool:
    """Whether w is a 32-bit encoding (not a 16-bit compressed parcel)."""
    return (w & BASE_32BIT_MASK) == BASE_32BIT_MATCH


def _fp_dest(w: int, op: int) -> str:
    """Classifies destination register file for scalar/vector FP operations."""
    if op == OP_LOAD_FP:
        return FPR if funct3(w) in _SCALAR_FP_LOAD_WIDTHS else VPR
    if (funct7(w) >> 2) in _OP_FP_GPR_FUNCT5:
        return GPR
    return FPR


def _vector_dest(w: int) -> str:
    """Classifies destination register file for vector (OP_V) instructions."""
    f3 = funct3(w)
    if f3 == _OPCFG:
        return GPR  # vsetvli / vsetivli / vsetvl
    f6 = funct6(w)
    if f3 == _OPMVV and f6 == _VXUNARY0:
        return GPR
    if f3 == _OPFVV and f6 == _VXUNARY0:
        return FPR
    return VPR


def dest_register_file(w: int) -> Optional[str]:
    """Returns GPR, FPR, VPR, or None (no destination register) for word w.

    Raises:
      ValueError: w is not a 32-bit encoding, or its major opcode has no
        classification rule.
    """
    if not is_32bit(w):
        raise ValueError(f"0x{w:08x} is not a 32-bit encoding")
    op = opcode(w)
    if op in _GPR_MAJORS:
        return GPR
    if op in _NO_DEST_MAJORS:
        return None
    if op in _FPR_MAJORS:
        return FPR
    if op == OP_SYSTEM:
        # funct3 == 0: ecall/ebreak/mret/wfi/mpause (no destination).
        # Otherwise Zicsr, which returns the old CSR value in rd.
        return GPR if funct3(w) else None
    if op in (OP_LOAD_FP, OP_FP):
        return _fp_dest(w, op)
    if op == OP_V:
        return _vector_dest(w)
    raise ValueError(
        f"0x{w:08x}: no destination rule for major opcode 0x{op:02x}"
    )
