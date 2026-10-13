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

from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test


@coralflow_test
async def core_mini_axi_tutorial(fixture):
    """Testbench to run your CoralNPU program."""
    _ = fixture

    # TODO: Load your program into ITCM with "fixture.load_elf_and_lookup_symbols"

    # TODO: Write your program inputs with "fixture.write"

    # TODO: Run your program and wait for halted with "fixture.run_to_halt"

    # TODO: Read your program outputs and print the result with "fixture.read"


if __name__ == "__main__":
    coralflow_main()
