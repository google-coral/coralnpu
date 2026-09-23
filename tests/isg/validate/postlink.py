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
"""Post-link invariant checker for CoralNPU ISG ELFs.

Reads the linked payload bytes between the `isg_payload_start` and
`isg_payload_end` symbols, decodes every 32-bit word against the hardware
decoder alphabet (mask/match pairs dumped from the Chisel decode tables), and
re-checks the straight-line invariants directly on the encoded fields. This
catches anything the assembler or linker changed after the source validator
ran (relaxation, pseudo-op expansion, compressed encodings, etc.).
"""

import argparse
import json
import struct
import sys
from typing import Dict, List, Optional, Sequence

from tests.isg.gen.constraints import (
    BRANCH_OPS,
    CSR_REG_OPS,
    DATA_BASE_REG,
    FLOAT_LOAD_OPS,
    FLOAT_RM_OPS,
    FLOAT_STORE_OPS,
    FORBIDDEN_OPS,
    ILLEGAL_STIMULUS_WORDS,
    LOAD_OPS,
    SAFE_READABLE_CSRS,
    SCRATCH_SIZE,
    STORE_OPS,
    TRAP_STIMULUS_OPS,
    get_access_size,
    writable_csrs,
)
from tests.isg.isa import encoding as enc

PAYLOAD_START_SYMBOL = "isg_payload_start"
PAYLOAD_END_SYMBOL = "isg_payload_end"
BASE_REG_SYMBOL = "isg_base_reg"

# rm field encodings other than the five static modes: 0b101 and 0b110 are
# reserved (illegal instruction), 0b111 is dyn (see "Anomaly 2").
_RM_NON_STATIC = {0b101, 0b110, 0b111}

HEX_BASE = 16
BRANCH_TARGET_OFFSET = 4
JUMP_TARGET_OFFSET = 4
JALR_TARGET_OFFSET = 8
WORD_SIZE_BYTES = 4
CSR_REG_SHIFT = 20
AUIPC_IMM_SHIFT = 12


class PostLinkViolationError(Exception):
    """Raised when a linked payload violates ISG invariants."""


def load_alphabet_patterns(alphabet_json_path: str) -> List[Dict]:
    """Loads (name, mask, match) entries from an alphabet JSON file."""
    with open(alphabet_json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return [{
        "name": insn["name"],
        "mask": int(insn["mask"], HEX_BASE),
        "match": int(insn["match"], HEX_BASE),
    } for insn in data["instructions"]]


def decode(word: int, patterns: Sequence[Dict]) -> List[str]:
    """Returns the names of all alphabet entries matching word."""
    return [p["name"] for p in patterns if word & p["mask"] == p["match"]]


def _decode_single_name(
    w: int,
    patterns: Sequence[Dict],
    traps_enabled: bool,
    where: str,
) -> Optional[str]:
    """Decodes a word and verifies uniqueness against hardware patterns."""
    names = decode(w, patterns)
    if not names:
        if traps_enabled and w in ILLEGAL_STIMULUS_WORDS:
            return None
        kind = (
            "undecodable word"
            if enc.is_32bit(w) else "compressed/non-32-bit encoding"
        )
        raise PostLinkViolationError(
            f"{where}: {kind}; does not decode against the hardware alphabet"
        )
    if len(names) > 1:
        raise PostLinkViolationError(f"{where}: ambiguous decode {names}")
    return names[0]


def _check_memory_word(
    where: str, name: str, w: int, base_reg: int = DATA_BASE_REG
) -> None:
    """Verifies that memory access words respect base register and buffer bounds."""
    is_store = name in STORE_OPS | FLOAT_STORE_OPS
    offset = enc.imm_s(w) if is_store else enc.imm_i(w)
    size = get_access_size(name)
    if enc.rs1(w) != base_reg:
        raise PostLinkViolationError(
            f"{where}: {name} base x{enc.rs1(w)} != x{base_reg}"
        )
    if not 0 <= offset <= SCRATCH_SIZE - size:
        raise PostLinkViolationError(
            f"{where}: {name} offset {offset} out of bounds"
        )


def _is_valid_auipc_pair(w: int, prev_word: Optional[int]) -> bool:
    """Checks whether jalr is correctly paired with an auipc instruction."""
    if prev_word is None or enc.rs1(w) == 0:
        return False
    if enc.opcode(prev_word) != enc.OP_AUIPC:
        return False
    if (prev_word >> AUIPC_IMM_SHIFT) != 0:
        return False
    return enc.rd(prev_word) == enc.rs1(w)


def _check_branch_word(where: str, name: str, w: int) -> None:
    """Verifies that branches are reflexive and target +4."""
    if enc.rs1(w) != enc.rs2(w):
        raise PostLinkViolationError(f"{where}: {name} is not reflexive")
    if enc.imm_b(w) != BRANCH_TARGET_OFFSET:
        raise PostLinkViolationError(
            f"{where}: {name} target offset {enc.imm_b(w)} != 4"
        )


def _check_jal_word(where: str, w: int) -> None:
    """Verifies that jal targets +4."""
    if enc.imm_j(w) != JUMP_TARGET_OFFSET:
        raise PostLinkViolationError(
            f"{where}: jal target offset {enc.imm_j(w)} != 4"
        )


def _check_jalr_word(where: str, w: int, prev_word: Optional[int]) -> None:
    """Verifies that jalr pairs with auipc and targets +8."""
    if not _is_valid_auipc_pair(
            w, prev_word) or enc.imm_i(w) != JALR_TARGET_OFFSET:
        raise PostLinkViolationError(
            f"{where}: jalr not paired with 'auipc x{enc.rs1(w)}, 0' / +8"
        )


def _check_control_word(
    where: str, name: str, w: int, prev_word: Optional[int]
) -> None:
    """Verifies that branches and jumps conform to straight-line invariants."""
    if name in BRANCH_OPS:
        _check_branch_word(where, name, w)
    elif name == "jal":
        _check_jal_word(where, w)
    elif name == "jalr":
        _check_jalr_word(where, w, prev_word)


def _check_csr_word(
    where: str, name: str, w: int, traps_enabled: bool
) -> None:
    """Verifies that CSR writes and reads respect sandboxing permissions."""
    csr = w >> CSR_REG_SHIFT
    overwrite = name == "csrrw"
    writes = overwrite or enc.rs1(w) != 0
    if writes and csr not in writable_csrs(traps_enabled, overwrite):
        raise PostLinkViolationError(
            f"{where}: write to unauthorized CSR 0x{csr:03x}"
        )
    if enc.rd(w) != 0 and csr not in SAFE_READABLE_CSRS:
        raise PostLinkViolationError(
            f"{where}: read of unsafe CSR 0x{csr:03x}"
        )


def _check_safety_invariants(
    where: str,
    name: str,
    w: int,
    traps_enabled: bool,
    base_reg: int = DATA_BASE_REG,
) -> None:
    """Verifies that the instruction is not forbidden or clobbering base reg."""
    if name in FORBIDDEN_OPS:
        raise PostLinkViolationError(f"{where}: forbidden opcode {name}")
    if name in TRAP_STIMULUS_OPS and not traps_enabled:
        raise PostLinkViolationError(
            f"{where}: trap opcode {name} in non-trapping payload"
        )
    try:
        dest = enc.dest_register_file(w)
    except ValueError as e:
        raise PostLinkViolationError(f"{where}: {name}: {e}") from None
    if dest == enc.GPR and enc.rd(w) == base_reg:
        raise PostLinkViolationError(
            f"{where}: {name} writes base register x{base_reg}"
        )


def _check_semantic_invariants(
    where: str,
    name: str,
    w: int,
    prev_word: Optional[int],
    traps_enabled: bool,
    base_reg: int = DATA_BASE_REG,
) -> None:
    """Verifies memory, control, CSR, and floating-point invariants."""
    all_memory_ops = LOAD_OPS | FLOAT_LOAD_OPS | STORE_OPS | FLOAT_STORE_OPS
    all_control_ops = BRANCH_OPS | {"jal", "jalr"}

    if name in all_memory_ops:
        _check_memory_word(where, name, w, base_reg)
    elif name in all_control_ops:
        _check_control_word(where, name, w, prev_word)
    elif name in CSR_REG_OPS:
        _check_csr_word(where, name, w, traps_enabled)

    if name in FLOAT_RM_OPS and enc.funct3(w) in _RM_NON_STATIC:
        raise PostLinkViolationError(
            f"{where}: {name} uses non-static rounding mode "
            f"rm={enc.funct3(w):03b}"
        )


def validate_payload_words(
    words: Sequence[int],
    patterns: Sequence[Dict],
    traps_enabled: bool = False,
    base_reg: int = DATA_BASE_REG,
) -> None:
    """Validates encoded payload words; raises on the first violation."""
    if not words:
        raise PostLinkViolationError("Empty payload")

    prev_word: Optional[int] = None
    for idx, w in enumerate(words):
        where = f"word {idx} (0x{w:08x})"
        name = _decode_single_name(w, patterns, traps_enabled, where)
        if name is not None:
            _check_safety_invariants(where, name, w, traps_enabled, base_reg)
            _check_semantic_invariants(
                where, name, w, prev_word, traps_enabled, base_reg
            )
        prev_word = w


def read_base_reg(elf_path: str) -> int:
    """Extracts the scratchpad base register index from the ELF symbol table."""
    from elftools.elf.elffile import ELFFile

    with open(elf_path, "rb") as f:
        elf = ELFFile(f)
        symtab = elf.get_section_by_name(".symtab")
        if symtab is None:
            raise PostLinkViolationError(f"{elf_path}: no symbol table")
        syms = symtab.get_symbol_by_name(BASE_REG_SYMBOL)
        if not syms:
            return DATA_BASE_REG
        return syms[0]["st_value"]


def read_payload_words(elf_path: str) -> List[int]:
    """Extracts payload instruction words from a linked ISG ELF."""
    from elftools.elf.constants import SH_FLAGS
    from elftools.elf.elffile import ELFFile

    with open(elf_path, "rb") as f:
        elf = ELFFile(f)
        symtab = elf.get_section_by_name(".symtab")
        if symtab is None:
            raise PostLinkViolationError(f"{elf_path}: no symbol table")

        def addr_of(sym_name: str) -> int:
            """Resolves the virtual address of a given symbol name."""
            syms = symtab.get_symbol_by_name(sym_name)
            if not syms:
                raise PostLinkViolationError(
                    f"{elf_path}: missing symbol {sym_name}"
                )
            return syms[0]["st_value"]

        start = addr_of(PAYLOAD_START_SYMBOL)
        end = addr_of(PAYLOAD_END_SYMBOL)
        if end <= start or (end - start) % WORD_SIZE_BYTES:
            raise PostLinkViolationError(
                f"{elf_path}: bad payload range [0x{start:x}, 0x{end:x})"
            )

        # Only allocated, executable sections: non-allocated PROGBITS sections
        # (.comment, .debug_*) have sh_addr 0 and would otherwise appear to
        # contain a payload linked at a low ITCM address.
        required_flags = SH_FLAGS.SHF_ALLOC | SH_FLAGS.SHF_EXECINSTR
        for section in elf.iter_sections():
            base = section["sh_addr"]
            is_code = (
                section["sh_type"] == "SHT_PROGBITS"
                and (section["sh_flags"] & required_flags) == required_flags
            )
            if is_code and base <= start and end <= base + section["sh_size"]:
                data = section.data()[start - base:end - base]
                return list(
                    struct.unpack(f"<{len(data) // WORD_SIZE_BYTES}I", data)
                )

    raise PostLinkViolationError(
        f"{elf_path}: payload range not contained in an allocated executable "
        "PROGBITS section"
    )


def main() -> None:
    """Parses command-line arguments and validates post-link ISG ELFs."""
    parser = argparse.ArgumentParser(
        description="CoralNPU ISG post-link ELF invariant checker"
    )
    parser.add_argument(
        "--alphabet", required=True, help="Path to alphabet JSON file"
    )
    parser.add_argument(
        "--traps-enabled",
        action="store_true",
        help="Whether traps are enabled in the checked programs",
    )
    parser.add_argument("elfs", nargs="+", help="Linked ISG ELF files")
    args = parser.parse_args()

    patterns = load_alphabet_patterns(args.alphabet)
    failures = 0
    for elf_path in args.elfs:
        try:
            words = read_payload_words(elf_path)
            base_reg = read_base_reg(elf_path)
            validate_payload_words(
                words, patterns, args.traps_enabled, base_reg=base_reg
            )
            print(
                f"Post-link check PASSED for {elf_path} ({len(words)} words)"
            )
        except PostLinkViolationError as e:
            print(
                f"Post-link check FAILED for {elf_path}: {e}", file=sys.stderr
            )
            failures += 1

    if failures:
        print(f"{failures}/{len(args.elfs)} ELFs failed", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
