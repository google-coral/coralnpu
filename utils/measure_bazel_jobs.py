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
"""Measures OS process and runnable-thread concurrency under Bazel.

Wraps a `bazel build` or `bazel test` command, samples `/proc` descendants of
`bazel info server_pid`, and correlates OS process and thread counts against
Bazel's JSON trace profile (`--profile`).

Usage:
  python3 utils/measure_bazel_jobs.py -- \
    bazel build --jobs=32 --disk_cache= --remote_cache= \
      //tests/cocotb:rvv_core_mini_axi_model
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import gzip
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any


def read_proc_stat(stat_path: str) -> tuple[int, str, str, int] | None:
    """Parses (ppid, comm, state, num_threads) from a Linux /proc stat file."""
    try:
        with open(stat_path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    lparen = data.find(b"(")
    rparen = data.rfind(b")")
    if lparen == -1 or rparen == -1 or rparen <= lparen:
        return None
    comm = data[lparen + 1:rparen].decode("utf-8", errors="replace")
    rest = data[rparen + 2:].split()
    if len(rest) < 18:
        return None
    state = rest[0].decode("ascii", errors="replace")
    try:
        ppid = int(rest[1])
        num_threads = int(rest[17])
    except ValueError:
        return None
    return ppid, comm, state, num_threads


def count_runnable_tasks(pid: int, proc_root: str = "/proc") -> int:
    """Counts threads in R or D kernel state under <proc_root>/<pid>/task."""
    runnable = 0
    task_dir = os.path.join(proc_root, str(pid), "task")
    try:
        tids = os.listdir(task_dir)
    except OSError:
        return 0
    for tid in tids:
        parsed = read_proc_stat(os.path.join(task_dir, tid, "stat"))
        if parsed is not None and parsed[2] in ("R", "D"):
            runnable += 1
    return runnable


def _read_cmdline(pid: int, proc_root: str = "/proc") -> str:
    try:
        with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as f:
            raw = f.read(512)
        parts = [
            p.decode("utf-8", errors="replace")
            for p in raw.split(b"\x00")
            if p
        ]
        return " ".join(parts)
    except OSError:
        return ""


def sample_tree(server_pid: int, proc_root: str = "/proc") -> dict[str, Any]:
    """Samples all descendant processes and threads of server_pid."""
    children: dict[int, list[int]] = defaultdict(list)
    proc_info: dict[int, tuple[int, str, str, int]] = {}

    try:
        entries = os.listdir(proc_root)
    except OSError:
        return {}

    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        parsed = read_proc_stat(os.path.join(proc_root, entry, "stat"))
        if parsed is not None:
            proc_info[pid] = parsed
            children[parsed[0]].append(pid)

    if server_pid not in proc_info:
        return {}

    direct_slots = children.get(server_pid, [])
    total_procs = 0
    total_threads = 0
    total_runnable = 0
    slot_summaries = []

    for slot_pid in direct_slots:
        stack = [slot_pid]
        slot_procs = 0
        slot_threads = 0
        slot_runnable = 0
        leaf_comms: dict[str, int] = defaultdict(int)
        while stack:
            cur = stack.pop()
            info = proc_info.get(cur)
            if info is None:
                continue
            _, comm, _, nthreads = info
            slot_procs += 1
            slot_threads += nthreads
            slot_runnable += count_runnable_tasks(cur, proc_root=proc_root)
            kids = children.get(cur, [])
            if not kids:
                leaf_comms[comm] += 1
            else:
                stack.extend(kids)
        total_procs += slot_procs
        total_threads += slot_threads
        total_runnable += slot_runnable
        slot_summaries.append({
            "slot_pid":
            slot_pid,
            "comm":
            proc_info[slot_pid][1],
            "procs":
            slot_procs,
            "threads":
            slot_threads,
            "runnable":
            slot_runnable,
            "leaves":
            dict(leaf_comms),
            "cmdline":
            _read_cmdline(slot_pid, proc_root=proc_root)[:160],
        })

    return {
        "ts": time.monotonic(),
        "active_slots": len(direct_slots),
        "total_procs": total_procs,
        "total_threads": total_threads,
        "total_runnable": total_runnable,
        "slots": slot_summaries,
    }


def analyze_bazel_profile(profile_path: str) -> dict[str, Any]:
    """Computes peak action and per-mnemonic concurrency from a Bazel trace."""
    if not os.path.exists(profile_path):
        return {}
    try:
        with gzip.open(profile_path, "rt", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:  # noqa: BLE001
        try:
            with open(profile_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:  # noqa: BLE001
            return {}

    events = data.get("traceEvents", [])
    intervals: list[tuple[int, int, str]] = []
    mnemonic_counts: dict[str, int] = defaultdict(int)
    peak_local_cpu_usage = 0.0

    for ev in events:
        cat = ev.get("cat")
        if cat == "action processing" and "ts" in ev and "dur" in ev:
            ts = int(ev["ts"])
            dur = int(ev["dur"])
            mnemonic = ev.get("args", {}).get("mnemonic", ev.get("name", "?"))
            mnemonic_counts[mnemonic] += 1
            intervals.append((ts, 1, mnemonic))
            intervals.append((ts + dur, -1, mnemonic))
        elif ev.get("ph") == "C" and ev.get("name") == "CPU usage (Bazel)":
            val = ev.get("args", {}).get("cpu")
            if isinstance(val, (int, float)) and val > peak_local_cpu_usage:
                peak_local_cpu_usage = float(val)

    intervals.sort(key=lambda x: (x[0], x[1]))
    cur = 0
    peak_concurrent_actions = 0
    cur_by_mnemonic: dict[str, int] = defaultdict(int)
    peak_by_mnemonic: dict[str, int] = defaultdict(int)
    for _, delta, mnemonic in intervals:
        cur += delta
        cur_by_mnemonic[mnemonic] += delta
        if cur > peak_concurrent_actions:
            peak_concurrent_actions = cur
        if cur_by_mnemonic[mnemonic] > peak_by_mnemonic[mnemonic]:
            peak_by_mnemonic[mnemonic] = cur_by_mnemonic[mnemonic]

    return {
        "peak_concurrent_bazel_actions":
        peak_concurrent_actions,
        "peak_bazel_cpu_cores":
        round(peak_local_cpu_usage, 2),
        "peak_concurrent_by_mnemonic":
        dict(
            sorted(peak_by_mnemonic.items(), key=lambda kv:
                   (-kv[1], kv[0]))[:15]
        ),
        "mnemonic_counts":
        dict(
            sorted(mnemonic_counts.items(), key=lambda kv:
                   (-kv[1], kv[0]))[:15]
        ),
    }


def percentile(vals: list[int], pct: float) -> int:
    """Returns the nearest-rank percentile of an integer series."""
    if not vals:
        return 0
    ordered = sorted(vals)
    idx = min(len(ordered) - 1, int(round((pct / 100.0) * (len(ordered) - 1))))
    return ordered[idx]


def inject_profile_flag(cmd: list[str], profile_path: str) -> list[str]:
    """Inserts --profile=<profile_path> after the Bazel subcommand."""
    injected = list(cmd)
    if len(injected) >= 2 and not any(a.startswith("--profile=")
                                      for a in injected):
        injected[2:2] = [f"--profile={profile_path}"]
    return injected


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--interval-ms",
        type=int,
        default=100,
        help="Sampling interval in milliseconds (default: 100).",
    )
    parser.add_argument(
        "--profile-out",
        type=str,
        default="",
        help="Optional path to retain Bazel JSON trace profile (.gz).",
    )
    parser.add_argument(
        "--json-out",
        type=str,
        default="",
        help="Optional path to write full summary JSON.",
    )
    parser.add_argument(
        "cmd",
        nargs=argparse.REMAINDER,
        help="Bazel command after '--'.",
    )
    args = parser.parse_args(argv)
    cmd = list(args.cmd)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        parser.error("Provide a bazel command after '--'.")

    workspace_dir = os.environ.get("BUILD_WORKING_DIRECTORY", "")
    if workspace_dir and os.path.isdir(workspace_dir):
        os.chdir(workspace_dir)

    server_pid = int(
        subprocess.check_output([cmd[0], "info", "server_pid"],
                                text=True).strip()
    )

    cleanup_profile = False
    profile_path = args.profile_out
    if not profile_path:
        fd, profile_path = tempfile.mkstemp(
            prefix="bazel_concurrency_", suffix=".profile.gz"
        )
        os.close(fd)
        cleanup_profile = True

    injected_cmd = inject_profile_flag(cmd, profile_path)

    samples: list[dict[str, int]] = []
    stop_event = threading.Event()
    worst_single_slot_procs: dict[str, Any] | None = None
    worst_single_slot_threads: dict[str, Any] | None = None

    def _sampler() -> None:
        nonlocal worst_single_slot_procs, worst_single_slot_threads
        interval_sec = max(0.02, args.interval_ms / 1000.0)
        while not stop_event.is_set():
            snap = sample_tree(server_pid)
            if snap:
                samples.append({
                    "active_slots": snap["active_slots"],
                    "total_procs": snap["total_procs"],
                    "total_threads": snap["total_threads"],
                    "total_runnable": snap["total_runnable"],
                })
                for sl in snap["slots"]:
                    if (worst_single_slot_procs is None
                            or sl["procs"] > worst_single_slot_procs["procs"]):
                        worst_single_slot_procs = sl
                    if (worst_single_slot_threads is None or sl["threads"]
                            > worst_single_slot_threads["threads"]):
                        worst_single_slot_threads = sl
            stop_event.wait(interval_sec)

    sampler_thread = threading.Thread(target=_sampler, daemon=True)
    sampler_thread.start()
    t0 = time.monotonic()
    rc = subprocess.call(injected_cmd)
    elapsed = time.monotonic() - t0
    stop_event.set()
    sampler_thread.join(timeout=2.0)

    prof = analyze_bazel_profile(profile_path)
    if cleanup_profile and os.path.exists(profile_path):
        os.remove(profile_path)

    runnable_series = [s["total_runnable"] for s in samples]
    proc_series = [s["total_procs"] for s in samples]
    thread_series = [s["total_threads"] for s in samples]
    slot_series = [s["active_slots"] for s in samples]

    report = {
        "exit_code": rc,
        "elapsed_sec": round(elapsed, 2),
        "samples_collected": len(samples),
        "bazel_server_pid": server_pid,
        "peak_active_server_children": max(slot_series, default=0),
        "peak_descendant_processes": max(proc_series, default=0),
        "p95_descendant_processes": percentile(proc_series, 95),
        "peak_descendant_threads": max(thread_series, default=0),
        "p95_descendant_threads": percentile(thread_series, 95),
        "peak_runnable_threads_R_or_D": max(runnable_series, default=0),
        "p95_runnable_threads_R_or_D": percentile(runnable_series, 95),
        "worst_single_action_by_procs": worst_single_slot_procs,
        "worst_single_action_by_threads": worst_single_slot_threads,
        "bazel_profile": prof,
    }

    print("\n=== Bazel Concurrency Measurement Summary ===", file=sys.stderr)
    print(json.dumps(report, indent=2), file=sys.stderr)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as jf:
            json.dump(report, jf, indent=2)

    return rc


if __name__ == "__main__":
    sys.exit(main())
