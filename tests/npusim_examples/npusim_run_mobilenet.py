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
import numpy as np

from coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture import (
    MpactNpuSimTestFixture,
)


async def _run_full_mobilenet():
    print("Running full mobilenet...")
    fixture = await MpactNpuSimTestFixture.Create(
        highmem=True, exit_on_ebreak=True
    )
    symbols = await fixture.load_elf_and_lookup_symbols(
        "tests/npusim_examples/run_full_mobilenet_v1_binary.elf",
        symbols=["inference_status", "inference_input", "inference_output"],
        optional=True,
    )

    if symbols.get("inference_input"):
        input_data = np.random.randint(
            -128, 127, size=(224 * 224 * 3, ), dtype=np.int8
        )
        await fixture.write("inference_input", input_data)

    print("Running simulation...", flush=True)
    await fixture.run_to_halt()
    print(f"cycles taken by the simulation {fixture.get_cycle_count()}")

    if symbols.get("inference_output"):
        output_data = await fixture.read(
            "inference_output", size=5, dtype=np.int8, shape=(5, )
        )
        max_idx = np.argmax(output_data)
        print(
            f"Output info: Top index {max_idx} with value {output_data[max_idx]} from {output_data}"
        )

    if symbols.get("inference_status"):
        inference_status = (
            await fixture.read("inference_status", size=1, dtype=np.uint8)
        )[0]
        print(f"inference_status {inference_status}")


def run_full_mobilenet():
    asyncio.run(_run_full_mobilenet())


if __name__ == "__main__":
    run_full_mobilenet()
