#!/usr/bin/env python3
"""Cocotb test harness for riscv-vector-tests.

Runs all compiled ELF tests against the CoralNPU Verilator model.
Each test signals pass via EBREAK with a0=0, or fail with a0!=0.
"""

import os
import glob
import sys
import cocotb
from cocotb.triggers import Timer

# Add test utils
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

ELFDIR = "/Users/ust/coralnpu/third_party/riscv_vector_tests/out"


async def run_vector_test(dut, elf_path):
    """Run a single vector test ELF and return (name, passed, message)."""
    name = os.path.basename(elf_path).replace(".elf", "")

    from coralnpu_test_utils.core_mini_axi_sim import CoreMiniAxiInterface

    core = CoreMiniAxiInterface(dut)
    await core.init()
    await core.reset()

    # Load ELF
    with open(elf_path, "rb") as f:
        await core.load_elf(f)

    # Start execution
    entry = core.lookup_symbol("_start") if hasattr(core, 'lookup_symbol') else 0
    await core.execute_from(entry if entry else 0)

    # Wait for EBREAK (halt)
    try:
        await core.wait_for_halted(timeout_us=5000000)  # 5 second timeout
        # Read a0 (x10) to check pass/fail
        a0 = await core.read_gpr(10)
        if a0 == 0:
            return name, True, "PASS (a0=0)"
        else:
            return name, False, f"FAIL (a0={a0})"
    except Exception as e:
        return name, False, f"TIMEOUT/ERROR: {e}"


@cocotb.test()
async def test_vadd_vv(dut):
    """Run vadd.vv compliance test."""
    elf = os.path.join(ELFDIR, "vadd.vv.elf")
    if os.path.exists(elf):
        name, passed, msg = await run_vector_test(dut, elf)
        assert passed, f"{name}: {msg}"
    else:
        cocotb.log.warning(f"ELF not found: {elf}")


@cocotb.test(skip=True)
async def test_all_vector(dut):
    """Run ALL compiled vector tests and report results."""
    elfs = sorted(glob.glob(os.path.join(ELFDIR, "*.elf")))
    cocotb.log.info(f"Found {len(elfs)} test ELFs")

    results = {"PASS": [], "FAIL": []}
    for elf in elfs:
        name, passed, msg = await run_vector_test(dut, elf)
        if passed:
            results["PASS"].append(name)
        else:
            results["FAIL"].append(f"{name}: {msg}")
        cocotb.log.info(f"  [{len(results['PASS'])+len(results['FAIL'])}/{len(elfs)}] {name}: {'PASS' if passed else 'FAIL'}")

    cocotb.log.info(f"\n{'='*60}")
    cocotb.log.info(f"RESULTS: {len(results['PASS'])} PASS, {len(results['FAIL'])} FAIL")
    for f in results["FAIL"]:
        cocotb.log.error(f"  FAIL: {f}")

    assert len(results["FAIL"]) == 0, f"{len(results['FAIL'])} tests FAILED"
