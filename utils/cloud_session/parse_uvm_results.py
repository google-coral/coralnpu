#!/usr/bin/env python3
"""Collects results of Verilator UVM batch tests (verilator_batch_uvm_test).

For each target it reads Bazel's status line from the `bazel test` log, the
per-program `Result: PASS|FAIL - <reason>` lines that utils/uvm_batch_runner.py
writes to test.log, and, where the runner kept its logs (it copies them to the
test outputs only when every program passed), the simulation time printed on
the `** UVM TEST PASSED|FAILED **` line. The UVM testbench prints times in ps.

usage: parse_uvm_results.py BAZEL_LOG TARGETS_FILE TESTLOGS_DIR OUT_PREFIX
Writes OUT_PREFIX.csv (one row per program) and OUT_PREFIX.log (a readable
summary with every failure's reason).
"""
import collections
import csv
import glob
import os
import re
import sys

STATUS_RE = re.compile(
    r"^(//\S+)\s+(?:\(cached\)\s+)?(PASSED|FAILED|TIMEOUT|FLAKY|NO STATUS|FAILED TO BUILD|"
    r"SKIPPED|INCOMPLETE)\b(?: in ([\d.]+)s)?"
)
RUNNING_RE = re.compile(r"Running UVM for (\S+?)\.\.\.")
RESULT_RE = re.compile(r"Result: (PASS|FAIL) - (.*)$")
END_RE = re.compile(r"@\s*(\d+):.*\*\* UVM TEST (PASSED|FAILED) \*\*")
TIME_RE = re.compile(r"@\s*(\d+):")


def sim_times(outputs_dir):
    """Maps a program's log file name to the simulation time (ps) it ended at."""
    times = {}
    for path in glob.glob(os.path.join(outputs_dir, "uvm_regression_batch",
                                       "logs", "*.log")):
        if os.path.basename(path) == "regression.log":
            continue
        last = None
        for line in open(path, errors="replace"):
            m = END_RE.search(line)
            if m:
                last = int(m.group(1))
        times[os.path.basename(path)] = last
    return times


def label_to_fname(label):
    return label.replace("//", "").replace(":", "_").replace("/", "_") + ".log"


def main():
    log, targets_file, testlogs, out = sys.argv[1:5]
    targets = [t.strip() for t in open(targets_file) if t.strip()]
    status = {}
    for line in open(log, errors="replace"):
        m = STATUS_RE.match(line)
        if m:
            status[m.group(1)
                   ] = (m.group(2), float(m.group(3)) if m.group(3) else None)

    rows = []
    for t in targets:
        pkg, name = t[2:].split(":")
        st, wall = status.get(t, ("NOT RUN", None))
        tdir = os.path.join(testlogs, pkg, name)
        times = sim_times(os.path.join(tdir, "test.outputs"))
        programs = []
        current = None
        errors = []
        logf = os.path.join(tdir, "test.log")
        if os.path.exists(logf):
            for line in open(logf, errors="replace"):
                m = RUNNING_RE.search(line)
                if m:
                    current = m.group(1)
                    errors = []
                    continue
                m = RESULT_RE.search(line)
                if m and current:
                    programs.append(
                        (current, m.group(1), m.group(2).strip(), errors)
                    )
                    current = None
                    continue
                if current and " - ERROR - " in line:
                    errors.append(line.split(" - ERROR - ", 1)[1].strip())
        if not programs:
            rows.append(
                dict(
                    bazel_target=t,
                    bazel_status=st,
                    bazel_test_wall_s=wall,
                    program="",
                    result="NO RESULT",
                    reason="no `Result:` line in test.log",
                    sim_time_ps="",
                    errors=""
                )
            )
        for prog, result, reason, errs in programs:
            ps = times.get(label_to_fname(prog))
            if ps is None:
                # Failed batches keep no logs; fall back to the time on the
                # first error the runner echoed, if any.
                for e in errs:
                    m = TIME_RE.search(e)
                    if m:
                        ps = int(m.group(1))
                        break
            rows.append(
                dict(
                    bazel_target=t,
                    bazel_status=st,
                    bazel_test_wall_s=wall,
                    program=prog,
                    result=result,
                    reason="" if reason == "None" else reason,
                    sim_time_ps="" if ps is None else ps,
                    errors=" | ".join(errs[:5])
                )
            )

    with open(out + ".csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    by_status = collections.Counter(
        status.get(t, ("NOT RUN", ))[0] for t in targets
    )
    by_result = collections.Counter(r["result"] for r in rows)
    with open(out + ".log", "w") as f:
        f.write("Verilator UVM regression (verilator_batch_uvm_test)\n")
        f.write(f"targets: {len(targets)}  bazel: {dict(by_status)}\n")
        f.write(f"programs: {len(rows)}  results: {dict(by_result)}\n")
        total_ps = sum(
            r["sim_time_ps"] for r in rows if r["sim_time_ps"] != ""
        )
        f.write(
            f"total simulated time: {total_ps} ps ({total_ps / 1e6:.3f} us)\n\n"
        )
        f.write("== By package ==\n")
        f.write(
            f"{'PROGRAMS':>8s} {'PASS':>5s} {'SIM TIME (us)':>14s} {'BAZEL (s)':>10s}  PACKAGE\n"
        )
        packages = collections.defaultdict(lambda: [0, 0, 0, 0.0])
        for r in rows:
            p = packages[r["bazel_target"][2:].split(":")[0]]
            p[0] += 1
            p[1] += r["result"] == "PASS"
            p[2] += r["sim_time_ps"] or 0
            p[3] += r["bazel_test_wall_s"] or 0
        for pkg, (n, ok, ps, wall) in sorted(packages.items(),
                                             key=lambda kv: -kv[1][0]):
            f.write(f"{n:8d} {ok:5d} {ps / 1e6:14.2f} {wall:10.1f}  {pkg}\n")
        f.write("\n== Failures ==\n")
        if all(r["result"] == "PASS" for r in rows):
            f.write("(none)\n")
        for r in rows:
            if r["result"] != "PASS":
                f.write(
                    f"{r['result']:9s} {r['bazel_target']}  program={r['program'] or '-'}  "
                    f"bazel={r['bazel_status']}\n    reason: {r['reason']}\n"
                )
                if r["errors"]:
                    f.write(f"    errors: {r['errors']}\n")
        f.write("\n== All programs ==\n")
        f.write(
            f"{'RESULT':9s} {'SIM TIME (ps)':>14s} {'BAZEL (s)':>9s}  TARGET\n"
        )
        for r in sorted(rows, key=lambda r: r["bazel_target"]):
            f.write(
                f"{r['result']:9s} {str(r['sim_time_ps']):>14s} "
                f"{str(r['bazel_test_wall_s'] or ''):>9s}  {r['bazel_target']}\n"
            )

    print("targets:", len(targets), dict(by_status))
    print("programs:", dict(by_result))


if __name__ == "__main__":
    main()
