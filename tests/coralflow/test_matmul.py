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
"""Reference single-source matrix multiplication test running interchangeably via CoralFlow."""

import numpy as np

from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.coralflow.runner import coralflow_test


@coralflow_test
async def test_matmul_kernel(fixture: BaseCoralNPUFixture):
    await fixture.load_elf_and_lookup_symbols(
        "tests/cocotb/rvv/ml_ops/rvv_matmul.elf",
        [
            "lhs_input",
            "rhs_input",
            "result_output",
            "lhs_rows",
            "rhs_cols",
            "inner",
        ],
    )

    # Test matrix dimensions: M=16, K=48, N=16 (within runner capacity 32x128x32)
    # Reference Core Cycles: 11,076 cycles
    lhs_rows = 16
    inner = 48
    rhs_cols = 16

    rng = np.random.default_rng(seed=42)
    lhs_input = rng.integers(-128, 128, size=(lhs_rows, inner), dtype=np.int8)
    rhs_input = rng.integers(-128, 128, size=(inner, rhs_cols), dtype=np.int8)
    golden_output = np.matmul(
        lhs_input.astype(np.int32), rhs_input.astype(np.int32)
    )

    await fixture.write_word("lhs_rows", lhs_rows)
    await fixture.write_word("rhs_cols", rhs_cols)
    await fixture.write_word("inner", inner)
    await fixture.write("lhs_input", lhs_input)
    # rvv_matmul kernel assumes rhs is stored column-major (order='F')
    await fixture.write("rhs_input", rhs_input.flatten(order="F"))
    await fixture.write(
        "result_output",
        np.zeros_like(golden_output).flatten()
    )

    halted = await fixture.run_to_halt(timeout_cycles=200000)
    assert halted

    out = await fixture.read(
        "result_output",
        dtype=np.int32,
        shape=(lhs_rows, rhs_cols),
    )
    np.testing.assert_array_equal(out, golden_output)


if __name__ == "__main__":
    test_matmul_kernel()
