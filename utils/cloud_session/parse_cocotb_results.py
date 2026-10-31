#!/usr/bin/env python3
"""Collects per-target Bazel status and per-testcase cocotb results.

Reads the target lines Bazel prints after `bazel test` (PASSED, FAILED, ...)
and the cocotb summary table at the end of each target's test.log
(TEST / STATUS / SIM TIME (ns) / REAL TIME (s)). A target that Bazel passed but
whose log has no cocotb table ran no testcase at all (for example a testcase
name in BUILD that the test module does not define); it is reported as
NOT RUN.

usage: parse_cocotb_results.py BAZEL_LOG TARGETS_FILE TESTLOGS_DIR OUT_PREFIX
Writes OUT_PREFIX.csv and OUT_PREFIX.json (one row per testcase) and
OUT_PREFIX.log (a readable summary: totals, a per-package table, every
testcase that did not pass and every testcase's result).
"""
import collections
import csv
import json
import os
import re
import sys

STATUS_RE = re.compile(
    r"^(//\S+)\s+(?:\(cached\)\s+)?(PASSED|FAILED|TIMEOUT|FLAKY|NO STATUS|FAILED TO BUILD|"
    r"SKIPPED|INCOMPLETE)\b(?: in ([\d.]+)s)?"
)
ROW_RE = re.compile(
    r"\*\*\s+(\S+)\s+(PASS|FAIL|SKIP)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+\*\*"
)


def num(v):
    return v if v != "" else 0


def write_summary(path, targets, status, rows):
    by_status = collections.Counter(
        status.get(t, ("NOT RUN", ))[0] for t in targets
    )
    by_result = collections.Counter(r["cocotb_result"] for r in rows)
    total_ns = sum(num(r["sim_time_ns"]) for r in rows)
    total_s = sum(num(r["cocotb_real_time_s"]) for r in rows)
    with open(path, "w") as f:
        f.write("Verilator cocotb regression\n")
        f.write(f"targets: {len(targets)}  bazel: {dict(by_status)}\n")
        f.write(f"testcases: {len(rows)}  results: {dict(by_result)}\n")
        f.write(
            f"total simulated time: {total_ns:.2f} ns ({total_ns / 1e6:.3f} ms)  "
            f"total cocotb real time: {total_s:.1f} s\n\n"
        )
        f.write("== By package ==\n")
        f.write(
            f"{'CASES':>6s} {'PASS':>5s} {'SIM TIME (ms)':>14s} {'REAL (s)':>9s}  PACKAGE\n"
        )
        packages = collections.defaultdict(lambda: [0, 0, 0.0, 0.0])
        for r in rows:
            p = packages[r["bazel_target"][2:].split(":")[0]]
            p[0] += 1
            p[1] += r["cocotb_result"] == "PASS"
            p[2] += num(r["sim_time_ns"])
            p[3] += num(r["cocotb_real_time_s"])
        for pkg, (n, ok, ns, s) in sorted(packages.items(),
                                          key=lambda kv: -kv[1][0]):
            f.write(f"{n:6d} {ok:5d} {ns / 1e6:14.3f} {s:9.1f}  {pkg}\n")
        f.write("\n== Not passed ==\n")
        bad = [r for r in rows if r["cocotb_result"] != "PASS"]
        if not bad:
            f.write("(none)\n")
        for r in bad:
            f.write(
                f"{r['cocotb_result']:8s} {r['bazel_target']}  testcase={r['testcase'] or '-'}  "
                f"bazel={r['bazel_status']}\n"
            )
        f.write("\n== All testcases ==\n")
        f.write(
            f"{'RESULT':8s} {'SIM TIME (ns)':>14s} {'REAL (s)':>9s}  TARGET / TESTCASE\n"
        )
        for r in sorted(rows, key=lambda r: r["bazel_target"]):
            f.write(
                f"{r['cocotb_result']:8s} {str(r['sim_time_ns']):>14s} "
                f"{str(r['cocotb_real_time_s']):>9s}  {r['bazel_target']}  {r['testcase']}\n"
            )


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
        logf = os.path.join(testlogs, pkg, name, "test.log")
        cases = []
        if os.path.exists(logf):
            for line in open(logf, errors="replace"):
                m = ROW_RE.search(line)
                if m:
                    cases.append((
                        m.group(1), m.group(2), float(m.group(3)),
                        float(m.group(4))
                    ))
        base = dict(bazel_target=t, bazel_status=st, bazel_test_wall_s=wall)
        if not cases:
            rows.append(
                dict(
                    base,
                    testcase="",
                    cocotb_result="NOT RUN",
                    sim_time_ns="",
                    cocotb_real_time_s=""
                )
            )
        for name_, result, sim_ns, real_s in cases:
            rows.append(
                dict(
                    base,
                    testcase=name_,
                    cocotb_result=result,
                    sim_time_ns=sim_ns,
                    cocotb_real_time_s=real_s
                )
            )

    with open(out + ".csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    with open(out + ".json", "w") as f:
        json.dump(rows, f, indent=1)
    write_summary(out + ".log", targets, status, rows)

    print(
        "targets:", len(targets),
        collections.Counter(status.get(t, ("NOT RUN", ))[0] for t in targets)
    )
    print(
        "cocotb cases:", collections.Counter(r["cocotb_result"] for r in rows)
    )
    for r in rows:
        if r["cocotb_result"] == "NOT RUN":
            print("ran no testcase:", r["bazel_target"], r["bazel_status"])


if __name__ == "__main__":
    main()
