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
"""Unit tests for ISG dispatch-pressure shaping module."""

import random
import unittest

from tests.isg.gen.shaping import (
    ACTIVE_SHAPING_MODES,
    CONTROL_OPS,
    DVU_OPS,
    FAST_ALU_OPS,
    FPU_TO_GPR_OPS,
    FRAGMENT_OPS,
    LOAD_OPS,
    LSU_OPS,
    MLU_OPS,
    SHAPING_MODES,
    STORE_OPS,
    STRADDLE_LSU_OPS,
    generate_shaped_sequence,
    resolve_shaping_mode,
)


class ShapingTest(unittest.TestCase):

    def setUp(self):
        self.alphabet = [
            "add", "sub", "mul", "mulh", "div", "rem", "lw", "sw", "lh", "sh",
            "lb", "sb", "jal", "jalr", "beq", "bne", "csrrw", "csrrwi",
            "fence", "fencei", "fencetso", "and", "or"
        ]
        self.rng = random.Random(42)

    def test_all_modes_produce_exact_count(self):
        for mode in SHAPING_MODES:
            seq = generate_shaped_sequence(
                mode=mode,
                count=64,
                available_alphabet=self.alphabet,
                traps_enabled=True,
                rng=random.Random(123),
            )
            self.assertEqual(
                len(seq), 64, f"Mode {mode} did not produce exact count"
            )
            for op, slot_mode in seq:
                self.assertIsInstance(op, str)
                self.assertNotIn(slot_mode, ("mixed", "distributed"))

    def test_mlu_contention_density(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="mlu_contention",
                count=300,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        mlu_count = sum(1 for op in seq if op in MLU_OPS)
        self.assertGreaterEqual(mlu_count, 180, "Expected >= 60% MLU ops")

        # Verify that interior ALU gaps span 1, 2, and 3 ops across lanes 0..3.
        alu_gaps = []
        run = 0
        for op in seq:
            if op in FAST_ALU_OPS:
                run += 1
            else:
                if run > 0:
                    alu_gaps.append(run)
                    run = 0
        self.assertEqual(
            set(alu_gaps),
            {1, 2, 3},
            f"Expected ALU gap lengths {{1, 2, 3}} between MLU bursts, got {alu_gaps}",
        )

    def test_dvu_backpressure_density(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="dvu_backpressure",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        dvu_count = sum(1 for op in seq if op in DVU_OPS)
        self.assertGreaterEqual(dvu_count, 60, "Expected >= 60% DVU ops")

    def test_lsu_serial_density(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="lsu_serial",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        lsu_count = sum(1 for op in seq if op in LSU_OPS)
        self.assertGreaterEqual(lsu_count, 60, "Expected >= 60% LSU ops")
        self.assertTrue(
            any(op in FAST_ALU_OPS for op in seq),
            "Expected interleaved ALU ops in lsu_serial",
        )

    def test_dispatch_fragment_density(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="dispatch_fragment",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        frag_count = sum(1 for op in seq if op in FRAGMENT_OPS)
        self.assertGreaterEqual(frag_count, 30, "Expected >= 30% fragment ops")

        class LowRng(random.Random):

            def random(self):
                return 0.1

        class HighRng(random.Random):

            def random(self):
                return 0.9

        seq_frag = [
            op for op, _ in generate_shaped_sequence(
                mode="dispatch_fragment",
                count=10,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=LowRng(),
            )
        ]
        self.assertTrue(all(op in FRAGMENT_OPS for op in seq_frag))

        seq_alu = [
            op for op, _ in generate_shaped_sequence(
                mode="dispatch_fragment",
                count=10,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=HighRng(),
            )
        ]
        self.assertTrue(all(op in FAST_ALU_OPS for op in seq_alu))

    def test_trap_storm_emits_traps(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="trap_storm",
                count=50,
                available_alphabet=self.alphabet,
                traps_enabled=True,
                rng=self.rng,
            )
        ]
        trap_count = sum(1 for op in seq if op in ("ecall", "undef"))
        self.assertGreaterEqual(
            trap_count, 10, "Expected >= 10 trap ops in storm"
        )

    def test_writeback_contention_density(self):
        alphabet = self.alphabet + ["fmv.x.w", "fcvt.w.s"]
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="writeback_contention",
                count=100,
                available_alphabet=alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        wb_ops = set(MLU_OPS + DVU_OPS + FPU_TO_GPR_OPS)
        wb_count = sum(1 for op in seq if op in wb_ops)
        self.assertGreaterEqual(
            wb_count, 60, f"Expected >= 60% writeback ops, got {wb_count}"
        )

    def test_lsu_stlf_pairs(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="lsu_stlf",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        lsu_count = sum(1 for op in seq if op in LSU_OPS)
        self.assertGreaterEqual(
            lsu_count, 70, f"Expected >= 70% LSU ops in stlf, got {lsu_count}"
        )
        store_followed_by_load = 0
        store_count = 0
        for i in range(len(seq) - 1):
            if seq[i] in STORE_OPS:
                store_count += 1
                if seq[i + 1] in LOAD_OPS:
                    store_followed_by_load += 1
        self.assertGreater(store_count, 0)
        self.assertEqual(
            store_followed_by_load,
            store_count,
            "Every store should be followed by a load in stlf pairs",
        )

        class StlfNoiseRng(random.Random):

            def random(self):
                return 0.1  # < STLF_ALU_NOISE_PROBABILITY (0.25)

        seq_noise = [
            op for op, _ in generate_shaped_sequence(
                mode="lsu_stlf",
                count=3,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=StlfNoiseRng(),
            )
        ]
        self.assertEqual(len(seq_noise), 3)
        self.assertIn(seq_noise[2], FAST_ALU_OPS)

    def test_rob_saturation_geometry(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="rob_saturation",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        alu_count = sum(1 for op in seq if op in FAST_ALU_OPS)
        self.assertGreaterEqual(
            alu_count, 70, f"Expected >= 70% fast ALU ops, got {alu_count}"
        )
        blocker_ops = set(DVU_OPS + MLU_OPS + ["fdiv.s", "fsqrt.s"])
        blocker_count = sum(1 for op in seq if op in blocker_ops)
        self.assertGreater(blocker_count, 0, "Expected at least 1 blocker op")

    def test_fetch_reorder_density(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="fetch_reorder",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        ctrl_count = sum(1 for op in seq if op in CONTROL_OPS)
        self.assertGreaterEqual(
            ctrl_count, 50, f"Expected >= 50% control ops, got {ctrl_count}"
        )
        self.assertTrue(
            any(op in FAST_ALU_OPS for op in seq),
            "Expected interleaved ALU ops in fetch_reorder",
        )

    def test_resolve_shaping_mode_distributed(self):
        modes_seen = set()
        for idx in range(len(ACTIVE_SHAPING_MODES) * 2):
            mode = resolve_shaping_mode(
                "distributed", batch_index=idx, traps_enabled=True
            )
            modes_seen.add(mode)
        expected = set(ACTIVE_SHAPING_MODES) | {"trap_storm"}
        self.assertEqual(
            modes_seen,
            expected,
            "Distributed shaping should cover all active modes",
        )
        # Test default parameter and traps_enabled=False
        modes_no_traps = {
            resolve_shaping_mode("distributed", batch_index=idx)
            for idx in range(len(ACTIVE_SHAPING_MODES) * 2)
        }
        self.assertEqual(modes_no_traps, set(ACTIVE_SHAPING_MODES))
        self.assertNotIn("trap_storm", modes_no_traps)
        # Test non-distributed passthrough
        self.assertEqual(
            resolve_shaping_mode("uniform", batch_index=0), "uniform"
        )

    def test_mixed_mode_anti_starvation(self):
        seq_pairs = generate_shaped_sequence(
            mode="mixed",
            count=200,
            available_alphabet=self.alphabet,
            traps_enabled=True,
            rng=random.Random(999),
        )
        seq = [op for op, _ in seq_pairs]
        slot_modes = {m for _, m in seq_pairs}
        self.assertEqual(len(seq), 200)
        self.assertNotIn("mixed", slot_modes)
        self.assertGreaterEqual(len(slot_modes), 10)
        has_mlu = any(op in MLU_OPS for op in seq)
        has_dvu = any(op in DVU_OPS for op in seq)
        has_lsu = any(op in LSU_OPS for op in seq)
        has_ctrl = any(op in CONTROL_OPS for op in seq)
        self.assertTrue(has_mlu, "Mixed stream should include MLU ops")
        self.assertTrue(has_dvu, "Mixed stream should include DVU ops")
        self.assertTrue(has_lsu, "Mixed stream should include LSU ops")
        self.assertTrue(has_ctrl, "Mixed stream should include Control ops")

    def test_lsu_straddle_excludes_byte_ops(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="lsu_straddle",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        straddle_count = sum(1 for op in seq if op in STRADDLE_LSU_OPS)
        self.assertGreaterEqual(straddle_count, 60)
        for op in seq:
            self.assertNotIn(op, ("lb", "lbu", "sb"))

    def test_trap_storm_without_traps_falls_back_to_fragment(self):
        seq = [
            op for op, _ in generate_shaped_sequence(
                mode="trap_storm",
                count=50,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=self.rng,
            )
        ]
        self.assertFalse(any(op in ("ecall", "undef") for op in seq))
        allowed = set(FRAGMENT_OPS) | set(FAST_ALU_OPS)
        self.assertTrue(all(op in allowed for op in seq))

    def test_integer_only_alphabet_no_fallback_pollution(self):
        seq_wb = [
            op for op, _ in generate_shaped_sequence(
                mode="writeback_contention",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=random.Random(7),
            )
        ]
        allowed_wb = set(MLU_OPS + DVU_OPS + FAST_ALU_OPS)
        self.assertTrue(
            all(op in allowed_wb for op in seq_wb),
            f"Unexpected non-WB/ALU op in integer-only writeback_contention: {set(seq_wb) - allowed_wb}",
        )

        seq_rr = [
            op for op, _ in generate_shaped_sequence(
                mode="retire_reorder",
                count=100,
                available_alphabet=self.alphabet,
                traps_enabled=False,
                rng=random.Random(8),
            )
        ]
        allowed_rr = set(DVU_OPS + MLU_OPS + LSU_OPS + FAST_ALU_OPS)
        self.assertTrue(all(op in allowed_rr for op in seq_rr))

        no_dvu_alphabet = [op for op in self.alphabet if op not in DVU_OPS]
        seq_rob_mlu = [
            op for op, _ in generate_shaped_sequence(
                mode="rob_saturation",
                count=40,
                available_alphabet=no_dvu_alphabet,
                traps_enabled=False,
                rng=random.Random(9),
            )
        ]
        self.assertIn(seq_rob_mlu[0], MLU_OPS)


if __name__ == "__main__":
    unittest.main()
