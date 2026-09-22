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


class FullyConnectedTester:

    def __init__(self, batches, input_depth, output_depth):
        self.batches = batches
        self.input_depth = input_depth
        self.output_depth = output_depth

        self.input_shape = np.array([batches, 1, 1, input_depth],
                                    dtype=np.int32)
        self.filter_shape = np.array([output_depth, 1, 1, input_depth],
                                     dtype=np.int32)
        self.bias_shape = np.array([output_depth], dtype=np.int32)
        self.output_shape = np.array([batches, 1, 1, output_depth],
                                     dtype=np.int32)

        r = runfiles.Create()
        self.elf_file = r.Rlocation(
            "coralnpu_hw/tests/cocotb/tutorial/tfmicro/fully_connected_test.elf"
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
                "input_offset",
                "filter_offset",
                "output_offset",
                "output_multiplier",
                "output_shift",
                "activation_min",
                "activation_max",
                "input_dims",
                "filter_dims",
                "bias_dims",
                "output_dims",
                "input_data",
                "filter_data",
                "bias_data",
                "output_data",
                "ref_cycles",
                "opt_cycles",
            ],
        )

        rng = np.random.default_rng()
        input_data = rng.integers(
            -128, 128, self.input_shape, dtype=np.int8
        ).flatten()
        filter_data = rng.integers(
            -128, 128, self.filter_shape, dtype=np.int8
        ).flatten()
        bias_data = rng.integers(
            -1000, 1000, self.bias_shape, dtype=np.int32
        ).flatten()

        await self.fixture.write_word("input_offset", 0)
        await self.fixture.write_word("filter_offset", 0)
        await self.fixture.write_word("output_offset", 0)
        await self.fixture.write_word("output_multiplier", 1073741824)
        # Use write with int32 array for signed values
        await self.fixture.write(
            "output_shift", np.array([-1], dtype=np.int32)
        )
        await self.fixture.write_word("activation_min", -128 & 0xFFFFFFFF)
        await self.fixture.write_word("activation_max", 127)

        await self.fixture.write("input_dims", self.input_shape)
        await self.fixture.write("filter_dims", self.filter_shape)
        await self.fixture.write("bias_dims", self.bias_shape)
        await self.fixture.write("output_dims", self.output_shape)

        await self.fixture.write("input_data", input_data)
        await self.fixture.write("filter_data", filter_data)
        await self.fixture.write("bias_data", bias_data)

    async def run(self, func_ptr: str, timeout_cycles):
        await self.fixture.write_ptr("impl", func_ptr)
        await self.fixture.write(
            "output_data",
            np.zeros([self.batches * self.output_depth], dtype=np.int8)
        )
        await self.fixture.run_to_halt(timeout_cycles=timeout_cycles)
        outputs = (
            await
            self.fixture.read("output_data", self.batches * self.output_depth)
        ).view(np.int8)

        data = await self.fixture.read(
            "ref_cycles" if func_ptr == "run_ref" else "opt_cycles", 8
        )
        measured_cycles = data.view(np.uint64)[0]
        return outputs, measured_cycles

    async def test(self, timeout_cycles=5000000):
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
async def test_fc_16_16(dut):
    t = FullyConnectedTester(batches=1, input_depth=16, output_depth=16)
    await t.setup(dut)
    await t.test()


@cocotb.test()
async def test_fc_64_64(dut):
    t = FullyConnectedTester(batches=1, input_depth=64, output_depth=64)
    await t.setup(dut)
    await t.test()


@cocotb.test(skip=True)
async def test_fc_256_256(dut):
    t = FullyConnectedTester(batches=1, input_depth=256, output_depth=256)
    await t.setup(dut)
    await t.test()
