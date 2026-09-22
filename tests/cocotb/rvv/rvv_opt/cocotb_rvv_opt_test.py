# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import cocotb
import numpy as np

from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture
from bazel_tools.tools.python.runfiles import runfiles


@cocotb.test()
async def core_mini_rvv_memcpy_test(dut):

    fixture = await VerilatorTestFixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.
        Rlocation('coralnpu_hw/tests/cocotb/rvv/rvv_opt/rvv_memcpy_test.elf'),
        ['in_buf', 'out_buf', 'size_n']
    )
    min_value = np.iinfo(np.uint8).min
    max_value = np.iinfo(np.uint8).max + 1
    for size_n in [1, 8, 24, 33, 48, 61, 127, 128, 231, 256, 501, 512, 0]:
        # adding 25 extra elements to input_data to test for over copying
        input_data = np.random.randint(
            min_value, max_value, size_n + 25, dtype=np.uint8
        )
        expected_output_buffer = np.zeros(512, dtype=np.uint8)
        await fixture.write('in_buf', input_data)
        await fixture.write('out_buf', np.zeros(512, dtype=np.uint8))
        await fixture.write('size_n', np.asarray([size_n]))
        cycle_count = await fixture.run_to_halt(timeout_cycles=10000)
        result = await fixture.read('out_buf', 512)
        expected_output_buffer[:size_n] = input_data[:size_n]
        assert (expected_output_buffer == result).all()


@cocotb.test()
async def core_mini_rvv_memset_test(dut):

    fixture = await VerilatorTestFixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.
        Rlocation('coralnpu_hw/tests/cocotb/rvv/rvv_opt/rvv_memset_test.elf'),
        ['val_in', 'out_buf', 'size_n']
    )
    min_value = np.iinfo(np.uint8).min
    max_value = np.iinfo(np.uint8).max + 1
    for size_n in [1, 8, 24, 33, 48, 61, 127, 128, 231, 256, 501, 512, 0]:
        for val in [0, 1, 42, 127, 128, 255]:
            val_u8 = np.uint8(val & 0xFF)
            expected_output_buffer = np.zeros(512, dtype=np.uint8)
            await fixture.write('val_in', np.asarray([val], dtype=np.uint32))
            await fixture.write('out_buf', np.zeros(512, dtype=np.uint8))
            await fixture.write(
                'size_n', np.asarray([size_n], dtype=np.uint32)
            )
            cycle_count = await fixture.run_to_halt(timeout_cycles=10000)
            result = await fixture.read('out_buf', 512)
            expected_output_buffer[:size_n] = val_u8
            assert (expected_output_buffer == result).all()
