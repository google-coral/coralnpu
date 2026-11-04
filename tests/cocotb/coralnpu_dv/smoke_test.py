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
"""Smoke test: the verification-core model boots and runs a program."""

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture

VWMUL_ELF = "coralnpu_hw/tests/cocotb/coralnpu_dv/vwmul.elf"
ELEMENT_COUNT = 32


@cocotb.test()
async def smoke_vwmul(dut):
    """Loads vwmul.elf, runs it to halt and checks the products."""
    fixture = await VerilatorTestFixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        runfiles.Create().Rlocation(VWMUL_ELF),
        ["input_a", "input_b", "output_products"],
    )
    rng = np.random.default_rng(8)
    a = rng.integers(-128, 128, ELEMENT_COUNT, dtype=np.int8)
    b = rng.integers(-128, 128, ELEMENT_COUNT, dtype=np.int8)
    await fixture.write("input_a", a)
    await fixture.write("input_b", b)
    await fixture.run_to_halt(timeout_cycles=10000)
    actual = await fixture.read(
        "output_products", dtype=np.int16, shape=(ELEMENT_COUNT, )
    )
    expected = a.astype(np.int16) * b.astype(np.int16)
    assert np.array_equal(actual, expected), \
        f"mismatch at {np.flatnonzero(actual != expected)}"
    dut._log.info(f"PASS: {actual[:4]} ...")