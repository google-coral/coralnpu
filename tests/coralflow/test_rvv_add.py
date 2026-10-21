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
"""Reference single-source test running interchangeably via CoralFlow."""

import numpy as np

from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.coralflow.runner import coralflow_test


@coralflow_test
async def test_rvv_add_kernel(fixture: BaseCoralNPUFixture):
    await fixture.load_elf_and_lookup_symbols(
        "tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf",
        ["in_buf_1", "in_buf_2", "out_buf"],
    )

    input_size = 16
    in1 = np.arange(input_size, dtype=np.uint8)
    in2 = np.arange(input_size, dtype=np.uint8) * 2

    await fixture.write("in_buf_1", in1)
    await fixture.write("in_buf_2", in2)

    halted = await fixture.run_to_halt()
    assert halted

    out = await fixture.read("out_buf", dtype=np.uint8, shape=(input_size, ))
    expected = in1 + in2
    np.testing.assert_array_equal(out, expected)


if __name__ == "__main__":
    test_rvv_add_kernel()
