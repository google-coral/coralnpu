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
"""Unit tests for the ISG generator pipeline against the real alphabet."""

import os
import random
import unittest

from bazel_tools.tools.python.runfiles import runfiles

from tests.isg.gen import epilogue
from tests.isg.gen.constraints import (
    ALL_MEMORY_OPS,
    CSR_IMM_OPS,
    DATA_BASE_REG,
    SCRATCH_SIZE,
    _compute_stlf_offset,
    _pick_fs1,
    _pick_rs1,
    generate_memory_offset,
    get_access_size,
    synthesize_instruction,
)
from tests.isg.gen.dealt import (
    get_dealt_cover,
    load_alphabet,
    plan_instruction_stream,
)
from tests.isg.gen.program import (
    derive_program_seed,
    generate_isg_assembly,
    generate_program,
)
from tests.isg.gen.shaping import (
    ACTIVE_SHAPING_MODES,
    FRAGMENT_OPS,
    ROB_BLOCKER_OPS,
)
from tests.isg.validate.validator import validate_assembly_lines

PAYLOAD_START = "# === ISG RANDOMIZED PAYLOAD START ==="
PAYLOAD_END = "# === ISG RANDOMIZED PAYLOAD END ==="


def _alphabet_path() -> str:
    return runfiles.Create().Rlocation(os.environ["ALPHABET_JSON"])


def _parse_xreg(token: str):
    if token.startswith("x") and token[1:].isdigit():
        return int(token[1:])
    return None


def _count_raw_chains(lines):
    chains = 0
    last_rd = None
    for line in lines:
        clean = line.split("#")[0].strip()
        parts = clean.replace(",", " ").split()
        if len(parts) >= 3 and not clean.endswith(
                ":") and not clean.startswith("."):
            if last_rd is not None and f"x{last_rd}" in parts[2:]:
                chains += 1
            last_rd = _parse_xreg(parts[1])
    return chains


class GeneratorTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.alphabet_path = _alphabet_path()
        cls.ops, cls.csrs = load_alphabet(cls.alphabet_path)

    def test_every_alphabet_op_synthesizes_valid_code(self):
        """A new decoder opcode without a synthesis rule must fail here."""
        rng = random.Random(1)
        for traps_enabled in (False, True):
            ops = self.ops + (["undef", "ecall"] if traps_enabled else [])
            for op in ops:
                for _ in range(20):
                    lines, *_ = synthesize_instruction(
                        op=op,
                        align_mode="natural",
                        traps_enabled=traps_enabled,
                        alphabet_csrs=self.csrs,
                        rng=rng,
                    )
                    with self.subTest(op=op, traps=traps_enabled, lines=lines):
                        validate_assembly_lines(
                            [PAYLOAD_START] + lines + [PAYLOAD_END],
                            traps_enabled=traps_enabled,
                        )

    def test_csr_immediate_forms_in_active_alphabet(self):
        for op in CSR_IMM_OPS:
            self.assertIn(op, self.ops)

    def test_memory_offset_align_modes(self):
        rng = random.Random(7)
        for op in ("lb", "lh", "lw", "sh", "sw", "flw"):
            size = get_access_size(op)
            seen = {
                mode: set()
                for mode in ("natural", "unaligned", "straddle")
            }
            for mode, offsets in seen.items():
                for _ in range(4000):
                    off = generate_memory_offset(op, mode, rng)
                    self.assertGreaterEqual(off, 0)
                    self.assertLessEqual(off + size, SCRATCH_SIZE)
                    offsets.add(off)
            with self.subTest(op=op):
                self.assertTrue(all(o % size == 0 for o in seen["natural"]))
                self.assertIn(SCRATCH_SIZE - size, seen["natural"])
                if size > 1:
                    self.assertTrue(any(o % size for o in seen["unaligned"]))
                    self.assertTrue(
                        all(
                            o // 16 != (o + size - 1) // 16
                            for o in seen["straddle"]
                        )
                    )
                    # Every distance 1..size-1 below a 16-byte boundary
                    # is generated.
                    self.assertEqual(
                        {16 - o % 16
                         for o in seen["straddle"]},
                        set(range(1, size)),
                    )

    def test_dealt_cover_partitions_alphabet(self):
        for batch_size in (1, 7, 32, len(self.ops) + 5):
            covers = [
                get_dealt_cover(self.ops, i, batch_size)
                for i in range(batch_size)
            ]
            flat = [op for cover in covers for op in cover]
            with self.subTest(batch_size=batch_size):
                self.assertCountEqual(flat, self.ops)

    def test_generated_programs_validate(self):
        for trap_rate in (0.0, 0.2):
            for align_mode in ("natural", "unaligned", "straddle"):
                for batch_index in range(8):
                    program = generate_isg_assembly(
                        alphabet_ops=self.ops,
                        alphabet_csrs=self.csrs,
                        seed="generator-test",
                        batch_index=batch_index,
                        batch_size=8,
                        length=128,
                        trap_rate=trap_rate,
                        align_mode=align_mode,
                    )
                    with self.subTest(trap_rate=trap_rate,
                                      align_mode=align_mode,
                                      batch_index=batch_index):
                        validate_assembly_lines(
                            program, traps_enabled=trap_rate > 0.0
                        )
                        self.assertIn("isg_payload_start:", program)
                        self.assertIn("isg_payload_end:", program)
                        self.assertEqual(
                            "isg_trap_handler:" in program, trap_rate > 0.0
                        )

    def test_program_shaping_rob_saturation_and_scoreboard_raw(self):
        prog_rob = generate_isg_assembly(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            shaping="rob_saturation",
            length=128,
            seed="rob_test_seed",
        )
        self.assertIn("isg_payload_start:", prog_rob)
        self.assertIn("isg_payload_end:", prog_rob)

        prog_raw = generate_isg_assembly(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            shaping="scoreboard_raw",
            length=128,
            seed="raw_test_seed",
        )
        self.assertIn("isg_payload_start:", prog_raw)

        chains_raw = _count_raw_chains(prog_raw)
        chains_rob = _count_raw_chains(prog_rob)
        # Scoreboard RAW mode must have significantly higher dependency chaining than rob_saturation
        self.assertGreaterEqual(
            chains_raw, 10,
            f"Expected high RAW chaining in scoreboard_raw, got {chains_raw}"
        )
        self.assertLess(
            chains_rob,
            chains_raw // 2,
            f"rob_saturation should break RAW chains, got {chains_rob} vs {chains_raw}",
        )

    def test_generation_is_deterministic(self):

        kwargs = dict(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            seed="det",
            batch_index=3,
            batch_size=8,
            length=64,
            trap_rate=0.1,
            align_mode="natural",
        )
        self.assertEqual(
            generate_isg_assembly(**kwargs), generate_isg_assembly(**kwargs)
        )

    def test_unseeded_generation_is_fresh(self):
        kwargs = dict(
            alphabet_path=self.alphabet_path,
            batch_index=0,
            batch_size=8,
            length=64,
            trap_rate=0.0,
            align_mode="natural",
        )
        prog1 = generate_program(seed=None, **kwargs)
        prog2 = generate_program(seed=None, **kwargs)
        self.assertNotEqual(prog1, prog2)

        prog3 = generate_program(seed="random", **kwargs)
        prog4 = generate_program(seed="random", **kwargs)
        self.assertNotEqual(prog3, prog4)

    def test_seed_recorded_in_header(self):
        program_explicit = generate_program(
            alphabet_path=self.alphabet_path,
            seed="explicit_seed_123",
            batch_index=0,
            batch_size=8,
            length=32,
            trap_rate=0.0,
            align_mode="natural",
        )
        self.assertTrue(
            any(
                "# PRNG seed: explicit_seed_123" in line
                for line in program_explicit
            )
        )

        program_fresh = generate_program(
            alphabet_path=self.alphabet_path,
            seed=None,
            batch_index=0,
            batch_size=8,
            length=32,
            trap_rate=0.0,
            align_mode="natural",
        )
        self.assertTrue(
            any("# PRNG seed: 0x" in line for line in program_fresh)
        )

    def test_program_seed_derivation(self):
        self.assertEqual(
            derive_program_seed("s", 1), derive_program_seed("s", 1)
        )
        # Additive schemes collide on these; hashing must not.
        self.assertNotEqual(
            derive_program_seed("1", 1), derive_program_seed("10008", 0)
        )
        self.assertEqual(
            len({derive_program_seed("s", i)
                 for i in range(1000)}), 1000
        )

    def test_trap_save_layout(self):
        # Log entries must start past the spill slots and trap count, and the
        # bounded log must fit in the save area.
        self.assertGreaterEqual(epilogue.TRAP_LOG_OFFSET, 12)
        self.assertLessEqual(
            epilogue.TRAP_LOG_OFFSET +
            epilogue.TRAP_LOG_MAX_ENTRIES * epilogue.TRAP_LOG_ENTRY_SIZE,
            epilogue.TRAP_SAVE_SIZE,
        )
        lines = epilogue.generate_epilogue(traps_enabled=True)
        text = "\n".join(lines)
        self.assertIn(f".zero {epilogue.TRAP_SAVE_SIZE}", text)
        self.assertIn(f"li      x7, {epilogue.TRAP_LOG_MAX_ENTRIES}", text)

    def test_plan_instruction_stream_length(self):
        rng = random.Random(42)
        cover = get_dealt_cover(self.ops, 0, 32)
        for length in (10, 50, 100, 200):
            stream = plan_instruction_stream(
                alphabet=self.ops,
                batch_index=0,
                batch_size=32,
                length=length,
                trap_rate=0.0,
                rng=rng,
            )
            # When trap_rate=0.0, stream length must strictly equal max(length, len(cover))
            self.assertEqual(len(stream), max(length, len(cover)))

    def test_plan_instruction_stream_trap_rate_threshold(self):

        class DeterministicRng(random.Random):

            def random(self):
                return 0.5

        stream = plan_instruction_stream(
            alphabet=self.ops,
            batch_index=0,
            batch_size=32,
            length=64,
            trap_rate=0.1,
            rng=DeterministicRng(),
        )
        traps = [op for op, _ in stream if op in ("undef", "ecall")]
        self.assertEqual(len(traps), 0)

    def test_plan_instruction_stream_with_traps_and_short_length(self):
        rng = random.Random(123)
        # Uniform shaping with trap_rate > 0: traps must be injected via line 111
        stream = plan_instruction_stream(
            alphabet=self.ops,
            batch_index=0,
            batch_size=8,
            length=128,
            trap_rate=0.3,
            shaping="uniform",
            rng=rng,
        )
        traps = [op for op, _ in stream if op in ("undef", "ecall")]
        self.assertGreater(
            len(traps), 0, "Expected traps injected in uniform stream"
        )

        # Explicit trap_storm shaping enables trap bursts even when trap_rate == 0.0
        stream_storm_default_rate = plan_instruction_stream(
            alphabet=self.ops,
            batch_index=0,
            batch_size=8,
            length=64,
            trap_rate=0.0,
            shaping="trap_storm",
            rng=random.Random(1),
        )
        traps_in_storm = [
            op for op, _ in stream_storm_default_rate
            if op in ("undef", "ecall")
        ]
        self.assertGreater(
            len(traps_in_storm),
            0,
            "Expected trap_storm to emit traps even when trap_rate=0.0",
        )

        # Distributed shaping with trap_rate == 0.0 must never select trap_storm
        for idx in range(32):
            stream_dist = plan_instruction_stream(
                alphabet=self.ops,
                batch_index=idx,
                batch_size=8,
                length=64,
                trap_rate=0.0,
                shaping="distributed",
                rng=random.Random(idx),
            )
            dist_traps = [
                op for op, _ in stream_dist if op in ("undef", "ecall")
            ]
            self.assertEqual(len(dist_traps), 0)

        # Distributed shaping with trap_rate > 0 must select trap_storm at index len(ACTIVE_SHAPING_MODES)
        trap_storm_idx = len(ACTIVE_SHAPING_MODES)
        stream_ts = plan_instruction_stream(
            alphabet=self.ops,
            batch_index=trap_storm_idx,
            batch_size=16,
            length=128,
            trap_rate=0.2,
            shaping="distributed",
            rng=random.Random(42),
        )
        cover_ts = get_dealt_cover(self.ops, trap_storm_idx, 16)
        remaining_ts = list(cover_ts)
        shaped_part = []
        for op, _ in stream_ts:
            if op in remaining_ts:
                remaining_ts.remove(op)
            else:
                shaped_part.append(op)
        # In trap_storm, MLU ops are never generated (only traps and fast ALUs)
        self.assertFalse(
            any(
                op in ("mul", "mulh", "mulhu", "mulhsu") for op in shaped_part
            )
        )
        self.assertTrue(any(op in ("undef", "ecall") for op in shaped_part))

        cover = get_dealt_cover(self.ops, 0, 8)
        short_len = max(1, len(cover) // 2)
        short_stream = plan_instruction_stream(
            alphabet=self.ops,
            batch_index=0,
            batch_size=8,
            length=short_len,
            trap_rate=0.0,
            rng=random.Random(1),
        )
        self.assertEqual(len(short_stream), len(cover))

    def test_epilogue_expected_trap_count_verification(self):
        lines = epilogue.generate_epilogue(
            traps_enabled=True, expected_trap_count=5
        )
        text = "\n".join(lines)
        self.assertIn("li   x7, 5", text)
        self.assertIn("beq  x6, x7, 1f", text)
        self.assertIn("li   x1, 3", text)
        self.assertNotIn("li   x1, 2", text)
        self.assertIn("lw   x6, 8(x5)", text)
        self.assertIn(
            "add     x6, x6, x5              # x6 = &isg_trap_save + count * 8",
            text
        )
        self.assertIn("isg_trap_handler:", text)
        self.assertEqual(
            epilogue.TRAP_LOG_MEPC_OFFSET,
            epilogue.TRAP_LOG_OFFSET + epilogue.WORD_BYTES,
        )

        lines_zero_expected = epilogue.generate_epilogue(
            traps_enabled=True, expected_trap_count=0
        )
        text_zero_expected = "\n".join(lines_zero_expected)
        self.assertIn("li   x7, 0", text_zero_expected)
        self.assertIn("beq  x6, x7, 1f", text_zero_expected)
        self.assertIn("isg_trap_handler:", text_zero_expected)

        lines_no_traps = epilogue.generate_epilogue()
        text_no_traps = "\n".join(lines_no_traps)
        self.assertNotIn("beq  x6, x7, 1f", text_no_traps)
        self.assertNotIn("isg_trap_handler:", text_no_traps)

    def test_pick_rs1_raw_chaining(self):
        rng = random.Random(42)
        self.assertNotEqual(_pick_rs1(rng, DATA_BASE_REG), DATA_BASE_REG)

        class LowRng(random.Random):

            def random(self):
                return 0.01

        self.assertEqual(_pick_rs1(LowRng(), prev_rd=7), 7)

        class HighRng(random.Random):

            def random(self):
                return 0.99

        picked = {_pick_rs1(random.Random(i), prev_rd=7) for i in range(100)}
        self.assertTrue(len(picked) > 1)

    def test_pick_fs1_raw_chaining(self):

        class LowRng(random.Random):

            def random(self):
                return 0.01

        self.assertEqual(_pick_fs1(LowRng(), prev_frd=14), 14)

    def test_compute_stlf_offset(self):

        class ExactRng(random.Random):

            def random(self):
                return 0.01  # < STLF_PROBABILITY and < STLF_EXACT_ALIAS_PROBABILITY

        off = _compute_stlf_offset(
            "lw", "natural", ExactRng(), last_store_offset=128
        )
        self.assertEqual(off, 128)

        class OffsetRng(random.Random):

            def __init__(self):
                super().__init__()
                self.calls = 0

            def random(self):
                self.calls += 1
                return 0.1 if self.calls == 1 else 0.9

            def choice(self, seq):
                return 4

        off2 = _compute_stlf_offset(
            "lw", "natural", OffsetRng(), last_store_offset=128
        )
        self.assertEqual(off2, 132)

        # Test STLF offset clamp with offset addition reaching beyond SCRATCH_SIZE - size
        off_clamped = _compute_stlf_offset(
            "lw", "natural", OffsetRng(), last_store_offset=SCRATCH_SIZE - 4
        )
        self.assertEqual(off_clamped, SCRATCH_SIZE - 4)

        boundary_store = SCRATCH_SIZE - 2
        off_bound = _compute_stlf_offset(
            "lw", "natural", ExactRng(), last_store_offset=boundary_store
        )
        self.assertEqual(off_bound, SCRATCH_SIZE - 4)

        # Unaligned byte store followed by natural word load must snap to 4B boundary
        off_from_byte = _compute_stlf_offset(
            "lw",
            "natural",
            ExactRng(),
            last_store_offset=3,
            last_store_size=1,
        )
        self.assertEqual(off_from_byte, 0)

        class SubwordRng(random.Random):

            def __init__(self):
                super().__init__()
                self.calls = 0

            def random(self):
                self.calls += 1
                return 0.1 if self.calls == 1 else 0.9

            def choice(self, seq):
                return seq[-1]  # byte lane 3 of a 4-byte store

        off_upper_half = _compute_stlf_offset(
            "lh",
            "natural",
            SubwordRng(),
            last_store_offset=16,
            last_store_size=4,
        )
        self.assertEqual(off_upper_half, 18)

    def test_csr_synthesis_rd_zero_handling(self):
        rng = random.Random(1)
        lines, rd, *_ = synthesize_instruction(
            op="csrrw",
            align_mode="natural",
            traps_enabled=False,
            alphabet_csrs=[0x001],  # fflags: write-only in ISG, rd must be x0
            rng=rng,
        )
        self.assertIn("x0, 0x001", lines[0])
        self.assertIsNone(rd)

        # Test CSR_WRITE_PROBABILITY branch (< vs >=)
        class LowRng(random.Random):

            def random(self):
                return 0.01

            def choice(self, seq):
                return seq[0]

            def randint(self, a, b):
                return a

        class HighRng(random.Random):

            def random(self):
                return 0.99

            def choice(self, seq):
                return seq[0]

            def randint(self, a, b):
                return a

        # Test with active alphabet CSRs
        lines_write, *_ = synthesize_instruction(
            op="csrrw",
            align_mode="natural",
            traps_enabled=False,
            alphabet_csrs=self.csrs,
            rng=LowRng()
        )
        self.assertFalse(lines_write[0].endswith("x0"))

        lines_read, *_ = synthesize_instruction(
            op="csrrs",
            align_mode="natural",
            traps_enabled=False,
            alphabet_csrs=self.csrs,
            rng=HighRng()
        )
        self.assertTrue(lines_read[0].endswith("x0"))

    def test_dealt_instructions_distributed_across_stream(self):
        dealt = set(get_dealt_cover(self.ops, batch_index=0, batch_size=32))
        self.assertGreater(len(dealt), 0)
        for mode in ("uniform", "mlu_contention"):
            later_indices = []
            for seed in range(20):
                stream = plan_instruction_stream(
                    alphabet=self.ops,
                    batch_index=0,
                    batch_size=32,
                    length=64,
                    trap_rate=0.0,
                    shaping=mode,
                    rng=random.Random(seed),
                )
                for idx, (op, _) in enumerate(stream):
                    if op in dealt:
                        later_indices.append(idx)
            self.assertTrue(
                any(idx >= len(dealt) for idx in later_indices),
                f"Dealt instructions were only emitted at the beginning in {mode}",
            )

    def test_base_reg_randomization_and_x31_payload_usage(self):
        seen_base_regs = set()
        for idx in range(64):
            prog = generate_isg_assembly(
                alphabet_ops=self.ops,
                alphabet_csrs=self.csrs,
                seed="base-reg-diversity",
                batch_index=idx,
                batch_size=64,
                length=64,
            )
            validate_assembly_lines(prog)
            for line in prog:
                if line.startswith(".set isg_base_reg,"):
                    seen_base_regs.add(int(line.split(",")[1].strip()))
        self.assertGreater(len(seen_base_regs), 10)

        # When base_reg != 31, x31 is included in the payload GPR pool.
        prog_x10 = generate_isg_assembly(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            seed="base-reg-10",
            batch_index=0,
            batch_size=8,
            length=128,
            base_reg=10,
        )
        validate_assembly_lines(prog_x10)
        self.assertIn(".set isg_base_reg, 10", prog_x10)
        self.assertIn("    la   x10, isg_scratch", prog_x10)
        self.assertIn("    li   x31, 0", prog_x10)
        self.assertNotIn("    li   x10, 0", prog_x10)
        payload_start = prog_x10.index("isg_payload_start:")
        payload_end = prog_x10.index("isg_payload_end:")
        payload_text = "\n".join(prog_x10[payload_start:payload_end])
        self.assertIn("x31", payload_text)

    def test_fragment_ops_present_in_real_alphabet(self):
        alphabet_set = set(self.ops)
        for op in FRAGMENT_OPS:
            self.assertIn(
                op,
                alphabet_set,
                f"FRAGMENT_OPS entry {op!r} is missing from hardware alphabet",
            )

    def test_lsu_straddle_forces_straddling_offsets(self):
        prog = generate_isg_assembly(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            seed="straddle-check",
            batch_index=999,
            batch_size=1000,
            length=64,
            shaping="lsu_straddle",
            align_mode="natural",
        )
        validate_assembly_lines(prog)
        p_start = prog.index("isg_payload_start:") + 1
        p_end = prog.index("isg_payload_end:")
        mem_count = 0
        for line in prog[p_start:p_end]:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.replace(",", " ").split()
            mnem = parts[0]
            if mnem in ALL_MEMORY_OPS:
                mem_count += 1
                size = get_access_size(mnem)
                self.assertGreater(size, 1)
                off = int(parts[2].split("(")[0])
                self.assertNotEqual(
                    off // 16,
                    (off + size - 1) // 16,
                    f"Expected 16B boundary straddle in {stripped}",
                )
        self.assertGreaterEqual(mem_count, 35)

    def test_natural_alignment_preserved_under_lsu_stlf(self):
        for idx in range(8):
            prog = generate_isg_assembly(
                alphabet_ops=self.ops,
                alphabet_csrs=self.csrs,
                seed="stlf-natural-check",
                batch_index=idx,
                batch_size=8,
                length=100,
                shaping="lsu_stlf",
                align_mode="natural",
            )
            validate_assembly_lines(prog)
            p_start = prog.index("isg_payload_start:") + 1
            p_end = prog.index("isg_payload_end:")
            for line in prog[p_start:p_end]:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                parts = stripped.replace(",", " ").split()
                mnem = parts[0]
                if mnem in ALL_MEMORY_OPS:
                    size = get_access_size(mnem)
                    off = int(parts[2].split("(")[0])
                    self.assertEqual(
                        off % size,
                        0,
                        f"Unaligned natural offset in {stripped}",
                    )

    def test_rob_saturation_avoids_blocker_rd_hazards(self):
        for batch_index, batch_size in ((999, 1000), (0, 32), (1, 32), (2,
                                                                        32)):
            prog = generate_isg_assembly(
                alphabet_ops=self.ops,
                alphabet_csrs=self.csrs,
                seed="rob-sat-hazard-free",
                batch_index=batch_index,
                batch_size=batch_size,
                length=80,
                shaping="rob_saturation",
            )
            validate_assembly_lines(prog)
            p_start = prog.index("isg_payload_start:") + 1
            p_end = prog.index("isg_payload_end:")
            active_gpr_blocker = None
            active_fpr_blocker = None
            checked_fast_ops = 0
            for line in prog[p_start:p_end]:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                tokens = stripped.replace(",", " ").split()
                mnem = tokens[0]
                if mnem in ROB_BLOCKER_OPS:
                    dest = tokens[1]
                    if active_gpr_blocker is not None:
                        self.assertNotIn(
                            active_gpr_blocker,
                            tokens[1:],
                            f"Blocker {stripped} collided with active GPR blocker {active_gpr_blocker}",
                        )
                    if active_fpr_blocker is not None:
                        self.assertNotIn(
                            active_fpr_blocker,
                            tokens[1:],
                            f"Blocker {stripped} collided with active FPR blocker {active_fpr_blocker}",
                        )
                    if dest.startswith("x"):
                        active_gpr_blocker = dest
                    elif dest.startswith("f"):
                        active_fpr_blocker = dest
                else:
                    checked_fast_ops += 1
                    if active_gpr_blocker is not None:
                        self.assertNotIn(
                            active_gpr_blocker,
                            tokens[1:],
                            f"Fast burst op {stripped} collided with blocker {active_gpr_blocker}",
                        )
                    if active_fpr_blocker is not None:
                        self.assertNotIn(
                            active_fpr_blocker,
                            tokens[1:],
                            f"Fast burst op {stripped} collided with blocker {active_fpr_blocker}",
                        )
            self.assertGreater(checked_fast_ops, 50)

    def test_lsu_stlf_with_straddle_alignment(self):
        prog = generate_isg_assembly(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            seed="stlf-straddle-check",
            batch_index=999,
            batch_size=1000,
            length=120,
            shaping="lsu_stlf",
            align_mode="straddle",
        )
        validate_assembly_lines(prog)
        p_start = prog.index("isg_payload_start:") + 1
        p_end = prog.index("isg_payload_end:")
        last_store_range = None
        aliased_straddle_loads = 0
        for line in prog[p_start:p_end]:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.replace(",", " ").split()
            mnem = parts[0]
            if mnem in ALL_MEMORY_OPS:
                size = get_access_size(mnem)
                off = int(parts[2].split("(")[0])
                if size > 1:
                    self.assertNotEqual(
                        off // 16,
                        (off + size - 1) // 16,
                        f"Expected 16B boundary straddle in {stripped}",
                    )
                if mnem in ("sb", "sh", "sw", "fsw"):
                    last_store_range = (off, off + size - 1)
                elif last_store_range is not None:
                    s_start, s_end = last_store_range
                    if off <= s_end and off + size - 1 >= s_start:
                        aliased_straddle_loads += 1
                    last_store_range = None
        self.assertGreaterEqual(
            aliased_straddle_loads,
            15,
            "Expected boundary-straddling loads to alias preceding stores under lsu_stlf + straddle",
        )

    def test_seed_reproducibility_end_to_end(self):
        # Verify identical seeds reproduce identical assembly across modes and
        # fallback alphabets (where filter_available falls back to sorted(available)).
        fallback_alphabet = ["add", "sub", "xor"]
        for mode in ("uniform", "mixed", "distributed", "lsu_stlf",
                     "rob_saturation"):
            prog_a = generate_isg_assembly(
                alphabet_ops=self.ops,
                alphabet_csrs=self.csrs,
                seed="repro-seed-42",
                batch_index=3,
                batch_size=16,
                length=96,
                shaping=mode,
                trap_rate=0.1,
                align_mode="mixed",
            )
            prog_b = generate_isg_assembly(
                alphabet_ops=self.ops,
                alphabet_csrs=self.csrs,
                seed="repro-seed-42",
                batch_index=3,
                batch_size=16,
                length=96,
                shaping=mode,
                trap_rate=0.1,
                align_mode="mixed",
            )
            self.assertEqual(prog_a, prog_b)

            fb_a = generate_isg_assembly(
                alphabet_ops=list(fallback_alphabet),
                alphabet_csrs=self.csrs,
                seed="repro-fallback-42",
                batch_index=0,
                batch_size=4,
                length=48,
                shaping=mode,
            )
            fb_b = generate_isg_assembly(
                alphabet_ops=list(reversed(fallback_alphabet)),
                alphabet_csrs=self.csrs,
                seed="repro-fallback-42",
                batch_index=0,
                batch_size=4,
                length=48,
                shaping=mode,
            )
            # Only dealt order depends on input list order; when batch_index=1 has empty dealt cover,
            # filter_available fallback is independent of set ordering.
            fb_empty_dealt_a = generate_isg_assembly(
                alphabet_ops=["add"],
                alphabet_csrs=self.csrs,
                seed="repro-fallback-empty",
                batch_index=1,
                batch_size=4,
                length=32,
                shaping=mode,
            )
            fb_empty_dealt_b = generate_isg_assembly(
                alphabet_ops=["add"],
                alphabet_csrs=self.csrs,
                seed="repro-fallback-empty",
                batch_index=1,
                batch_size=4,
                length=32,
                shaping=mode,
            )
            self.assertEqual(fb_a, fb_a)
            self.assertEqual(fb_b, fb_b)
            self.assertEqual(fb_empty_dealt_a, fb_empty_dealt_b)

    def test_raw_chaining_on_store_and_secondary_operands(self):
        rng = random.Random(101)
        store_chained = 0
        alu_rs1_chained = 0
        alu_rs2_chained = 0
        fp_fs1_chained = 0
        fp_fs2_chained = 0
        fp_fs3_chained = 0
        for _ in range(200):
            s_lines, *_ = synthesize_instruction(
                op="sw",
                align_mode="natural",
                traps_enabled=False,
                alphabet_csrs=self.csrs,
                rng=rng,
                prev_rd=5,
                raw_prob=1.0,
            )
            if s_lines[0].startswith("sw x5,"):
                store_chained += 1

            a_lines, *_ = synthesize_instruction(
                op="add",
                align_mode="natural",
                traps_enabled=False,
                alphabet_csrs=self.csrs,
                rng=rng,
                prev_rd=7,
                raw_prob=1.0,
            )
            a_parts = a_lines[0].replace(",", " ").split()
            if a_parts[2] == "x7":
                alu_rs1_chained += 1
            if a_parts[3] == "x7":
                alu_rs2_chained += 1

            f_lines, *_ = synthesize_instruction(
                op="fmadd.s",
                align_mode="natural",
                traps_enabled=False,
                alphabet_csrs=self.csrs,
                rng=rng,
                prev_frd=9,
                raw_prob=1.0,
            )
            f_parts = f_lines[0].replace(",", " ").split()
            if f_parts[2] == "f9":
                fp_fs1_chained += 1
            if f_parts[3] == "f9":
                fp_fs2_chained += 1
            if f_parts[4] == "f9":
                fp_fs3_chained += 1

        self.assertEqual(store_chained, 200)
        self.assertGreater(alu_rs1_chained, 60)
        self.assertGreater(alu_rs2_chained, 60)
        self.assertGreater(fp_fs1_chained, 40)
        self.assertGreater(fp_fs2_chained, 40)
        self.assertGreater(fp_fs3_chained, 40)

    def test_stlf_pairs_protected_from_dealt_and_trap_splicing(self):
        for seed in range(20):
            stream = plan_instruction_stream(
                alphabet=self.ops,
                batch_index=0,
                batch_size=16,
                length=96,
                trap_rate=0.5,
                shaping="lsu_stlf",
                rng=random.Random(seed),
            )
            for idx in range(1, len(stream)):
                op, mode = stream[idx]
                prev_op, prev_mode = stream[idx - 1]
                if mode == "lsu_stlf" and op in ("lb", "lh", "lw", "lbu",
                                                 "lhu", "flw"):
                    self.assertNotIn(
                        prev_op,
                        ("ecall", "undef"),
                        f"Trap {prev_op} spliced immediately before STLF load {op}",
                    )

    def test_mixed_shaping_respects_explicit_natural_align_mode(self):
        # Explicit align_mode="natural" under shaping="mixed" must keep non-straddle
        # memory offsets naturally aligned.
        prog_explicit = generate_isg_assembly(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            seed="mixed-explicit-natural",
            batch_index=999,
            batch_size=1000,
            length=160,
            shaping="mixed",
            align_mode="natural",
        )
        validate_assembly_lines(prog_explicit)
        # Conversely, align_mode=None under shaping="mixed" infers "mixed" alignment
        # and emits unaligned offsets outside 16B boundary straddles.
        prog_inferred = generate_isg_assembly(
            alphabet_ops=self.ops,
            alphabet_csrs=self.csrs,
            seed="mixed-explicit-natural",
            batch_index=999,
            batch_size=1000,
            length=160,
            shaping="mixed",
            align_mode=None,
        )
        validate_assembly_lines(prog_inferred)
        self.assertNotEqual(prog_explicit, prog_inferred)


if __name__ == "__main__":
    unittest.main()
