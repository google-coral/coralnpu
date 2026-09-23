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

import collections
import hashlib
import random
import secrets
from typing import Deque, List, Optional, Tuple

from tests.isg.gen.constraints import (
    DATA_BASE_REG,
    RAW_CHAIN_PROBABILITY,
    SCOREBOARD_RAW_CHAIN_PROBABILITY,
    synthesize_instruction,
)
from tests.isg.gen.dealt import load_alphabet, plan_instruction_stream
from tests.isg.gen.epilogue import generate_epilogue
from tests.isg.gen.prologue import generate_prologue
from tests.isg.gen.shaping import (
    MLU_OPS,
    ROB_ALU_BURST_MAX,
    ROB_BLOCKER_OPS,
    resolve_shaping_mode,
)
from tests.isg.gen.traps import is_trap_op

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


def generate_isg_assembly(
    alphabet_ops: List[str],
    alphabet_csrs: List[int],
    batch_index: int = 0,
    batch_size: int = DEFAULT_BATCH_SIZE,
    length: int = DEFAULT_PROGRAM_LENGTH,
    shaping: str = "uniform",
    trap_rate: float = 0.0,
    align_mode: Optional[str] = None,
    seed: Optional[str] = None,
    base_reg: Optional[int] = None,
) -> List[str]:
    """Generates the complete assembly file lines for an ISG test program.

    Args:
      alphabet_ops: Active opcode alphabet (see dealt.load_alphabet).
      alphabet_csrs: All CSR addresses in the alphabet.
      batch_index: Index of this program within the batch.
      batch_size: Number of programs in the batch (for dealt partitioning).
      length: Minimum number of opcode slots in the payload. Macro opcodes
        (jalr) expand to more than one instruction, and the dealt cover is
        always emitted in full, so the payload can exceed this.
      shaping: Dispatch-pressure shaping mode.
      trap_rate: Probability of injecting a trap stimulus per opcode slot.
      align_mode: Optional explicit memory offset alignment mode. When None,
        inferred from effective_shaping ("straddle" for "lsu_straddle", "mixed"
        for "mixed", and "natural" otherwise).
      seed: Batch seed string, or None/'random' to generate a fresh random seed.
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

    traps_enabled = trap_rate > 0.0 or shaping == "trap_storm"
    effective_shaping = resolve_shaping_mode(
        shaping=shaping,
        batch_index=batch_index,
        traps_enabled=traps_enabled,
    )

    opcode_plan = plan_instruction_stream(
        alphabet=alphabet_ops,
        batch_index=batch_index,
        batch_size=batch_size,
        length=length,
        trap_rate=trap_rate,
        shaping=shaping,
        rng=rng,
    )

    if effective_shaping == "lsu_straddle":
        effective_align_mode = "straddle"
    elif align_mode is None:
        effective_align_mode = (
            "mixed" if effective_shaping == "mixed" else "natural"
        )
    else:
        effective_align_mode = align_mode

    alphabet_set = set(alphabet_ops)
    active_rob_blockers = ((ROB_BLOCKER_OPS & alphabet_set)
                           or (frozenset(MLU_OPS) & alphabet_set))

    payload_lines: List[str] = []
    prev_rd = None
    prev_frd = None
    last_store_offset = None
    last_store_size = None
    recent_blockers: Deque[Tuple[Optional[int], Optional[int]]
                           ] = collections.deque(maxlen=ROB_ALU_BURST_MAX)
    for op, slot_mode in opcode_plan:
        if slot_mode == "scoreboard_raw":
            slot_raw_prob = SCOREBOARD_RAW_CHAIN_PROBABILITY
        elif slot_mode == "rob_saturation":
            slot_raw_prob = 0.0
        else:
            slot_raw_prob = RAW_CHAIN_PROBABILITY

        slot_align = (
            "straddle" if slot_mode == "lsu_straddle" else effective_align_mode
        )
        slot_stlf = slot_mode == "lsu_stlf"
        is_rob_blocker = (
            slot_mode == "rob_saturation" and op in active_rob_blockers
        )
        call_prev_rd = None if slot_mode == "rob_saturation" else prev_rd
        call_prev_frd = None if slot_mode == "rob_saturation" else prev_frd
        call_avoid_gpr = ({g
                           for g, _ in recent_blockers
                           if g is not None}
                          if slot_mode == "rob_saturation" else None)
        call_avoid_fpr = ({f
                           for _, f in recent_blockers
                           if f is not None}
                          if slot_mode == "rob_saturation" else None)
        call_store_offset = last_store_offset if slot_stlf else None
        call_store_size = last_store_size if slot_stlf else None
        insn_lines, new_rd, new_frd, new_store_offset, new_store_size = (
            synthesize_instruction(
                op=op,
                align_mode=slot_align,
                traps_enabled=traps_enabled,
                alphabet_csrs=alphabet_csrs,
                rng=rng,
                prev_rd=call_prev_rd,
                prev_frd=call_prev_frd,
                last_store_offset=call_store_offset,
                last_store_size=call_store_size,
                base_reg=effective_base_reg,
                avoid_gpr=call_avoid_gpr,
                avoid_fpr=call_avoid_fpr,
                raw_prob=slot_raw_prob,
            )
        )
        if is_rob_blocker:
            recent_blockers.append((new_rd, new_frd))
        if new_rd is not None:
            prev_rd = new_rd
        if new_frd is not None:
            prev_frd = new_frd
        last_store_offset = new_store_offset
        last_store_size = new_store_size
        payload_lines.extend(f"    {line}" for line in insn_lines)

    expected_trap_count = sum(1 for op, _ in opcode_plan if is_trap_op(op))

    header_lines = [
        f"# CoralNPU ISG Program (batch_index={batch_index}/{batch_size})",
        f"# PRNG seed: {effective_seed}",
        f"# Base register: x{effective_base_reg}",
    ]
    prologue_lines = generate_prologue(
        traps_enabled=traps_enabled,
        base_reg=effective_base_reg,
    )
    epilogue_lines = generate_epilogue(
        traps_enabled=traps_enabled, expected_trap_count=expected_trap_count
    )

    return header_lines + prologue_lines + payload_lines + epilogue_lines


def generate_program(
    alphabet_path: str,
    seed: Optional[str] = None,
    batch_index: int = 0,
    batch_size: int = DEFAULT_BATCH_SIZE,
    length: int = DEFAULT_PROGRAM_LENGTH,
    shaping: str = "uniform",
    trap_rate: float = 0.0,
    align_mode: Optional[str] = None,
    base_reg: Optional[int] = None,
) -> List[str]:
    """Compatibility wrapper that loads alphabet from path and generates assembly."""
    ops, csrs = load_alphabet(alphabet_path)
    return generate_isg_assembly(
        alphabet_ops=ops,
        alphabet_csrs=csrs,
        batch_index=batch_index,
        batch_size=batch_size,
        length=length,
        shaping=shaping,
        trap_rate=trap_rate,
        align_mode=align_mode,
        seed=seed,
        base_reg=base_reg,
    )
