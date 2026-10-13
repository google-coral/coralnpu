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


@coralflow_test
async def inst_cycle_counter_test(fixture):
    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/tutorial/counters/inst_cycle_counter_example.elf"
    )
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        ['cycle_count_lo', 'cycle_count_hi', 'inst_count_lo', 'inst_count_hi'],
    )
    await fixture.run_to_halt()
    cycle_count_lo = await fixture.read_word('cycle_count_lo')
    cycle_count_hi = await fixture.read_word('cycle_count_hi')
    inst_count_lo = await fixture.read_word('inst_count_lo')
    inst_count_hi = await fixture.read_word('inst_count_hi')
    cycle_count = (cycle_count_hi << 32) | cycle_count_lo
    instruction_count = (inst_count_hi << 32) | inst_count_lo
    print(
        f" {instruction_count} instructions are executed with {cycle_count} compute cycles",
        flush=True
    )


if __name__ == "__main__":
    coralflow_main()
