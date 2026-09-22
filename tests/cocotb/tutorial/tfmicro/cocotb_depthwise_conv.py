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

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture


def tolerate(target: int, tolerance=1.2) -> int:
    return int(target * tolerance)


class DepthwiseConvTest:
    # frozen: filter_xy=3, padding=1, dilation=1
    def __init__(self, in_d, dm=1, stride=1, out_h=4, out_w=4):
        self.dm = dm
        self.stride = stride
        out_d = in_d * dm
        in_h = out_h * stride
        in_w = out_w * stride
        self.in_shape = np.array([1, in_h, in_w, in_d], dtype=np.uint32)
        self.f_shape = np.array([1, 3, 3, out_d], dtype=np.uint32)
        self.bias_shape = np.array([out_d], dtype=np.uint32)
        self.out_shape = np.array([1, out_h, out_w, out_d], dtype=np.uint32)
        self.out_size = int(np.prod(self.out_shape))

        r = runfiles.Create()
        self.elf_file = r.Rlocation(
            'coralnpu_hw/tests/cocotb/tutorial/tfmicro/depthwise_conv_test.elf'
        )
        self.fixture = None

    async def load_and_populate_input(self, dut):
        self.fixture = await VerilatorTestFixture.Create(dut, highmem=True)
        await self.fixture.load_elf_and_lookup_symbols(
            self.elf_file, [
                'impl',
                'run_ref',
                'run_optimized',
                'dm',
                'stride',
                'filter_shape',
                'filter_data',
                'bias_shape',
                'bias_data',
                'input_shape',
                'input_data',
                'output_shape',
                'output_data',
            ]
        )

        rng = np.random.default_rng()
        filter_data = rng.integers(
            -128, 128, self.f_shape, dtype=np.int8
        ).flatten()
        # acc comes from 9x int16 so bias can't be full range.
        bias_data = rng.integers(
            -100000, 100000, self.out_shape[3], dtype=np.int32
        )
        input_data = rng.integers(
            -128, 128, self.in_shape, dtype=np.int8
        ).flatten()

        await self.fixture.write_word('stride', self.stride)
        await self.fixture.write_word('dm', self.dm)
        await self.fixture.write('filter_shape', self.f_shape)
        await self.fixture.write('filter_data', filter_data)
        await self.fixture.write('bias_shape', self.bias_shape)
        await self.fixture.write('bias_data', bias_data)
        await self.fixture.write('input_shape', self.in_shape)
        await self.fixture.write('input_data', input_data)
        await self.fixture.write('output_shape', self.out_shape)

    async def run(self, func_ptr: str, timeout_cycles):
        await self.fixture.write_ptr('impl', func_ptr)
        await self.fixture.write(
            'output_data', np.zeros([self.out_size], dtype=np.int8)
        )
        cycles = await self.fixture.run_to_halt(timeout_cycles=timeout_cycles)
        outputs = (await self.fixture.read('output_data',
                                           self.out_size)).view(np.int8)
        return outputs, cycles

    async def test(self, ref_target, opt_target):
        ref_output, ref_cycles = await self.run(
            'run_ref', tolerate(ref_target)
        )
        print(f'ref_cycles={ref_cycles}', flush=True)
        opt_output, opt_cycles = await self.run(
            'run_optimized', tolerate(opt_target)
        )
        print(f'opt_cycles={opt_cycles}', flush=True)

        assert (opt_output == ref_output).all()

    async def benchmark(self, opt_target):
        _, opt_cycles = await self.run('run_optimized', tolerate(opt_target))
        print(f'opt_cycles={opt_cycles}', flush=True)


# Tests
# Cycle count targets come from `-c dbg` runs and are significantly
# slower than `-c opt` because DCHECKs are enabled.


@cocotb.test()
async def test_dwconv8to8stride1(dut):
    t = DepthwiseConvTest(in_d=8)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=226_000, opt_target=26_600)


@cocotb.test()
async def test_dwconv8to8stride2(dut):
    t = DepthwiseConvTest(in_d=8, stride=2)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=257_000, opt_target=26_400)


@cocotb.test()
async def test_dwconv32to32stride1(dut):
    t = DepthwiseConvTest(in_d=32)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=899_000, opt_target=30_600)


@cocotb.test()
async def test_dwconv32to32stride2(dut):
    t = DepthwiseConvTest(in_d=32, stride=2)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=1_019_000, opt_target=28_500)


@cocotb.test()
async def test_dwconv64to64stride1(dut):
    t = DepthwiseConvTest(in_d=64)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=1_800_000, opt_target=49_300)


@cocotb.test()
async def test_dwconv64to64stride2(dut):
    t = DepthwiseConvTest(in_d=64, stride=2)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=2_040_000, opt_target=45_700)


@cocotb.test()
async def test_dwconv16to32stride2(dut):
    t = DepthwiseConvTest(in_d=16, dm=2, stride=2)
    await t.load_and_populate_input(dut)
    await t.test(ref_target=1_010_000, opt_target=41_600)


# Benchmarks are skipped by default.
# Run with COCOTB_TESTCASE=name
# Cycle count targets here come from `-c opt` runs.


@cocotb.test(skip=True)
async def benchmark_dwconv8to8(dut):
    t = DepthwiseConvTest(in_d=8, out_h=112, out_w=112)
    await t.load_and_populate_input(dut)
    # TODO(davidgao): update expectation after we get automatic lmul reduction
    await t.benchmark(opt_target=2_600_000)


@cocotb.test(skip=True)
async def benchmark_dwconv32to32(dut):
    t = DepthwiseConvTest(in_d=32, out_h=56, out_w=56)
    await t.load_and_populate_input(dut)
    await t.benchmark(opt_target=974_000)


@cocotb.test(skip=True)
async def benchmark_dwconv64to64(dut):
    t = DepthwiseConvTest(in_d=64, out_h=28, out_w=28)
    await t.load_and_populate_input(dut)
    await t.benchmark(opt_target=528_000)


@cocotb.test(skip=True)
async def benchmark_dwconv128to128(dut):
    t = DepthwiseConvTest(in_d=128, out_h=14, out_w=14)
    await t.load_and_populate_input(dut)
    await t.benchmark(opt_target=301_000)


@cocotb.test(skip=True)
async def benchmark_dwconv256to256(dut):
    t = DepthwiseConvTest(in_d=256, out_h=7, out_w=7)
    await t.load_and_populate_input(dut)
    await t.benchmark(opt_target=180_000)
