# Copyright 2025 Google LLC
"""Run all riscv-vector-tests on CoralNPU highmem Verilator model."""

import cocotb
import os
import glob
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface
from bazel_tools.tools.python.runfiles import runfiles

ELFDIR = "/Users/ust/coralnpu/third_party/riscv_vector_tests/out"
TIMEOUT_US = 10_000_000  # 10 seconds per test

async def run_one_test(dut, elf_path):
    """Load and run a single test ELF. Returns (name, passed, message)."""
    name = os.path.basename(elf_path).replace(".elf", "")
    
    core = CoreMiniAxiInterface(dut)
    await core.init()
    await core.reset()
    
    # Load ELF
    with open(elf_path, "rb") as f:
        await core.load_elf(f)
    
    # Run
    try:
        await core.execute_from(0)
        await core.wait_for_halted(timeout_us=TIMEOUT_US)
        # Check a0 (x10) for pass/fail
        a0 = await core.read_gpr(10)
        if a0 == 0:
            return name, True, "PASS"
        else:
            return name, False, f"FAIL (a0={a0})"
    except Exception as e:
        return name, False, f"ERROR: {e}"


@cocotb.test(skip=False)
async def test_all_vectors(dut):
    """Run all compiled riscv-vector-tests against Chisel RVV."""
    elfs = sorted(glob.glob(os.path.join(ELFDIR, "*.elf")))
    cocotb.log.info(f"Found {len(elfs)} test ELFs")

    results = {"PASS": [], "FAIL": []}
    for i, elf in enumerate(elfs):
        name, passed, msg = await run_one_test(dut, elf)
        if passed:
            results["PASS"].append(name)
        else:
            results["FAIL"].append((name, msg))
        
        # Print progress every 10 tests
        if (i + 1) % 10 == 0 or not passed:
            total = len(results["PASS"]) + len(results["FAIL"])
            cocotb.log.info(f"  [{total:4d}/{len(elfs)}] {name:45s} {'PASS' if passed else msg}")

    cocotb.log.info(f"\n{'='*70}")
    cocotb.log.info(f"FINAL: {len(results['PASS'])}/{len(elfs)} PASS")
    if results["FAIL"]:
        cocotb.log.error(f"FAILURES ({len(results['FAIL'])}):")
        for name, msg in results["FAIL"][:50]:
            cocotb.log.error(f"  {name}: {msg}")
    
    assert len(results["FAIL"]) == 0, f"{len(results['FAIL'])} tests FAILED"
