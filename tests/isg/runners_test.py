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
"""Unit tests for ISG CoralFlow triage helpers, CI runner, and hammer runner."""

import asyncio
import io
import json
import logging
import os
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tests.isg import isg_coralflow_test
from tests.isg import run_ci_tranche
from tests.isg import run_hammer
from tests.isg.validate import triage


class TriageHelpersTest(unittest.TestCase):
    """Tests CoralFlow target parsing, batch ELF discovery, and log extraction."""

    def test_parse_coralflow_target_variants(self):
        self.assertEqual(
            triage.parse_coralflow_target("//tests/isg:isg_ci_50_uvm"),
            ("//tests/isg", "isg_ci_50", "_uvm"),
        )
        self.assertEqual(
            triage.parse_coralflow_target("//tests/isg:isg_regression_vcs"),
            ("//tests/isg", "isg_regression", "_vcs"),
        )
        self.assertEqual(
            triage.parse_coralflow_target(":isg_ci_50_verilator"),
            ("//tests/isg", "isg_ci_50", "_verilator"),
        )
        self.assertEqual(
            triage.parse_coralflow_target(
                "//tests/isg:verilator_uvm_regression_isg_ci_50"
            ),
            ("//tests/isg", "isg_ci_50", "_uvm"),
        )

    def test_format_single_and_filtered_repro_commands(self):
        self.assertEqual(
            triage.format_single_program_target(
                "//tests/isg:isg_ci_50_uvm", "isg_ci_50_017.elf"
            ),
            "//tests/isg:isg_ci_50_017_uvm",
        )
        self.assertEqual(
            triage.format_single_program_target(
                "//tests/isg:isg_regression_vcs", "isg_regression_004"
            ),
            "//tests/isg:isg_regression_004_vcs",
        )
        self.assertEqual(
            triage.format_filtered_batch_command(
                "//tests/isg:isg_ci_50_uvm",
                ["isg_ci_50_017.elf", "isg_ci_50_042"],
                "seed_123",
            ),
            "bazel test //tests/isg:isg_ci_50_uvm "
            "--test_filter=isg_ci_50_017,isg_ci_50_042 "
            "--//tests/isg:isg_seed=seed_123",
        )
        self.assertEqual(
            triage.format_filtered_batch_command(
                "//tests/isg:isg_ci_50_vcs",
                ["isg_ci_50_017"],
                "seed_123",
            ),
            "bazel test //tests/isg:isg_ci_50_vcs "
            "--test_env=ISG_ELF_FILTER=isg_ci_50_017 "
            "--//tests/isg:isg_seed=seed_123",
        )

    def test_extract_failed_binaries_uvm_regression_blocks(self):
        """Ensures only failing UVM test blocks are extracted, ignoring trailing report summary."""
        uvm_log = "\n".join([
            "UVM_INFO @ 0: [coralnpu_regression_test] --- STARTING TEST: isg_ci_50_000.elf ---",
            "UVM_INFO @ 1200: [coralnpu_regression_test] tohost write detected with PASS status (0).",
            "UVM_INFO @ 1200: [coralnpu_regression_test] ** UVM TEST PASSED **",
            "UVM_INFO @ 1200: [coralnpu_regression_test] --- FINISHED TEST: isg_ci_50_000.elf ---",
            "UVM_INFO @ 1210: [coralnpu_regression_test] --- STARTING TEST: isg_ci_50_017.elf ---",
            "UVM_ERROR @ 2400: [COSIM_MISMATCH] GPR x5 mismatch: RTL=0x1, Spike=0x2",
            "UVM_ERROR @ 2405: [coralnpu_regression_test] ** UVM TEST FAILED **",
            "UVM_INFO @ 2405: [coralnpu_regression_test] --- FINISHED TEST: isg_ci_50_017.elf ---",
            "UVM_INFO @ 2415: [coralnpu_regression_test] --- STARTING TEST: isg_ci_50_049.elf ---",
            "UVM_INFO @ 3500: [coralnpu_regression_test] ** UVM TEST PASSED **",
            "UVM_INFO @ 3500: [coralnpu_regression_test] --- FINISHED TEST: isg_ci_50_049.elf ---",
            "--- UVM Report Summary ---",
            "UVM_ERROR :    2",
        ])
        self.assertEqual(
            triage.extract_failed_binaries(uvm_log), ["isg_ci_50_017"]
        )

    def test_extract_failed_binaries_unfinished_timeout_and_cocotb_tohost(
        self
    ):
        partial_uvm_log = "\n".join([
            "UVM_INFO @ 0: [coralnpu_regression_test] --- STARTING TEST: isg_ci_50_000.elf ---",
            "UVM_INFO @ 900: [coralnpu_regression_test] ** UVM TEST PASSED **",
            "UVM_INFO @ 900: [coralnpu_regression_test] --- FINISHED TEST: isg_ci_50_000.elf ---",
            "UVM_INFO @ 910: [coralnpu_regression_test] --- STARTING TEST: isg_ci_50_022.elf ---",
        ])
        self.assertEqual(
            triage.extract_failed_binaries(partial_uvm_log), ["isg_ci_50_022"]
        )

        cocotb_log = "AssertionError: isg_ci_50_005.elf: expected tohost == 1, got 0x00000003"
        self.assertEqual(
            triage.extract_failed_binaries(cocotb_log), ["isg_ci_50_005"]
        )

        uvm_batch_log = (
            "AssertionError: Batch simulation had 1 failure(s):\n"
            "  isg_ci_50_044: did not write tohost and did not report UVM TEST PASSED"
        )
        self.assertEqual(
            triage.extract_failed_binaries(uvm_batch_log), ["isg_ci_50_044"]
        )

    def test_collect_target_failure_logs_reads_outputs_zip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_dir = (
                Path(tmpdir) / "bazel-testlogs" / "tests" / "isg" /
                "isg_ci_50_uvm" / "test.outputs"
            )
            outputs_dir.mkdir(parents=True)
            zip_path = outputs_dir / "outputs.zip"
            sim_log = "\n".join([
                "--- STARTING TEST: isg_ci_50_031.elf ---",
                "UVM_ERROR @ 500: [coralnpu_regression_test] ** UVM TEST FAILED **",
                "--- FINISHED TEST: isg_ci_50_031.elf ---",
            ])
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.writestr("uvm_sim_error_abcd.log", sim_log)
            (outputs_dir / "uvm_sim_error_batch.log").write_text(
                "--- STARTING TEST: tests/isg/isg_ci_50_044.bin ---\n"
                "UVM_ERROR @ 600: [COSIM_MISMATCH] GPR x1 mismatch\n"
                "--- FINISHED TEST: tests/isg/isg_ci_50_044.bin ---\n",
                encoding="utf-8",
            )

            collected = triage.collect_target_failure_logs(
                tmpdir, "//tests/isg:isg_ci_50_uvm", stdout="RuntimeError"
            )
            self.assertEqual(
                triage.extract_failed_binaries(collected),
                ["isg_ci_50_031", "isg_ci_50_044"],
            )

    def test_discover_batch_elfs_exact_stem_and_filter(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            for name in (
                    "isg_rvv_000.elf",
                    "isg_rvv_001.elf",
                    "isg_rvv_fresh_000.elf",
            ):
                (Path(tmpdir) / name).write_bytes(b"\x7fELF")

            fake_script = os.path.join(tmpdir, "isg_coralflow_test.py")
            Path(fake_script).write_text("", encoding="utf-8")

            fake_runfiles = mock.Mock()
            fake_runfiles.Rlocation.return_value = fake_script

            with mock.patch.object(
                    isg_coralflow_test.runfiles,
                    "Create",
                    return_value=fake_runfiles,
            ):
                with mock.patch.dict(
                        os.environ,
                    {
                        "TEST_TARGET": "//tests/isg:isg_rvv_verilator",
                        "ISG_ELF_FILTER": "",
                    },
                        clear=False,
                ):
                    discovered = [
                        os.path.basename(p)
                        for p in isg_coralflow_test._discover_batch_elfs()
                    ]
                    self.assertEqual(
                        discovered, ["isg_rvv_000.elf", "isg_rvv_001.elf"]
                    )

                with mock.patch.dict(
                        os.environ,
                    {
                        "TEST_TARGET": "//tests/isg:isg_rvv_001_uvm",
                        "ISG_ELF_FILTER": "",
                    },
                        clear=False,
                ):
                    discovered_single = [
                        os.path.basename(p)
                        for p in isg_coralflow_test._discover_batch_elfs()
                    ]
                    self.assertEqual(discovered_single, ["isg_rvv_001.elf"])

                with mock.patch.dict(
                        os.environ,
                    {
                        "TEST_TARGET": "//tests/isg:isg_rvv_vcs",
                        "ISG_ELF_FILTER": "isg_rvv_001",
                    },
                        clear=False,
                ):
                    filtered = [
                        os.path.basename(p)
                        for p in isg_coralflow_test._discover_batch_elfs()
                    ]
                    self.assertEqual(filtered, ["isg_rvv_001.elf"])


class RunnersMainTest(unittest.TestCase):
    """Tests run_ci_tranche.py and run_hammer.py workflows with mocked Bazel runs."""

    def test_ci_tranche_dry_run_and_failure_repro(self):
        ctx = run_ci_tranche.ExecutionContext(
            monotonic_clock=lambda: 10.0,
            epoch_clock=lambda: 1700000000,
            rand_range=lambda lo, hi: 4321,
            utc_timestamp=lambda: "2026-11-03 00:00:00 UTC",
        )
        buf = io.StringIO()
        with mock.patch(
                "sys.argv",
            ["run_ci_tranche.py", "--dry-run"]), redirect_stdout(buf):
            rc = run_ci_tranche.main(ctx)
        self.assertEqual(rc, 0)
        self.assertIn("ci_1700000000_4321", buf.getvalue())
        self.assertIn("Opcode coverage verified: 100.0%", buf.getvalue())

        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_dir = (
                Path(tmpdir) / "bazel-testlogs" / "tests" / "isg" /
                "isg_ci_50_uvm" / "test.outputs"
            )
            outputs_dir.mkdir(parents=True)
            with zipfile.ZipFile(outputs_dir / "outputs.zip", "w") as zf:
                zf.writestr(
                    "uvm_sim_error_1.log",
                    "--- STARTING TEST: isg_ci_50_017.elf ---\n"
                    "UVM_ERROR @ 100: ** UVM TEST FAILED **\n"
                    "--- FINISHED TEST: isg_ci_50_017.elf ---\n",
                )

            fail_buf = io.StringIO()
            with mock.patch.object(run_ci_tranche, "_REPO_ROOT", tmpdir), \
                 mock.patch.object(run_ci_tranche, "run_command", return_value=3), \
                 mock.patch("sys.argv", ["run_ci_tranche.py", "--seed", "pin_seed"]), \
                 redirect_stdout(fail_buf):
                rc = run_ci_tranche.main(ctx)
            self.assertEqual(rc, 3)
            out = fail_buf.getvalue()
            self.assertIn(
                "bazel test //tests/isg:isg_ci_50_017_uvm --//tests/isg:isg_seed=pin_seed",
                out,
            )

    def test_hammer_runner_stop_on_fail_and_json_report(self):
        ticks = iter([0.0, 0.0, 1.0, 2.5, 2.5, 2.5])
        ctx = run_hammer.ExecutionContext(
            monotonic_clock=lambda: next(ticks, 3.0),
            epoch_clock=lambda: 1700000000,
            rand_range=lambda lo, hi: 5555,
            utc_timestamp=lambda: "2026-11-03 00:00:00 UTC",
        )
        fake_proc = subprocess.CompletedProcess(
            args=["bazel"],
            returncode=1,
            stdout=(
                "--- STARTING TEST: isg_ci_50_008.elf ---\n"
                "UVM_ERROR @ 400: COSIM_MISMATCH\n"
                "--- FINISHED TEST: isg_ci_50_008.elf ---\n"
                "--- STARTING TEST: isg_ci_50_019.elf ---\n"
                "UVM_ERROR @ 900: COSIM_MISMATCH\n"
                "--- FINISHED TEST: isg_ci_50_019.elf ---\n"
            ),
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            json_path = os.path.join(tmpdir, "summary.json")
            buf = io.StringIO()
            with mock.patch.object(run_hammer, "_REPO_ROOT", tmpdir), \
                 mock.patch.object(subprocess, "run", return_value=fake_proc), \
                 mock.patch(
                     "sys.argv",
                     [
                         "run_hammer.py",
                         "--max-tranches",
                         "3",
                         "--stop-on-fail",
                         "--output-json",
                         json_path,
                     ],
                 ), redirect_stdout(buf):
                rc = run_hammer.main(ctx)

            self.assertEqual(rc, run_hammer.EXIT_FAILURE)
            out = buf.getvalue()
            self.assertIn("//tests/isg:isg_ci_50_008_uvm", out)
            self.assertIn("//tests/isg:isg_ci_50_019_uvm", out)
            self.assertIn(
                "--test_filter=isg_ci_50_008,isg_ci_50_019",
                out,
            )

            summary = json.loads(Path(json_path).read_text(encoding="utf-8"))
            self.assertEqual(summary["total_tranches"], 1)
            self.assertEqual(summary["failed_tranches"], 1)
            self.assertEqual(
                summary["results"][0]["failed_binaries"],
                ["isg_ci_50_008", "isg_ci_50_019"],
            )

    def test_coralflow_batch_quiet_by_default_and_verbose_flag(self):

        class FakeDutLog:

            def __init__(self):
                self.level = logging.INFO
                self.messages = []
                self.observed_levels = []

            def setLevel(self, lvl):
                self.level = lvl

            def info(self, msg):
                self.messages.append(msg)

        class FakeFixture:

            def __init__(self, dut_log):
                self.core_mini_axi = mock.Mock(dut=mock.Mock(_log=dut_log))
                self.calls = []

            async def run_batch(self, elfs, timeout_cycles=100000):
                del timeout_cycles
                self.calls.append(
                    (list(elfs), self.core_mini_axi.dut._log.level)
                )

        dut_log = FakeDutLog()
        fixture = FakeFixture(dut_log)
        with mock.patch.object(
                isg_coralflow_test,
                "_discover_batch_elfs",
                return_value=["/tmp/prog_000.elf", "/tmp/prog_001.elf"],
        ), mock.patch.dict(
                os.environ,
            {"ISG_VERBOSE": "", "CORALFLOW_VERBOSE": ""},
                clear=False,
        ), mock.patch("sys.argv", ["isg_coralflow_test.py"]):
            asyncio.run(isg_coralflow_test.isg_batch_test.__wrapped__(fixture))

        self.assertEqual(
            fixture.calls,
            [(["/tmp/prog_000.elf", "/tmp/prog_001.elf"], logging.WARNING)],
        )
        self.assertEqual(dut_log.level, logging.INFO)
        self.assertEqual(dut_log.messages, [])

        verbose_log = FakeDutLog()
        verbose_fixture = FakeFixture(verbose_log)
        with mock.patch.object(
                isg_coralflow_test,
                "_discover_batch_elfs",
                return_value=["/tmp/prog_000.elf", "/tmp/prog_001.elf"],
        ), mock.patch.dict(
                os.environ,
            {"ISG_VERBOSE": "1", "CORALFLOW_VERBOSE": ""},
                clear=False,
        ), mock.patch("sys.argv", ["isg_coralflow_test.py"]):
            asyncio.run(
                isg_coralflow_test.isg_batch_test.__wrapped__(verbose_fixture)
            )

        self.assertEqual(len(verbose_fixture.calls), 2)
        self.assertEqual(len(verbose_log.messages), 2)
        self.assertIn("Executing (1/2): prog_000.elf", verbose_log.messages[0])

        # Verify build-level isg_verbose_config default and UVM single-batch execution
        class FakeUvmFixture:

            def __init__(self):
                self.calls = []

            async def run_batch(self, elfs, timeout_cycles=100000):
                del timeout_cycles
                self.calls.append(list(elfs))

        uvm_fixture = FakeUvmFixture()
        fake_cfg = mock.Mock(ISG_VERBOSE_DEFAULT=True)
        with mock.patch.object(
                isg_coralflow_test,
                "_discover_batch_elfs",
                return_value=["/tmp/prog_000.elf", "/tmp/prog_001.elf"],
        ), mock.patch.object(
                isg_coralflow_test,
                "isg_verbose_config",
                fake_cfg,
        ), mock.patch.dict(
                os.environ,
            {"ISG_VERBOSE": "", "CORALFLOW_VERBOSE": ""},
                clear=False,
        ), mock.patch("sys.argv", ["isg_coralflow_test.py"]):
            self.assertTrue(isg_coralflow_test._is_verbose())
            asyncio.run(
                isg_coralflow_test.isg_batch_test.__wrapped__(uvm_fixture)
            )
        self.assertEqual(
            uvm_fixture.calls,
            [["/tmp/prog_000.elf", "/tmp/prog_001.elf"]],
        )

    def test_runners_verbose_flag_forwards_bazel_options(self):
        ctx = run_ci_tranche.ExecutionContext(
            monotonic_clock=lambda: 1.0,
            epoch_clock=lambda: 1700000000,
            rand_range=lambda lo, hi: 1111,
            utc_timestamp=lambda: "2026-11-03 00:00:00 UTC",
        )
        recorded_cmds = []

        def fake_run(cmd, cwd=None):
            del cwd
            recorded_cmds.append(list(cmd))
            return 0

        buf = io.StringIO()
        with mock.patch.object(run_ci_tranche, "run_command", side_effect=fake_run), \
             mock.patch(
                 "sys.argv",
                 ["run_ci_tranche.py", "--no-coverage-check", "--verbose"],
             ), redirect_stdout(buf):
            rc = run_ci_tranche.main(ctx)
        self.assertEqual(rc, 0)
        self.assertEqual(len(recorded_cmds), 1)
        self.assertIn("--test_output=all", recorded_cmds[0])
        self.assertIn("--//tests/isg:isg_verbose=true", recorded_cmds[0])
        self.assertIn("--test_env=ISG_VERBOSE=1", recorded_cmds[0])


if __name__ == "__main__":
    unittest.main()
