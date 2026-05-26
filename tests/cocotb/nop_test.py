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

# This test is used for baseline vector power analysis.
# It loads the NOP stress test binary and runs it to provide a baseline
# power measurement.

import cocotb
from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles

@cocotb.test()
async def nop_stress_test(dut):
    """Test that runs a loop with 512 NOPs unrolled.

    Used for baseline vector power analysis.
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'nop_test.elf'

    # Load the ELF. We pass an empty list for symbols since we don't need to read/write data.
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/' + elf_file),
        [])

    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")
