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
                fnmatch.fnmatch(
                    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul", pattern
                )
                for pattern in denylist
            )
        )


if __name__ == "__main__":
    unittest.main()
