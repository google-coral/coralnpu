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
import unittest

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
        self.assertTrue(
            any(
                fnmatch.
                fnmatch("//tests/cocotb/rvv/ml_ops:rvv_float_matmul", pattern)
                for pattern in denylist
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


if __name__ == "__main__":
    unittest.main()
