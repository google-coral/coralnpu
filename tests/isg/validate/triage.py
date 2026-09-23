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
"""CoralFlow target parsing and failure-log triage helpers for ISG runners."""

from __future__ import annotations

import os
import re
import zipfile
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

CORALFLOW_BACKEND_SUFFIXES: Tuple[str, ...] = (
    "_uvm",
    "_verilator",
    "_vcs",
    "_npusim",
    "_nexus_fpga",
)

_BLOCK_START_RE = re.compile(r"---\s*STARTING TEST:\s*(\S+?)\s*---")
_BLOCK_END_RE = re.compile(r"---\s*FINISHED TEST:\s*(\S+?)\s*---")
_FIXTURE_FAIL_PATTERNS: Tuple[re.Pattern[str], ...] = (
    re.compile(
        r"\b([A-Za-z0-9_]+)(?:\.(?:elf|bin))?:\s*(?:expected tohost|did not report UVM TEST PASSED|did not write tohost)"
    ),
    re.compile(
        r"Missing execution block for ([A-Za-z0-9_]+)(?:\.(?:elf|bin))?\b"
    ),
)
_DUMPED_LOG_RE = re.compile(r"Full simulation log dumped to:\s*(\S+)")

_BLOCK_FAILURE_MARKERS: Tuple[str, ...] = (
    "** UVM TEST FAILED **",
    "UVM_ERROR",
    "UVM_FATAL",
    "COSIM_MISMATCH",
    "FAILED: Timeout",
    "FAILED: Co-Simulation mismatch",
    "FAILED: Unknown error",
    "Result: FAIL",
)


def parse_coralflow_target(target: str) -> Tuple[str, str, str]:
    """Splits a Bazel CoralFlow target into (package, batch_stem, backend_suffix).

    For example, '//tests/isg:isg_ci_50_uvm' -> ('//tests/isg', 'isg_ci_50', '_uvm').
    """
    if ":" in target:
        pkg, target_name = target.rsplit(":", 1)
        if not pkg:
            pkg = "//tests/isg"
    else:
        pkg = "//tests/isg"
        target_name = target

    for suffix in CORALFLOW_BACKEND_SUFFIXES:
        if target_name.endswith(suffix):
            return pkg, target_name[:-len(suffix)], suffix

    stem = (
        target_name.removeprefix("verilator_uvm_regression_"
                                 ).removeprefix("vcs_uvm_regression_")
    )
    return pkg, stem, "_uvm"


def format_single_program_target(target: str, prog_name: str) -> str:
    """Builds the per-program CoralFlow Bazel target label for `prog_name`."""
    pkg, _, suffix = parse_coralflow_target(target)
    clean_prog = prog_name.split(":")[-1].removesuffix(".elf")
    if clean_prog.endswith(suffix):
        clean_prog = clean_prog[:-len(suffix)]
    return f"{pkg}:{clean_prog}{suffix}"


def format_filtered_batch_command(
    target: str,
    prog_names: Sequence[str],
    seed: str,
    extra_flags: str = "",
) -> Optional[str]:
    """Builds a single-simulation filtered batch command when supported."""
    cleaned = [
        p.split(":")[-1].removesuffix(".elf") for p in prog_names if p.strip()
    ]
    if not cleaned:
        return None
    _, _, suffix = parse_coralflow_target(target)
    joined = ",".join(cleaned)
    tail = f" {extra_flags.strip()}" if extra_flags.strip() else ""
    if suffix == "_uvm":
        return (
            f"bazel test {target} --test_filter={joined} "
            f"--//tests/isg:isg_seed={seed}{tail}"
        )
    if suffix in ("_verilator", "_vcs"):
        return (
            f"bazel test {target} --test_env=ISG_ELF_FILTER={joined} "
            f"--//tests/isg:isg_seed={seed}{tail}"
        )
    return None


def extract_failed_binaries(
    log_text: str,
    echo_errors: bool = False,
) -> List[str]:
    """Extracts failing ISG program stems from CoralFlow UVM or Cocotb logs."""
    failed: List[str] = []

    def _record(prog: Optional[str]) -> None:
        if not prog:
            return
        stem = os.path.basename(prog).removesuffix(".elf").removesuffix(".bin")
        if stem and stem not in failed:
            failed.append(stem)

    current_prog: Optional[str] = None
    saw_pass = False
    saw_fail = False

    for raw_line in log_text.splitlines():
        line = raw_line.strip()

        start_match = _BLOCK_START_RE.search(line)
        if start_match:
            if current_prog is not None and (saw_fail or not saw_pass):
                _record(current_prog)
            current_prog = start_match.group(1)
            saw_pass = False
            saw_fail = False
            continue

        end_match = _BLOCK_END_RE.search(line)
        if end_match and current_prog is not None:
            if saw_fail or not saw_pass:
                _record(current_prog)
            current_prog = None
            saw_pass = False
            saw_fail = False
            continue

        if current_prog is not None:
            if "** UVM TEST PASSED **" in line:
                saw_pass = True
            if any(marker in line for marker in _BLOCK_FAILURE_MARKERS):
                saw_fail = True
                if echo_errors:
                    print(f"    {line}", flush=True)

        for pattern in _FIXTURE_FAIL_PATTERNS:
            m = pattern.search(line)
            if m:
                if echo_errors:
                    print(f"    {line}", flush=True)
                _record(m.group(1))

    if current_prog is not None and (saw_fail or not saw_pass):
        _record(current_prog)

    return failed


def collect_target_failure_logs(
    repo_root: str | os.PathLike[str],
    target: str,
    stdout: str = "",
) -> str:
    """Gathers stdout, Bazel test.log, and UVM undeclared error logs on failure."""
    chunks: List[str] = []
    if stdout:
        chunks.append(stdout)

    for dumped_match in _DUMPED_LOG_RE.finditer(stdout):
        dumped_path = Path(dumped_match.group(1))
        if dumped_path.is_file():
            try:
                chunks.append(
                    dumped_path.read_text(encoding="utf-8", errors="replace")
                )
            except OSError:
                pass

    pkg, stem, suffix = parse_coralflow_target(target)
    rel_pkg = pkg.lstrip("/")
    target_name = f"{stem}{suffix}"
    testlog_dir = Path(repo_root) / "bazel-testlogs" / rel_pkg / target_name

    test_log = testlog_dir / "test.log"
    if test_log.is_file():
        try:
            chunks.append(
                test_log.read_text(encoding="utf-8", errors="replace")
            )
        except OSError:
            pass

    outputs_dir = testlog_dir / "test.outputs"
    outputs_zip = outputs_dir / "outputs.zip"
    if outputs_zip.is_file():
        try:
            with zipfile.ZipFile(outputs_zip, "r") as zf:
                for member in sorted(zf.namelist()):
                    base = os.path.basename(member)
                    if base.startswith("uvm_sim_error_") and base.endswith(
                            ".log"):
                        with zf.open(member) as fp:
                            chunks.append(
                                fp.read().decode("utf-8", errors="replace")
                            )
        except (OSError, zipfile.BadZipFile):
            pass
    if outputs_dir.is_dir():
        for log_file in sorted(outputs_dir.glob("uvm_sim_error_*.log")):
            if log_file.is_file():
                try:
                    chunks.append(
                        log_file.read_text(encoding="utf-8", errors="replace")
                    )
                except OSError:
                    pass

    return "\n".join(chunks)
