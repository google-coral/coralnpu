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

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
import numpy as np


@coralflow_test(highmem=True)
async def run_full_mobilenet(fixture):
    print("Running full mobilenet...")
    r = runfiles.Create()
    symbols = await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            "coralnpu_hw/tests/npusim_examples/run_full_mobilenet_v1_binary.elf"
        ),
        symbols=["inference_status", "inference_input", "inference_output"],
        optional=True,
    )

    if "inference_input" in symbols:
        input_data = np.random.randint(
            -128, 127, size=(224 * 224 * 3, ), dtype=np.int8
        )
        await fixture.write("inference_input", input_data)

    print("Running simulation...", flush=True)
    await fixture.run_to_halt()
    print(f"cycles taken by the simulation {fixture.get_cycle_count()}")

    if "inference_output" in symbols:
        output_data = await fixture.read(
            "inference_output", size=5, dtype=np.int8, shape=(5, )
        )
        max_idx = np.argmax(output_data)
        print(
            f"Output info: Top index {max_idx} with value {output_data[max_idx]} from {output_data}"
        )

    if "inference_status" in symbols:
        inference_status = int(
            (await fixture.read("inference_status", size=1, dtype=np.int8))[0]
        )
        print(f"inference_status {inference_status}")
        assert inference_status == 0, (
            f"MobileNet inference failed with status {inference_status}"
        )


if __name__ == "__main__":
    coralflow_main()
