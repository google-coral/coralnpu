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
"""CoralFlow runner for constrained-random ISG ELF batches."""

import logging
import os

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test

_BACKEND_SUFFIXES = (
    "_uvm",
    "_verilator",
    "_vcs",
    "_npusim",
    "_nexus_fpga",
)


def _discover_batch_elfs() -> list[str]:
    """Locates the linked ELF binaries for the active ISG batch."""
    r = runfiles.Create()
    script_path = r.Rlocation("coralnpu_hw/tests/isg/isg_coralflow_test.py")
    if script_path and os.path.exists(script_path):
        isg_dir = os.path.dirname(script_path)
    else:
        isg_dir = os.path.dirname(os.path.abspath(__file__))

    all_elfs = sorted(
        os.path.join(isg_dir, name)
        for name in os.listdir(isg_dir)
        if name.endswith(".elf")
    )

    test_target = os.environ.get("TEST_TARGET", "")
    if ":" in test_target:
        target_name = test_target.rsplit(":", 1)[-1]
        for suffix in _BACKEND_SUFFIXES:
            if target_name.endswith(suffix):
                batch_prefix = target_name[:-len(suffix)] + "_"
                matching = [
                    path for path in all_elfs
                    if os.path.basename(path).startswith(batch_prefix)
                ]
                if matching:
                    return matching
                break

    return all_elfs


@coralflow_test
async def isg_batch_test(fixture):
    """Executes every ELF in the ISG batch and verifies clean termination."""
    elf_paths = _discover_batch_elfs()
    assert elf_paths, "No ISG ELF binaries found in runfiles."

    for elf_path in elf_paths:
        elf_name = os.path.basename(elf_path)
        logging.info("Running ISG program: %s", elf_name)
        await fixture.load_elf_and_lookup_symbols(elf_path, ["tohost"])
        await fixture.run_to_halt(timeout_cycles=100000)
        tohost = await fixture.read_word("tohost")
        assert tohost == 1, (
            f"{elf_name}: expected tohost == 1, got 0x{tohost:08x}"
        )


if __name__ == "__main__":
    coralflow_main()
