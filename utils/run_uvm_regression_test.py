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
        self.assertIn(
            "//tests/cocotb/rvv/ml_ops:rvv_float_matmul_assembly", denylist
        )
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
                fnmatch.fnmatch(
                    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul_assembly",
                    pattern,
                ) for pattern in denylist
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

    def test_format_batch_entry(self):
        entry = run_uvm_regression.format_batch_entry(
            elf="/path/to/test.elf",
            tohost=0x80001000,
            entry=0x00000000,
            timeout=100000,
            spike_log="SPIKE",
            target="//examples:hello_world",
        )
        self.assertEqual(
            entry,
            "/path/to/test.elf 80001000 00000000 100000 SPIKE //examples:hello_world\n",
        )

    @mock.patch("subprocess.run")
    def test_build_spike_success(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["bazel"], returncode=0
        )
        self.assertTrue(run_uvm_regression.build_spike())
        mock_run.assert_called_once_with([
            "bazel", "build", "//sw/coralnpu_sim:spike_cosim_dpi"
        ],
                                         check=True)

    @mock.patch(
        "subprocess.run",
        side_effect=subprocess.CalledProcessError(1, ["bazel"])
    )
    def test_build_spike_failure(self, mock_run):
        self.assertFalse(run_uvm_regression.build_spike())

    @mock.patch("utils.run_uvm_regression.build_simulator", return_value=True)
    @mock.patch("utils.run_uvm_regression.run_uvm_batch")
    @mock.patch("os.makedirs")
    @mock.patch("os.chmod")
    @mock.patch("os.path.exists", return_value=True)
    @mock.patch("utils.run_uvm_regression.get_entry_point", return_value=0)
    @mock.patch(
        "utils.run_uvm_regression.get_tohost_addr", return_value=0x80001000
    )
    @mock.patch("shutil.copy2")
    @mock.patch("shutil.make_archive")
    def test_run_full_regression_sets_spike_option(
        self, mock_archive, mock_copy, mock_tohost, mock_entry, mock_exists,
        mock_chmod, mock_makedirs, mock_batch, mock_build
    ):
        mock_batch.return_value = (
            [{
                "Target": "//examples:hello_world",
                "Status": "PASS",
                "Reason": "None",
                "Log Path": "logs/hello_world.log",
            }],
            {"//examples:hello_world"},
        )
        with mock.patch("builtins.open", mock.mock_open()) as mock_file:
            run_uvm_regression.run_full_regression(
                tests_to_run=[
                    ("//examples:hello_world", "/path/to/hello_world.elf")
                ],
                spike_enabled=True,
                mpact_root="/fake/mpact",
                mpact_riscv_root=None,
                temp_elf_dir="/tmp",
                simulator="vcs",
            )
            # Find the write calls to verify the batch list entry wrote SPIKE
            written = "".join(
                call.args[0]
                for call in mock_file().write.call_args_list
                if call.args
            )
            self.assertIn("SPIKE", written)


if __name__ == "__main__":
    unittest.main()
