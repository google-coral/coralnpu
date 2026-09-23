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
"""Continuous and Duration-Based Hammer Stress Test Runner for CoralNPU ISG.

This tool executes back-to-back tranches of randomized ISG programs under 3-way
lockstep co-simulation (CoralNPU RTL vs MPACT ISS vs Spike DPI-C) using dynamic
fresh seeds to uncover rare pipeline hazards and microarchitectural edge cases
via the law of large numbers.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import subprocess
import sys
import time
import types
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, List, Mapping, Optional, Sequence

# Workspace root: set by `bazel run`; otherwise derived from this file's
# location in the source tree.
_REPO_ROOT = os.environ.get("BUILD_WORKSPACE_DIRECTORY") or str(
    Path(__file__).resolve().parent.parent.parent
)
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from tests.isg.gen.dealt import load_alphabet
from tests.isg.validate.coverage import (
    find_alphabet_path,
    verify_stream_batch_coverage,
)
from tests.isg.validate.triage import (
    collect_target_failure_logs,
    extract_failed_binaries as _extract_failed_binaries,
    format_filtered_batch_command,
    format_single_program_target,
)

DEFAULT_BATCH_SIZE: int = 50
DEFAULT_PROGRAM_LENGTH: int = 64
DEFAULT_TRAP_RATE: float = 0.05
DEFAULT_SHAPING: str = "distributed"
DEFAULT_DURATION_MINUTES: float = 30.0
DEFAULT_TARGET: str = "//tests/isg:isg_ci_50_uvm"
DEFAULT_PREFIX: str = "hammer"

BANNER_WIDTH: int = 72
SECONDS_PER_MINUTE: float = 60.0
EXIT_INTERRUPTED: int = 130
EXIT_SUCCESS: int = 0
EXIT_FAILURE: int = 1
RANDOM_SUFFIX_MIN: int = 1000
RANDOM_SUFFIX_MAX: int = 9999
NS_PER_SECOND: int = 1_000_000_000

# Global cancellation flag for clean signal handling
_INTERRUPTED = False


@dataclass(frozen=True)
class ExecutionContext:
    """Execution context providing clock and seed generator dependencies."""

    monotonic_clock: Callable[[], float] = time.monotonic
    epoch_clock: Callable[[],
                          int] = lambda: int(time.time_ns() // NS_PER_SECOND)
    rand_range: Callable[[int, int], int] = random.randrange
    utc_timestamp: Callable[
        [],
        str] = lambda: time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


@dataclass(frozen=True)
class TrancheResult:
    """Outcome of an individual tranche run."""

    index: int
    seed: str
    passed: bool
    elapsed: float
    failed_binaries: List[str]
    output: str = ""


HammerSummary = Mapping[str, object]


def _signal_handler(sig: int, frame: Optional[types.FrameType]) -> None:
    """Handles external interruption signals gracefully."""
    del sig, frame
    global _INTERRUPTED
    if not _INTERRUPTED:
        print(
            "\n[Hammer] Interruption signal received (Ctrl+C). Completing summary...",
            flush=True,
        )
        _INTERRUPTED = True
    else:
        print("\n[Hammer] Forced exit requested.", flush=True)
        sys.exit(EXIT_INTERRUPTED)


def extract_failed_binaries(stdout: str) -> List[str]:
    """Parses CoralFlow simulation logs to identify failed test binaries."""
    return _extract_failed_binaries(stdout, echo_errors=True)


def print_reproduction_commands(
    target: str,
    seed: str,
    failed_binaries: List[str],
) -> None:
    """Prints reproduction commands for failed tranches or binaries."""
    print("--- Failure Repro Command(s) ---", flush=True)
    if failed_binaries:
        for fb in failed_binaries:
            single_target = format_single_program_target(target, fb)
            print(
                f"  bazel test {single_target} --//tests/isg:isg_seed={seed}",
                flush=True,
            )
        if len(failed_binaries) > 1:
            batch_cmd = format_filtered_batch_command(
                target, failed_binaries, seed
            )
            if batch_cmd:
                print(
                    "  # Or re-run failing subset in one batched sim:",
                    flush=True
                )
                print(f"  {batch_cmd}", flush=True)
    else:
        print(
            f"  bazel test {target} --//tests/isg:isg_seed={seed}", flush=True
        )
    print("--------------------------------\n", flush=True)


def run_tranche(
    target: str,
    batch_size: int,
    idx: int,
    seed: str,
    ctx: ExecutionContext,
    verbose: bool = False,
) -> TrancheResult:
    """Runs a single tranche of tests in lockstep co-simulation."""
    print(
        f"\n[{idx+1:04d}] Launching tranche with seed: {seed} ({batch_size} binaries)...",
        flush=True,
    )
    start = ctx.monotonic_clock()
    cmd = [
        "bazel",
        "test",
        target,
        f"--//tests/isg:isg_seed={seed}",
        "--test_output=all" if verbose else "--test_output=errors",
    ]
    if verbose:
        cmd.extend([
            "--//tests/isg:isg_verbose=true",
            "--test_env=ISG_VERBOSE=1",
        ])
    proc = subprocess.run(
        cmd,
        cwd=_REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    elapsed = ctx.monotonic_clock() - start
    if verbose and proc.stdout:
        print(proc.stdout, flush=True)

    passed = proc.returncode == 0
    status_str = f"PASSED ({batch_size}/{batch_size})" if passed else "FAILED"
    print(f"[{idx+1:04d}] Result: {status_str} in {elapsed:.1f}s", flush=True)

    failed_binaries: List[str] = []
    combined_logs = proc.stdout or ""
    if not passed:
        print("\n--- Failure Detected in Tranche ---", flush=True)
        combined_logs = collect_target_failure_logs(
            _REPO_ROOT, target, stdout=proc.stdout or ""
        )
        failed_binaries = extract_failed_binaries(combined_logs)
        print_reproduction_commands(target, seed, failed_binaries)

    return TrancheResult(
        index=idx + 1,
        seed=seed,
        passed=passed,
        elapsed=elapsed,
        failed_binaries=failed_binaries,
        output=combined_logs if not passed else "",
    )


def verify_hammer_coverage(batch_size: int) -> None:
    """Performs preflight coverage verification across all opcodes and shaping modes."""
    alphabet_path = find_alphabet_path()
    if not alphabet_path:
        return

    instructions, _ = load_alphabet(str(alphabet_path))
    report = verify_stream_batch_coverage(
        alphabet=instructions,
        batch_size=batch_size,
        length=DEFAULT_PROGRAM_LENGTH,
        shaping=DEFAULT_SHAPING,
        trap_rate=DEFAULT_TRAP_RATE,
        seed="hammer_preflight",
    )
    if not report["is_complete"]:
        sys.stderr.write(
            f"[Hammer] ERROR: Opcode coverage check failed! Missing: {report['missing_opcodes']}\n"
        )
        sys.exit(EXIT_FAILURE)
    if not report.get("is_shape_complete", True):
        sys.stderr.write(
            f"[Hammer] ERROR: Shape coverage check failed! Missing shapes: {report.get('missing_shaping_modes')}\n"
        )
        sys.exit(EXIT_FAILURE)

    print(
        f"[Hammer] Preflight: 100.0% opcode coverage ({report['covered_alphabet_count']}/{report['alphabet_size']}) & 100.0% shape coverage ({len(report['covered_shaping_modes'])}/{len(report['target_shaping_modes'])} modes) verified.",
        flush=True,
    )


def print_start_banner(
    target: str,
    duration_minutes: float,
    target_duration_sec: float,
    batch_size: int,
    max_tranches: Optional[int],
    stop_on_fail: bool,
    start_utc: str,
) -> None:
    """Prints hammer start banner and configuration."""
    print("=" * BANNER_WIDTH, flush=True)
    print(" CoralNPU ISG Continuous Hammer Stress Runner", flush=True)
    print("=" * BANNER_WIDTH, flush=True)
    print(f"Target Suite:         {target}")
    if duration_minutes > 0.0:
        print(
            f"Target Duration:      {duration_minutes:.1f} minutes ({target_duration_sec:.0f}s)"
        )
    else:
        print("Target Duration:      Continuous (until interrupted)")
    print(f"Batch Size:           {batch_size} programs per tranche")
    print(f"Max Tranches:         {max_tranches or 'Unlimited'}")
    print(f"Stop on Fail:         {stop_on_fail}")
    print(f"Start Time:           {start_utc}")
    print("=" * BANNER_WIDTH, flush=True)


def print_progress_status(
    results: Sequence[TrancheResult],
    batch_size: int,
    duration_minutes: float,
    elapsed_now: float,
    target_duration_sec: float,
) -> None:
    """Prints live cumulative pass/fail progress during execution."""
    cum_passed = sum(1 for r in results if r.passed)
    cum_programs = len(results) * batch_size
    cum_pct = (
        cum_passed * batch_size / cum_programs * 100.0
    ) if cum_programs else 0.0
    elapsed_min = elapsed_now / SECONDS_PER_MINUTE
    if duration_minutes > 0.0:
        remaining_sec = max(0.0, target_duration_sec - elapsed_now)
        rem_min = remaining_sec / SECONDS_PER_MINUTE
        print(
            f"  >>> Progress: {len(results)} tranches ({cum_programs} binaries) | Pass: {cum_pct:.1f}% | Elapsed: {elapsed_min:.1f}m / {duration_minutes:.1f}m | Remaining: {rem_min:.1f}m",
            flush=True,
        )
    else:
        print(
            f"  >>> Progress: {len(results)} tranches ({cum_programs} binaries) | Pass: {cum_pct:.1f}% | Elapsed: {elapsed_min:.1f}m",
            flush=True,
        )


def print_final_summary(
    results: Sequence[TrancheResult],
    batch_size: int,
    total_elapsed: float,
) -> None:
    """Prints final summary table across all executed tranches."""
    total_tranches = len(results)
    total_programs = total_tranches * batch_size
    passed_tranches = sum(1 for r in results if r.passed)
    failed_tranches = total_tranches - passed_tranches
    total_passed_programs = passed_tranches * batch_size
    pass_pct = (
        total_passed_programs / total_programs * 100.0
    ) if total_programs else 0.0
    elapsed_mins = total_elapsed / SECONDS_PER_MINUTE

    print("\n" + "=" * BANNER_WIDTH, flush=True)
    print(" CORALNPU ISG HAMMER STRESS RUNNER SUMMARY", flush=True)
    print("=" * BANNER_WIDTH, flush=True)
    print(f"Total Tranches:       {total_tranches}")
    print(f"Total Binaries:       {total_programs}")
    print(f"Passed Tranches:      {passed_tranches} / {total_tranches}")
    print(f"Failed Tranches:      {failed_tranches} / {total_tranches}")
    print(
        f"Program Pass Rate:    {pass_pct:.2f}% ({total_passed_programs}/{total_programs})"
    )
    print(
        f"Total Wall Time:      {total_elapsed:.1f}s ({elapsed_mins:.2f} mins)"
    )
    if total_tranches > 0:
        print(f"Avg Time Per Tranche: {total_elapsed/total_tranches:.1f}s")
    print("=" * BANNER_WIDTH, flush=True)


def save_summary_log(path: Optional[str], summary_data: HammerSummary) -> None:
    """Writes machine-readable JSON summary log if requested."""
    if not path:
        return
    with open(path, "w", encoding="utf-8") as f:
        json.dump(summary_data, f, indent=2)
    print(f"[Hammer] Summary report saved to {path}", flush=True)


def should_terminate_loop(
    elapsed_so_far: float,
    target_duration_sec: float,
    duration_minutes: float,
    tranche_idx: int,
    max_tranches: Optional[int],
) -> bool:
    """Evaluates whether hammer termination criteria have been met."""
    if duration_minutes > 0.0 and elapsed_so_far >= target_duration_sec:
        rem_min = elapsed_so_far / SECONDS_PER_MINUTE
        print(
            f"\n[Hammer] Target duration reached ({rem_min:.2f} mins >= {duration_minutes:.1f} mins).",
            flush=True,
        )
        return True
    if max_tranches and tranche_idx >= max_tranches:
        print(
            f"\n[Hammer] Maximum tranches reached ({tranche_idx} >= {max_tranches}).",
            flush=True,
        )
        return True
    return False


def parse_arguments() -> argparse.Namespace:
    """Parses command-line arguments for the hammer stress runner."""
    parser = argparse.ArgumentParser(
        description="Continuous & Duration-Based ISG Hammer Stress Test Runner"
    )
    parser.add_argument(
        "--duration-minutes",
        type=float,
        default=DEFAULT_DURATION_MINUTES,
        help=
        f"Target test duration in minutes (default: {DEFAULT_DURATION_MINUTES}, 0 for continuous)",
    )
    parser.add_argument(
        "--continuous",
        action="store_true",
        help=
        "Run indefinitely until interrupted (equivalent to --duration-minutes 0)",
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
        help=f"Programs per tranche (default: {DEFAULT_BATCH_SIZE})",
    )
    parser.add_argument(
        "--max-tranches",
        type=int,
        default=None,
        help="Maximum number of tranches to execute (default: unlimited)",
    )
    parser.add_argument(
        "--stop-on-fail",
        dest="stop_on_fail",
        action="store_true",
        default=True,
        help="Stop immediately on first failing tranche (default: True)",
    )
    parser.add_argument(
        "--no-stop-on-fail",
        dest="stop_on_fail",
        action="store_false",
        help="Continue running even if a tranche fails",
    )
    parser.add_argument(
        "--output-json",
        type=str,
        default=None,
        help="Optional path to write JSON summary log",
    )
    parser.add_argument(
        "--prefix",
        type=str,
        default=DEFAULT_PREFIX,
        help=f"Seed prefix string (default: {DEFAULT_PREFIX})",
    )
    parser.add_argument(
        "--no-coverage-check",
        action="store_true",
        help="Skip pre-run coverage and shape distribution verification",
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
    """Main execution loop for continuous and duration-based stress testing."""
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    exec_ctx = ctx or ExecutionContext()
    args = parse_arguments()

    duration_minutes = 0.0 if args.continuous else args.duration_minutes
    target_duration_sec = duration_minutes * SECONDS_PER_MINUTE
    start_utc = exec_ctx.utc_timestamp()

    print_start_banner(
        args.target,
        duration_minutes,
        target_duration_sec,
        args.batch_size,
        args.max_tranches,
        args.stop_on_fail,
        start_utc,
    )

    if not args.no_coverage_check:
        verify_hammer_coverage(args.batch_size)

    results: List[TrancheResult] = []
    total_start = exec_ctx.monotonic_clock()
    tranche_idx = 0

    while not _INTERRUPTED:
        elapsed_so_far = exec_ctx.monotonic_clock() - total_start
        if should_terminate_loop(
                elapsed_so_far,
                target_duration_sec,
                duration_minutes,
                tranche_idx,
                args.max_tranches,
        ):
            break

        epoch = exec_ctx.epoch_clock()
        rand_suffix = exec_ctx.rand_range(RANDOM_SUFFIX_MIN, RANDOM_SUFFIX_MAX)
        seed = f"{args.prefix}_{tranche_idx+1:04d}_{epoch}_{rand_suffix}"
        res = run_tranche(
            args.target,
            args.batch_size,
            tranche_idx,
            seed,
            exec_ctx,
            verbose=args.verbose,
        )
        results.append(res)
        tranche_idx += 1

        elapsed_now = exec_ctx.monotonic_clock() - total_start
        print_progress_status(
            results, args.batch_size, duration_minutes, elapsed_now,
            target_duration_sec
        )

        if not res.passed and args.stop_on_fail:
            print(
                "[Hammer] Stopping execution immediately due to failed tranche (--stop-on-fail active).",
                flush=True,
            )
            break

    total_elapsed = exec_ctx.monotonic_clock() - total_start
    print_final_summary(results, args.batch_size, total_elapsed)

    failed_tranches = sum(1 for r in results if not r.passed)
    summary_data = {
        "target": args.target,
        "duration_minutes": duration_minutes,
        "total_elapsed_seconds": total_elapsed,
        "total_tranches": len(results),
        "total_binaries": len(results) * args.batch_size,
        "passed_tranches": len(results) - failed_tranches,
        "failed_tranches": failed_tranches,
        "results": [asdict(r) for r in results],
    }
    save_summary_log(args.output_json, summary_data)

    return EXIT_FAILURE if failed_tranches > 0 else EXIT_SUCCESS


if __name__ == "__main__":
    sys.exit(main())
