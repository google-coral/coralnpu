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

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
import numpy as np


@coralflow_test(highmem=True)
async def core_mini_rvv_mobilenet_v1(fixture):
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/tutorial/tfmicro/run_mobilenet_v1_025_partial_binary.elf'
        ),
        ['inference_status', 'inference_status_message'],
    )
    # NOTE: Running the example in DEBUG mode is too slow could take more than 500Million cycles
    await fixture.run_to_halt(timeout_cycles=130_000_000)
    cycle_count = fixture.get_cycle_count()
    print(f'Total number of execution cycles: {cycle_count} \n', flush=True)
    tflite_inference_status = (await
                               fixture.read_word('inference_status')).view(
                                   np.int32
                               )
    tflite_inference_message = bytes(
        (await fixture.read('inference_status_message', 31))
    ).decode()
    assert tflite_inference_status == 0, tflite_inference_message
    print(' \n Partial mobilenet Invoke() successful \n', flush=True)


if __name__ == '__main__':
    coralflow_main()
