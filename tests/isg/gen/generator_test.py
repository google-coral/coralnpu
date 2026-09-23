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
    CSR_IMM_OPS,
    SCRATCH_SIZE,
    generate_memory_offset,
    get_access_size,
    synthesize_instruction,
)
from tests.isg.gen.dealt import get_dealt_cover, load_alphabet, plan_instruction_stream
from tests.isg.gen.program import derive_program_seed, generate_program
from tests.isg.validate.validator import validate_assembly_lines

PAYLOAD_START = "# === ISG RANDOMIZED PAYLOAD START ==="
PAYLOAD_END = "# === ISG RANDOMIZED PAYLOAD END ==="


def _alphabet_path() -> str:
    return runfiles.Create().Rlocation(os.environ["ALPHABET_JSON"])


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
                    lines = synthesize_instruction(
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
                    program = generate_program(
                        alphabet_path=self.alphabet_path,
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

    def test_generation_is_deterministic(self):
        kwargs = dict(
            alphabet_path=self.alphabet_path,
            seed="det",
            batch_index=3,
            batch_size=8,
            length=64,
            trap_rate=0.1,
            align_mode="natural",
        )
        self.assertEqual(
            generate_program(**kwargs), generate_program(**kwargs)
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
        for length in (10, 50, 100, 200):
            stream = plan_instruction_stream(
                alphabet=self.ops,
                batch_index=0,
                batch_size=32,
                length=length,
                trap_rate=0.0,
                rng=rng,
            )
            self.assertGreaterEqual(len(stream), length)

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
        traps = [op for op in stream if op in ("undef", "ecall")]
        self.assertEqual(len(traps), 0)

    def test_dealt_instructions_distributed_across_stream(self):
        dealt = set(get_dealt_cover(self.ops, batch_index=0, batch_size=32))
        self.assertGreater(len(dealt), 0)
        later_indices = []
        for seed in range(20):
            stream = plan_instruction_stream(
                alphabet=self.ops,
                batch_index=0,
                batch_size=32,
                length=64,
                trap_rate=0.0,
                rng=random.Random(seed),
            )
            for idx, op in enumerate(stream):
                if op in dealt:
                    later_indices.append(idx)
        self.assertTrue(any(idx >= len(dealt) for idx in later_indices))

    def test_base_reg_randomization_and_x31_payload_usage(self):
        seen_base_regs = set()
        for idx in range(64):
            prog = generate_program(
                alphabet_path=self.alphabet_path,
                seed="base-reg-diversity",
                batch_index=idx,
                batch_size=64,
                length=64,
                trap_rate=0.0,
                align_mode="natural",
            )
            validate_assembly_lines(prog)
            for line in prog:
                if line.startswith(".set isg_base_reg,"):
                    seen_base_regs.add(int(line.split(",")[1].strip()))
        self.assertGreater(len(seen_base_regs), 10)

        # When base_reg != 31, x31 is included in the payload GPR pool.
        prog_x10 = generate_program(
            alphabet_path=self.alphabet_path,
            seed="base-reg-10",
            batch_index=0,
            batch_size=8,
            length=128,
            trap_rate=0.0,
            align_mode="natural",
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


if __name__ == "__main__":
    unittest.main()
