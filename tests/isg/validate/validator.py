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
"""Pre-assembly invariant validator for CoralNPU ISG.

Checks the generated .S payload text. The encoded ELF is checked separately by
postlink.py.
"""

import argparse
import re
import sys
from typing import List, Optional, Tuple

from tests.isg.gen.constraints import (
    BRANCH_OPS,
    CSR_NAMES,
    DATA_BASE_REG,
    FLOAT_LOAD_OPS,
    FLOAT_RM_OPS,
    FLOAT_STORE_OPS,
    ILLEGAL_STIMULUS_WORDS,
    LOAD_OPS,
    ROUNDING_MODES,
    SAFE_READABLE_CSRS,
    SCRATCH_SIZE,
    STORE_OPS,
    UNSUPPORTED_FLOAT_OPS,
    get_access_size,
    writable_csrs,
)

ALL_LOAD_OPS = LOAD_OPS | FLOAT_LOAD_OPS
ALL_STORE_OPS = STORE_OPS | FLOAT_STORE_OPS

OP_IDX = 0
RD_IDX = 1
RS1_IDX = 1
RS2_IDX = 2
MEM_OFFSET_IDX = 2
MEM_BASE_IDX = 3
BRANCH_TARGET_IDX = 3
JUMP_TARGET_IDX = 2
JALR_BASE_IDX = 3
AUIPC_IMM_IDX = 2
MIN_TOKENS_FOR_AUIPC = 3
JALR_TARGET_OFFSET = 8
WORD_TOKENS_LEN = 2
WORD_STIMULUS_IDX = 1
CSR_RD_IDX = 1
CSR_REG_IDX = 2
CSR_SRC_IDX = 3
CSR_PSEUDO_REG_IDX = 1
CSR_PSEUDO_SRC_IDX = 2
AUTO_RADIX = 0

# Real CSR instructions: op -> always writes (regardless of source operand).
_CSR_REAL_OPS = {
    "csrrw": True,
    "csrrs": False,
    "csrrc": False,
    "csrrwi": True,
    "csrrsi": False,
    "csrrci": False,
}
# CSR pseudo-instructions with no rd: op -> always writes.
_CSR_WRITE_PSEUDO_OPS = {
    "csrw": True,
    "csrs": False,
    "csrc": False,
    "csrwi": True,
    "csrsi": False,
    "csrci": False,
}

_ZERO_OPERANDS = {"x0", "zero", "0"}
_PLUS_4 = ".+4"
_BASE_REG_SET_RE = re.compile(r"^\.set\s+isg_base_reg\s*,\s*(\d+)\b")
_BASE_REG_COMMENT_RE = re.compile(r"^#\s*Base register:\s*x(\d+)\b")


def extract_base_reg(lines: List[str], default: int = DATA_BASE_REG) -> int:
    """Extracts the program's scratchpad base register from assembly lines."""
    for raw_line in lines:
        line = raw_line.strip()
        m = _BASE_REG_SET_RE.match(line) or _BASE_REG_COMMENT_RE.match(line)
        if m:
            return int(m.group(1))
    return default


class InvariantViolationError(Exception):
    """Raised when an instruction violates straight-line invariants."""


def _parse_csr(token: str, idx: int, line: str) -> int:
    if token in CSR_NAMES:
        return CSR_NAMES[token]
    try:
        return int(token, AUTO_RADIX)
    except ValueError:
        raise InvariantViolationError(
            f"Line {idx}: Unrecognized CSR operand '{token}': {line}"
        ) from None


def _csr_access(op: str,
                tokens: List[str]) -> Optional[Tuple[str, str, str, bool]]:
    """Returns (rd, csr, src, always_writes) for CSR ops, else None."""
    if op in _CSR_REAL_OPS:
        return (
            tokens[CSR_RD_IDX],
            tokens[CSR_REG_IDX],
            tokens[CSR_SRC_IDX],
            _CSR_REAL_OPS[op],
        )
    if op == "csrr":
        return tokens[CSR_RD_IDX], tokens[CSR_REG_IDX], "x0", False
    if op in _CSR_WRITE_PSEUDO_OPS:
        return (
            "x0",
            tokens[CSR_PSEUDO_REG_IDX],
            tokens[CSR_PSEUDO_SRC_IDX],
            _CSR_WRITE_PSEUDO_OPS[op],
        )
    return None


def _is_payload_instruction(code: str) -> bool:
    """Returns True if the stripped code line represents an instruction."""
    if not code or code.endswith(":"):
        return False
    if code.startswith(".") and not code.startswith(".word"):
        return False
    return True


def extract_payload_lines(lines: List[str]) -> List[str]:
    """Returns payload instruction lines between the ISG payload markers.

    Directives, labels, comments and blank lines are dropped, except `.word`,
    which emits an instruction word and therefore counts as payload.
    """
    in_payload = False
    payload_lines: List[str] = []

    for raw_line in lines:
        line = raw_line.strip()
        if "ISG RANDOMIZED PAYLOAD START" in line:
            in_payload = True
            continue
        if "ISG RANDOMIZED PAYLOAD END" in line:
            in_payload = False
            continue
        if not in_payload:
            continue
        code = line.split("#")[0].strip()
        if _is_payload_instruction(code):
            payload_lines.append(line)

    return payload_lines


def validate_assembly_lines(
    lines: List[str],
    traps_enabled: bool = False,
    base_reg: Optional[int] = None,
) -> None:
    """Validates all straight-line execution invariants in the assembly stream."""
    effective_base_reg = (
        base_reg if base_reg is not None else extract_base_reg(lines)
    )
    payload_lines = extract_payload_lines(lines)

    if not payload_lines:
        raise InvariantViolationError(
            "No payload instructions found between markers"
        )

    prev_auipc_reg: Optional[str] = None

    for idx, line in enumerate(payload_lines):
        # Strip comments
        code = line.split("#")[0].strip()
        if not code:
            continue

        tokens = re.split(r"[\s,()]+", code)
        tokens = [t for t in tokens if t]
        try:
            prev_auipc_reg = _check_line(
                idx,
                line,
                tokens,
                traps_enabled,
                prev_auipc_reg,
                base_reg=effective_base_reg,
            )
        except (IndexError, ValueError) as e:
            raise InvariantViolationError(
                f"Line {idx}: Malformed operands ({e}): {line}"
            ) from None


def _check_dest_base_reg(
    idx: int,
    line: str,
    op: str,
    tokens: List[str],
    base_reg: int = DATA_BASE_REG,
) -> None:
    """Verifies that instructions never overwrite the base register."""
    if len(tokens) > 1 and tokens[RD_IDX] == f"x{base_reg}":
        if op not in ALL_STORE_OPS and op not in BRANCH_OPS:
            raise InvariantViolationError(
                f"Line {idx}: Destination register cannot be x{base_reg}: {line}"
            )


def _check_memory_line(
    idx: int,
    line: str,
    op: str,
    tokens: List[str],
    base_reg: int = DATA_BASE_REG,
) -> None:
    """Verifies that memory operations use base_reg and have bounded offset."""
    kind = "Load" if op in ALL_LOAD_OPS else "Store"
    offset = int(tokens[MEM_OFFSET_IDX])
    base = tokens[MEM_BASE_IDX]
    size = get_access_size(op)
    if base != f"x{base_reg}":
        raise InvariantViolationError(
            f"Line {idx}: {kind} base register must be x{base_reg}, got {base}: {line}"
        )
    if not (0 <= offset <= SCRATCH_SIZE - size):
        raise InvariantViolationError(
            f"Line {idx}: {kind} offset {offset} out of bounds [0, {SCRATCH_SIZE - size}]: {line}"
        )


def _check_branch_line(idx: int, line: str, tokens: List[str]) -> None:
    """Verifies that branch operations are reflexive and target .+4."""
    rs1 = tokens[RS1_IDX]
    rs2 = tokens[RS2_IDX]
    if rs1 != rs2:
        raise InvariantViolationError(
            f"Line {idx}: Branch rs1 ({rs1}) must equal rs2 ({rs2}): {line}"
        )
    if "".join(tokens[BRANCH_TARGET_IDX:]) != _PLUS_4:
        raise InvariantViolationError(
            f"Line {idx}: Branch target must be .+4: {line}"
        )


def _check_jal_line(idx: int, line: str, tokens: List[str]) -> None:
    """Verifies that direct jumps target .+4."""
    if "".join(tokens[JUMP_TARGET_IDX:]) != _PLUS_4:
        raise InvariantViolationError(
            f"Line {idx}: jal target must be .+4: {line}"
        )


def _check_jalr_line(
    idx: int, line: str, tokens: List[str], prev_auipc_reg: Optional[str]
) -> None:
    """Verifies that indirect jumps are paired with preceding auipc."""
    xd = tokens[RD_IDX]
    offset = int(tokens[MEM_OFFSET_IDX])
    xt = tokens[JALR_BASE_IDX]
    if (xt in _ZERO_OPERANDS or prev_auipc_reg != xt
            or offset != JALR_TARGET_OFFSET):
        raise InvariantViolationError(
            f"Line {idx}: jalr {xd}, {offset}({xt}) not paired with auipc {xt}, 0: {line}"
        )


def _check_word_stimulus(idx: int, line: str, tokens: List[str]) -> None:
    """Verifies that .word only emits valid illegal instruction stimulus."""
    if (len(tokens) != WORD_TOKENS_LEN
            or int(tokens[WORD_STIMULUS_IDX],
                   AUTO_RADIX) not in ILLEGAL_STIMULUS_WORDS):
        raise InvariantViolationError(
            f"Line {idx}: .word is not an illegal-instruction stimulus: {line}"
        )


def _check_csr_line(
    idx: int, line: str, op: str, tokens: List[str], traps_enabled: bool
) -> None:
    """Verifies CSR access permissions against security invariants."""
    access = _csr_access(op, tokens)
    if access is None:
        return
    rd, csr_tok, src, always_writes = access
    csr_addr = _parse_csr(csr_tok, idx, line)
    writes = always_writes or src not in _ZERO_OPERANDS
    if writes and csr_addr not in writable_csrs(traps_enabled, always_writes):
        raise InvariantViolationError(
            f"Line {idx}: Write to unauthorized CSR 0x{csr_addr:03x}: {line}"
        )
    if rd not in _ZERO_OPERANDS and csr_addr not in SAFE_READABLE_CSRS:
        raise InvariantViolationError(
            f"Line {idx}: Read of unsafe CSR 0x{csr_addr:03x} into {rd}: {line}"
        )


def _check_float_line(idx: int, line: str, op: str, tokens: List[str]) -> None:
    """Verifies floating-point static rounding mode and ISA extensions."""
    if "dyn" in tokens[1:]:
        raise InvariantViolationError(
            f"Line {idx}: Dynamic rounding mode is not allowed: {line}"
        )
    if op in FLOAT_RM_OPS and tokens[-1] not in ROUNDING_MODES:
        raise InvariantViolationError(
            f"Line {idx}: Missing static rounding mode (assembler default is dyn): {line}"
        )
    if op in UNSUPPORTED_FLOAT_OPS:
        raise InvariantViolationError(
            f"Line {idx}: Unsupported floating-point opcode: {line}"
        )


def _check_trap_stimulus(
    idx: int, line: str, op: str, traps_enabled: bool
) -> None:
    """Verifies trap stimulus presence against test configuration."""
    if not traps_enabled and op in ("ecall", ".word"):
        raise InvariantViolationError(
            f"Line {idx}: Trap instruction '{op}' present in non-trapping payload: {line}"
        )


def _check_auipc_tracker(op: str, tokens: List[str]) -> Optional[str]:
    """Tracks auipc destination register for pairing with jalr."""
    if (op == "auipc" and len(tokens) >= MIN_TOKENS_FOR_AUIPC
            and tokens[AUIPC_IMM_IDX] == "0"):
        return tokens[RD_IDX]
    return None


def _check_opcode_invariants(
    idx: int,
    line: str,
    op: str,
    tokens: List[str],
    prev_auipc_reg: Optional[str],
    base_reg: int = DATA_BASE_REG,
) -> None:
    """Dispatches opcode-specific checks for memory and control flow."""
    if op in ALL_LOAD_OPS or op in ALL_STORE_OPS:
        _check_memory_line(idx, line, op, tokens, base_reg)
        return
    if op in BRANCH_OPS:
        _check_branch_line(idx, line, tokens)
        return
    if op == "jal":
        _check_jal_line(idx, line, tokens)
        return
    if op == "jalr":
        _check_jalr_line(idx, line, tokens, prev_auipc_reg)
        return
    if op == ".word":
        _check_word_stimulus(idx, line, tokens)
        return


def _check_line(
    idx: int,
    line: str,
    tokens: List[str],
    traps_enabled: bool,
    prev_auipc_reg: Optional[str],
    base_reg: int = DATA_BASE_REG,
) -> Optional[str]:
    """Checks one payload instruction.

    Returns:
      The register written by this line if it is `auipc xT, 0` (for jalr
      pairing), else None.

    Raises:
      InvariantViolationError: The line violates an invariant.
      IndexError, ValueError: The line's operands are malformed.
    """
    op = tokens[OP_IDX]

    _check_dest_base_reg(idx, line, op, tokens, base_reg)
    _check_opcode_invariants(idx, line, op, tokens, prev_auipc_reg, base_reg)
    _check_csr_line(idx, line, op, tokens, traps_enabled)
    _check_float_line(idx, line, op, tokens)
    _check_trap_stimulus(idx, line, op, traps_enabled)

    return _check_auipc_tracker(op, tokens)


def main() -> None:
    """Parses arguments and runs the invariant validator on an assembly file."""
    parser = argparse.ArgumentParser(
        description="CoralNPU ISG Invariant Validator"
    )
    parser.add_argument(
        "--assembly", required=True, help="Path to assembly .S file"
    )
    parser.add_argument(
        "--traps-enabled",
        action="store_true",
        help="Whether traps are enabled in test",
    )
    args = parser.parse_args()

    with open(args.assembly, "r", encoding="utf-8") as f:
        lines = f.readlines()

    try:
        validate_assembly_lines(lines, traps_enabled=args.traps_enabled)
        print(f"Validation PASSED for {args.assembly}")
    except InvariantViolationError as e:
        print(f"Validation FAILED: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
