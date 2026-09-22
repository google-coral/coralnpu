# Copyright 2026 Google LLC
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

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture


def tolerate(target: int, tolerance=1.2) -> int:
    return int(target * tolerance)


class MaxPoolTest:

    def __init__(self, in_d, stride=2, filter_size=2, out_h=4, out_w=4):
        self.stride = stride
        self.filter_size = filter_size
        in_h = out_h * stride
        in_w = out_w * stride
        self.in_shape = np.array([1, in_h, in_w, in_d], dtype=np.uint32)
        self.out_shape = np.array([1, out_h, out_w, in_d], dtype=np.uint32)
        self.out_size = int(np.prod(self.out_shape))

        r = runfiles.Create()
        self.elf_file = r.Rlocation(
            "coralnpu_hw/tests/cocotb/tutorial/tfmicro/pooling_test.elf"
        )
        self.fixture = None

    async def load_and_populate_input(self, dut):
        self.fixture = await VerilatorTestFixture.Create(dut, highmem=True)
        await self.fixture.load_elf_and_lookup_symbols(
            self.elf_file,
            [
                "impl",
                "run_ref",
                "run_optimized",
                "stride",
                "filter_size",
                "input_shape",
                "input_data",
                "output_shape",
                "output_data",
                "ref_cycles",
                "opt_cycles",
            ],
        )

        rng = np.random.default_rng()
        input_data = rng.integers(
            -128, 128, self.in_shape, dtype=np.int8
        ).flatten()

        await self.fixture.write_word("stride", self.stride)
        await self.fixture.write_word("filter_size", self.filter_size)
        await self.fixture.write("input_shape", self.in_shape)
        await self.fixture.write("input_data", input_data)
        await self.fixture.write("output_shape", self.out_shape)

    async def run(self, func_ptr: str, timeout_cycles):
        await self.fixture.write_ptr("impl", func_ptr)
        await self.fixture.write(
            "output_data", np.zeros([self.out_size], dtype=np.int8)
        )
        halt_cycles = await self.fixture.run_to_halt(
            timeout_cycles=timeout_cycles
        )
        outputs = (await self.fixture.read("output_data",
                                           self.out_size)).view(np.int8)

        # Read measured cycles from the C variables (8 bytes for uint64_t)
        data = await self.fixture.read(
            "ref_cycles" if func_ptr == "run_ref" else "opt_cycles", 8
        )
        measured_cycles = data.view(np.uint64)[0]
        return outputs, measured_cycles

    async def test(self, ref_target, opt_target):
        ref_output, ref_cycles = await self.run(
            "run_ref", tolerate(ref_target)
        )
        print(f"ref_cycles={ref_cycles}", flush=True)
        opt_output, opt_cycles = await self.run(
            "run_optimized", tolerate(opt_target)
        )
        print(f"opt_cycles={opt_cycles}", flush=True)

        if opt_cycles > 0:
            print(f"speedup={float(ref_cycles) / opt_cycles:.2f}x", flush=True)

        assert (opt_output == ref_output).all()


# Tests


@cocotb.test()
async def test_maxpool16stride2(dut):
    t = MaxPoolTest(in_d=16)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=500_000, opt_target=100_000)


@cocotb.test()
async def test_maxpool32stride2(dut):
    t = MaxPoolTest(in_d=32)
    await t.load_and_populate_input(dut)
    # Ref target based on depthwise_conv ref results (very slow)
    await t.test(ref_target=1_000_000, opt_target=100_000)


@cocotb.test()
async def test_maxpool64stride2(dut):
    t = MaxPoolTest(in_d=64)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=2_000_000, opt_target=100_000)
