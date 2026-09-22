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

import asyncio
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture import MpactNpuSimTestFixture
import numpy as np


def tolerate(target: int, variance=0.2) -> int:
    return int(target * (1 + variance))


class MpactDepthwiseConvTest:

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

    async def load_and_populate_input(self):
        self.fixture = await MpactNpuSimTestFixture.Create(highmem=True)
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
        self.filter_data = rng.integers(-128, 128, self.f_shape, dtype=np.int8)
        filter_data_flat = self.filter_data.flatten()
        bias_data = rng.integers(
            -100000, 100000, self.out_shape[3], dtype=np.int32
        )
        input_data = rng.integers(
            -128, 128, self.in_shape, dtype=np.int8
        ).flatten()
        await self.fixture.write_word('stride', int(self.stride))
        await self.fixture.write_word('dm', int(self.dm))
        await self.fixture.write('filter_shape', self.f_shape)
        await self.fixture.write('filter_data', filter_data_flat)
        await self.fixture.write('bias_shape', self.bias_shape)
        await self.fixture.write('bias_data', bias_data)
        await self.fixture.write('input_shape', self.in_shape)
        await self.fixture.write('input_data', input_data)
        await self.fixture.write('output_shape', self.out_shape)

    async def run(self, fun_ptr):
        await self.fixture.write_ptr('impl', fun_ptr)
        await self.fixture.write(
            'output_data', np.zeros([self.out_size], dtype=np.int8)
        )
        cycles = await self.fixture.run_to_halt()
        outputs = (await self.fixture.read('output_data',
                                           self.out_size)).view(np.int8)
        return cycles, outputs

    async def test(self, ref_target, opt_target):
        opt_cycles, ref_outputs = await self.run(fun_ptr="run_optimized")
        ref_cycles, opt_outputs = await self.run(fun_ptr="run_ref")
        print(f"opt_cycles {opt_cycles}")
        print(f"ref_cycles {ref_cycles}")
        assert (opt_outputs == ref_outputs).all()
        assert opt_cycles < tolerate(opt_target)
        assert ref_cycles < tolerate(ref_target)


async def run_tests():

    print("Running functional tests...")
    print("test_dwconv8to8stride1")
    t = MpactDepthwiseConvTest(in_d=32)
    await t.load_and_populate_input()
    await t.test(ref_target=171_880, opt_target=7_907)

    print("test_dwconv32to32stride2")
    t = MpactDepthwiseConvTest(in_d=32, stride=2)
    await t.load_and_populate_input()
    await t.test(ref_target=182_500, opt_target=7_752)

    print("test_dwconv64to64stride1")
    t = MpactDepthwiseConvTest(in_d=64)
    await t.load_and_populate_input()
    await t.test(ref_target=337_804, opt_target=10_800)

    print("test_dwconv64to64stride2")
    t = MpactDepthwiseConvTest(in_d=64, stride=2)
    await t.load_and_populate_input()
    await t.test(ref_target=359_251, opt_target=10_675)

    print("test_dwconv16to32stride2")
    t = MpactDepthwiseConvTest(in_d=16, dm=2, stride=2)
    await t.load_and_populate_input()
    await t.test(ref_target=177_961, opt_target=9_586)


if __name__ == "__main__":
    asyncio.run(run_tests())
