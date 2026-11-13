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
"""Standardized nested JSON telemetry reporting for CoralFlow."""

from __future__ import annotations

import argparse
import atexit
import contextlib
import contextvars
from datetime import datetime, timezone
import json
import logging
import os
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterator, NoReturn

_DISABLED_VALUES = {"", "0", "false", "no", "off"}

# In-memory cache of telemetry reports created by the current process,
# keyed by (abs_path, suite, normalized_target).
_PROCESS_REPORTS: dict[tuple[str, str, str], dict[str, Any]] = {}
_WRITTEN_PATHS: list[str] = []

_ACTIVE_ARGV: contextvars.ContextVar[list[str] | None] = (
    contextvars.ContextVar("_ACTIVE_ARGV", default=None)
)


class _SafeArgumentParser(argparse.ArgumentParser):
    """ArgumentParser that raises ArgumentError instead of calling sys.exit."""

    def error(self, message: str) -> NoReturn:
        raise argparse.ArgumentError(None, message)


def reset_telemetry_session() -> None:
    """Clears in-process telemetry report state (primarily for unit tests)."""
    _PROCESS_REPORTS.clear()
    _WRITTEN_PATHS.clear()


@contextlib.contextmanager
def telemetry_cli_scope(argv: list[str] | None) -> Iterator[None]:
    """Scopes an explicit CLI argv list for telemetry resolution."""
    if argv is None:
        yield
        return
    token = _ACTIVE_ARGV.set(list(argv))
    try:
        yield
    finally:
        _ACTIVE_ARGV.reset(token)


def _format_display_path(path: str) -> str:
    """Formats sandbox/execroot telemetry paths into workspace-relative paths."""
    if "/execroot/" in path and "/bazel-out/" in path:
        after_bazel_out = path.split("/bazel-out/", 1)[1]
        if "/testlogs/" in after_bazel_out:
            return "bazel-testlogs/" + after_bazel_out.split("/testlogs/",
                                                             1)[1]
        return "bazel-out/" + after_bazel_out
    return path


def _print_exit_telemetry_summary() -> None:
    """Prints a prominent summary of written telemetry JSON files at process exit."""
    if not _WRITTEN_PATHS:
        return
    lines = ["=" * 88]
    for path in _WRITTEN_PATHS:
        lines.append(
            f"[CORALFLOW TELEMETRY] JSON Report: {_format_display_path(path)}"
        )
    lines.append("=" * 88)
    print("\n" + "\n".join(lines) + "\n", flush=True)


atexit.register(_print_exit_telemetry_summary)


def _find_workspace_root() -> str | None:
    """Finds the CoralNPU repository root when running via `bazel run`."""
    ws_env = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "").strip()
    if ws_env and os.path.isdir(ws_env) and os.access(ws_env, os.W_OK):
        return ws_env
    return None


def _is_path_like_override(val: str) -> bool:
    """Returns True if a CORALFLOW_TELEMETRY value looks like a file path."""
    return os.sep in val or "/" in val or val.lower().endswith(".json")


def _resolve_output_path(path: str) -> str:
    """Resolves relative output paths against BUILD_WORKING_DIRECTORY if set."""
    if not os.path.isabs(path):
        working_dir = os.environ.get("BUILD_WORKING_DIRECTORY", "").strip()
        if working_dir and os.path.isdir(working_dir):
            return os.path.abspath(os.path.join(working_dir, path))
    return os.path.abspath(path)


def _sanitize_filename_component(value: str, fallback: str) -> str:
    """Sanitizes a value for safe use as a single filename component."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip())
    cleaned = re.sub(r"\.{2,}", "_", cleaned)
    cleaned = cleaned.strip("._-")
    return cleaned or fallback


def _is_subpath(path: str, parent: str) -> bool:
    """Returns True if path lies within parent directory."""
    try:
        abs_parent = os.path.abspath(parent)
        return os.path.commonpath([os.path.abspath(path),
                                   abs_parent]) == abs_parent
    except ValueError:
        return False


def _parse_telemetry_cli_args(
    argv: list[str] | None = None,
) -> tuple[bool, str | None]:
    """Parses --telemetry and --telemetry-output CLI arguments safely."""
    parser = _SafeArgumentParser(
        add_help=False,
        allow_abbrev=False,
        exit_on_error=False,
    )
    parser.add_argument("--telemetry", action="store_true", default=False)
    parser.add_argument(
        "--telemetry-output",
        "--telemetry_output",
        dest="telemetry_output",
        default=None,
    )
    if argv is None:
        active_argv = _ACTIVE_ARGV.get()
        args_list = sys.argv[1:] if active_argv is None else active_argv
    else:
        args_list = argv

    try:
        ns, _ = parser.parse_known_args(args_list)
    except (argparse.ArgumentError, SystemExit) as exc:
        logging.warning("Ignoring malformed telemetry CLI arguments: %s", exc)
        return False, None
    return bool(ns.telemetry or ns.telemetry_output), ns.telemetry_output


def is_telemetry_enabled(argv: list[str] | None = None) -> bool:
    """Returns True if telemetry reporting is enabled via CLI flag or environment."""
    cli_enabled, _ = _parse_telemetry_cli_args(argv)
    if cli_enabled:
        return True
    if os.environ.get("CORALFLOW_TELEMETRY_OUTPUT", "").strip():
        return True
    env_val = os.environ.get("CORALFLOW_TELEMETRY", "").strip()
    return env_val.lower() not in _DISABLED_VALUES


def get_default_telemetry_path(
    suite: str = "test",
    target: str = "coralflow",
    argv: list[str] | None = None,
) -> str:
    """Resolves the target path for the telemetry JSON report."""
    _, cli_output = _parse_telemetry_cli_args(argv)
    if cli_output:
        return _resolve_output_path(cli_output)

    env_output = os.environ.get("CORALFLOW_TELEMETRY_OUTPUT", "").strip()
    if env_output:
        return _resolve_output_path(env_output)

    env_val = os.environ.get("CORALFLOW_TELEMETRY", "").strip()
    if (env_val and env_val.lower() not in _DISABLED_VALUES
            and _is_path_like_override(env_val)):
        return _resolve_output_path(env_val)

    safe_suite = _sanitize_filename_component(suite, "test")
    safe_target = _sanitize_filename_component(target.lower(), "coralflow")
    filename = f"{safe_suite}_{safe_target}.json"

    ws_root = _find_workspace_root()
    if ws_root:
        reports_dir = os.path.join(ws_root, "telemetry_reports")
        try:
            os.makedirs(reports_dir, exist_ok=True)
            if os.access(reports_dir, os.W_OK):
                return os.path.join(reports_dir, filename)
        except OSError:
            pass

    output_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", "").strip()
    if output_dir:
        return os.path.join(output_dir, "test_telemetry.json")
    return os.path.join("telemetry_reports", filename)


def get_git_commit() -> str:
    """Resolves the current Git commit SHA from environment or git rev-parse."""
    for env_key in (
            "GIT_COMMIT",
            "BUILD_SCM_REVISION",
            "CORALNPU_BUILD_GIT_VERSION",
    ):
        val = os.environ.get(env_key, "").strip()
        if val and val != "ffffffffffffffffffffffffffffffffffffffff":
            return val[:12]

    raw_cwds = (
        os.environ.get("BUILD_WORKSPACE_DIRECTORY", "").strip(),
        os.path.dirname(os.path.realpath(__file__)),
        os.getcwd(),
    )
    seen_cwds: set[str] = set()
    for candidate_cwd in raw_cwds:
        if not candidate_cwd or candidate_cwd in seen_cwds:
            continue
        seen_cwds.add(candidate_cwd)
        if not os.path.isdir(candidate_cwd):
            continue
        try:
            res = subprocess.run(
                ["git", "rev-parse", "--short=8", "HEAD"],
                cwd=candidate_cwd,
                capture_output=True,
                text=True,
                timeout=2.0,
                check=False,
            )
            if res.returncode == 0 and res.stdout.strip():
                return res.stdout.strip()
        except Exception:
            pass

    return "unknown"


def _atomic_write_json(abs_path: str, payload: dict[str, Any]) -> None:
    """Atomically writes payload as JSON using an exclusive temporary file."""
    parent_dir = os.path.dirname(abs_path) or "."
    base_name = os.path.basename(abs_path)
    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=parent_dir,
                prefix=f".{base_name}.",
                suffix=".tmp",
                delete=False,
        ) as f:
            tmp_path = f.name
            json.dump(payload, f, indent=2)
            f.write("\n")
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, abs_path)
        tmp_path = None
    finally:
        if tmp_path is not None:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def record_test_telemetry(
    suite: str,
    test_name: str,
    target: str,
    status: str,
    cycles: int | None,
    wall_time_sec: float,
    output_path: str | None = None,
    board_id: str | None = None,
    error: str | None = None,
) -> str:
    """Updates and writes the nested JSON telemetry report for the current process.

    Args:
      suite: Top-level test suite or target name.
      test_name: Individual testcase function name.
      target: Execution backend ('npusim', 'verilator', 'vcs', 'uvm', 'nexus_fpga').
      status: Execution outcome ('PASSED', 'FAILED', or 'SKIPPED').
      cycles: Total simulated/hardware core cycles, or None if unavailable.
      wall_time_sec: Host wall-clock duration in seconds.
      output_path: Optional override path for the JSON file.
      board_id: Optional physical board serial identifier when running on FPGA.
      error: Optional failure summary if status == 'FAILED'.

    Returns:
      The path to the surviving written telemetry JSON file.
    """
    normalized_target = target.lower().strip()
    raw_path = output_path or get_default_telemetry_path(
        suite=suite, target=normalized_target
    )
    abs_path = _resolve_output_path(raw_path)
    parent_dir = os.path.dirname(abs_path)
    if parent_dir:
        os.makedirs(parent_dir, exist_ok=True)

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    cache_key = (abs_path, suite, normalized_target)
    report = _PROCESS_REPORTS.get(cache_key)
    if report is None:
        report = {
            "suite": suite,
            "git_commit": get_git_commit(),
            "timestamp": now_iso,
            "target": normalized_target,
            "tests": {},
        }
        _PROCESS_REPORTS[cache_key] = report
    else:
        report["timestamp"] = now_iso

    if board_id and "board_id" not in report:
        report["board_id"] = board_id

    test_entry: dict[str, Any] = {
        "status": status,
        "cycles": int(cycles) if cycles is not None else None,
        "wall_time_sec": round(float(wall_time_sec), 4),
    }
    if error:
        test_entry["error"] = error
    report["tests"][test_name] = test_entry

    _atomic_write_json(abs_path, report)

    reported_path = abs_path
    undeclared_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", "").strip()
    if undeclared_dir and os.path.isdir(undeclared_dir):
        undeclared_file = os.path.abspath(
            os.path.join(undeclared_dir, "test_telemetry.json")
        )
        if undeclared_file != abs_path:
            try:
                _atomic_write_json(undeclared_file, report)
                ws_root = _find_workspace_root()
                if not _is_subpath(abs_path, undeclared_dir) and (
                        not ws_root or not _is_subpath(abs_path, ws_root)):
                    reported_path = undeclared_file
            except OSError as exc:
                logging.warning(
                    "Failed to mirror telemetry report to %s: %s",
                    undeclared_file,
                    exc,
                )

    if reported_path not in _WRITTEN_PATHS:
        _WRITTEN_PATHS.append(reported_path)

    return reported_path
