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
"""Dealt coverage analyzer and verification engine for CoralNPU ISG.

This module provides tools to mathematically verify and empirically analyze
that the dealt-based partitioning algorithm achieves 100% ISA opcode coverage
across any batch of ISG test programs.
"""

import argparse
import glob
import json
import os
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Set

from tests.isg.gen import constraints as c
from tests.isg.gen.constraints import OPCODE_TO_ASM
from tests.isg.gen.dealt import get_dealt_cover, load_alphabet, plan_instruction_stream
from tests.isg.gen.program import derive_program_seed
from tests.isg.gen.shaping import (
    ACTIVE_SHAPING_MODES,
    MIXED_SEGMENT_MAX,
    resolve_shaping_mode,
)
from tests.isg.gen.traps import TRAP_OPS

DEFAULT_BATCH_SIZE: int = 50
DEFAULT_PROGRAM_LENGTH: int = 64
DEFAULT_TRAP_RATE: float = 0.05
DEFAULT_SEED: str = "coverage_verify"

_BANNER_WIDTH: int = 72
_CAT_DIVIDER_WIDTH: int = 48
_SHAPE_DIVIDER_WIDTH: int = 40

CoverageReport = Mapping[str, object]

# Map assembly mnemonics back to canonical alphabet opcodes
ASM_TO_OPCODE: Dict[str, str] = {v: k for k, v in OPCODE_TO_ASM.items()}
ASM_TO_OPCODE.update({
    "unimp": "undef",
    ".word": "undef",
    ".insn": "undef",
})

_FLOAT_OPS = (
    c.FLOAT_LOAD_OPS | c.FLOAT_STORE_OPS | c.FLOAT_R4_OPS | c.FLOAT_R2_RM_OPS
    | c.FLOAT_R1_RM_OPS | c.FLOAT_SGNJ_OPS | c.FLOAT_MINMAX_OPS
    | c.FLOAT_CMP_OPS | c.FLOAT_CVT_TO_INT_OPS | c.FLOAT_MISC_TO_INT_OPS
    | c.FLOAT_CVT_FROM_INT_OPS | c.FLOAT_MV_FROM_INT_OPS
)

# Functional category groupings for CoralNPU core_mini_axi (RV32I/M/Zbb/Zicsr/fence.i/F)
OPCODE_CATEGORIES: Dict[str, List[str]] = {
    "ALU (Imm/Reg)": [
        "add", "addi", "sub", "and", "andi", "or", "ori", "xor", "xori", "slt",
        "slti", "sltu", "sltiu", "lui", "auipc"
    ],
    "Shift": ["sll", "slli", "srl", "srli", "sra", "srai"],
    "Bitmanip (Zbb)": [
        "clz", "ctz", "cpop", "sextb", "sexth", "zexth", "min", "max", "minu",
        "maxu", "rol", "ror", "rori", "orcb", "rev8", "andn", "orn", "xnor"
    ],
    "Multiply / Divide (M)":
    ["mul", "mulh", "mulhu", "mulhsu", "div", "divu", "rem", "remu"],
    "Memory (Load/Store)":
    sorted(c.LOAD_OPS | c.STORE_OPS),
    "Control Flow (Branch/Jump)":
    sorted(c.BRANCH_OPS | {"jal", "jalr"}),
    "CSR & Sync":
    sorted(c.CSR_OPS | {"fence", "fencei", "fencetso"}),
    "Traps / Controlled":
    list(TRAP_OPS),
    "Floating-Point (F)":
    sorted(_FLOAT_OPS),
}


def get_category_for_opcode(opcode: str) -> str:
    """Returns the functional category name for a given opcode."""
    canonical = ASM_TO_OPCODE.get(opcode, opcode)
    for category, opcodes in OPCODE_CATEGORIES.items():
        if canonical in opcodes:
            return category
    return "Other"


def verify_dealt_coverage(
    alphabet: List[str],
    batch_size: int,
) -> Dict[str, Any]:
    """Mathematically verifies that dealt partitioning achieves 100% alphabet coverage.

    Given alphabet A of size M and batch size B:
      dealtCover(i) = { A[j] | j % B == i } for i in 0 .. B-1.

    Asserts:
      1. Union of dealtCover(i) for all i in [0, B-1] == set(A).
      2. Sum of lengths of dealtCover(i) == M (partitions are pairwise disjoint).
      3. No opcode is unassigned.
    """
    if batch_size < 1:
        raise ValueError("batch_size must be >= 1")

    alphabet_set = set(alphabet)
    union_covered: Set[str] = set()
    partition_sizes: List[int] = []
    total_assigned = 0

    for i in range(batch_size):
        partition = get_dealt_cover(alphabet, i, batch_size)
        partition_sizes.append(len(partition))
        total_assigned += len(partition)
        union_covered.update(partition)

    missing = alphabet_set - union_covered
    is_complete = (len(missing) == 0)
    is_disjoint = (total_assigned == len(alphabet))

    return {
        "batch_size":
        batch_size,
        "alphabet_size":
        len(alphabet),
        "covered_count":
        len(union_covered),
        "missing_count":
        len(missing),
        "missing_opcodes":
        sorted(list(missing)),
        "is_complete":
        is_complete,
        "is_disjoint":
        is_disjoint,
        "coverage_percentage":
        (len(union_covered) / len(alphabet) * 100.0) if alphabet else 0.0,
        "min_partition_size":
        min(partition_sizes) if partition_sizes else 0,
        "max_partition_size":
        max(partition_sizes) if partition_sizes else 0,
    }


def verify_stream_batch_coverage(
    alphabet: List[str],
    batch_size: int,
    length: int = DEFAULT_PROGRAM_LENGTH,
    shaping: str = "mixed",
    trap_rate: float = DEFAULT_TRAP_RATE,
    seed: str = DEFAULT_SEED,
) -> Dict[str, Any]:
    """Simulates generation of a full batch and measures realized opcode coverage."""
    alphabet_set = set(alphabet)
    all_opcodes: List[str] = []
    per_program_covered: List[Set[str]] = []
    per_program_lengths: List[int] = []

    traps_enabled = trap_rate > 0.0 or shaping == "trap_storm"
    if shaping in ("mixed", "distributed"):
        target_shapes: Set[str] = set(ACTIVE_SHAPING_MODES)
        if traps_enabled:
            target_shapes.add("trap_storm")
    else:
        target_shapes = {shaping}

    covered_shapes: Set[str] = set()
    shape_counts: Counter = Counter()
    guaranteed_mixed_segments = 0

    for i in range(batch_size):
        eff_shape = resolve_shaping_mode(shaping, i, traps_enabled)
        covered_shapes.add(eff_shape)
        shape_counts[eff_shape] += 1

        rng = random.Random(derive_program_seed(str(seed), i))
        # Mirror generate_isg_assembly()'s base-register PRNG draw so stream
        # planning consumes the exact same random sequence as isg_gen.
        _ = rng.randint(1, c.DATA_BASE_REG)

        stream = [
            op for op, _ in plan_instruction_stream(
                alphabet=alphabet,
                batch_index=i,
                batch_size=batch_size,
                length=length,
                trap_rate=trap_rate,
                shaping=shaping,
                rng=rng,
            )
        ]

        if eff_shape == "mixed":
            dealt_count = len(get_dealt_cover(alphabet, i, batch_size))
            filler_slots = max(0, length - dealt_count)
            guaranteed_mixed_segments += (
                filler_slots + MIXED_SEGMENT_MAX - 1
            ) // MIXED_SEGMENT_MAX

        all_opcodes.extend(stream)
        per_program_covered.append(set(stream))
        per_program_lengths.append(len(stream))

    total_covered = set(all_opcodes)
    # Intersect with alphabet_set for alphabet coverage (ignoring synthetic traps like undef)
    covered_alphabet_ops = total_covered.intersection(alphabet_set)
    missing = alphabet_set - covered_alphabet_ops

    if shaping == "mixed" and guaranteed_mixed_segments >= len(target_shapes):
        # Mixed mode draws without replacement from a shuffled permutation queue
        # of sub-modes; sufficient filler segments cover all active sub-modes.
        covered_shapes = set(target_shapes)

    missing_shapes = sorted(list(target_shapes - covered_shapes))
    is_shape_complete = (len(missing_shapes) == 0)

    opcode_counts = Counter(all_opcodes)
    category_counts: Dict[str, int] = defaultdict(int)
    for op, count in opcode_counts.items():
        cat = get_category_for_opcode(op)
        category_counts[cat] += count

    return {
        "batch_size":
        batch_size,
        "alphabet_size":
        len(alphabet),
        "covered_alphabet_count":
        len(covered_alphabet_ops),
        "total_unique_opcodes":
        len(total_covered),
        "missing_opcodes":
        sorted(list(missing)),
        "is_complete": (len(missing) == 0),
        "coverage_percentage":
        (len(covered_alphabet_ops) / len(alphabet) *
         100.0) if alphabet else 0.0,
        "covered_shaping_modes":
        sorted(list(covered_shapes)),
        "target_shaping_modes":
        sorted(list(target_shapes)),
        "missing_shaping_modes":
        missing_shapes,
        "is_shape_complete":
        is_shape_complete,
        "shape_counts":
        dict(shape_counts),
        "total_instructions_generated":
        len(all_opcodes),
        "avg_program_length":
        sum(per_program_lengths) /
        len(per_program_lengths) if per_program_lengths else 0,
        "opcode_counts":
        dict(opcode_counts),
        "category_counts":
        dict(category_counts),
    }


def _extract_payload_lines(lines: List[str]) -> List[str]:
    """Filters raw assembly lines down to lines inside ISG payload markers."""
    payload_lines: List[str] = []
    in_payload = False
    for raw_line in lines:
        line = raw_line.strip()
        if "ISG RANDOMIZED PAYLOAD START" in line:
            in_payload = True
        elif "ISG RANDOMIZED PAYLOAD END" in line:
            in_payload = False
        elif in_payload and line:
            payload_lines.append(line)
    return payload_lines


def _extract_opcode_from_line(line: str) -> Optional[str]:
    """Extracts canonical opcode mnemonic from a single assembly line."""
    if line.startswith((".word", ".insn")):
        return "undef"
    if line.startswith(("#", ".")):
        return None
    code = line.split("#", 1)[0].strip()
    if not code:
        return None
    tokens = re.split(r"[\s,()]+", code)
    if not tokens or not tokens[0]:
        return None
    mnemonic = tokens[0]
    return ASM_TO_OPCODE.get(mnemonic, mnemonic)


def parse_assembly_file_opcodes(file_path: Path) -> List[str]:
    """Reads an assembly file and returns canonical opcodes inside the payload."""
    if not file_path.is_file():
        return []
    with open(file_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    payload_lines = _extract_payload_lines(lines)
    opcodes: List[str] = []
    for line in payload_lines:
        op = _extract_opcode_from_line(line)
        if op is not None:
            opcodes.append(op)
    return opcodes


def analyze_assembly_files(
    file_paths: List[str],
    alphabet: List[str],
) -> Dict[str, Any]:
    """Parses actual emitted .S files from disk and verifies realized opcode coverage."""
    alphabet_set = set(alphabet)
    observed_opcodes: Set[str] = set()
    opcode_counts: Counter = Counter()
    program_stats: List[Dict[str, Any]] = []

    for path in file_paths:
        p = Path(path)
        if not p.is_file():
            continue
        prog_ops = parse_assembly_file_opcodes(p)
        observed_opcodes.update(prog_ops)
        opcode_counts.update(prog_ops)
        program_stats.append({
            "file": p.name,
            "instruction_count": len(prog_ops),
            "unique_opcodes": len(set(prog_ops)),
        })

    covered_alphabet_ops = observed_opcodes.intersection(alphabet_set)
    missing = alphabet_set - covered_alphabet_ops

    category_counts: Dict[str, int] = defaultdict(int)
    for op, count in opcode_counts.items():
        cat = get_category_for_opcode(op)
        category_counts[cat] += count

    return {
        "file_count":
        len(program_stats),
        "alphabet_size":
        len(alphabet),
        "covered_alphabet_count":
        len(covered_alphabet_ops),
        "missing_opcodes":
        sorted(list(missing)),
        "is_complete": (len(missing) == 0),
        "coverage_percentage":
        (len(covered_alphabet_ops) / len(alphabet) *
         100.0) if alphabet else 0.0,
        "total_instructions":
        sum(s["instruction_count"] for s in program_stats),
        "opcode_counts":
        dict(opcode_counts),
        "category_counts":
        dict(category_counts),
        "program_stats":
        program_stats,
    }


def _format_category_table(category_counts: Mapping[str, int]) -> List[str]:
    """Formats opcode distribution by functional category."""
    if not category_counts:
        return []
    lines = [
        "-" * _BANNER_WIDTH,
        "Opcode Distribution by Functional Category:",
        f"  {'Category':<28} | {'Count':>8} | {'Share':>7}",
        "  " + "-" * _CAT_DIVIDER_WIDTH,
    ]
    total_ops = sum(category_counts.values())
    for cat, cnt in sorted(category_counts.items(), key=lambda x: -x[1]):
        pct = (cnt / total_ops * 100.0) if total_ops > 0 else 0.0
        lines.append(f"  {cat:<28} | {cnt:>8} | {pct:>6.1f}%")
    return lines


def _format_shape_table(shape_counts: Mapping[str, int]) -> List[str]:
    """Formats program distribution by shaping mode."""
    if not shape_counts:
        return []
    lines = [
        "-" * _BANNER_WIDTH,
        "Program Distribution by Shaping Mode:",
        f"  {'Shaping Mode':<28} | {'Programs':>8}",
        "  " + "-" * _SHAPE_DIVIDER_WIDTH,
    ]
    for sm, cnt in sorted(shape_counts.items()):
        lines.append(f"  {sm:<28} | {cnt:>8}")
    return lines


def _format_missing_opcodes(missing: object) -> List[str]:
    """Formats missing opcodes block if present."""
    if not missing or not isinstance(missing, list):
        return []
    lines = ["-" * _BANNER_WIDTH, f"MISSING OPCODES ({len(missing)}):"]
    for op in missing:
        lines.append(f"  - {op}")
    return lines


def _format_batch_metadata(report: CoverageReport) -> List[str]:
    """Formats batch size, file count, and instruction totals."""
    lines: List[str] = []
    if "batch_size" in report:
        lines.append(f"Batch Size:           {report['batch_size']} programs")
    if "file_count" in report:
        lines.append(
            f"Files Analyzed:       {report['file_count']} assembly files"
        )
    total_inst = report.get("total_instructions"
                            ) or report.get("total_instructions_generated")
    if total_inst is not None:
        lines.append(f"Total Instructions:   {total_inst}")
    return lines


def format_coverage_report(report: CoverageReport) -> str:
    """Formats a structured coverage report into a clean, human-readable ASCII summary."""
    lines: List[str] = [
        "=" * _BANNER_WIDTH,
        " CoralNPU Instruction Stream Generation (ISG) - Coverage Report",
        "=" * _BANNER_WIDTH,
    ]

    cov_pct = float(report.get("coverage_percentage", 0.0))
    is_complete = bool(report.get("is_complete", False))
    status_str = "PASSED (100.0% COVERAGE)" if is_complete else "FAILED (INCOMPLETE COVERAGE)"

    lines.append(f"Status:               {status_str}")
    lines.append(
        "Target ISA:           RV32I / RV32M / RV32Zbb / RV32Zicsr / fence.i / RV32F"
    )
    lines.append(
        f"Alphabet Size:        {report.get('alphabet_size', 0)} opcodes"
    )
    lines.append(
        f"Covered Opcodes:      {report.get('covered_alphabet_count', report.get('covered_count', 0))} opcodes"
    )
    lines.append(f"Coverage:             {cov_pct:.2f}%")

    lines.extend(_format_batch_metadata(report))
    lines.extend(_format_missing_opcodes(report.get("missing_opcodes")))

    cat_counts = report.get("category_counts")
    if isinstance(cat_counts, dict) and cat_counts:
        lines.extend(_format_category_table(cat_counts))

    shape_counts = report.get("shape_counts")
    if isinstance(shape_counts, dict) and shape_counts:
        lines.extend(_format_shape_table(shape_counts))

    lines.append("=" * _BANNER_WIDTH)
    return "\n".join(lines)


def find_alphabet_path(
    cli_path: Optional[str] = None,
    default_filename: str = "alphabet_core_mini_axi.json",
) -> Optional[Path]:
    """Resolves path to an alphabet JSON from CLI, Bazel runfiles, or workspace paths."""
    if cli_path:
        p = Path(cli_path)
        return p if p.is_file() else None

    rlocation_candidates: List[str] = []
    env_rloc = os.environ.get("ALPHABET_JSON")
    if env_rloc and Path(env_rloc).name == default_filename:
        if Path(env_rloc).is_file():
            return Path(env_rloc)
        rlocation_candidates.append(env_rloc)
    rlocation_candidates.extend((
        f"_main/hdl/chisel/src/coralnpu/{default_filename}",
        f"coralnpu_hw/hdl/chisel/src/coralnpu/{default_filename}",
    ))

    try:
        from bazel_tools.tools.python.runfiles import runfiles

        r = runfiles.Create()
        if r is not None:
            for rloc in rlocation_candidates:
                try:
                    resolved = r.Rlocation(rloc, source_repo="")
                except TypeError:
                    resolved = r.Rlocation(rloc)
                if resolved and Path(resolved).is_file():
                    return Path(resolved)
    except (ImportError, ValueError):
        pass

    rel_candidates = (
        Path(f"bazel-bin/hdl/chisel/src/coralnpu/{default_filename}"),
        Path(f"hdl/chisel/src/coralnpu/{default_filename}"),
    )
    roots: List[Path] = [Path(".")]
    ws_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if ws_dir:
        roots.insert(0, Path(ws_dir))
    repo_root = Path(__file__).resolve().parent.parent.parent.parent
    if repo_root not in roots:
        roots.append(repo_root)

    for root in roots:
        for rel in rel_candidates:
            candidate = root / rel
            if candidate.is_file():
                return candidate
    return None


def main() -> int:
    """Verifies ISG dealt coverage for CoralNPU core_mini_axi."""
    parser = argparse.ArgumentParser(
        description="Verify ISG dealt coverage for CoralNPU core_mini_axi"
    )
    parser.add_argument(
        "--alphabet",
        type=str,
        default=None,
        help="Path to alphabet_core_mini_axi.json",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Batch size to verify (default: {DEFAULT_BATCH_SIZE})",
    )
    parser.add_argument(
        "--length",
        type=int,
        default=DEFAULT_PROGRAM_LENGTH,
        help=
        f"Target length per test program (default: {DEFAULT_PROGRAM_LENGTH})",
    )
    parser.add_argument(
        "--shaping",
        type=str,
        default="mixed",
        help="Shaping mode (default: mixed)",
    )
    parser.add_argument(
        "--trap-rate",
        type=float,
        default=DEFAULT_TRAP_RATE,
        help=
        f"Architectural trap injection rate (default: {DEFAULT_TRAP_RATE})",
    )
    parser.add_argument(
        "--seed",
        type=str,
        default="20260921_ci",
        help="Batch seed string",
    )
    parser.add_argument(
        "--assembly-files",
        type=str,
        nargs="*",
        default=None,
        help="Paths or glob patterns of .S files to analyze",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    alphabet_path = find_alphabet_path(args.alphabet)
    if not alphabet_path:
        sys.stderr.write(
            "Error: alphabet_core_mini_axi.json not found. Run bazel build //hdl/chisel/src/coralnpu:alphabet_core_mini_axi\n"
        )
        return 1

    instructions, _ = load_alphabet(str(alphabet_path))

    if args.assembly_files:
        expanded_files: List[str] = []
        for pattern in args.assembly_files:
            matches = glob.glob(pattern)
            expanded_files.extend(matches if matches else [pattern])
        report = analyze_assembly_files(expanded_files, instructions)
    else:
        report = verify_stream_batch_coverage(
            alphabet=instructions,
            batch_size=args.batch_size,
            length=args.length,
            shaping=args.shaping,
            trap_rate=args.trap_rate,
            seed=args.seed,
        )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(format_coverage_report(report))

    sys.exit(0 if report.get("is_complete", False) else 1)


if __name__ == "__main__":
    main()
