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
import sys

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test

try:
    from tests.isg import isg_verbose_config
except ImportError:
    isg_verbose_config = None

_BACKEND_SUFFIXES = (
    "_uvm",
    "_verilator",
    "_vcs",
    "_npusim",
    "_nexus_fpga",
)


def _is_verbose(
    argv: list[str] | None = None,
    env: dict[str, str] | None = None,
) -> bool:
    """Returns True when verbose per-program execution logging is enabled."""
    active_argv = sys.argv[1:] if argv is None else argv
    if "-v" in active_argv or "--verbose" in active_argv:
        return True
    active_env = os.environ if env is None else env
    for key in ("ISG_VERBOSE", "CORALFLOW_VERBOSE"):
        raw = active_env.get(key, "").strip().lower()
        if raw in ("1", "true"):
            return True
        if raw in ("0", "false"):
            return False
    return bool(getattr(isg_verbose_config, "ISG_VERBOSE_DEFAULT", False))


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
    verbose = _is_verbose()
    dut_log = getattr(
        getattr(getattr(fixture, "core_mini_axi", None), "dut", None),
        "_log",
        None,
    )
    if verbose:
        os.environ["CORALFLOW_VERBOSE"] = "1"
        total = len(elf_paths)
        if dut_log is not None and hasattr(dut_log, "info"):
            for idx, elf_path in enumerate(elf_paths, 1):
                dut_log.info(
                    f"[ISG] Executing ({idx}/{total}): "
                    f"{os.path.basename(elf_path)}"
                )
                await fixture.run_batch([elf_path], timeout_cycles=100000)
            return
        for idx, elf_path in enumerate(elf_paths, 1):
            logging.info(
                "[ISG] Queued for batch execution (%d/%d): %s",
                idx,
                total,
                os.path.basename(elf_path),
            )
        await fixture.run_batch(elf_paths, timeout_cycles=100000)
        return

    prev_level = None
    if (dut_log is not None and hasattr(dut_log, "level")
            and hasattr(dut_log, "setLevel")):
        prev_level = dut_log.level
        dut_log.setLevel(max(prev_level, logging.WARNING))
    try:
        await fixture.run_batch(elf_paths, timeout_cycles=100000)
    finally:
        if prev_level is not None:
            dut_log.setLevel(prev_level)


if __name__ == "__main__":
    if _is_verbose():
        os.environ["CORALFLOW_VERBOSE"] = "1"
    coralflow_main()
