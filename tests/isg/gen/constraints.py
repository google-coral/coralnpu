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
"""Operand synthesis and straight-line execution invariants for CoralNPU ISG."""

import random
from typing import Collection, List, Optional, Tuple, Union

from tests.isg.gen.traps import ILLEGAL_WORDS, is_trap_op, synthesize_trap

DATA_BASE_REG = 31  # Default base register for isg_scratch address
SCRATCH_SIZE = 2048  # Scratchpad size in bytes
ALL_GPRS = list(range(1, 32))  # x1 .. x31
GPR_POOL = list(range(1, 31))  # Default GPR pool when base_reg == 31
FPR_POOL = list(range(0, 32))  # f0 .. f31

AvoidRegs = Optional[Union[int, Collection[int]]]


def _normalize_avoid(avoid: AvoidRegs) -> frozenset[int]:
    """Normalizes an optional single register or collection of registers into a frozenset."""
    if avoid is None:
        return frozenset()
    if isinstance(avoid, int):
        return frozenset((avoid, ))
    return frozenset(avoid)


def get_gpr_pool(
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
) -> List[int]:
    """Returns non-zero general-purpose registers excluding base_reg and avoid_gpr."""
    avoid_set = _normalize_avoid(avoid_gpr)
    pool = [r for r in ALL_GPRS if r != base_reg and r not in avoid_set]
    return pool if pool else [r for r in ALL_GPRS if r != base_reg]


def get_fpr_pool(avoid_fpr: AvoidRegs = None) -> List[int]:
    """Returns floating-point registers excluding avoid_fpr."""
    avoid_set = _normalize_avoid(avoid_fpr)
    pool = [r for r in FPR_POOL if r not in avoid_set]
    return pool if pool else list(FPR_POOL)


WORD_BYTES = 4
STRADDLE_BOUNDARY_ALIGNMENT = 16
IMM20_MAX = 0xFFFFF
IMM12_MIN = -2048
IMM12_MAX = 2047
SHAMT_MAX = 31
CSR_WRITE_PROBABILITY = 0.5
CSR_IMM_MAX = 31

MIXED_ALIGN_WEIGHTS = [0.4, 0.4, 0.2]
RAW_CHAIN_PROBABILITY = 0.25
SCOREBOARD_RAW_CHAIN_PROBABILITY = 0.85
STLF_PROBABILITY = 0.75
STLF_EXACT_ALIAS_PROBABILITY = 0.5
STLF_OFFSETS = [0, 1, 2, 3]
HALFWORD_BYTES = 2

BRANCH_OPS = {"beq", "bne", "blt", "bge", "bltu", "bgeu"}
LOAD_OPS = {"lb", "lh", "lw", "lbu", "lhu"}
STORE_OPS = {"sb", "sh", "sw"}
SHIFT_IMM_OPS = {"slli", "srli", "srai", "rori"}
ALU_IMM_OPS = {"addi", "slti", "sltiu", "xori", "ori", "andi"}
UNARY_OPS = {
    "clz",
    "ctz",
    "cpop",
    "sextb",
    "sext.b",
    "sexth",
    "sext.h",
    "zexth",
    "zext.h",
    "orcb",
    "orc.b",
    "rev8",
}
OPCODE_TO_ASM = {
    "sextb": "sext.b",
    "sexth": "sext.h",
    "zexth": "zext.h",
    "orcb": "orc.b",
    "fencei": "fence.i",
    "fencetso": "fence.tso",
}
ALU_REG_OPS = {
    "add",
    "sub",
    "slt",
    "sltu",
    "xor",
    "or",
    "and",
    "sll",
    "srl",
    "sra",
    "mul",
    "mulh",
    "mulhsu",
    "mulhu",
    "div",
    "divu",
    "rem",
    "remu",
    "andn",
    "orn",
    "xnor",
    "max",
    "maxu",
    "min",
    "minu",
    "rol",
    "ror",
}
CSR_REG_OPS = {"csrrw", "csrrs", "csrrc"}
CSR_IMM_OPS = {"csrrwi", "csrrsi", "csrrci"}
CSR_OPS = CSR_REG_OPS | CSR_IMM_OPS

# Opcodes that must never appear in a payload: they leave straight-line
# execution, change privilege state, or stop the core.
FORBIDDEN_OPS = frozenset({"mret", "wfi", "ebreak", "mpause"})
# Alphabet opcodes used only as controlled trap stimuli (traps enabled).
TRAP_STIMULUS_OPS = frozenset({"ecall"})

# Floating-point (RV32F) opcode groups. Zfbfmin is intentionally absent:
# FloatInstruction.table exports only the 26 RV32F base instructions (see
# "Anomaly 4" in instruction_stream_generation.md).
FLOAT_LOAD_OPS = {"flw"}
FLOAT_STORE_OPS = {"fsw"}
FLOAT_R4_OPS = {"fmadd.s", "fmsub.s", "fnmsub.s", "fnmadd.s"}
FLOAT_R2_RM_OPS = {"fadd.s", "fsub.s", "fmul.s", "fdiv.s"}
FLOAT_R1_RM_OPS = {"fsqrt.s"}
FLOAT_SGNJ_OPS = {"fsgnj.s", "fsgnjn.s", "fsgnjx.s"}
FLOAT_MINMAX_OPS = {"fmin.s", "fmax.s"}
FLOAT_CMP_OPS = {"feq.s", "flt.s", "fle.s"}
FLOAT_CVT_TO_INT_OPS = {"fcvt.w.s", "fcvt.wu.s"}
FLOAT_MISC_TO_INT_OPS = {"fmv.x.w", "fclass.s"}
FLOAT_CVT_FROM_INT_OPS = {"fcvt.s.w", "fcvt.s.wu"}
FLOAT_MV_FROM_INT_OPS = {"fmv.w.x"}

# Opcodes that carry a rounding-mode (rm) field.
FLOAT_RM_OPS = (
    FLOAT_R4_OPS | FLOAT_R2_RM_OPS | FLOAT_R1_RM_OPS
    | FLOAT_CVT_TO_INT_OPS | FLOAT_CVT_FROM_INT_OPS
)

ALL_MEMORY_OPS = LOAD_OPS | STORE_OPS | FLOAT_LOAD_OPS | FLOAT_STORE_OPS
ALL_ALU_OPS = ({"lui", "auipc"}
               | ALU_IMM_OPS
               | SHIFT_IMM_OPS
               | UNARY_OPS
               | ALU_REG_OPS)
FLOAT_ARITH_OPS = (
    FLOAT_R4_OPS
    | FLOAT_R2_RM_OPS
    | FLOAT_R1_RM_OPS
    | FLOAT_SGNJ_OPS
    | FLOAT_MINMAX_OPS
    | FLOAT_CMP_OPS
    | FLOAT_CVT_TO_INT_OPS
    | FLOAT_MISC_TO_INT_OPS
    | FLOAT_CVT_FROM_INT_OPS
    | FLOAT_MV_FROM_INT_OPS
)
SYSTEM_OPS = {
    "fence", "fencei", "fence.i", "fencetso", "fence.tso", "ecall", "undef"
}

# Zfbfmin / Zfh-style opcodes that must never appear in a payload.
UNSUPPORTED_FLOAT_OPS = {
    "fcvt.s.bf16", "fcvt.bf16.s", "fmv.x.h", "fmv.h.x", "flh", "fsh"
}

# Static rounding modes only; "dyn" is excluded (see "Anomaly 2").
ROUNDING_MODES = ["rne", "rtz", "rdn", "rup", "rmm"]

# Illegal-instruction trap stimuli emitted for the "undef" pseudo-opcode. The
# post-link checker accepts exactly these undecodable words when traps are
# enabled.
ILLEGAL_STIMULUS_WORDS = frozenset(ILLEGAL_WORDS)

CSR_FFLAGS = 0x001
CSR_FRM = 0x002
CSR_FCSR = 0x003
CSR_MSTATUS = 0x300
CSR_MISA = 0x301
CSR_MIE = 0x304
CSR_MTVEC = 0x305
CSR_MSCRATCH = 0x340
CSR_MEPC = 0x341
CSR_MCAUSE = 0x342
CSR_MTVAL = 0x343
CSR_MIP = 0x344

# CSRs the payload may write. When traps are enabled, mscratch holds the trap
# handler's save-area pointer and must not be clobbered by the payload.
SAFE_WRITABLE_CSRS_NO_TRAP = [CSR_MSCRATCH, CSR_FFLAGS, CSR_FRM, CSR_FCSR]
SAFE_WRITABLE_CSRS_TRAP = [CSR_FFLAGS, CSR_FRM, CSR_FCSR]

# Writable CSRs that may only be fully overwritten (csrrw/csrrwi). Their accrued
# exception flags diverge between RTL and the ISS (see "Anomaly 3"), and a
# set/clear write folds the old flags into the new value, which the co-sim
# checker compares on CSR writeback.
OVERWRITE_ONLY_CSRS = {CSR_FFLAGS, CSR_FCSR}

# CSRs whose value may be returned into a GPR, i.e. that read identically on
# RTL, MPACT and Spike.
#   - mtval (0x343) is excluded (see "Anomaly 1").
#   - fflags (0x001) and fcsr (0x003) are excluded because accrued exception
#     flags diverge (see "Anomaly 3"). They may still be written, but only with
#     rd = x0 so the old value is never observed.
#   - mip (0x344) reflects pending interrupts, which can depend on cycle timing
#     in RTL but not in an ISS. It is safe only because ISG programs run with
#     no interrupt sources active (CoralNPU is used as an accelerator, not as a
#     microcontroller), so it reads identically everywhere. Remove it from
#     this set if ISG starts enabling interrupt sources.
#   - dscratch0 (0x7b2) and dscratch1 (0x7b3) are excluded because MPACT does
#     not implement them.
SAFE_READABLE_CSRS = {
    CSR_MISA,
    CSR_MIE,
    CSR_MTVEC,
    CSR_MSCRATCH,
    CSR_MEPC,
    CSR_MCAUSE,
    CSR_MIP,
    CSR_FRM,
}

# Symbolic CSR names accepted by the validator.
CSR_NAMES = {
    "fflags": CSR_FFLAGS,
    "frm": CSR_FRM,
    "fcsr": CSR_FCSR,
    "mstatus": CSR_MSTATUS,
    "misa": CSR_MISA,
    "mie": CSR_MIE,
    "mtvec": CSR_MTVEC,
    "mscratch": CSR_MSCRATCH,
    "mepc": CSR_MEPC,
    "mcause": CSR_MCAUSE,
    "mtval": CSR_MTVAL,
    "mip": CSR_MIP,
}


def writable_csrs(traps_enabled: bool, overwrite: bool = True) -> List[int]:
    """Returns the CSRs the payload may write.

    Args:
      traps_enabled: Whether the program installs the ISG trap handler.
      overwrite: True for csrrw/csrrwi (the written value is the source
        operand). False for csrrs/csrrc[i], whose written value depends on the
        CSR's old contents; OVERWRITE_ONLY_CSRS are excluded in that case.
    """
    pool = (
        SAFE_WRITABLE_CSRS_TRAP
        if traps_enabled else SAFE_WRITABLE_CSRS_NO_TRAP
    )
    if overwrite:
        return pool
    return [c for c in pool if c not in OVERWRITE_ONLY_CSRS]


def get_access_size(op: str) -> int:
    """Returns memory access size in bytes for a load or store opcode."""
    if op in ("lb", "lbu", "sb"):
        return 1
    if op in ("lh", "lhu", "sh"):
        return HALFWORD_BYTES
    if op in ("lw", "sw", "flw", "fsw"):
        return WORD_BYTES
    raise ValueError(f"Unknown memory op: {op}")


def generate_memory_offset(
    op: str, align_mode: str, rng: random.Random
) -> int:
    """Generates a memory offset in [0, SCRATCH_SIZE - size] adhering to align_mode."""
    size = get_access_size(op)
    max_offset = SCRATCH_SIZE - size

    if align_mode == "mixed":
        # 40% natural, 40% straddle (straddling 16B dbus), 20% general unaligned
        sub_mode = rng.choices(
            ["natural", "straddle", "unaligned"],
            weights=MIXED_ALIGN_WEIGHTS,
        )[0]
        return generate_memory_offset(op, sub_mode, rng)

    if align_mode == "natural":
        return rng.randrange(0, max_offset + 1, size)

    if align_mode == "unaligned":
        return rng.randint(0, max_offset)

    if align_mode == "straddle":
        # Multi-byte accesses straddling a 16-byte boundary:
        # (offset // 16) != ((offset + size - 1) // 16)
        if size == 1:
            # 1-byte access cannot straddle
            return rng.randint(0, max_offset)
        # Straddling offsets are those within size - 1 bytes below a 16-byte
        # boundary: 16 * k - j for j in [1, size - 1]. k ranges over boundaries
        # strictly inside the buffer, so every access stays in bounds.
        boundary = STRADDLE_BOUNDARY_ALIGNMENT * rng.randint(
            1, SCRATCH_SIZE // STRADDLE_BOUNDARY_ALIGNMENT - 1
        )
        return boundary - rng.randint(1, size - 1)

    raise ValueError(f"Unknown align_mode: {align_mode}")


def _pick_rs1(
    rng: random.Random,
    prev_rd: Optional[int],
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
) -> int:
    """Selects a GPR source register, preferring prev_rd for RAW dependency chains."""
    avoid_set = _normalize_avoid(avoid_gpr)
    if (prev_rd is not None and prev_rd != base_reg
            and prev_rd not in avoid_set and rng.random() < raw_prob):
        return prev_rd
    return rng.choice(get_gpr_pool(base_reg, avoid_gpr=avoid_set))


def _pick_fs1(
    rng: random.Random,
    prev_frd: Optional[int],
    avoid_fpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
) -> int:
    """Selects an FPR source register, preferring prev_frd for RAW dependency chains."""
    avoid_set = _normalize_avoid(avoid_fpr)
    if (prev_frd is not None and prev_frd not in avoid_set
            and rng.random() < raw_prob):
        return prev_frd
    return rng.choice(get_fpr_pool(avoid_fpr=avoid_set))


def _pick_fp_sources(
    count: int,
    rng: random.Random,
    prev_frd: Optional[int],
    fpr_pool: List[int],
    avoid_fpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
) -> List[int]:
    """Selects `count` FPR source operands, distributing RAW chaining uniformly across positions."""
    chain_idx = rng.randrange(count)
    return [
        _pick_fs1(rng, prev_frd, avoid_fpr=avoid_fpr, raw_prob=raw_prob)
        if idx == chain_idx else rng.choice(fpr_pool) for idx in range(count)
    ]


def _compute_stlf_offset(
    op: str,
    align_mode: str,
    rng: random.Random,
    last_store_offset: Optional[int],
    last_store_size: Optional[int] = None,
) -> int:
    """Computes load offset paired with a preceding store for DTCM byte-mask aliasing."""
    size = get_access_size(op)
    if last_store_offset is not None and rng.random() < STLF_PROBABILITY:
        if rng.random() < STLF_EXACT_ALIAS_PROBABILITY:
            candidate = min(SCRATCH_SIZE - size, last_store_offset)
        else:
            offsets = (
                list(range(last_store_size)) if
                (last_store_size is not None
                 and last_store_size > 1) else STLF_OFFSETS
            )
            candidate = min(
                SCRATCH_SIZE - size,
                last_store_offset + rng.choice(offsets),
            )
        if align_mode == "natural":
            candidate = (candidate // size) * size
        elif align_mode == "straddle" and size > 1:
            if (candidate // STRADDLE_BOUNDARY_ALIGNMENT
                    != (candidate + size - 1) // STRADDLE_BOUNDARY_ALIGNMENT):
                return candidate
            store_end = last_store_offset + (last_store_size or 1) - 1
            b_low = (
                last_store_offset // STRADDLE_BOUNDARY_ALIGNMENT
            ) * STRADDLE_BOUNDARY_ALIGNMENT
            straddle_candidates = [
                off for b in (b_low, b_low + STRADDLE_BOUNDARY_ALIGNMENT)
                if 0 < b < SCRATCH_SIZE for off in range(b - size + 1, b)
                if off <= store_end and off + size - 1 >= last_store_offset
            ]
            if straddle_candidates:
                return rng.choice(straddle_candidates)
            return generate_memory_offset(op, align_mode, rng)
        return candidate
    return generate_memory_offset(op, align_mode, rng)


def _synthesize_memory(
    op: str,
    align_mode: str,
    rng: random.Random,
    prev_frd: Optional[int],
    last_store_offset: Optional[int],
    last_store_size: Optional[int] = None,
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
    avoid_fpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
    prev_rd: Optional[int] = None,
) -> Tuple[List[str], Optional[int], Optional[int], Optional[int],
           Optional[int]]:
    """Synthesizes load and store instructions with optional store-to-load address pairing."""
    gpr_pool = get_gpr_pool(base_reg, avoid_gpr=avoid_gpr)
    fpr_pool = get_fpr_pool(avoid_fpr=avoid_fpr)
    if op in LOAD_OPS:
        rd = rng.choice(gpr_pool)
        offset = _compute_stlf_offset(
            op, align_mode, rng, last_store_offset, last_store_size
        )
        return [f"{op} x{rd}, {offset}(x{base_reg})"], rd, None, None, None

    if op in STORE_OPS:
        rs2 = _pick_rs1(
            rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
        )
        offset = generate_memory_offset(op, align_mode, rng)
        return [f"{op} x{rs2}, {offset}(x{base_reg})"
                ], None, None, offset, get_access_size(op)

    if op in FLOAT_LOAD_OPS:
        fd = rng.choice(fpr_pool)
        offset = _compute_stlf_offset(
            op, align_mode, rng, last_store_offset, last_store_size
        )
        return [f"{op} f{fd}, {offset}(x{base_reg})"], None, fd, None, None

    if op in FLOAT_STORE_OPS:
        fs2 = _pick_fs1(rng, prev_frd, avoid_fpr=avoid_fpr, raw_prob=raw_prob)
        offset = generate_memory_offset(op, align_mode, rng)
        return [f"{op} f{fs2}, {offset}(x{base_reg})"
                ], None, None, offset, get_access_size(op)

    raise ValueError(f"Unknown memory op: {op}")


def _synthesize_control(
    op: str,
    rng: random.Random,
    last_store_offset: Optional[int],
    last_store_size: Optional[int],
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
) -> Tuple[List[str], Optional[int], Optional[int], Optional[int],
           Optional[int]]:
    """Synthesizes branch and jump instructions adhering to straight-line invariants."""
    gpr_pool = get_gpr_pool(base_reg, avoid_gpr=avoid_gpr)
    if op in BRANCH_OPS:
        rs = rng.choice(gpr_pool)
        return [
            f"{op} x{rs}, x{rs}, . + 4"
        ], None, None, last_store_offset, last_store_size
    if op == "jal":
        rd = rng.choice(gpr_pool)
        return [
            f"jal x{rd}, . + 4"
        ], rd, None, last_store_offset, last_store_size
    if op == "jalr":
        xt = rng.choice(gpr_pool)
        xd = rng.choice(gpr_pool)
        return [
            f"auipc x{xt}, 0", f"jalr x{xd}, 8(x{xt})"
        ], xd, None, last_store_offset, last_store_size
    raise ValueError(f"Unknown control op: {op}")


def _synthesize_alu(
    op: str,
    rng: random.Random,
    prev_rd: Optional[int],
    last_store_offset: Optional[int],
    last_store_size: Optional[int],
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
) -> Tuple[List[str], Optional[int], Optional[int], Optional[int],
           Optional[int]]:
    """Synthesizes integer ALU and shift instructions."""
    gpr_pool = get_gpr_pool(base_reg, avoid_gpr=avoid_gpr)
    if op in ("lui", "auipc"):
        rd = rng.choice(gpr_pool)
        imm = rng.randint(0, IMM20_MAX)
        return [
            f"{op} x{rd}, {imm}"
        ], rd, None, last_store_offset, last_store_size
    if op in ALU_IMM_OPS:
        rd = rng.choice(gpr_pool)
        rs1 = _pick_rs1(
            rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
        )
        imm = rng.randint(IMM12_MIN, IMM12_MAX)
        return [
            f"{op} x{rd}, x{rs1}, {imm}"
        ], rd, None, last_store_offset, last_store_size
    if op in SHIFT_IMM_OPS:
        rd = rng.choice(gpr_pool)
        rs1 = _pick_rs1(
            rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
        )
        shamt = rng.randint(0, SHAMT_MAX)
        return [
            f"{op} x{rd}, x{rs1}, {shamt}"
        ], rd, None, last_store_offset, last_store_size
    if op in UNARY_OPS:
        rd = rng.choice(gpr_pool)
        rs1 = _pick_rs1(
            rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
        )
        asm_op = OPCODE_TO_ASM.get(op, op)
        return [
            f"{asm_op} x{rd}, x{rs1}"
        ], rd, None, last_store_offset, last_store_size
    if op in ALU_REG_OPS:
        rd = rng.choice(gpr_pool)
        if rng.random() < 0.5:
            rs1 = _pick_rs1(
                rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
            )
            rs2 = rng.choice(gpr_pool)
        else:
            rs1 = rng.choice(gpr_pool)
            rs2 = _pick_rs1(
                rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
            )
        return [
            f"{op} x{rd}, x{rs1}, x{rs2}"
        ], rd, None, last_store_offset, last_store_size
    raise ValueError(f"Unknown ALU op: {op}")


def _synthesize_float(
    op: str,
    rng: random.Random,
    prev_rd: Optional[int],
    prev_frd: Optional[int],
    last_store_offset: Optional[int],
    last_store_size: Optional[int],
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
    avoid_fpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
) -> Tuple[List[str], Optional[int], Optional[int], Optional[int],
           Optional[int]]:
    """Synthesizes scalar floating-point arithmetic instructions."""
    gpr_pool = get_gpr_pool(base_reg, avoid_gpr=avoid_gpr)
    fpr_pool = get_fpr_pool(avoid_fpr=avoid_fpr)
    if op in FLOAT_R4_OPS:
        fd = rng.choice(fpr_pool)
        fs1, fs2, fs3 = _pick_fp_sources(
            3, rng, prev_frd, fpr_pool, avoid_fpr=avoid_fpr, raw_prob=raw_prob
        )
        rm = rng.choice(ROUNDING_MODES)
        return [
            f"{op} f{fd}, f{fs1}, f{fs2}, f{fs3}, {rm}"
        ], None, fd, last_store_offset, last_store_size
    if op in FLOAT_R2_RM_OPS:
        fd = rng.choice(fpr_pool)
        fs1, fs2 = _pick_fp_sources(
            2, rng, prev_frd, fpr_pool, avoid_fpr=avoid_fpr, raw_prob=raw_prob
        )
        rm = rng.choice(ROUNDING_MODES)
        return [
            f"{op} f{fd}, f{fs1}, f{fs2}, {rm}"
        ], None, fd, last_store_offset, last_store_size
    if op in FLOAT_R1_RM_OPS:
        fd = rng.choice(fpr_pool)
        fs1 = _pick_fs1(rng, prev_frd, avoid_fpr=avoid_fpr, raw_prob=raw_prob)
        rm = rng.choice(ROUNDING_MODES)
        return [
            f"{op} f{fd}, f{fs1}, {rm}"
        ], None, fd, last_store_offset, last_store_size
    if op in FLOAT_SGNJ_OPS or op in FLOAT_MINMAX_OPS:
        fd = rng.choice(fpr_pool)
        fs1, fs2 = _pick_fp_sources(
            2, rng, prev_frd, fpr_pool, avoid_fpr=avoid_fpr, raw_prob=raw_prob
        )
        return [
            f"{op} f{fd}, f{fs1}, f{fs2}"
        ], None, fd, last_store_offset, last_store_size
    if op in FLOAT_CMP_OPS:
        rd = rng.choice(gpr_pool)
        fs1, fs2 = _pick_fp_sources(
            2, rng, prev_frd, fpr_pool, avoid_fpr=avoid_fpr, raw_prob=raw_prob
        )
        return [
            f"{op} x{rd}, f{fs1}, f{fs2}"
        ], rd, None, last_store_offset, last_store_size
    if op in FLOAT_CVT_TO_INT_OPS:
        rd = rng.choice(gpr_pool)
        fs1 = _pick_fs1(rng, prev_frd, avoid_fpr=avoid_fpr, raw_prob=raw_prob)
        rm = rng.choice(ROUNDING_MODES)
        return [
            f"{op} x{rd}, f{fs1}, {rm}"
        ], rd, None, last_store_offset, last_store_size
    if op in FLOAT_MISC_TO_INT_OPS:
        rd = rng.choice(gpr_pool)
        fs1 = _pick_fs1(rng, prev_frd, avoid_fpr=avoid_fpr, raw_prob=raw_prob)
        return [
            f"{op} x{rd}, f{fs1}"
        ], rd, None, last_store_offset, last_store_size
    if op in FLOAT_CVT_FROM_INT_OPS:
        fd = rng.choice(fpr_pool)
        rs1 = _pick_rs1(
            rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
        )
        rm = rng.choice(ROUNDING_MODES)
        return [
            f"{op} f{fd}, x{rs1}, {rm}"
        ], None, fd, last_store_offset, last_store_size
    if op in FLOAT_MV_FROM_INT_OPS:
        fd = rng.choice(fpr_pool)
        rs1 = _pick_rs1(
            rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
        )
        return [
            f"{op} f{fd}, x{rs1}"
        ], None, fd, last_store_offset, last_store_size
    raise ValueError(f"Unknown float op: {op}")


def _synthesize_csr(
    op: str,
    traps_enabled: bool,
    alphabet_csrs: List[int],
    rng: random.Random,
    prev_rd: Optional[int],
    last_store_offset: Optional[int],
    last_store_size: Optional[int],
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
) -> Tuple[List[str], Optional[int], Optional[int], Optional[int],
           Optional[int]]:
    """Synthesizes CSR instructions enforcing read and write safety invariants."""
    gpr_pool = get_gpr_pool(base_reg, avoid_gpr=avoid_gpr)
    is_imm = op in CSR_IMM_OPS
    is_overwrite = op in ("csrrw", "csrrwi")
    is_write = is_overwrite or rng.random() < CSR_WRITE_PROBABILITY

    if is_write:
        csr = rng.choice(writable_csrs(traps_enabled, is_overwrite))
    else:
        valid_readable = [c for c in alphabet_csrs if c in SAFE_READABLE_CSRS]
        if not valid_readable:
            raise ValueError(
                "No alphabet CSR is in SAFE_READABLE_CSRS; refusing to read an unsafe CSR"
            )
        csr = rng.choice(valid_readable)

    rd = rng.choice(gpr_pool) if csr in SAFE_READABLE_CSRS else 0

    if is_imm:
        src = str(rng.randint(1, CSR_IMM_MAX)) if is_write else "0"
    else:
        src_reg = _pick_rs1(
            rng, prev_rd, base_reg, avoid_gpr=avoid_gpr, raw_prob=raw_prob
        )
        src = f"x{src_reg}" if is_write else "x0"

    produced_rd = rd if rd != 0 else None
    return [
        f"{op} x{rd}, 0x{csr:03x}, {src}"
    ], produced_rd, None, last_store_offset, last_store_size


def _synthesize_system(
    op: str,
    rng: random.Random,
    last_store_offset: Optional[int],
    last_store_size: Optional[int],
) -> Tuple[List[str], Optional[int], Optional[int], Optional[int],
           Optional[int]]:
    """Synthesizes fences, trap stimuli, and pseudo-instructions."""
    if op == "fence":
        return ["fence rw, rw"], None, None, last_store_offset, last_store_size
    if op in ("fencei", "fence.i"):
        return ["fence.i"], None, None, last_store_offset, last_store_size
    if op in ("fencetso", "fence.tso"):
        return ["fence.tso"], None, None, last_store_offset, last_store_size
    if is_trap_op(op):
        return synthesize_trap(
            op, rng
        ), None, None, last_store_offset, last_store_size
    raise ValueError(f"Unsupported system opcode: {op}")


def synthesize_instruction(
    op: str,
    align_mode: str,
    traps_enabled: bool,
    alphabet_csrs: List[int],
    rng: random.Random,
    prev_rd: Optional[int] = None,
    prev_frd: Optional[int] = None,
    last_store_offset: Optional[int] = None,
    last_store_size: Optional[int] = None,
    base_reg: int = DATA_BASE_REG,
    avoid_gpr: AvoidRegs = None,
    avoid_fpr: AvoidRegs = None,
    raw_prob: float = RAW_CHAIN_PROBABILITY,
) -> Tuple[List[str], Optional[int], Optional[int], Optional[int],
           Optional[int]]:
    """Synthesizes assembly lines for a given opcode enforcing all straight-line invariants.

    Args:
      op: Opcode name from the active alphabet, or "undef"/"ecall".
      align_mode: Memory offset alignment mode (see generate_memory_offset).
      traps_enabled: Whether the program installs the ISG trap handler.
      alphabet_csrs: All CSR addresses in the alphabet. Pure reads are drawn
        from the subset that is also in SAFE_READABLE_CSRS.
      rng: Program PRNG.
      prev_rd: Most recent GPR destination, preferred as a GPR source (RAW chains).
      prev_frd: Most recent FPR destination, preferred as an FPR source.
      last_store_offset: Offset of the preceding store for DTCM load pairing.
      last_store_size: Size in bytes of the preceding store.
      base_reg: GPR index holding the scratchpad base address.
      avoid_gpr: Optional GPR or set of GPRs excluded from rd/rs1/rs2 (used in rob_saturation).
      avoid_fpr: Optional FPR or set of FPRs excluded from fd/fs1/fs2/fs3 (used in rob_saturation).
      raw_prob: Probability of chaining source operands from prev_rd/prev_frd.

    Returns:
      (lines, produced_rd, produced_frd, new_store_offset, new_store_size).
    """
    if op in ALL_MEMORY_OPS:
        return _synthesize_memory(
            op,
            align_mode,
            rng,
            prev_frd,
            last_store_offset,
            last_store_size=last_store_size,
            base_reg=base_reg,
            avoid_gpr=avoid_gpr,
            avoid_fpr=avoid_fpr,
            raw_prob=raw_prob,
            prev_rd=prev_rd,
        )
    if op in BRANCH_OPS or op in ("jal", "jalr"):
        return _synthesize_control(
            op,
            rng,
            last_store_offset,
            last_store_size,
            base_reg=base_reg,
            avoid_gpr=avoid_gpr,
        )
    if op in ALL_ALU_OPS:
        return _synthesize_alu(
            op,
            rng,
            prev_rd,
            last_store_offset,
            last_store_size,
            base_reg=base_reg,
            avoid_gpr=avoid_gpr,
            raw_prob=raw_prob,
        )
    if op in FLOAT_ARITH_OPS:
        return _synthesize_float(
            op,
            rng,
            prev_rd,
            prev_frd,
            last_store_offset,
            last_store_size,
            base_reg=base_reg,
            avoid_gpr=avoid_gpr,
            avoid_fpr=avoid_fpr,
            raw_prob=raw_prob,
        )
    if op in CSR_OPS:
        return _synthesize_csr(
            op,
            traps_enabled,
            alphabet_csrs,
            rng,
            prev_rd,
            last_store_offset,
            last_store_size,
            base_reg=base_reg,
            avoid_gpr=avoid_gpr,
            raw_prob=raw_prob,
        )
    if op in SYSTEM_OPS or is_trap_op(op):
        return _synthesize_system(op, rng, last_store_offset, last_store_size)
    raise ValueError(f"Unsupported opcode for synthesis: {op}")
