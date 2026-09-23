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
from typing import List, Tuple

from tests.isg.gen.constraints import FORBIDDEN_OPS, TRAP_STIMULUS_OPS

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
    rng: random.Random,
) -> List[str]:
    """Plans opcode sequence for a test program guaranteeing dealt coverage."""
    dealt = get_dealt_cover(alphabet, batch_index, batch_size)

    raw_ops: List[str] = list(dealt)
    while len(raw_ops) < length:
        raw_ops.append(rng.choice(alphabet))
    rng.shuffle(raw_ops)

    stream: List[str] = []
    for op in raw_ops:
        if trap_rate > 0.0 and rng.random() < trap_rate:
            # Inject a controlled trap immediately before op (op still follows)
            trap_op = rng.choice(["undef", "ecall"])
            stream.append(trap_op)
        stream.append(op)

    return stream
