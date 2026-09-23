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
"""Dispatch-pressure shaping for CoralNPU ISG.

Shapes the instruction stream to intentionally stress microarchitectural
bottlenecks:
- MLU multiplier contention
- Non-pipelined DVU divider backpressure
- LSU reservation station, super-slot, and 16-byte split transfer pressure
- Out-of-order retirement into RetirementBuffer
- Scoreboard RAW/WAW dependency interlocks
- Dispatch-group fragmentation (slot 0 restrictions & terminating ops)
- Trap entry/exit bursts
"""

import random
from typing import List, Set, Tuple

from tests.isg.gen.traps import TRAP_OPS

SHAPING_MODES = [
    "uniform",
    "mlu_contention",
    "dvu_backpressure",
    "lsu_serial",
    "lsu_straddle",
    "retire_reorder",
    "scoreboard_raw",
    "dispatch_fragment",
    "trap_storm",
    "writeback_contention",
    "lsu_stlf",
    "rob_saturation",
    "fetch_reorder",
    "mixed",
    "distributed",
]

ACTIVE_SHAPING_MODES = [
    "mlu_contention",
    "dvu_backpressure",
    "lsu_serial",
    "lsu_straddle",
    "retire_reorder",
    "scoreboard_raw",
    "dispatch_fragment",
    "writeback_contention",
    "lsu_stlf",
    "rob_saturation",
    "fetch_reorder",
    "mixed",
]

# Burst sizing parameters
MLU_BURST_MIN = 4
MLU_BURST_MAX = 8
MLU_ALU_GAP_MIN = 1
MLU_ALU_GAP_MAX = 3
DVU_BURST_MIN = 3
DVU_BURST_MAX = 6
LSU_BURST_MIN = 4
LSU_BURST_MAX = 8
RETIRE_FAST_MIN = 2
RETIRE_FAST_MAX = 4
TRAP_BURST_MIN = 2
TRAP_BURST_MAX = 5
WB_BURST_MIN = 3
WB_BURST_MAX = 5
ROB_ALU_BURST_MIN = 16
ROB_ALU_BURST_MAX = 24
FETCH_BURST_MIN = 2
FETCH_BURST_MAX = 4
MIXED_SEGMENT_MIN = 8
MIXED_SEGMENT_MAX = 16

# Probability parameters
DISPATCH_FRAG_PROBABILITY = 0.5
STLF_ALU_NOISE_PROBABILITY = 0.25


def resolve_shaping_mode(
    shaping: str,
    batch_index: int = 0,
    traps_enabled: bool = False,
) -> str:
    """Resolves effective shaping mode for a program, supporting batch-level distribution."""
    if shaping == "distributed":
        modes = list(ACTIVE_SHAPING_MODES)
        if traps_enabled:
            modes.append("trap_storm")
        return modes[batch_index % len(modes)]
    return shaping


MLU_OPS = ["mul", "mulh", "mulhsu", "mulhu"]
DVU_OPS = ["div", "divu", "rem", "remu"]
LSU_OPS = ["lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw", "flw", "fsw"]
STRADDLE_LSU_OPS = ["lh", "lw", "lhu", "sh", "sw", "flw", "fsw"]
STORE_OPS = ["sb", "sh", "sw", "fsw"]
LOAD_OPS = ["lb", "lh", "lw", "lbu", "lhu", "flw"]
FPU_TO_GPR_OPS = [
    "fmv.x.w",
    "fcvt.w.s",
    "fcvt.wu.s",
    "feq.s",
    "flt.s",
    "fle.s",
    "fclass.s",
]
BRANCH_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
JUMP_OPS = ["jal", "jalr"]
CONTROL_OPS = BRANCH_OPS + JUMP_OPS
FPU_MULTI_OPS = [
    "fadd.s",
    "fsub.s",
    "fmul.s",
    "fdiv.s",
    "fsqrt.s",
    "fmadd.s",
    "fmsub.s",
    "fnmsub.s",
    "fnmadd.s",
]
FAST_ALU_OPS = [
    "add",
    "sub",
    "and",
    "or",
    "xor",
    "sll",
    "srl",
    "sra",
    "slt",
    "sltu",
    "addi",
    "xori",
    "ori",
    "andi",
    "slli",
    "srli",
    "srai",
    "slti",
    "sltiu",
]
FRAGMENT_OPS = [
    "jal",
    "jalr",
    "csrrw",
    "csrrs",
    "csrrc",
    "csrrwi",
    "csrrsi",
    "csrrci",
    "fence",
    "fencei",
    "fencetso",
]
ROB_BLOCKER_OPS = frozenset(DVU_OPS + ["fdiv.s", "fsqrt.s"])


def filter_available(targets: List[str], available: Set[str]) -> List[str]:
    """Filters target ops to only those present in the active alphabet."""
    res = [op for op in targets if op in available]
    return res if res else sorted(available)


def _emit_burst_stream(
    count: int,
    primary_ops: List[str],
    burst_min: int,
    burst_max: int,
    avail_alu: List[str],
    rng: random.Random,
    alu_min: int = 1,
    alu_max: int = 1,
) -> List[str]:
    """Generates bursts of primary instructions interleaved with ALU ops."""
    seq: List[str] = []
    while len(seq) < count:
        burst_len = min(rng.randint(burst_min, burst_max), count - len(seq))
        for _ in range(burst_len):
            seq.append(rng.choice(primary_ops))
        gap_target = (
            alu_min if alu_min == alu_max else rng.randint(alu_min, alu_max)
        )
        gap_len = min(gap_target, count - len(seq))
        for _ in range(gap_len):
            seq.append(rng.choice(avail_alu))
    return seq


def _emit_dispatch_fragment(
    count: int,
    avail_frag: List[str],
    avail_alu: List[str],
    rng: random.Random,
) -> List[str]:
    """Generates instructions with high density of slot-0 / group-terminating ops."""
    seq: List[str] = []
    while len(seq) < count:
        op_list = (
            avail_frag
            if rng.random() < DISPATCH_FRAG_PROBABILITY else avail_alu
        )
        seq.append(rng.choice(op_list))
    return seq


def _emit_retire_reorder(
    count: int,
    multi_ops: List[str],
    avail_alu: List[str],
    rng: random.Random,
) -> List[str]:
    """Interleaves multi-cycle operations with 1-cycle ALU ops to reorder retirement."""
    seq: List[str] = []
    while len(seq) < count:
        seq.append(rng.choice(multi_ops))
        fast_count = min(
            rng.randint(RETIRE_FAST_MIN, RETIRE_FAST_MAX), count - len(seq)
        )
        for _ in range(fast_count):
            seq.append(rng.choice(avail_alu))
    return seq


def _emit_lsu_stlf(
    count: int,
    avail_stores: List[str],
    avail_loads: List[str],
    avail_alu: List[str],
    rng: random.Random,
) -> List[str]:
    """Generates back-to-back store-to-load pairs for DTCM turnaround and byte-mask aliasing."""
    seq: List[str] = []
    while len(seq) < count:
        seq.append(rng.choice(avail_stores))
        if len(seq) < count:
            seq.append(rng.choice(avail_loads))
        if len(seq) < count and rng.random() < STLF_ALU_NOISE_PROBABILITY:
            seq.append(rng.choice(avail_alu))
    return seq


def _emit_rob_saturation(
    count: int,
    avail_set: Set[str],
    available_alphabet: List[str],
    avail_alu: List[str],
    rng: random.Random,
) -> List[str]:
    """Emits a head-of-line stall followed by ALU burst to saturate the ROB."""
    slow_blockers = [
        op for op in (DVU_OPS + ["fdiv.s", "fsqrt.s"]) if op in avail_set
    ]
    mlu_blockers = [op for op in MLU_OPS if op in avail_set]
    blockers = slow_blockers or mlu_blockers or list(available_alphabet)
    seq: List[str] = []
    while len(seq) < count:
        seq.append(rng.choice(blockers))
        alu_burst = min(
            rng.randint(ROB_ALU_BURST_MIN, ROB_ALU_BURST_MAX),
            count - len(seq)
        )
        for _ in range(alu_burst):
            seq.append(rng.choice(avail_alu))
    return seq


def _emit_mlu_contention(
    count: int,
    avail_mlu: List[str],
    avail_alu: List[str],
    rng: random.Random,
) -> List[str]:
    """Emits MLU bursts with 1-3 ALU gaps to sweep all 4 dispatch lanes."""
    return _emit_burst_stream(
        count,
        avail_mlu,
        MLU_BURST_MIN,
        MLU_BURST_MAX,
        avail_alu,
        rng,
        MLU_ALU_GAP_MIN,
        MLU_ALU_GAP_MAX,
    )


def _emit_writeback_contention(
    count: int,
    wb_multi: List[str],
    avail_alu: List[str],
    rng: random.Random,
) -> List[str]:
    """Emits ops contending for the single scalar writeback arbiter port."""
    return _emit_burst_stream(
        count, wb_multi, WB_BURST_MIN, WB_BURST_MAX, avail_alu, rng
    )


def _emit_trap_storm(
    count: int,
    traps_enabled: bool,
    avail_frag: List[str],
    avail_alu: List[str],
    rng: random.Random,
) -> List[str]:
    """Emits bursts of traps or fragment ops."""
    trap_choices = TRAP_OPS if traps_enabled else avail_frag
    return _emit_burst_stream(
        count, trap_choices, TRAP_BURST_MIN, TRAP_BURST_MAX, avail_alu, rng
    )


def _emit_mixed(
    count: int,
    available_alphabet: List[str],
    traps_enabled: bool,
    rng: random.Random,
) -> List[Tuple[str, str]]:
    """Generates composite stream alternating across multiple shaping modes."""
    sub_modes = [
        "mlu_contention",
        "dvu_backpressure",
        "lsu_serial",
        "lsu_straddle",
        "retire_reorder",
        "scoreboard_raw",
        "dispatch_fragment",
        "writeback_contention",
        "lsu_stlf",
        "rob_saturation",
        "fetch_reorder",
    ]
    if traps_enabled:
        sub_modes.append("trap_storm")

    seq: List[Tuple[str, str]] = []
    mode_queue: List[str] = []
    while len(seq) < count:
        if not mode_queue:
            mode_queue = list(sub_modes)
            rng.shuffle(mode_queue)
        chosen_sub = mode_queue.pop()
        segment_len = min(
            rng.randint(MIXED_SEGMENT_MIN, MIXED_SEGMENT_MAX),
            count - len(seq)
        )
        seq.extend(
            generate_shaped_sequence(
                mode=chosen_sub,
                count=segment_len,
                available_alphabet=available_alphabet,
                traps_enabled=traps_enabled,
                rng=rng,
            )
        )
    return seq


def generate_shaped_sequence(
    mode: str,
    count: int,
    available_alphabet: List[str],
    traps_enabled: bool,
    rng: random.Random,
) -> List[Tuple[str, str]]:
    """Generates (opcode, slot_mode) pairs shaped for microarchitectural pressure."""
    if mode in ("mixed", "distributed"):
        return _emit_mixed(count, available_alphabet, traps_enabled, rng)

    avail_set = set(available_alphabet)
    avail_mlu = filter_available(MLU_OPS, avail_set)
    avail_dvu = filter_available(DVU_OPS, avail_set)
    avail_lsu = filter_available(LSU_OPS, avail_set)
    avail_straddle_lsu = filter_available(STRADDLE_LSU_OPS, avail_set)
    avail_stores = filter_available(STORE_OPS, avail_set)
    avail_loads = filter_available(LOAD_OPS, avail_set)
    avail_alu = filter_available(FAST_ALU_OPS, avail_set)
    avail_frag = filter_available(FRAGMENT_OPS, avail_set)
    avail_control = filter_available(CONTROL_OPS, avail_set)

    burst_configs = {
        "dvu_backpressure": (avail_dvu, DVU_BURST_MIN, DVU_BURST_MAX),
        "lsu_serial": (avail_lsu, LSU_BURST_MIN, LSU_BURST_MAX),
        "lsu_straddle": (avail_straddle_lsu, LSU_BURST_MIN, LSU_BURST_MAX),
        "fetch_reorder": (avail_control, FETCH_BURST_MIN, FETCH_BURST_MAX),
    }

    if mode in burst_configs:
        primary, b_min, b_max = burst_configs[mode]
        ops = _emit_burst_stream(count, primary, b_min, b_max, avail_alu, rng)
        return [(op, mode) for op in ops]

    if mode == "mlu_contention":
        ops = _emit_mlu_contention(count, avail_mlu, avail_alu, rng)
        return [(op, mode) for op in ops]

    if mode == "uniform":
        return [(rng.choice(available_alphabet), mode) for _ in range(count)]

    if mode == "retire_reorder":
        multi_ops = filter_available(
            DVU_OPS + MLU_OPS + LSU_OPS + FPU_MULTI_OPS, avail_set
        )
        ops = _emit_retire_reorder(count, multi_ops, avail_alu, rng)
        return [(op, mode) for op in ops]

    if mode == "dispatch_fragment":
        ops = _emit_dispatch_fragment(count, avail_frag, avail_alu, rng)
        return [(op, mode) for op in ops]

    if mode == "trap_storm":
        ops = _emit_trap_storm(
            count, traps_enabled, avail_frag, avail_alu, rng
        )
        return [(op, mode) for op in ops]

    if mode == "scoreboard_raw":
        pool = filter_available(
            FAST_ALU_OPS + LSU_OPS + MLU_OPS + FPU_MULTI_OPS, avail_set
        )
        return [(rng.choice(pool), mode) for _ in range(count)]

    if mode == "writeback_contention":
        wb_multi = filter_available(
            MLU_OPS + DVU_OPS + FPU_TO_GPR_OPS, avail_set
        )
        ops = _emit_writeback_contention(count, wb_multi, avail_alu, rng)
        return [(op, mode) for op in ops]

    if mode == "lsu_stlf":
        ops = _emit_lsu_stlf(count, avail_stores, avail_loads, avail_alu, rng)
        return [(op, mode) for op in ops]

    if mode == "rob_saturation":
        ops = _emit_rob_saturation(
            count, avail_set, available_alphabet, avail_alu, rng
        )
        return [(op, mode) for op in ops]

    raise ValueError(f"Unknown shaping mode: {mode}")
