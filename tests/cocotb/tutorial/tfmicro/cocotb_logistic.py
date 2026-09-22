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

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture


class LogisticTester:

    def __init__(self, input_size):
        self.input_size = input_size
        r = runfiles.Create()
        self.elf_file = r.Rlocation(
            "coralnpu_hw/tests/cocotb/tutorial/tfmicro/logistic_test.elf"
        )
        self.fixture = None

    async def setup(self, dut):
        self.fixture = await VerilatorTestFixture.Create(dut, highmem=True)
        await self.fixture.load_elf_and_lookup_symbols(
            self.elf_file,
            [
                "impl",
                "run_ref",
                "run_optimized",
                "run_init",
                "input_zero_point",
                "input_range_radius",
                "input_multiplier",
                "input_left_shift",
                "input_size",
                "input_data",
                "output_data",
                "ref_cycles",
                "opt_cycles",
                "debug_val",
                "debug_lut",
            ],
        )

        rng = np.random.default_rng()
        # Cover the whole int8 range to test LUT
        input_data = np.arange(-128, 128, dtype=np.int8)
        if self.input_size > len(input_data):
            input_data = np.pad(
                input_data, (0, self.input_size - len(input_data)), "edge"
            )
        else:
            input_data = input_data[:self.input_size]

        await self.fixture.write_word("input_zero_point", 0)
        await self.fixture.write_word("input_range_radius", 127)
        await self.fixture.write_word("input_multiplier", 1073741824)
        await self.fixture.write(
            "input_left_shift", np.array([0], dtype=np.int32)
        )
        await self.fixture.write_word("input_size", self.input_size)
        await self.fixture.write("input_data", input_data)

        # Initialize the kernel (populate LUT) after parameters are written
        await self.fixture.write_ptr("impl", "run_init")
        await self.fixture.run_to_halt(timeout_cycles=1000000)

        # Print debug info
        debug_val = await self.fixture.read_word("debug_val")
        print(f"DEBUG: VLMAX={debug_val}", flush=True)
        debug_lut = (await self.fixture.read("debug_lut", 256)).view(np.int8)
        print(f"DEBUG: LUT[:16]={debug_lut[:16].tolist()}", flush=True)
        print(f"DEBUG: LUT[120:136]={debug_lut[120:136].tolist()}", flush=True)
        print(f"DEBUG: LUT[-16:]={debug_lut[-16:].tolist()}", flush=True)

    async def run(self, func_ptr: str, timeout_cycles):
        await self.fixture.write_ptr("impl", func_ptr)
        await self.fixture.write(
            "output_data", np.zeros([self.input_size], dtype=np.int8)
        )
        await self.fixture.run_to_halt(timeout_cycles=timeout_cycles)
        outputs = (await self.fixture.read("output_data",
                                           self.input_size)).view(np.int8)

        data = await self.fixture.read(
            "ref_cycles" if func_ptr == "run_ref" else "opt_cycles", 8
        )
        measured_cycles = data.view(np.uint64)[0]
        return outputs, measured_cycles

    async def test(self, timeout_cycles=1000000):
        ref_output, ref_cycles = await self.run("run_ref", timeout_cycles)
        print(f"ref_cycles={ref_cycles}", flush=True)
        opt_output, opt_cycles = await self.run(
            "run_optimized", timeout_cycles
        )
        print(f"opt_cycles={opt_cycles}", flush=True)
        if opt_cycles > 0:
            print(f"speedup={float(ref_cycles) / opt_cycles:.2f}x", flush=True)

        assert (opt_output == ref_output).all()


@cocotb.test()
async def test_logistic_256(dut):
    t = LogisticTester(input_size=256)
    await t.setup(dut)
    await t.test()


@cocotb.test(skip=True)
async def test_logistic_1024(dut):
    t = LogisticTester(input_size=1024)
    await t.setup(dut)
    await t.test()
