# Copyright 2026 Antmicro
#

import os

import cocotb
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture

REPS = 32

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


def _markdown_output_path():
    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
    if not out_dir:
        return None
    return os.path.join(out_dir, "measured_instruction_cycles.md")


@cocotb.test()
async def isa_cycle_bench_test(dut):
    """Benchmarks each instruction in BENCHMARKS on RTL and reports its cycle cost."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/isa_cycle_bench.elf")

    md_path = _markdown_output_path()
    md_file = open(md_path, "w") if md_path else None  # noqa: SIM115

    def emit(line):
        # cocotb's log formatter chokes on a fully empty message, so give it
        # a harmless placeholder while still writing a real blank line to
        # the markdown file.
        dut._log.info(line if line else " ")
        if md_file:
            md_file.write(line + "\n")
            md_file.flush()
            os.fsync(md_file.fileno())

    emit(
        "| Instruction | Category | Raw delta (cycles) | Raw delta normalized (cycles) | Cycles/instruction |"
    )
    emit("|---|---|---:|---:|---:|")

    rows = []
    for bench_index, (bench_id, mnemonic, category) in enumerate(BENCHMARKS):
        await fixture.load_elf_and_lookup_symbols(
            elf_path, ["g_selected_bench", "g_result"]
        )
        await fixture.write_word("g_selected_bench", bench_index)
        await fixture.run_to_halt(timeout_cycles=100000)
        raw_delta = int.from_bytes(
            bytes(await fixture.read_word("g_result")), "little"
        )
        assert raw_delta != 0xFFFFFFFF, f"benchmark {mnemonic} did not run"

        # raw_data include 2 additional cycles needed for reading cycles counter, we need to subtract it
        raw_data_normalized = raw_delta - 2
        cycles_per_instr = raw_data_normalized / REPS

        rows.append((mnemonic, category, raw_delta, cycles_per_instr))
        emit(
            f"| `{mnemonic}` | {category} | {raw_delta} | {raw_data_normalized} | {cycles_per_instr:.2f} |"
        )

    if md_file:
        md_file.close()
        dut._log.info(f"Wrote {md_path}")

    assert len(rows) == len(BENCHMARKS)
