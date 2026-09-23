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
"""Dealt-based partitioning for 100% batch coverage in CoralNPU ISG."""

import json
import random
from typing import List, Optional, Tuple

from tests.isg.gen.constraints import FORBIDDEN_OPS, TRAP_STIMULUS_OPS
from tests.isg.gen.shaping import (
    LOAD_OPS,
    STORE_OPS,
    generate_shaped_sequence,
    resolve_shaping_mode,
)
from tests.isg.gen.traps import TRAP_OPS

# Opcodes excluded from standard random payload. ecall is only injected as a
# controlled trap.
DEFAULT_EXCLUDED_OPS = FORBIDDEN_OPS | TRAP_STIMULUS_OPS

# The decoder's csrrw/csrrs/csrrc BitPats wildcard funct3[2], so each entry
# also covers its immediate form (csrrwi/csrrsi/csrrci). Split them into
# distinct opcodes so dealt partitioning guarantees coverage of both forms.
CSR_IMM_FORMS = {
    "csrrw": "csrrwi",
    "csrrs": "csrrsi",
    "csrrc": "csrrci",
}


def load_alphabet(alphabet_json_path: str) -> Tuple[List[str], List[int]]:
    """Loads instructions and CSR addresses from alphabet JSON."""
    with open(alphabet_json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    instructions: List[str] = []
    for insn in data["instructions"]:
        name = insn["name"]
        if name in DEFAULT_EXCLUDED_OPS:
            continue
        instructions.append(name)
        if name in CSR_IMM_FORMS:
            instructions.append(CSR_IMM_FORMS[name])
    csrs = [csr["address"] for csr in data["csrs"]]
    return instructions, csrs


def get_dealt_cover(alphabet: List[str], batch_index: int,
                    batch_size: int) -> List[str]:
    """Computes dealtCover(i) = { alphabet[j] | j % batch_size == batch_index }."""
    return [
        alphabet[j]
        for j in range(len(alphabet))
        if j % batch_size == batch_index
    ]


def plan_instruction_stream(
    alphabet: List[str],
    batch_index: int,
    batch_size: int,
    length: int,
    trap_rate: float,
    shaping: str = "uniform",
    rng: Optional[random.Random] = None,
) -> List[Tuple[str, str]]:
    """Plans (opcode, slot_mode) sequence for a test program guaranteeing dealt coverage."""
    if rng is None:
        rng = random.Random(0)

    traps_enabled = (trap_rate > 0.0) or (shaping == "trap_storm")
    effective_shaping = resolve_shaping_mode(
        shaping=shaping,
        batch_index=batch_index,
        traps_enabled=traps_enabled,
    )

    dealt = get_dealt_cover(alphabet, batch_index, batch_size)
    rng.shuffle(dealt)

    stream: List[Tuple[str, str]] = []
    stlf_stores = set(STORE_OPS)
    stlf_loads = set(LOAD_OPS)

    # Fill the remaining length with shaped instructions
    remaining_needed = max(0, length - len(dealt))
    if remaining_needed > 0:
        shaped = generate_shaped_sequence(
            mode=effective_shaping,
            count=remaining_needed,
            available_alphabet=alphabet,
            traps_enabled=traps_enabled,
            rng=rng,
        )
        if effective_shaping == "uniform":
            stream.extend((op, "uniform") for op in dealt)
            stream.extend(shaped)
            rng.shuffle(stream)
        else:
            # Insert dealt opcodes at random positions within the shaped stream
            # so they execute against live, non-zero register values without
            # scrambling contiguous hazard bursts or splitting paired STLF
            # [store, load] sequences.
            stream = list(shaped)
            for op in dealt:
                valid_positions = [
                    pos for pos in range(len(stream) + 1) if not (
                        0 < pos < len(stream) and stream[pos -
                                                         1][1] == "lsu_stlf"
                        and stream[pos][1] == "lsu_stlf" and stream[pos - 1][0]
                        in stlf_stores and stream[pos][0] in stlf_loads
                    )
                ]
                pos = (
                    rng.choice(valid_positions)
                    if valid_positions else rng.randint(0, len(stream))
                )
                slot_mode = (
                    stream[pos][1] if pos < len(stream) else
                    (stream[-1][1] if stream else effective_shaping)
                )
                stream.insert(pos, (op, slot_mode))
    else:
        fallback_mode = (
            "uniform" if effective_shaping == "mixed" else effective_shaping
        )
        stream.extend((op, fallback_mode) for op in dealt)

    # Interleave or inject traps if trap_rate > 0 and shaping is not already trap_storm
    if trap_rate > 0.0 and effective_shaping != "trap_storm":
        final_stream: List[Tuple[str, str]] = []
        for op, slot_mode in stream:
            is_stlf_load = slot_mode == "lsu_stlf" and op in stlf_loads
            if (slot_mode != "trap_storm" and not is_stlf_load
                    and rng.random() < trap_rate):
                trap_op = rng.choice(TRAP_OPS)
                final_stream.append((trap_op, slot_mode))
            final_stream.append((op, slot_mode))
        stream = final_stream

    # RetirementBuffer.scala decouples decode faults from preceding control-flow
    # instructions, so traps require no artificial post-branch ROB padding.
    return stream
