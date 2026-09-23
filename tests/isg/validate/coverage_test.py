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
"""Unit tests for ISG dealt coverage closure and analysis."""

import os
import runpy
import sys
import tempfile
import unittest
from unittest import mock

from bazel_tools.tools.python.runfiles import runfiles

from tests.isg.gen.dealt import get_dealt_cover, load_alphabet
from tests.isg.gen.shaping import SHAPING_MODES
from tests.isg.validate.coverage import (
    analyze_assembly_files,
    get_category_for_opcode,
    verify_dealt_coverage,
    verify_stream_batch_coverage,
)


class DealtCoverageTest(unittest.TestCase):
    """Test suite for mathematical and empirical dealt coverage verification."""

    @classmethod
    def setUpClass(cls):
        alphabet_path = runfiles.Create().Rlocation(
            os.environ["ALPHABET_JSON"]
        )
        cls.alphabet_path = alphabet_path
        cls.instructions, cls.csrs = load_alphabet(alphabet_path)

    def test_alphabet_non_empty(self):
        """Ensures the core_mini_axi alphabet contains all expected instructions."""
        self.assertGreater(len(self.instructions), 60)
        self.assertIn("add", self.instructions)
        self.assertIn("mul", self.instructions)
        self.assertIn("clz", self.instructions)
        self.assertIn("lw", self.instructions)
        self.assertIn("beq", self.instructions)
        self.assertIn("csrrw", self.instructions)

    def test_mathematical_coverage_various_batch_sizes(self):
        """Verifies 100% dealt coverage across batch sizes 1 to 128."""
        test_sizes = [1, 2, 4, 7, 8, 16, 32, 50, 64, 68, 100, 128]
        for b_size in test_sizes:
            with self.subTest(batch_size=b_size):
                res = verify_dealt_coverage(self.instructions, b_size)
                self.assertTrue(
                    res["is_complete"],
                    f"Incomplete coverage for batch_size={b_size}"
                )
                self.assertTrue(
                    res["is_disjoint"],
                    f"Non-disjoint partition for batch_size={b_size}"
                )
                self.assertEqual(res["missing_count"], 0)
                self.assertEqual(res["covered_count"], len(self.instructions))
                self.assertAlmostEqual(res["coverage_percentage"], 100.0)

    def test_balanced_partitioning(self):
        """Verifies that dealt partitions differ in size by at most 1."""
        for b_size in [16, 32, 50]:
            res = verify_dealt_coverage(self.instructions, b_size)
            self.assertLessEqual(
                res["max_partition_size"] - res["min_partition_size"],
                1,
                f"Unbalanced partitions for batch_size={b_size}",
            )

    def test_stream_batch_coverage_ci_50(self):
        """Verifies 100% realized coverage on a 50-program tranche with mixed shaping and traps."""
        report = verify_stream_batch_coverage(
            alphabet=self.instructions,
            batch_size=50,
            length=64,
            shaping="mixed",
            trap_rate=0.05,
            seed="test_ci_50",
        )
        self.assertTrue(report["is_complete"])
        self.assertEqual(len(report["missing_opcodes"]), 0)
        self.assertEqual(
            report["covered_alphabet_count"], len(self.instructions)
        )
        self.assertAlmostEqual(report["coverage_percentage"], 100.0)

    def test_shape_coverage_distributed(self):
        """Verifies 100% shape coverage closure across a 50-program distributed tranche."""
        report = verify_stream_batch_coverage(
            alphabet=self.instructions,
            batch_size=50,
            length=64,
            shaping="distributed",
            trap_rate=0.05,
            seed="test_dist_shapes",
        )
        self.assertTrue(
            report["is_complete"], "Opcode coverage should be complete"
        )
        self.assertTrue(
            report.get("is_shape_complete", False),
            f"Missing shapes: {report.get('missing_shaping_modes')}",
        )
        self.assertEqual(len(report.get("missing_shaping_modes", [])), 0)
        self.assertGreaterEqual(
            len(report.get("covered_shaping_modes", [])), 12
        )

    def test_stream_batch_coverage_various_shapings(self):
        """Verifies 100% realized coverage across all distinct shaping modes on batch size 32."""
        for shaping in SHAPING_MODES:
            with self.subTest(shaping=shaping):
                report = verify_stream_batch_coverage(
                    alphabet=self.instructions,
                    batch_size=32,
                    length=64,
                    shaping=shaping,
                    trap_rate=0.05,
                    seed=f"test_shaping_{shaping}",
                )
                self.assertTrue(
                    report["is_complete"],
                    f"Missing opcodes in {shaping}: {report['missing_opcodes']}"
                )
                self.assertEqual(report["missing_opcodes"], [])
                self.assertAlmostEqual(report["coverage_percentage"], 100.0)

    def test_categories_coverage(self):
        """Verifies every instruction in the alphabet is classified into a known functional category."""
        for op in self.instructions:
            cat = get_category_for_opcode(op)
            self.assertNotEqual(
                cat, "Other",
                f"Instruction {op} lacks functional category mapping"
            )

    def test_invalid_batch_size(self):
        """Verifies ValueError is raised for batch_size < 1 with exact message."""
        with self.assertRaisesRegex(ValueError, r"batch_size must be >= 1"):
            verify_dealt_coverage(self.instructions, 0)

    def test_analyze_assembly_files(self):
        """Verifies analyze_assembly_files parses assembly files and counts opcodes."""
        from tests.isg.gen.program import generate_isg_assembly

        with tempfile.TemporaryDirectory() as tmpdir:
            p0 = os.path.join(tmpdir, "test_0.S")
            p1 = os.path.join(tmpdir, "test_1.S")

            asm0 = generate_isg_assembly(
                alphabet_ops=self.instructions,
                alphabet_csrs=self.csrs,
                batch_index=0,
                batch_size=2,
                length=32,
                seed="cov_test",
                shaping="uniform",
                trap_rate=0.0,
                align_mode="natural",
            )
            asm1 = generate_isg_assembly(
                alphabet_ops=self.instructions,
                alphabet_csrs=self.csrs,
                batch_index=1,
                batch_size=2,
                length=32,
                seed="cov_test",
                shaping="uniform",
                trap_rate=0.0,
                align_mode="natural",
            )

            with open(p0, "w", encoding="utf-8") as f:
                for line in asm0:
                    f.write(f"{line}\n")
            with open(p1, "w", encoding="utf-8") as f:
                for line in asm1:
                    f.write(f"{line}\n")

            report = analyze_assembly_files([p0, p1], self.instructions)
            self.assertEqual(report["file_count"], 2)
            self.assertTrue(report["is_complete"])
            self.assertEqual(report["missing_opcodes"], [])
            self.assertAlmostEqual(report["coverage_percentage"], 100.0)

    def test_analyze_assembly_files_payload_boundaries_and_traps(self):
        """Verifies payload boundary filtering and undef opcode detection."""
        with tempfile.TemporaryDirectory() as tmpdir:
            test_asm = os.path.join(tmpdir, "boundary_test.S")
            with open(test_asm, "w", encoding="utf-8") as f:
                f.write("# Header comment\n")
                f.write("    addi x1, x0, 1 # Before payload\n")
                f.write(".globl isg_payload_start\n")
                f.write("isg_payload_start:\n")
                f.write("    # --- ISG RANDOMIZED PAYLOAD START ---\n")
                f.write("    add x2, x1, x1\n")
                f.write("    .insn 0x0000007b # Undef trap\n")
                f.write("    .word 0x0000002b # Undef word\n")
                f.write("    # --- ISG RANDOMIZED PAYLOAD END ---\n")
                f.write("isg_payload_end:\n")
                f.write("    addi x2, x0, 2 # After payload\n")

            non_existent = os.path.join(tmpdir, "missing.S")
            report = analyze_assembly_files([test_asm, non_existent],
                                            self.instructions)
            self.assertEqual(report["file_count"], 1)
            self.assertIn("add", report["opcode_counts"])
            self.assertIn("undef", report["opcode_counts"])
            self.assertEqual(report["opcode_counts"]["undef"], 2)
            # Instructions before or after payload must not be included
            self.assertNotIn("addi", report["opcode_counts"])

    def test_format_coverage_report_complete(self):
        """Verifies format_coverage_report output with complete coverage."""
        from tests.isg.validate.coverage import format_coverage_report

        mock_report = {
            "is_complete": True,
            "coverage_percentage": 100.0,
            "alphabet_size": 75,
            "covered_alphabet_count": 75,
            "batch_size": 50,
            "total_instructions": 3200,
            "missing_opcodes": [],
            "category_counts": {
                "ALU (Imm/Reg)": 1000,
                "Shift": 200,
            },
            "shape_counts": {
                "distributed": 50,
            },
        }
        text = format_coverage_report(mock_report)
        self.assertIn(
            " CoralNPU Instruction Stream Generation (ISG) - Coverage Report",
            text
        )
        self.assertIn("PASSED (100.0% COVERAGE)", text)
        self.assertIn(
            "  Category                     |    Count |   Share", text
        )
        self.assertIn(
            "  ALU (Imm/Reg)                |     1000 |   83.3%", text
        )
        self.assertIn("  Shaping Mode                 | Programs", text)
        self.assertIn("  distributed                  |       50", text)

    def test_format_coverage_report_incomplete_and_missing(self):
        """Verifies format_coverage_report output when coverage is incomplete."""
        from tests.isg.validate.coverage import format_coverage_report

        empty_report_text = format_coverage_report({})
        self.assertIn("FAILED (INCOMPLETE COVERAGE)", empty_report_text)

        incomplete_report = {
            "is_complete": False,
            "coverage_percentage": 90.0,
            "alphabet_size": 10,
            "covered_alphabet_count": 9,
            "missing_opcodes": ["mul", "div"],
            "category_counts": {},
            "shape_counts": {},
        }
        text = format_coverage_report(incomplete_report)
        self.assertIn("FAILED (INCOMPLETE COVERAGE)", text)
        self.assertIn("MISSING OPCODES (2):", text)
        self.assertIn("  - mul", text)
        self.assertIn("  - div", text)

    def test_stream_batch_coverage_zero_trap_rate(self):
        """Verifies target shapes and covered shapes exclude trap_storm when trap_rate is 0.0."""
        report = verify_stream_batch_coverage(
            alphabet=self.instructions,
            batch_size=20,
            length=16,
            shaping="distributed",
            trap_rate=0.0,
            seed="zero_trap",
        )
        self.assertNotIn("trap_storm", report["target_shaping_modes"])
        self.assertNotIn("trap_storm", report["covered_shaping_modes"])

    def test_stream_batch_coverage_small_batch_missing_shapes(self):
        """Verifies missing_shaping_modes when batch_size < number of target shapes."""
        report = verify_stream_batch_coverage(
            alphabet=self.instructions,
            batch_size=3,
            length=16,
            shaping="distributed",
            trap_rate=0.05,
            seed="small_batch",
        )
        self.assertFalse(report["is_shape_complete"])
        self.assertGreater(len(report["missing_shaping_modes"]), 0)

    def test_stream_batch_coverage_undersized_mixed_missing_shapes(self):
        """Verifies mixed mode flags incomplete shape coverage when filler budget is too small."""
        report = verify_stream_batch_coverage(
            alphabet=self.instructions,
            batch_size=1,
            length=16,
            shaping="mixed",
            trap_rate=0.05,
            seed="tiny_mixed",
        )
        self.assertFalse(report["is_shape_complete"])
        self.assertGreater(len(report["missing_shaping_modes"]), 0)

    def test_stream_batch_coverage_single_profile_shape_complete(self):
        """Verifies explicit single-profile runs target and satisfy their own profile."""
        report = verify_stream_batch_coverage(
            alphabet=self.instructions,
            batch_size=8,
            length=64,
            shaping="mlu_contention",
            trap_rate=0.0,
            seed="single_profile",
        )
        self.assertEqual(report["target_shaping_modes"], ["mlu_contention"])
        self.assertEqual(report["covered_shaping_modes"], ["mlu_contention"])
        self.assertEqual(report["missing_shaping_modes"], [])
        self.assertTrue(report["is_shape_complete"])

    def test_stream_batch_coverage_matches_program_generator_prng(self):
        """Verifies verify_stream_batch_coverage uses the exact same PRNG sequence as program.py."""
        import random
        from tests.isg.gen import constraints as c
        from tests.isg.gen.dealt import plan_instruction_stream
        from tests.isg.gen.program import derive_program_seed, generate_isg_assembly
        from tests.isg.validate.coverage import _extract_opcode_from_line, _extract_payload_lines

        seed = "prng_parity_seed"
        batch_size = 4
        length = 48
        report = verify_stream_batch_coverage(
            alphabet=self.instructions,
            batch_size=batch_size,
            length=length,
            shaping="distributed",
            trap_rate=0.05,
            seed=seed,
        )

        expected_counts = {}
        for idx in range(batch_size):
            rng = random.Random(derive_program_seed(seed, idx))
            expected_base_reg = rng.randint(1, c.DATA_BASE_REG)
            plan = [
                op for op, _ in plan_instruction_stream(
                    alphabet=self.instructions,
                    batch_index=idx,
                    batch_size=batch_size,
                    length=length,
                    trap_rate=0.05,
                    shaping="distributed",
                    rng=rng,
                )
            ]
            for op in plan:
                expected_counts[op] = expected_counts.get(op, 0) + 1

            asm_lines = generate_isg_assembly(
                alphabet_ops=self.instructions,
                alphabet_csrs=self.csrs,
                batch_index=idx,
                batch_size=batch_size,
                length=length,
                shaping="distributed",
                trap_rate=0.05,
                seed=seed,
            )
            self.assertIn(f"# Base register: x{expected_base_reg}", asm_lines)
            emitted_ops = {
                _extract_opcode_from_line(l)
                for l in _extract_payload_lines(asm_lines)
            }
            for op in set(plan):
                self.assertIn(op, emitted_ops)

        self.assertEqual(report["opcode_counts"], expected_counts)

    def test_find_alphabet_path_resolution(self):
        """Verifies find_alphabet_path resolves CLI, runfiles, and workspace paths."""
        from tests.isg.validate.coverage import find_alphabet_path

        resolved_cli = find_alphabet_path(self.alphabet_path)
        self.assertIsNotNone(resolved_cli)
        self.assertEqual(str(resolved_cli), self.alphabet_path)
        self.assertIsNone(find_alphabet_path("/nonexistent/alphabet.json"))

        resolved_default = find_alphabet_path()
        self.assertIsNotNone(resolved_default)
        self.assertTrue(resolved_default.is_file())

    def test_cli_main_execution(self):
        """Verifies CLI main function exit codes for complete and incomplete runs."""
        from tests.isg.validate import coverage

        with mock.patch("sys.argv",
                        ["coverage.py", "--alphabet", self.alphabet_path,
                         "--batch-size", "50", "--length", "64"]):
            with mock.patch("sys.exit") as mock_exit:
                coverage.main()
                mock_exit.assert_called_with(0)

        with tempfile.TemporaryDirectory() as tmpdir:
            partial_asm = os.path.join(tmpdir, "partial.S")
            with open(partial_asm, "w", encoding="utf-8") as f:
                f.write(
                    ".globl isg_payload_start\nisg_payload_start:\nadd x1, x1, x1\nisg_payload_end:\n"
                )

            with mock.patch(
                    "sys.argv",
                [
                    "coverage.py",
                    "--alphabet",
                    self.alphabet_path,
                    "--assembly-files",
                    partial_asm,
                ],
            ):
                with mock.patch("sys.exit") as mock_exit:
                    coverage.main()
                    mock_exit.assert_called_with(1)

        # Test report without is_complete fallback
        with mock.patch(
                "tests.isg.validate.coverage.verify_stream_batch_coverage",
                return_value={},
        ):
            with mock.patch(
                    "sys.argv",
                [
                    "coverage.py",
                    "--alphabet",
                    self.alphabet_path,
                ],
            ):
                with mock.patch("sys.exit") as mock_exit:
                    coverage.main()
                    mock_exit.assert_called_with(1)

        # Test script direct execution to exercise __main__ guard
        with mock.patch(
                "sys.argv",
            ["coverage.py", "--invalid-unrecognized-arg"],
        ):
            with self.assertRaises(SystemExit) as cm:
                runpy.run_path(coverage.__file__, run_name="__main__")
            self.assertEqual(cm.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
