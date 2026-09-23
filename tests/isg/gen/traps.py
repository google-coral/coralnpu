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
"""Trap generators and utilities for CoralNPU ISG."""

import random
from typing import List

TRAP_OPS = ["ecall", "undef"]

# Well-known 32-bit illegal words for RV32 (all zeros or unassigned 32-bit major opcodes)
ILLEGAL_WORDS = [
    0x0000007B,  # custom-3 unassigned 32-bit major opcode
    0x00000000,  # all zeros
    0x0000002B,  # custom-1 unassigned 32-bit major opcode
]


def is_trap_op(op: str) -> bool:
    """Returns True if opcode corresponds to a controlled trap stimulus."""
    return op in TRAP_OPS


def synthesize_trap(op: str, rng: random.Random) -> List[str]:
    """Synthesizes assembly lines for an architectural trap."""
    if op == "ecall":
        return ["ecall"]
    elif op == "undef":
        word = rng.choice(ILLEGAL_WORDS)
        return [f".word 0x{word:08x}"]
    raise ValueError(f"Unknown trap op: {op}")
