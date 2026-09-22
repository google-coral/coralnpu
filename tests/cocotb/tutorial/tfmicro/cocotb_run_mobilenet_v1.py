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
async def core_mini_rvv_mobilenet_v1(dut):

    fixture = await VerilatorTestFixture.Create(dut, highmem=True)
    r = runfiles.Create()
    elf_files = ['run_mobilenet_v1_025_partial_binary.elf']
    for elf_file in elf_files:
        await fixture.load_elf_and_lookup_symbols(
            r.
            Rlocation('coralnpu_hw/tests/cocotb/tutorial/tfmicro/' + elf_file),
            ['inference_status', 'inference_status_message']
        )
        # NOTE: Running the example in DEBUG mode is too slow could take more than 500Million cycles
        cycle_count = await fixture.run_to_halt(timeout_cycles=130_000_000)
        print(
            f"Total number of execution cycles: {cycle_count} \n", flush=True
        )
        tflite_inference_status = (
            await fixture.read_word('inference_status')
        ).view(np.int32)
        tflite_inference_message = bytes(
            (await fixture.read('inference_status_message', 31))
        ).decode()
        assert tflite_inference_status == 0, tflite_inference_message
        print(f" \n Partial mobilenet Invoke() successful \n", flush=True)
