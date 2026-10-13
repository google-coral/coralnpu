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


@coralflow_test
async def core_mini_axi_tutorial(fixture):
    """Testbench to run your CoralNPU program."""
    r = runfiles.Create()

    # Elf file is generated from bazel build //examples:coralnpu_v2_hello_world_add_floats
    elf_path = r.Rlocation(
        "coralnpu_hw/examples/coralnpu_v2_hello_world_add_floats.elf"
    )
    if not elf_path:
        raise ValueError("elf_path must consist a valid path ")

    await fixture.load_elf_and_lookup_symbols(
        elf_path, ["input1", "input2", "output"]
    )

    # this example is passing inputs from dtcm instead of defining in memory.
    input1_data = np.arange(1, 9, dtype=np.float32)
    input2_data = 0.213 * np.ones(8, dtype=np.float32)

    await fixture.write("input1", input1_data)
    await fixture.write("input2", input2_data)
    rinput1 = (await fixture.read("input1", 4 * 8)).view(np.float32)
    rinput2 = (await fixture.read("input2", 4 * 8)).view(np.float32)
    print(f"Reading input1 values : {rinput1}")
    print(f"Reading input2 values : {rinput2}")

    # Run your program and wait for halted
    await fixture.run_to_halt()
    # Read your program outputs and print the result
    expected = input1_data + input2_data
    routputs = (await fixture.read("output", 4 * 8)).view(np.float32)
    print(f"outputs are {routputs}")
    # check for correctness
    for idx in range(len(routputs)):
        if expected[idx] == routputs[idx]:
            continue
        else:
            raise ValueError(
                f"expected value at {idx} doesn't match result {expected[idx]} vs {routputs[idx]}"
            )
    print(f"Outputs from program {routputs}")


if __name__ == "__main__":
    coralflow_main()
