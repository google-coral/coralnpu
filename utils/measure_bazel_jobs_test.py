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
"""Unit tests for measure_bazel_jobs."""

import gzip
import json
import os
import tempfile
import unittest

from utils.measure_bazel_jobs import (
    analyze_bazel_profile,
    inject_profile_flag,
    percentile,
    read_proc_stat,
    sample_tree,
)


def _write_fake_proc(
    proc_root: str,
    pid: int,
    ppid: int,
    comm: str,
    state: str = "S",
    task_states: list[str] | None = None,
    cmdline: str = "",
) -> None:
    states = task_states if task_states is not None else [state]
    pid_dir = os.path.join(proc_root, str(pid))
    task_root = os.path.join(pid_dir, "task")
    os.makedirs(task_root, exist_ok=True)

    def _stat_line(tid: int, st: str, nthreads: int) -> str:
        # Fields after '(comm) ': state(0) ppid(1) ... num_threads(17)
        fields = [st, str(ppid)] + ["0"] * 15 + [str(nthreads), "0", "0"]
        return f"{tid} ({comm}) " + " ".join(fields) + "\n"

    with open(os.path.join(pid_dir, "stat"), "w", encoding="utf-8") as f:
        f.write(_stat_line(pid, states[0], len(states)))
    with open(os.path.join(pid_dir, "cmdline"), "wb") as f:
        f.write(cmdline.replace(" ", "\x00").encode("utf-8"))

    for idx, st in enumerate(states):
        tid = pid * 100 + idx
        tid_dir = os.path.join(task_root, str(tid))
        os.makedirs(tid_dir, exist_ok=True)
        with open(os.path.join(tid_dir, "stat"), "w", encoding="utf-8") as f:
            f.write(_stat_line(tid, st, len(states)))


class MeasureBazelJobsTest(unittest.TestCase):
    """Tests /proc tree sampling and Bazel Chrome trace profile parsing."""

    def test_read_proc_stat_handles_spaces_and_parens_in_comm(self):
        with tempfile.TemporaryDirectory() as tmp:
            _write_fake_proc(
                tmp,
                pid=42,
                ppid=10,
                comm="java (worker)",
                state="R",
                task_states=["R", "S", "D"],
            )
            parsed = read_proc_stat(os.path.join(tmp, "42", "stat"))
            self.assertEqual(parsed, (10, "java (worker)", "R", 3))

    def test_sample_tree_aggregates_descendants_and_runnable_tasks(self):
        with tempfile.TemporaryDirectory() as tmp:
            # Unrelated process outside server_pid subtree
            _write_fake_proc(
                tmp, pid=50, ppid=1, comm="sshd", task_states=["R", "R"]
            )
            # Bazel server root
            _write_fake_proc(
                tmp,
                pid=100,
                ppid=1,
                comm="bazel(coralnpu)",
                task_states=["S"]
            )
            # Slot 1: linux-sandbox -> make -> 2 clang leaf processes
            _write_fake_proc(
                tmp,
                pid=200,
                ppid=100,
                comm="linux-sandbox",
                task_states=["S"],
                cmdline="linux-sandbox -W /tmp/s1",
            )
            _write_fake_proc(
                tmp, pid=201, ppid=200, comm="make", task_states=["S"]
            )
            _write_fake_proc(
                tmp, pid=202, ppid=201, comm="clang++", task_states=["R"]
            )
            _write_fake_proc(
                tmp, pid=203, ppid=201, comm="clang++", task_states=["D"]
            )
            # Slot 2: persistent Scalac worker with 4 threads (1 runnable)
            _write_fake_proc(
                tmp,
                pid=300,
                ppid=100,
                comm="java",
                task_states=["R", "S", "S", "S"],
                cmdline="java -XX:ActiveProcessorCount=4 ScalaWorker",
            )

            snap = sample_tree(server_pid=100, proc_root=tmp)
            self.assertEqual(snap["active_slots"], 2)
            self.assertEqual(snap["total_procs"], 5)
            self.assertEqual(snap["total_threads"], 8)
            self.assertEqual(snap["total_runnable"], 3)

            by_pid = {s["slot_pid"]: s for s in snap["slots"]}
            self.assertEqual(by_pid[200]["procs"], 4)
            self.assertEqual(by_pid[200]["runnable"], 2)
            self.assertEqual(by_pid[200]["leaves"], {"clang++": 2})
            self.assertEqual(by_pid[300]["threads"], 4)
            self.assertEqual(by_pid[300]["runnable"], 1)

    def test_analyze_bazel_profile_computes_overlapping_concurrency(self):
        trace = {
            "traceEvents": [
                {
                    "cat": "action processing",
                    "name": "Verilate a",
                    "ts": 100,
                    "dur": 200,
                    "args": {
                        "mnemonic": "Verilate"
                    },
                },
                {
                    "cat": "action processing",
                    "name": "Verilate b",
                    "ts": 150,
                    "dur": 200,
                    "args": {
                        "mnemonic": "Verilate"
                    },
                },
                {
                    "cat": "action processing",
                    "name": "ChiselEmitVerilog c",
                    "ts": 200,
                    "dur": 50,
                    "args": {
                        "mnemonic": "ChiselEmitVerilog"
                    },
                },
                # Non-overlapping action touching boundary at ts=300
                {
                    "cat": "action processing",
                    "name": "CppCompile d",
                    "ts": 300,
                    "dur": 40,
                    "args": {
                        "mnemonic": "CppCompile"
                    },
                },
                {
                    "ph": "C",
                    "name": "CPU usage (Bazel)",
                    "ts": 210,
                    "args": {
                        "cpu": 10.0
                    },
                },
                {
                    "ph": "C",
                    "name": "CPU usage (total)",
                    "ts": 210,
                    "args": {
                        "system cpu": 48.0
                    },
                },
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            gz_path = os.path.join(tmp, "command.profile.gz")
            with gzip.open(gz_path, "wt", encoding="utf-8") as f:
                json.dump(trace, f)

            summary = analyze_bazel_profile(gz_path)
            self.assertEqual(summary["peak_concurrent_bazel_actions"], 3)
            self.assertEqual(summary["peak_bazel_cpu_cores"], 10.0)
            self.assertEqual(
                summary["peak_concurrent_by_mnemonic"]["Verilate"], 2
            )
            self.assertEqual(summary["mnemonic_counts"]["Verilate"], 2)

    def test_inject_profile_flag_and_percentile(self):
        self.assertEqual(
            inject_profile_flag(["bazel", "build", "--jobs=8", "//..."],
                                "/tmp/p.gz"),
            [
                "bazel",
                "build",
                "--profile=/tmp/p.gz",
                "--jobs=8",
                "//...",
            ],
        )
        self.assertEqual(
            inject_profile_flag(
                ["bazel", "test", "--profile=/existing.gz", "//..."],
                "/tmp/p.gz",
            ),
            ["bazel", "test", "--profile=/existing.gz", "//..."],
        )
        self.assertEqual(percentile([], 95), 0)
        self.assertEqual(percentile(list(range(1, 21)), 95), 19)


if __name__ == "__main__":
    unittest.main()
