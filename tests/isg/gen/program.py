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
"""Whole-program assembly for CoralNPU ISG (prologue, payload, epilogue)."""

import hashlib
import random
import secrets
from typing import List, Optional

from tests.isg.gen.constraints import DATA_BASE_REG, synthesize_instruction
from tests.isg.gen.dealt import load_alphabet, plan_instruction_stream
from tests.isg.gen.epilogue import generate_epilogue
from tests.isg.gen.prologue import generate_prologue

SEED_HEX_DIGITS = 16
HEX_BASE = 16
SEED_RANDOM_BITS = 64
DEFAULT_BATCH_SIZE = 32
DEFAULT_PROGRAM_LENGTH = 64


def derive_program_seed(seed_str: str, batch_index: int) -> int:
    """Derives a deterministic 64-bit PRNG seed for one program in a batch.

    Hashing (seed, batch_index) together avoids the collisions of additive
    schemes (e.g. seed S at index 1 equaling seed S + k at index 0).
    """
    digest = hashlib.sha256(f"{seed_str}:{batch_index}".encode("utf-8"))
    return int(digest.hexdigest()[:SEED_HEX_DIGITS], HEX_BASE)


def generate_program(
    alphabet_path: str,
    seed: Optional[str] = None,
    batch_index: int = 0,
    batch_size: int = DEFAULT_BATCH_SIZE,
    length: int = DEFAULT_PROGRAM_LENGTH,
    trap_rate: float = 0.0,
    align_mode: str = "natural",
    base_reg: Optional[int] = None,
) -> List[str]:
    """Generates the full assembly (prologue, payload, epilogue) of a program.

    Args:
      alphabet_path: Path to the alphabet JSON dumped from the decoder.
      seed: Batch seed string, or None/'random' to generate a fresh random seed.
      batch_index: Index of this program within the batch.
      batch_size: Number of programs in the batch (for dealt partitioning).
      length: Minimum number of opcode slots in the payload. Macro opcodes
        (jalr) expand to more than one instruction, and the dealt cover is
        always emitted in full, so the payload can exceed this.
      trap_rate: Probability of injecting a trap stimulus per opcode slot.
      align_mode: Memory offset alignment mode.
      base_reg: Optional explicit scratchpad base register (1..31). When None,
        a register is selected uniformly from x1..x31 using the program PRNG.
    """
    if seed is None or seed == "" or seed == "random":
        effective_seed = f"0x{secrets.randbits(SEED_RANDOM_BITS):016x}"
    else:
        effective_seed = str(seed)

    rng = random.Random(derive_program_seed(effective_seed, batch_index))

    effective_base_reg = (
        base_reg if base_reg is not None else rng.randint(1, DATA_BASE_REG)
    )

    alphabet_ops, alphabet_csrs = load_alphabet(alphabet_path)

    traps_enabled = trap_rate > 0.0

    opcode_plan = plan_instruction_stream(
        alphabet=alphabet_ops,
        batch_index=batch_index,
        batch_size=batch_size,
        length=length,
        trap_rate=trap_rate,
        rng=rng,
    )

    payload_lines = []
    for op in opcode_plan:
        insn_lines = synthesize_instruction(
            op=op,
            align_mode=align_mode,
            traps_enabled=traps_enabled,
            alphabet_csrs=alphabet_csrs,
            rng=rng,
            base_reg=effective_base_reg,
        )
        payload_lines.extend(f"    {line}" for line in insn_lines)

    header_lines = [
        f"# CoralNPU ISG Program (batch_index={batch_index}/{batch_size})",
        f"# PRNG seed: {effective_seed}",
        f"# Base register: x{effective_base_reg}",
    ]
    prologue_lines = generate_prologue(
        traps_enabled=traps_enabled,
        base_reg=effective_base_reg,
    )
    epilogue_lines = generate_epilogue(traps_enabled=traps_enabled)

    return header_lines + prologue_lines + payload_lines + epilogue_lines
