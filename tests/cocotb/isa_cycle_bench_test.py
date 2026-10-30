# Copyright 2026 Antmicro
#
# Drives the per-instruction cycle-cost microbenchmark on RTL.
#
# The benchmark table lives in isa_cycle_bench_defs.h and is parsed from there
# rather than duplicated here, so the host and the firmware cannot drift
# apart. Because ITCM is only 8 KiB the benchmarks are split into groups, each
# compiled into its own ELF; this test walks every group's ELF and runs every
# benchmark in it one program execution at a time.

import json
import logging
import os
import re

from bazel_tools.tools.python.runfiles import runfiles
import numpy as np

from coralnpu_test_utils.coralflow.runner import (
    coralflow_main,
    coralflow_test,
    get_target_environment,
)

BENCH_DEFS_RLOCATION = "coralnpu_hw/tests/cocotb/isa_cycle_bench_defs.h"
ELF_RLOCATION_FMT = "coralnpu_hw/tests/cocotb/isa_cycle_bench_{group}.elf"
BENCH_RUN_ALL = 0xFFFFFFFE

# Cycles spent in the two `csrr mcycle` bracket instructions, which are inside
# the measured window but are not part of the instruction under test.
BRACKET_OVERHEAD_CYCLES = 2

_REPS_RE = re.compile(r"^#define\s+BENCH_REPS\s+(\d+)\s*$", re.MULTILINE)
_GROUP_RE = re.compile(r"^#define\s+BENCH_LIST_(\w+)\(X\)", re.MULTILINE)
# Each benchmark is one X(...) call on its own line (isa_cycle_bench_defs.h
# wraps these in `// clang-format off` so they stay that way).
_ENTRY_RE = re.compile(
    r'^\s*X\(\s*(\w+)\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,', re.MULTILINE
)
_THROUGHPUT_RE = re.compile(
    r"^#define\s+BENCH_THROUGHPUT_IDS((?:[^\n]*\\\n)*[^\n]*)", re.MULTILINE
)

# Bare instruction for rows whose display mnemonic does not start with the
# instruction actually measured (`ret` and `call` are pseudo-instructions).
INSTRUCTION_OVERRIDES = {
    "JALR": "jalr",
    "CALL_RET": "jalr",
}

# What a row's "Cycles/instruction" number means: whether consecutive
# instances of the measured instruction are chained through a
# read-after-write dependency or are independent of each other.
MEASURES_LATENCY = "latency"
MEASURES_THROUGHPUT = "throughput"


def _parse_bench_defs(text):
    """Extracts (reps, throughput_ids, [(group, [(id, mnemonic, cat)]), ...])."""
    reps_match = _REPS_RE.search(text)
    assert reps_match, "BENCH_REPS not found in isa_cycle_bench_defs.h"
    reps = int(reps_match.group(1))

    throughput_match = _THROUGHPUT_RE.search(text)
    assert throughput_match, "BENCH_THROUGHPUT_IDS not found"
    throughput_ids = set(
        "".join(re.findall(r'"([^"]*)"', throughput_match.group(1))).split()
    )

    groups = []
    starts = list(_GROUP_RE.finditer(text))
    assert starts, "no BENCH_LIST_<GROUP>() macros found"
    for index, match in enumerate(starts):
        end = starts[index +
                     1].start() if index + 1 < len(starts) else len(text)
        entries = _ENTRY_RE.findall(text, match.end(), end)
        assert entries, f"group {match.group(1)} has no benchmarks"
        groups.append((match.group(1), entries))

    known_ids = {entry[0] for _, entries in groups for entry in entries}
    unknown = sorted(throughput_ids - known_ids)
    assert not unknown, f"BENCH_THROUGHPUT_IDS names unknown benchmarks: {unknown}"
    return reps, throughput_ids, groups


def _compute_output_path(filename):
    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
    if not out_dir:
        return None
    return os.path.join(out_dir, filename)


@coralflow_test
async def isa_cycle_bench_test(fixture):
    """Benchmarks every instruction in isa_cycle_bench_defs.h on RTL."""
    r = runfiles.Create()

    with open(r.Rlocation(BENCH_DEFS_RLOCATION)) as defs_file:
        reps, throughput_ids, groups = _parse_bench_defs(defs_file.read())

    md_path = _compute_output_path("measured_instruction_cycles.md")
    stats_path = _compute_output_path("measured_instruction_cycles.json")
    md_file = open(md_path, "w") if md_path else None  # noqa: SIM115

    def emit(line):
        # cocotb's log formatter chokes on a fully empty message, so give it
        # a harmless placeholder while still writing a real blank line to
        # the markdown file.
        logging.info(line if line else " ")
        if md_file:
            md_file.write(line + "\n")
            md_file.flush()
            os.fsync(md_file.fileno())

    emit(
        "| Instruction | Category | Measures | Raw delta (cycles) | Raw delta normalized (cycles) | Cycles/instruction |"
    )
    emit("|---|---|---|---:|---:|---:|")

    rows = []
    failures = []

    def measures_of(bench_id):
        if bench_id in throughput_ids:
            return MEASURES_THROUGHPUT
        return MEASURES_LATENCY

    def record_failure(group, bench_id, mnemonic, category, exc):
        measures = measures_of(bench_id)
        logging.error(f"benchmark {mnemonic} ({group}) failed: {exc}")
        failures.append(f"{mnemonic} ({group}): {exc}")
        emit(
            f"| `{mnemonic}` | {category} | {measures} | FAILED | FAILED | FAILED |"
        )

    def record_row(group, bench_id, mnemonic, category, raw_delta):
        if raw_delta == 0xFFFFFFFF:
            record_failure(
                group, bench_id, mnemonic, category, "benchmark did not run"
            )
            return

        measures = measures_of(bench_id)
        # raw_delta includes the two bracket `csrr mcycle` instructions,
        # which are not part of the instruction under test.
        raw_delta_normalized = raw_delta - BRACKET_OVERHEAD_CYCLES
        cycles_per_instr = raw_delta_normalized / reps

        rows.append({
            # `mnemonic` is the display label, which may carry a variant
            # suffix such as "beq (taken)" or "ret (jalr)"; `instruction`
            # is the bare instruction, for joining against an
            # instruction-coverage report.
            "mnemonic":
            mnemonic,
            "instruction":
            INSTRUCTION_OVERRIDES.get(bench_id,
                                      mnemonic.split(" ")[0]),
            "group":
            group.lower(),
            "category":
            category,
            # "latency" if consecutive instances of the instruction are
            # chained through a read-after-write dependency, otherwise
            # "throughput". Latency and throughput rows are not
            # comparable with each other.
            "measures":
            measures,
            "raw_delta":
            raw_delta,
            "raw_delta_normalized":
            raw_delta_normalized,
            "cycles_per_instr":
            cycles_per_instr,
        })
        emit(
            f"| `{mnemonic}` | {category} | {measures} | {raw_delta} | {raw_delta_normalized} | {cycles_per_instr:.2f} |"
        )

    async def check_bench_count(group, entries):
        bench_count = int(await fixture.read_word("g_bench_count"))
        assert bench_count == len(entries), (
            f"{group} ELF has {bench_count} benchmarks but the header "
            f"lists {len(entries)}; the ELF is built from a different "
            "group than the one parsed"
        )

    symbols = ["g_selected_bench", "g_result", "g_results", "g_bench_count"]

    # UvmTestFixture spawns a fresh simulator subprocess on every run_to_halt()
    # call. On EDACloud VCS UVM, each `simv` cold start and FlexLM license
    # checkout takes ~45-50s, so one run_to_halt() call per benchmark would
    # exceed Bazel's 3600s test timeout. On UVM, execute all benchmarks of a
    # group in a single invocation via BENCH_RUN_ALL, while keeping isolated
    # per-benchmark runs (each run_to_halt() restarts the program from reset)
    # on persistent Cocotb/FPGA backends.
    run_all = get_target_environment() == "uvm"

    for group, entries in groups:
        try:
            elf_path = r.Rlocation(
                ELF_RLOCATION_FMT.format(group=group.lower())
            )
            if not elf_path or not os.path.isfile(elf_path):
                raise FileNotFoundError(
                    f"no ELF built for benchmark group {group}; is it in "
                    "ISA_CYCLE_BENCH_GROUPS in tests/cocotb/BUILD?"
                )
            await fixture.load_elf_and_lookup_symbols(elf_path, symbols)
        except Exception as exc:  # noqa: BLE001 - reported in bulk below
            for bench_id, mnemonic, category in entries:
                record_failure(group, bench_id, mnemonic, category, exc)
            continue

        if run_all:
            try:
                await fixture.write_word("g_selected_bench", BENCH_RUN_ALL)
                await fixture.write(
                    "g_results",
                    np.full(len(entries), 0xFFFFFFFF, dtype=np.uint32),
                )
                await fixture.run_to_halt(timeout_cycles=500000)
                await check_bench_count(group, entries)
                raw_deltas = await fixture.read(
                    "g_results", dtype=np.uint32, shape=(len(entries), )
                )
            except Exception as exc:  # noqa: BLE001 - reported in bulk below
                for bench_id, mnemonic, category in entries:
                    record_failure(group, bench_id, mnemonic, category, exc)
                continue
            for (bench_id, mnemonic, category), raw_delta in zip(entries,
                                                                 raw_deltas):
                record_row(group, bench_id, mnemonic, category, int(raw_delta))
            continue

        for bench_index, (bench_id, mnemonic, category) in enumerate(entries):
            try:
                await fixture.write_word("g_selected_bench", bench_index)
                await fixture.write_word("g_result", 0xFFFFFFFF)
                await fixture.run_to_halt(timeout_cycles=100000)
                await check_bench_count(group, entries)
                raw_delta = int(await fixture.read_word("g_result"))
            except Exception as exc:  # noqa: BLE001 - reported in bulk below
                record_failure(group, bench_id, mnemonic, category, exc)
                continue
            record_row(group, bench_id, mnemonic, category, raw_delta)

    if md_file:
        md_file.close()
        logging.info(f"Wrote {md_path}")

    if stats_path:
        with open(stats_path, "w") as stats_file:
            stats = {row["mnemonic"]: row for row in rows}
            json.dump(stats, stats_file, indent=2)

    total = sum(len(entries) for _, entries in groups)
    logging.info(f"Benchmarked {len(rows)}/{total} instructions")
    assert not failures, "benchmarks failed:\n" + "\n".join(failures)


if __name__ == "__main__":
    coralflow_main()
