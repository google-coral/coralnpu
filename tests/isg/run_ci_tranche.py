#!/usr/bin/env python3
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
"""Dynamic CI Tranche Runner for CoralNPU Constrained-Random ISG.

This script manages unseeded/fresh execution of ISG program tranches in CI
pipelines, generating dynamic random seeds per invocation, verifying 100%
batch opcode coverage closure, executing the cosimulation regression via Bazel,
and emitting exact reproduction commands for any failures.
"""

from __future__ import annotations

import argparse
import os
import random
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional, Tuple

from tests.isg.gen.dealt import load_alphabet
from tests.isg.validate.coverage import (
    find_alphabet_path,
    verify_stream_batch_coverage,
)
from tests.isg.validate.triage import (
    collect_target_failure_logs,
    extract_failed_binaries,
    format_filtered_batch_command,
    format_single_program_target,
    parse_coralflow_target,
)

DEFAULT_BATCH_SIZE: int = 50
DEFAULT_PROGRAM_LENGTH: int = 64
DEFAULT_TRAP_RATE: float = 0.05
DEFAULT_SHAPING: str = "distributed"
DEFAULT_TARGET: str = "//tests/isg:isg_ci_50_uvm"

BANNER_WIDTH: int = 72
RANDOM_SUFFIX_MIN: int = 1000
RANDOM_SUFFIX_MAX: int = 9999
NS_PER_SECOND: int = 1_000_000_000

# Workspace root: set by `bazel run`; otherwise derived from this file's
# location in the source tree.
_REPO_ROOT = os.environ.get("BUILD_WORKSPACE_DIRECTORY") or str(
    Path(__file__).resolve().parent.parent.parent
)


@dataclass(frozen=True)
class ExecutionContext:
    """Provides clock, timestamp, and seed randomness dependencies."""

    monotonic_clock: Callable[[], float] = time.monotonic
    epoch_clock: Callable[[],
                          int] = lambda: int(time.time_ns() // NS_PER_SECOND)
    rand_range: Callable[[int, int], int] = random.randrange
    utc_timestamp: Callable[
        [],
        str] = lambda: time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


def run_command(cmd: List[str], cwd: Optional[str] = None) -> int:
    """Runs a shell command and streams stdout/stderr."""
    p = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdout=sys.stdout,
        stderr=sys.stderr,
    )
    p.communicate()
    return p.returncode


def generate_seed(
    seed_arg: Optional[str],
    ctx: ExecutionContext,
) -> Tuple[str, bool]:
    """Resolves or dynamically generates a unique tranche seed."""
    if seed_arg:
        return seed_arg, False
    epoch = ctx.epoch_clock()
    rand_suffix = ctx.rand_range(RANDOM_SUFFIX_MIN, RANDOM_SUFFIX_MAX)
    return f"ci_{epoch}_{rand_suffix}", True


def print_banner(
    target: str,
    batch_size: int,
    seed: str,
    dynamic: bool,
    timestamp: str,
) -> None:
    """Prints tranche execution banner and run metadata."""
    print("=" * BANNER_WIDTH)
    print(" CoralNPU ISG Dynamic CI Tranche Runner")
    print("=" * BANNER_WIDTH)
    print(f"Target:               {target}")
    print(f"Batch Size:           {batch_size} binaries")
    mode_str = "(dynamically generated)" if dynamic else "(user specified)"
    print(f"Seed:                 {seed} {mode_str}")
    print(f"Timestamp:            {timestamp}")
    print("=" * BANNER_WIDTH)


def verify_tranche_coverage(seed: str, batch_size: int) -> None:
    """Verifies 100% dealt opcode and shaping coverage before execution."""
    print("\n[ISG CI] Verifying 100% dealt coverage closure for tranche...")
    alphabet_path = find_alphabet_path()
    if not alphabet_path:
        print(
            "[ISG CI] Notice: alphabet JSON not built yet; will be built by Bazel."
        )
        return

    instructions, _ = load_alphabet(str(alphabet_path))
    report = verify_stream_batch_coverage(
        alphabet=instructions,
        batch_size=batch_size,
        length=DEFAULT_PROGRAM_LENGTH,
        shaping=DEFAULT_SHAPING,
        trap_rate=DEFAULT_TRAP_RATE,
        seed=seed,
    )
    if not report["is_complete"]:
        sys.stderr.write(
            f"[ISG CI] ERROR: Opcode coverage closure failed! Missing: {report['missing_opcodes']}\n"
        )
        sys.exit(1)
    if not report.get("is_shape_complete", True):
        sys.stderr.write(
            f"[ISG CI] ERROR: Shape coverage closure failed! Missing shapes: {report.get('missing_shaping_modes')}\n"
        )
        sys.exit(1)

    print(
        f"[ISG CI] Opcode coverage verified: 100.0% ({report['covered_alphabet_count']}/{report['alphabet_size']} opcodes covered across {batch_size} programs)."
    )
    print(
        f"[ISG CI] Shape coverage verified: 100.0% ({len(report['covered_shaping_modes'])}/{len(report['target_shaping_modes'])} active shaping modes covered across {batch_size} programs)."
    )


def print_reproduction_commands(
    target: str,
    seed: str,
    failed: bool,
    failed_binaries: Optional[List[str]] = None,
) -> None:
    """Prints exact single-program and batch reproduction commands."""
    _, stem, _ = parse_coralflow_target(target)
    header = (
        "[ISG CI] To reproduce this exact tranche failure:"
        if failed else "[ISG CI] Exact Reproduction Command:"
    )
    print(f"\n{header}")
    print(f"  bazel test {target} --//tests/isg:isg_seed={seed}")

    if failed and failed_binaries:
        print("\n[ISG CI] Failing program target(s):")
        for prog in failed_binaries:
            single_target = format_single_program_target(target, prog)
            print(
                f"  bazel test {single_target} --//tests/isg:isg_seed={seed}"
            )
        if len(failed_binaries) > 1:
            batch_cmd = format_filtered_batch_command(
                target, failed_binaries, seed
            )
            if batch_cmd:
                print("\n[ISG CI] Filtered single-sim batch reproduction:")
                print(f"  {batch_cmd}")
    else:
        sample_idx = "000" if failed else "023"
        sub_header = (
            "[ISG CI] To inspect and run an individual program (for example 0):"
            if failed else
            "[ISG CI] Single Target Reproduction (for example program 23):"
        )
        sample_target = format_single_program_target(
            target, f"{stem}_{sample_idx}"
        )
        print(f"\n{sub_header}")
        print(f"  bazel test {sample_target} --//tests/isg:isg_seed={seed}")


def execute_tranche(
    target: str,
    seed: str,
    batch_size: int,
    ctx: ExecutionContext,
    verbose: bool = False,
) -> int:
    """Executes the tranche Bazel test suite and logs results."""
    bazel_cmd = [
        "bazel",
        "test",
        target,
        f"--//tests/isg:isg_seed={seed}",
        "--test_output=all" if verbose else "--test_output=errors",
    ]
    if verbose:
        bazel_cmd.extend([
            "--//tests/isg:isg_verbose=true",
            "--test_env=ISG_VERBOSE=1",
        ])

    print("\n[ISG CI] Invoking Bazel test suite:")
    print("  " + " ".join(bazel_cmd))
    print("-" * BANNER_WIDTH)

    start_time = ctx.monotonic_clock()
    ret = run_command(bazel_cmd, cwd=_REPO_ROOT)
    elapsed = ctx.monotonic_clock() - start_time

    print("-" * BANNER_WIDTH)
    if ret == 0:
        print(
            f"[ISG CI] TRANCHE RUN SUCCESSFUL: All {batch_size} binaries PASSED! ({elapsed:.2f}s)"
        )
        print_reproduction_commands(target, seed, failed=False)
    else:
        print(
            f"[ISG CI] TRANCHE RUN FAILED with exit code {ret} ({elapsed:.2f}s)"
        )
        failure_logs = collect_target_failure_logs(_REPO_ROOT, target)
        failed_binaries = extract_failed_binaries(
            failure_logs, echo_errors=True
        )
        print_reproduction_commands(
            target, seed, failed=True, failed_binaries=failed_binaries
        )

    print("=" * BANNER_WIDTH)
    return ret


def parse_arguments() -> argparse.Namespace:
    """Parses command-line arguments for the CI tranche runner."""
    parser = argparse.ArgumentParser(
        description="CoralNPU ISG Dynamic CI Tranche Runner"
    )
    parser.add_argument(
        "--seed",
        type=str,
        default=None,
        help=
        "Seed for the tranche. If omitted, generates a dynamic fresh seed.",
    )
    parser.add_argument(
        "--target",
        type=str,
        default=DEFAULT_TARGET,
        help=f"Bazel batch test target to run (default: {DEFAULT_TARGET})",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Number of programs in tranche (default: {DEFAULT_BATCH_SIZE})",
    )
    parser.add_argument(
        "--no-coverage-check",
        action="store_true",
        help="Skip pre-run dealt coverage closure verification",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without executing them",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help=
        "Enable verbose per-program generation, validation, and simulation output",
    )
    return parser.parse_args()


def main(ctx: Optional[ExecutionContext] = None) -> int:
    """Executes the dynamic CI tranche runner workflow."""
    exec_ctx = ctx or ExecutionContext()
    args = parse_arguments()

    seed, dynamic = generate_seed(args.seed, exec_ctx)
    now_utc = exec_ctx.utc_timestamp()

    print_banner(args.target, args.batch_size, seed, dynamic, now_utc)

    if not args.no_coverage_check:
        verify_tranche_coverage(seed, args.batch_size)

    if args.dry_run:
        print("\n[ISG CI] Dry run complete.")
        return 0

    return execute_tranche(
        args.target, seed, args.batch_size, exec_ctx, verbose=args.verbose
    )


if __name__ == "__main__":
    sys.exit(main())
