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

import fnmatch
import subprocess
import unittest
from unittest import mock

from utils import run_uvm_regression


class RunUvmRegressionTest(unittest.TestCase):

    def test_zvfbf_and_first_ml_ops_targets_are_denylisted(self):
        denylist = run_uvm_regression.DENYLIST

        self.assertIn("//tests/cocotb:zvfbf_test", denylist)
        self.assertIn("//tests/cocotb/rvv/ml_ops:rvv_float_matmul", denylist)
        self.assertTrue(
            any(
                fnmatch.fnmatch("//tests/cocotb:zvfbf_test", pattern)
                for pattern in denylist
            )
        )
        self.assertIn("//tests/cocotb/vme_test:vme_test_program", denylist)
        self.assertIn(
            "//tests/cocotb/vme_test:vme_matmul_test_program", denylist
        )
        self.assertTrue(
            any(
                fnmatch.
                fnmatch("//tests/cocotb/rvv/ml_ops:rvv_float_matmul", pattern)
                for pattern in denylist
            )
        )
        self.assertTrue(
            any(
                fnmatch.
                fnmatch("//tests/cocotb/vme_test:vme_test_program", pattern)
                for pattern in denylist
            )
        )
        self.assertTrue(
            any(
                fnmatch.fnmatch(
                    "//tests/cocotb/vme_test:vme_matmul_test_program", pattern
                ) for pattern in denylist
            )
        )

    def test_all_bf16_targets_are_denylisted(self):
        denylist = run_uvm_regression.DENYLIST
        sample_bf16_targets = [
            "//tests/cocotb/rvv/ml_ops:rvv_bf16_matmul",
            "@coralnpu_hw//tests/cocotb/rvv/ml_ops:rvv_bf16_matmul",
            "//tests/cocotb/rvv/arithmetics:rvv_bf16_mac_vv_m1",
            "@coralnpu_hw//tests/cocotb/rvv/arithmetics:rvv_bf16_pipeline_mf2",
            "//tests/cocotb:rvv_bf16_ops_cocotb_test",
        ]
        for t in sample_bf16_targets:
            self.assertTrue(
                any(fnmatch.fnmatch(t, pattern) for pattern in denylist),
                f"Expected target '{t}' to be excluded by DENYLIST"
            )

    def test_spike_isa_uses_xdummy_not_xcoralnpu(self):
        spike_isa = run_uvm_regression.SPIKE_ISA
        self.assertIn(
            "xdummy",
            spike_isa,
            "SPIKE_ISA must specify 'xdummy' to set MISA.X without loading external dynamic libraries",
        )
        self.assertNotIn(
            "xcoralnpu",
            spike_isa,
            "SPIKE_ISA must not specify 'xcoralnpu' which triggers missing dynamic library errors (code 255)",
        )

    @mock.patch("subprocess.run")
    def test_check_spike_sanity_success(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["spike"], returncode=0, stdout="", stderr=""
        )
        result = run_uvm_regression.check_spike_sanity(
            "/fake/spike", "/fake/elf", 0
        )
        self.assertTrue(result)
        mock_run.assert_called_once()
        self.assertIn("--instructions=1", mock_run.call_args[0][0])
        self.assertIn(
            f"--isa={run_uvm_regression.SPIKE_ISA}", mock_run.call_args[0][0]
        )
        self.assertIn("--priv=m", mock_run.call_args[0][0])

    @mock.patch("subprocess.run")
    def test_check_spike_sanity_failure(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["spike"],
            returncode=255,
            stdout="",
            stderr="couldn't find shared library",
        )
        result = run_uvm_regression.check_spike_sanity(
            "/fake/spike", "/fake/elf", 0
        )
        self.assertFalse(result)

    @mock.patch(
        "utils.run_uvm_regression.check_spike_sanity", return_value=False
    )
    @mock.patch("os.path.exists", return_value=True)
    @mock.patch("utils.run_uvm_regression.get_entry_point", return_value=0)
    def test_run_full_regression_aborts_on_preflight_failure(
        self, mock_entry, mock_exists, mock_sanity
    ):
        tests_to_run = [("//examples:hello_world", "/path/to/hello_world.elf")]
        with self.assertRaises(SystemExit) as cm:
            run_uvm_regression.run_full_regression(
                tests_to_run=tests_to_run,
                spike_bin="/fake/spike",
                mpact_root="/fake/mpact",
                mpact_riscv_root=None,
                temp_elf_dir="/tmp",
                simulator="vcs",
            )
        self.assertEqual(cm.exception.code, 1)

    @mock.patch(
        "utils.run_uvm_regression.check_spike_sanity", return_value=True
    )
    @mock.patch(
        "utils.run_uvm_regression.generate_spike_log", return_value=False
    )
    @mock.patch("os.path.exists", return_value=True)
    @mock.patch("utils.run_uvm_regression.get_entry_point", return_value=0)
    @mock.patch("utils.run_uvm_regression.get_tohost_addr", return_value=0)
    @mock.patch("shutil.copy2")
    def test_run_full_regression_aborts_on_non_denylisted_spike_failure(
        self, mock_copy, mock_tohost, mock_entry, mock_exists, mock_gen,
        mock_sanity
    ):
        tests_to_run = [("//examples:hello_world", "/path/to/hello_world.elf")]
        with self.assertRaises(SystemExit) as cm:
            run_uvm_regression.run_full_regression(
                tests_to_run=tests_to_run,
                spike_bin="/fake/spike",
                mpact_root="/fake/mpact",
                mpact_riscv_root=None,
                temp_elf_dir="/tmp",
                simulator="vcs",
            )
        self.assertEqual(cm.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
