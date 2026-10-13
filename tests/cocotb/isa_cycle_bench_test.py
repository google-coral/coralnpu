# Copyright 2026 Antmicro
#

import json
import logging
import os

from bazel_tools.tools.python.runfiles import runfiles
import numpy as np

from coralnpu_test_utils.coralflow.runner import (
    coralflow_main,
    coralflow_test,
    get_target_environment,
)

REPS = 32
BENCH_RUN_ALL = 0xFFFFFFFE

# (BenchId enum name in isa_cycle_bench.cc, display mnemonic, category).
# Order must match the BenchId enum in isa_cycle_bench.cc.
BENCHMARKS = [
    ("BENCH_NOP", "nop", "baseline"),
    ("BENCH_ADD", "add", "RV32I ALU"),
    ("BENCH_SUB", "sub", "RV32I ALU"),
    ("BENCH_AND", "and", "RV32I ALU"),
    ("BENCH_OR", "or", "RV32I ALU"),
    ("BENCH_XOR", "xor", "RV32I ALU"),
    ("BENCH_SLL", "sll", "RV32I ALU"),
    ("BENCH_SRL", "srl", "RV32I ALU"),
    ("BENCH_SRA", "sra", "RV32I ALU"),
    ("BENCH_SLT", "slt", "RV32I ALU"),
    ("BENCH_ADDI", "addi", "RV32I ALU immediate"),
    ("BENCH_SLTI", "slti", "RV32I ALU immediate"),
    ("BENCH_SLTIU", "sltiu", "RV32I ALU immediate"),
    ("BENCH_ANDI", "andi", "RV32I ALU immediate"),
    ("BENCH_ORI", "ori", "RV32I ALU immediate"),
    ("BENCH_XORI", "xori", "RV32I ALU immediate"),
    ("BENCH_SLLI", "slli", "RV32I ALU immediate"),
    ("BENCH_SRLI", "srli", "RV32I ALU immediate"),
    ("BENCH_SRAI", "srai", "RV32I ALU immediate"),
    ("BENCH_LW", "lw", "Load/Store"),
    ("BENCH_SW", "sw", "Load/Store"),
    ("BENCH_LB", "lb", "Load/Store"),
    ("BENCH_SB", "sb", "Load/Store"),
    ("BENCH_BEQ_TAKEN", "beq (taken)", "Control flow"),
    ("BENCH_BEQ_NOT_TAKEN", "beq (not taken)", "Control flow"),
    ("BENCH_JAL", "jal", "Control flow"),
    ("BENCH_MUL", "mul", "M extension"),
    ("BENCH_MULH", "mulh", "M extension"),
    ("BENCH_DIV", "div", "M extension"),
    ("BENCH_DIVU", "divu", "M extension"),
    ("BENCH_REM", "rem", "M extension"),
    ("BENCH_FADD_S", "fadd.s", "F extension"),
    ("BENCH_FMUL_S", "fmul.s", "F extension"),
    ("BENCH_FDIV_S", "fdiv.s", "F extension"),
    ("BENCH_FSQRT_S", "fsqrt.s", "F extension"),
    ("BENCH_FMADD_S", "fmadd.s", "F extension"),
    ("BENCH_VADD_VV", "vadd.vv", "RVV integer (e32, vl=4)"),
    ("BENCH_VSUB_VV", "vsub.vv", "RVV integer (e32, vl=4)"),
    ("BENCH_VAND_VV", "vand.vv", "RVV integer (e32, vl=4)"),
    ("BENCH_VMUL_VV", "vmul.vv", "RVV integer (e32, vl=4)"),
    ("BENCH_VLE32_V", "vle32.v", "RVV integer (e32, vl=4)"),
    ("BENCH_VSE32_V", "vse32.v", "RVV integer (e32, vl=4)"),
    ("BENCH_VREDSUM_VS", "vredsum.vs", "RVV integer (e32, vl=4)"),
    ("BENCH_VFADD_VV", "vfadd.vv", "RVV float (e32, vl=4)"),
    ("BENCH_VFMUL_VV", "vfmul.vv", "RVV float (e32, vl=4)"),
]


def _compute_output_path(filename):
    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
    if not out_dir:
        return None
    return os.path.join(out_dir, filename)


@coralflow_test
async def isa_cycle_bench_test(fixture):
    """Benchmarks each instruction in BENCHMARKS on RTL and reports its cycle cost."""
    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/isa_cycle_bench.elf")

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
        "| Instruction | Category | Raw delta (cycles) | Raw delta normalized (cycles) | Cycles/instruction |"
    )
    emit("|---|---|---:|---:|---:|")

    await fixture.load_elf_and_lookup_symbols(
        elf_path, ["g_selected_bench", "g_result", "g_results"]
    )
    rows = []

    def record_row(mnemonic, category, raw_delta):
        assert raw_delta != 0xFFFFFFFF, f"benchmark {mnemonic} did not run"
        # raw_delta includes 2 additional cycles needed for reading mcycle.
        raw_data_normalized = raw_delta - 2
        cycles_per_instr = raw_data_normalized / REPS
        rows.append((
            mnemonic,
            category,
            raw_delta,
            raw_data_normalized,
            cycles_per_instr,
        ))
        emit(
            f"| `{mnemonic}` | {category} | {raw_delta} | {raw_data_normalized} | {cycles_per_instr:.2f} |"
        )

    # UvmTestFixture spawns a fresh simulator subprocess on every run_to_halt()
    # call. On EDACloud VCS UVM, each `simv` cold start and FlexLM license
    # checkout takes ~45-50s, so 45 sequential run_to_halt() calls (~2,160s+
    # plus license contention) exceed Bazel's 3600s test timeout. Execute all
    # 45 benchmarks in a single UVM invocation via BENCH_RUN_ALL, while keeping
    # isolated per-benchmark soft-resets on persistent Cocotb/FPGA backends.
    if get_target_environment() == "uvm":
        await fixture.write_word("g_selected_bench", BENCH_RUN_ALL)
        await fixture.write(
            "g_results",
            np.full(len(BENCHMARKS), 0xFFFFFFFF, dtype=np.uint32),
        )
        await fixture.run_to_halt(timeout_cycles=500000)
        raw_deltas = await fixture.read(
            "g_results", dtype=np.uint32, shape=(len(BENCHMARKS), )
        )
        for (_, mnemonic, category), raw_delta in zip(BENCHMARKS, raw_deltas):
            record_row(mnemonic, category, int(raw_delta))
    else:
        for bench_index, (_, mnemonic, category) in enumerate(BENCHMARKS):
            await fixture.write_word("g_selected_bench", bench_index)
            await fixture.write_word("g_result", 0xFFFFFFFF)
            await fixture.run_to_halt(timeout_cycles=100000)
            raw_delta = await fixture.read_word("g_result")
            record_row(mnemonic, category, int(raw_delta))

    if md_file:
        md_file.close()
        logging.info(f"Wrote {md_path}")

    if stats_path:
        with open(stats_path, "w") as stats_file:
            stats = {
                row[0]: {
                    "category": row[1],
                    "raw_delta": row[2],
                    "raw_delta_normalized": row[3],
                    "cycles_per_instr": row[4],
                }
                for row in rows
            }
            json.dump(stats, stats_file, indent=2)

    assert len(rows) == len(BENCHMARKS)


if __name__ == "__main__":
    coralflow_main()
