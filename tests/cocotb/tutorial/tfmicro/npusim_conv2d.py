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

import asyncio
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture import MpactNpuSimTestFixture
import numpy as np


class MpactConv2DTest:

    def __init__(self, in_d, out_d, stride=1, out_h=4, out_w=4):
        self.stride = stride
        in_h = out_h * stride
        in_w = out_w * stride
        self.in_shape = np.array([1, in_h, in_w, in_d], dtype=np.uint32)
        self.f_shape = np.array([out_d, 4, 4, in_d], dtype=np.uint32)
        self.bias_shape = np.array([out_d], dtype=np.uint32)
        self.out_shape = np.array([1, out_h, out_w, out_d], dtype=np.uint32)
        self.out_size = int(np.prod(self.out_shape))

        r = runfiles.Create()
        self.elf_file = r.Rlocation(
            'coralnpu_hw/tests/cocotb/tutorial/tfmicro/conv2d_test.elf'
        )
        self.fixture = None

    async def load_and_populate_input(self):
        self.fixture = await MpactNpuSimTestFixture.Create(highmem=True)
        await self.fixture.load_elf_and_lookup_symbols(
            self.elf_file, [
                'impl',
                'run_ref',
                'run_opt',
                'stride',
                'filter_shape',
                'filter_data',
                'bias_shape',
                'bias_data',
                'input_shape',
                'input_data',
                'output_shape',
                'output_data',
                'params',
            ]
        )
        rng = np.random.default_rng()
        filter_data = rng.integers(
            -128, 128, self.f_shape, dtype=np.int8
        ).flatten()
        bias_data = rng.integers(
            -100000, 100000, self.out_shape[3], dtype=np.int32
        )
        input_data = rng.integers(
            -128, 128, self.in_shape, dtype=np.int8
        ).flatten()

        await self.fixture.write_word('stride', int(self.stride))
        await self.fixture.write('filter_shape', self.f_shape)
        await self.fixture.write('filter_data', filter_data)

        await self.fixture.write('bias_shape', self.bias_shape)
        await self.fixture.write('bias_data', bias_data)
        await self.fixture.write('input_shape', self.in_shape)
        await self.fixture.write('input_data', input_data)

        # Verify input_data integrity
        read_back_input = (
            await self.fixture.read('input_data', len(input_data))
        ).view(np.int8)
        if not (read_back_input == input_data).all():
            print("Input data mismatch during load!")
            raise AssertionError("Input data corrupted during write_memory")
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

    async def test(self):
        opt_cycles, opt_outputs = await self.run(fun_ptr="run_opt")
        ref_cycles, ref_outputs = await self.run(fun_ptr="run_ref")
        print(f"ref_cycles {ref_cycles} opt_cycles {opt_cycles}")
        assert (opt_outputs == ref_outputs).all()


async def run_tests():

    print("test_conv2d_16x1")
    t = MpactConv2DTest(in_d=16, out_d=1, stride=1, out_h=4, out_w=4)
    await t.load_and_populate_input()
    await t.test()

    print("test_conv2d_16x16")
    t = MpactConv2DTest(in_d=16, out_d=16, stride=1, out_h=4, out_w=4)
    await t.load_and_populate_input()
    await t.test()

    print("test_conv2d_16x16_s2_h8w8")
    t = MpactConv2DTest(in_d=16, out_d=16, stride=2, out_h=8, out_w=8)
    await t.load_and_populate_input()
    await t.test()

    print("test_conv2d_48x5")
    t = MpactConv2DTest(in_d=48, out_d=5, stride=1, out_h=8, out_w=8)
    await t.load_and_populate_input()
    await t.test()

    print("test_conv2d_21x16")
    t = MpactConv2DTest(in_d=21, out_d=16, stride=1, out_h=2, out_w=2)
    await t.load_and_populate_input()
    await t.test()


if __name__ == "__main__":
    asyncio.run(run_tests())
