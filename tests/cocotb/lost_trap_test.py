# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Lost Trap Reproduction Test

Reproduces the LOST_TRAP bug: two back-to-back vector loads to invalid
addresses should each cause a trap (trap_count=2), but the missing
mstatus.MIE/MPIE mechanism allows the second fault to overwrite mepc
before the first trap handler completes, resulting in trap_count=1.

The test asserts trap_count == 2 and will FAIL when the bug is present,
confirming the issue.
"""

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_test_fixture import Fixture


@cocotb.test()
async def lost_trap_test(dut):
    """Two back-to-back vector loads to invalid addresses must each trap.

    Expected: trap_count = 2 (both faults handled)
    Buggy:    trap_count = 1 (second fault overwrites mepc, one trap lost)
    """
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)

    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/lost_trap_test.elf")
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        ["trap_count", "last_mcause", "last_mepc", "last_mtval"],
    )

    dut._log.info("Running lost trap reproduction test...")
    dut._log.info("Two back-to-back vle32.v to invalid addresses (0x90000000, 0x90001000)")
    dut._log.info("Expected: trap_count=2, Buggy: trap_count=1")

    await fixture.core_mini_axi.execute_from(fixture.entry_point)

    total_cycles = 0
    max_cycles = 5000
    check_interval = 500
    halted = False
    faulted = False

    while total_cycles < max_cycles:
        for _ in range(check_interval):
            await ClockCycles(dut.io_aclk, 1)
            total_cycles += 1
            if dut.io_halted.value == 1:
                halted = True
                break
            if dut.io_fault.value == 1:
                faulted = True
                break
        if halted or faulted:
            break

        trap_count = (await fixture.read_word("trap_count")).view(np.uint32)[0]
        last_mcause = (await fixture.read_word("last_mcause")).view(np.uint32)[0]
        last_mepc = (await fixture.read_word("last_mepc")).view(np.uint32)[0]
        dut._log.info(
            f"[cycle {total_cycles}] halted={dut.io_halted.value} "
            f"fault={dut.io_fault.value} trap_count={trap_count} "
            f"last_mcause=0x{last_mcause:X} last_mepc=0x{last_mepc:08X}"
        )

    dut._log.info(f"Simulation ended at cycle {total_cycles}: halted={halted}, faulted={faulted}")

    assert halted or faulted, (
        f"Core did not halt or fault within {max_cycles} cycles. "
        f"Core appears stuck."
    )

    trap_count = (await fixture.read_word("trap_count")).view(np.uint32)[0]
    last_mcause = (await fixture.read_word("last_mcause")).view(np.uint32)[0]
    last_mepc = (await fixture.read_word("last_mepc")).view(np.uint32)[0]
    last_mtval = (await fixture.read_word("last_mtval")).view(np.uint32)[0]

    dut._log.info("=" * 60)
    dut._log.info("Lost Trap Test Results")
    dut._log.info("=" * 60)
    dut._log.info(f"  halted      = {halted}")
    dut._log.info(f"  faulted     = {faulted}")
    dut._log.info(f"  cycles      = {total_cycles}")
    dut._log.info(f"  trap_count  = {trap_count} (expected: 2)")
    dut._log.info(f"  last_mcause = 0x{last_mcause:08X} (5 = load access fault)")
    dut._log.info(f"  last_mepc   = 0x{last_mepc:08X}")
    dut._log.info(f"  last_mtval  = 0x{last_mtval:08X}")
    dut._log.info("=" * 60)

    if faulted:
        dut._log.info("Core hit a FAULT (usage fault / unrecoverable). Not mpause halt.")

    assert trap_count == 2, (
        f"Expected trap_count=2 but got {trap_count}. "
        f"last_mcause=0x{last_mcause:X}, last_mepc=0x{last_mepc:08X}"
    )
