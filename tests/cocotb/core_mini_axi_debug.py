# Copyright 2025 Google LLC
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

import cocotb
import random

from cocotb.triggers import ClockCycles
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface, DmCmdType, DmRspOp
from coralnpu_test_utils.core_mini_axi_pyocd_gdbserver import CoreMiniAxiGDBServer
from bazel_tools.tools.python.runfiles import runfiles


@cocotb.test()
async def core_mini_axi_debug_gdbserver(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    gdbserver = CoreMiniAxiGDBServer(core_mini_axi)
    r = runfiles.Create()

    # Just poke some FPU register.
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/registers.elf"),
              "rb") as f:
        cmds = [
            "info reg f0",
        ]
        assert await gdbserver.run(f, cmds)

    # Test which calls memcpy through a function pointer.
    # Ensure we correctly break in memcpy.
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/fptr.elf"), "rb") as f:
        memcpy = core_mini_axi.lookup_symbol(f, "memcpy")
        cmds = [
            f"break *{hex(memcpy)}",
            "continue",
            f"if $pc != {hex(memcpy)}",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

    # Test which calls a computation function repeatedly.
    # Check the result of the second iteration, which should be 5.
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/math.elf"), "rb") as f:
        cmds = [
            f"break math",
            "continue",
            "continue",
            "delete",
            "finish",
            "if $a0 != 5",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

    # Set and continue to a breakpoint, and then single step.
    # This step should cause the PC to change.
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/math.elf"), "rb") as f:
        cmds = [
            f"break math",
            "continue",
            "set $bpc = $pc",
            "stepi",
            "if $bpc == $pc",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

    # Set and continue to a breakpoint, and single step.
    # The breakpointed function is an infinite loop, so PC should not change.
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/loop.elf"), "rb") as f:
        cmds = [
            f"break loop",
            "continue",
            "set $bpc = $pc",
            "stepi",
            "if $bpc != $pc",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

    # Test memory writes/reads at different sizes via GDB.
    # Target DTCM at address 0x10000.
    dtcm_addr = 0x10000
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/noop.elf"), "rb") as f:
        # Test byte write/read
        cmds = [
            f"set {{unsigned char}}{hex(dtcm_addr)} = 0xAA",
            f"if {{unsigned char}}{hex(dtcm_addr)} != 0xAA",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

        # Test short write/read
        cmds = [
            f"set {{unsigned short}}{hex(dtcm_addr)} = 0xBBCC",
            f"if {{unsigned short}}{hex(dtcm_addr)} != 0xBBCC",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

        # Test word write/read
        cmds = [
            f"set {{unsigned int}}{hex(dtcm_addr)} = 0xDDEEFF00",
            f"if {{unsigned int}}{hex(dtcm_addr)} != 0xDDEEFF00",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

        # Test offset/misaligned accesses
        # Byte at offset 1 (0x10001)
        cmds = [
            f"set {{unsigned char}}{hex(dtcm_addr + 1)} = 0x55",
            f"if {{unsigned char}}{hex(dtcm_addr + 1)} != 0x55",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

        # Short at offset 2 (0x10002) - Upper half of word
        cmds = [
            f"set {{unsigned short}}{hex(dtcm_addr + 2)} = 0x8899",
            f"if {{unsigned short}}{hex(dtcm_addr + 2)} != 0x8899",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

        # Short at offset 1 (0x10001) - Misaligned
        # Note: This relies on the memory subsystem supporting this strobe pattern (0110).
        cmds = [
            f"set {{unsigned short}}{hex(dtcm_addr + 1)} = 0x3344",
            f"if {{unsigned short}}{hex(dtcm_addr + 1)} != 0x3344",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)

        # Test block access (7 bytes)
        # Should result in 4-byte, 2-byte, 1-byte accesses.
        # Write 0x01020304050607
        cmds = [
            f"set {{unsigned long long}}{hex(dtcm_addr)} = 0x07060504030201",
            # Verify bytes individually
            f"if {{unsigned char}}{hex(dtcm_addr)} != 0x01",
            "quit 1",
            "end",
            f"if {{unsigned char}}{hex(dtcm_addr + 4)} != 0x05",
            "quit 1",
            "end",
            f"if {{unsigned char}}{hex(dtcm_addr + 6)} != 0x07",
            "quit 1",
            "end",
        ]
        assert await gdbserver.run(f, cmds)


@cocotb.test()
async def core_mini_axi_debug_dmactive(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    # If we're not active, go ahead and become active
    dmcontrol = await core_mini_axi.dm_read(0x10)
    dmactive = dmcontrol & (1 << 0)
    if not dmactive:
        dmcontrol = dmcontrol | 1
        rsp = await core_mini_axi.dm_write(0x10, dmcontrol)
        assert rsp["op"] == DmRspOp.SUCCESS

    # Set some random value into data0
    data0_val = random.randint(0, 2**32 - 1)
    rsp = await core_mini_axi.dm_write(0x4, data0_val)
    assert rsp["op"] == DmRspOp.SUCCESS
    data0_reg = await core_mini_axi.dm_read(0x4)
    assert (data0_reg == data0_val)

    # Push the debug module into reset
    dmcontrol = dmcontrol & ~1
    rsp = await core_mini_axi.dm_write(0x10, dmcontrol)
    assert rsp["op"] == DmRspOp.SUCCESS
    retries = 0
    while True:
        dmcontrol = await core_mini_axi.dm_read(0x10)
        dmactive = dmcontrol & 1
        if dmactive == 0:
            break
        retries += 1
        if retries == 100:
            assert False, "Failed to set dmactive"

    # Pull the debug module out of reset
    dmcontrol = dmcontrol | 1
    rsp = await core_mini_axi.dm_write(0x10, dmcontrol)
    assert rsp["op"] == DmRspOp.SUCCESS
    retries = 0
    while True:
        dmcontrol = await core_mini_axi.dm_read(0x10)
        dmactive = dmcontrol & 1
        if dmactive == 1:
            break
        retries += 1
        if retries == 100:
            assert False, "Failed to set dmactive"

    # This should be 0 after reset.
    data0_reg = await core_mini_axi.dm_read(0x4)
    assert (data0_reg == 0)


@cocotb.test()
async def core_mini_axi_debug_probe_impl(dut):
    # See Debug Spec 3.13 Version Detection
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    dmcontrol = await core_mini_axi.dm_read(0x10)
    dmactive = dmcontrol & (1 << 0)
    ndmreset = dmcontrol & (1 << 1)
    if dmactive == 0 or ndmreset == 1:
        retries = 0
        while True:
            # Set dmactive, clear ndmreset
            new_dmcontrol = dmcontrol | 1 & ~(1 << 1)
            rsp = await core_mini_axi.dm_write(0x10, new_dmcontrol)
            assert rsp["op"] == DmRspOp.SUCCESS
            dmcontrol = await core_mini_axi.dm_read(0x10)
            dmactive = dmcontrol & (1 << 0)
            if dmactive == 1:
                break
            retries += 1
            if retries == 100:
                assert False, "Failed to set dmactive"
    dmstatus = await core_mini_axi.dm_read(0x11)
    version = dmstatus & (2 << 0)
    # TODO(atv): Don't care about the concrete version for now, just a version.
    assert (version != 0)

    hartinfo = await core_mini_axi.dm_read(0x12)
    nscratch = (hartinfo >> 20) & 0xF
    assert (nscratch == 2)
    dataaccess = (hartinfo >> 16) & 1
    assert (dataaccess == 0)
    datasize = (hartinfo >> 12) & 0xF
    assert (datasize == 0)
    dataaddr = hartinfo & 0xFFF
    assert (dataaddr == 0x7B4)


@cocotb.test()
async def core_mini_axi_debug_ndmreset(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    dmcontrol = await core_mini_axi.dm_read(0x10)
    dmcontrol = dmcontrol | (1 << 1)
    rsp = await core_mini_axi.dm_write(0x10, dmcontrol)
    assert rsp["op"] == DmRspOp.SUCCESS

    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/noop.elf"), "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.execute_from(entry_point)
        wait_for_halted_asserted = False
        try:
            await core_mini_axi.wait_for_halted()
        except:
            wait_for_halted_asserted = True
        assert wait_for_halted_asserted
        dmcontrol = dmcontrol & ~(1 << 1)
        rsp = await core_mini_axi.dm_write(0x10, dmcontrol)
        assert rsp["op"] == DmRspOp.SUCCESS
        await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_axi_debug_halt_resume(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/noop.elf"), "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

        await core_mini_axi.dm_request_halt()

        # Start the core so we're ungated (can we do something better here?)
        await core_mini_axi.execute_from(entry_point)

        # Probe for halted
        await core_mini_axi.dm_wait_for_halted()
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr_cause = (dcsr >> 6) & 0b111
        assert (dcsr_cause == 3)

        await ClockCycles(core_mini_axi.dut.io_aclk, 1000)
        # We are halted via debug, so the program should not have executed.
        assert core_mini_axi.dut.io_halted.value == 0

        await core_mini_axi.dm_request_resume()

        await core_mini_axi.dm_wait_for_resumed()

        await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_axi_debug_hartsel(dut):
    # This should be 1
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    # Write all 1s to hartsel, read back to see the real count
    dmcontrol = await core_mini_axi.dm_read(0x10)
    dmcontrol = dmcontrol | (0xFFFFF << 6)
    rsp = await core_mini_axi.dm_write(0x10, dmcontrol)
    assert rsp["op"] == DmRspOp.SUCCESS
    dmcontrol = await core_mini_axi.dm_read(0x10)
    hartsel = (dmcontrol >> 6) & 0xFFFFF
    assert (hartsel == 1)


@cocotb.test()
async def core_mini_axi_debug_abstract_access_registers(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/noop.elf"), "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.dm_request_halt()

        # Start the core so we're ungated (can we do something better here?)
        await core_mini_axi.execute_from(entry_point)

        # Probe for halted
        await core_mini_axi.dm_wait_for_halted()
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr_cause = (dcsr >> 6) & 0b111
        assert (dcsr_cause == 3)

        # Read back the mvendorid CSR
        mvendorid = await core_mini_axi.dm_read_reg(0xF11)
        assert (mvendorid == 0x426)

        regs = [
            0x7B2,  # dscratch0
            0x100a,  # a0
            0x1030,  # f10
        ]

        for reg in regs:
            new_val = random.randint(0, 2**32 - 1)

            # Write reg
            await core_mini_axi.dm_write_reg(reg, new_val)

            # Reset data0
            await core_mini_axi.dm_write(0x04, 0)

            # Read dscratch0
            readback = await core_mini_axi.dm_read_reg(reg)
            assert (readback == new_val)


@cocotb.test()
async def core_mini_axi_debug_abstract_access_nonexistent_register(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/noop.elf"), "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.dm_request_halt()
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.dm_wait_for_halted()

        # Read a non-existent register. This should fail.
        await core_mini_axi.dm_read_reg(0xDEAD, DmRspOp.FAILED)


@cocotb.test()
async def core_mini_axi_debug_single_step(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/noop.elf"), "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.dm_request_halt()

        # Start the core so we're ungated (can we do something better here?)
        await core_mini_axi.execute_from(entry_point)

        # Probe for halted
        await core_mini_axi.dm_wait_for_halted()
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr_cause = (dcsr >> 6) & 0b111
        assert (dcsr_cause == 3)

        # Write `step` in dcsr
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr = dcsr | (1 << 2)
        await core_mini_axi.dm_write_reg(0x7B0, dcsr)

        # Read `dpc`
        dpc = await core_mini_axi.dm_read_reg(0x7B1)

        for i in range(0, 3):
            await core_mini_axi.dm_request_resume()

            # Probe for halted to re-occur
            await core_mini_axi.dm_wait_for_halted()
            dcsr = await core_mini_axi.dm_read_reg(0x7B0)
            dcsr_cause = (dcsr >> 6) & 0b111
            assert (dcsr_cause == 4)

            # Check some CSRs?
            new_dpc = await core_mini_axi.dm_read_reg(0x7B1)
            assert (new_dpc == (dpc + 4))
            dpc = new_dpc

        # Clear `step` in dcsr
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr = dcsr & ~(1 << 2)
        await core_mini_axi.dm_write_reg(0x7B0, dcsr)

        await core_mini_axi.dm_request_resume()

        await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_axi_debug_breakpoint(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/noop.elf"), "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.dm_request_halt()

        # Start the core so we're ungated (can we do something better here?)
        await core_mini_axi.execute_from(entry_point)

        # Probe for halted
        await core_mini_axi.dm_wait_for_halted()
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr_cause = (dcsr >> 6) & 0b111
        assert (dcsr_cause == 3)

        main = core_mini_axi.lookup_symbol(f, "main")

        # Write 0 to tselect
        await core_mini_axi.dm_write_reg(0x7A0, 0)

        # Validate tinfo
        tinfo = await core_mini_axi.dm_read_reg(0x7A4)
        # Assert about tinfo
        assert tinfo == 0x01000040

        # Write 0 to tdata1, read back
        await core_mini_axi.dm_write_reg(0x7A1, 0)
        tdata1 = await core_mini_axi.dm_read_reg(0x7A1)
        # Check that the trigger is type 6
        assert (tdata1 & 0x60000000) == 0x60000000

        # Write tdata2
        await core_mini_axi.dm_write_reg(0x7A2, main)
        # TODO(atv): Actually make tdata1 mutable-ish instead of fixed config.
        # Even if that just disable things.
        # Write mcontext6-type data to tdata1
        # tdata1 = tdata1 |...
        desired_tdata1 = 0x68001044
        await core_mini_axi.dm_write_reg(0x7A1, desired_tdata1)
        tdata1 = await core_mini_axi.dm_read_reg(0x7A1)
        assert tdata1 == desired_tdata1

        # Request resume
        await core_mini_axi.dm_request_resume()

        # Probe for halted to re-occur
        await core_mini_axi.dm_wait_for_halted()
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr_cause = (dcsr >> 6) & 0b111
        assert (dcsr_cause == 2)

        new_dpc = await core_mini_axi.dm_read_reg(0x7B1)
        assert (new_dpc == main)

        # Tick a few cycles, we should still be halted.
        await ClockCycles(core_mini_axi.dut.io_aclk, 100)
        await core_mini_axi.dm_wait_for_halted()

        # Clear breakpoint
        await core_mini_axi.dm_write_reg(0x7A0, 0)
        await core_mini_axi.dm_write_reg(0x7A1, 0)
        await core_mini_axi.dm_write_reg(0x7A2, 0)

        # Request resume
        await core_mini_axi.dm_request_resume()

        # Assert that the program eventually terminates successfully.
        await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_axi_debug_scalar_registers(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/registers.elf"),
              "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_wfi()

        await core_mini_axi.dm_request_halt()
        await core_mini_axi.dm_wait_for_halted()

        # After WFI, check that the registers have their expected values.
        for i in range(1, 32):
            scalar = await core_mini_axi.dm_read_reg(i + 0x1000)
            expected_val = (1 << i)
            assert (scalar == expected_val)

        flt = await core_mini_axi.dm_read_reg(0x1020)
        assert (flt == 0)
        for i in range(1, 32):
            flt = await core_mini_axi.dm_read_reg(i + 0x1020)
            expected_val = (1 << i)
            assert (flt == expected_val)

        # Write x30 and x31 to the same value, so the test case
        # exits successfully.
        await core_mini_axi.dm_write_reg(0x101e, 0xdeadbeef)
        await core_mini_axi.dm_write_reg(0x101f, 0xdeadbeef)
        await core_mini_axi.dm_request_resume()
        # NB: We don't raise_irq here, because the debug halt resolves WFI.

        await core_mini_axi.wait_for_halted()
        assert core_mini_axi.dut.io_fault.value == 0


@cocotb.test()
async def core_mini_axi_debug_trigger_match(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    with open(r.Rlocation("coralnpu_hw/tests/cocotb/debug_trigger_test.elf"),
              "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

        await core_mini_axi.dm_request_halt()
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.dm_wait_for_halted()

        addr_b = core_mini_axi.lookup_symbol(f, "trigger_target")
        tdata1_val = 0x68001044

        await core_mini_axi.dm_write_reg(0x7A0, 0)  # Select trigger 0
        await core_mini_axi.dm_write_reg(
            0x7A1, tdata1_val
        )  # Configure trigger 0 (tdata1)
        await core_mini_axi.dm_write_reg(
            0x7A2, addr_b
        )  # Set match address (tdata2)

        await core_mini_axi.dm_request_resume()

        # Wait for trigger halt
        await core_mini_axi.dm_wait_for_halted()

        # Verify cause is trigger (2)
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr_cause = (dcsr >> 6) & 0b111
        assert dcsr_cause == 2, f"Expected trigger cause (2), got {dcsr_cause}"

        # Verify dpc is AddrB
        dpc = await core_mini_axi.dm_read_reg(0x7B1)
        assert dpc == addr_b, f"Expected dpc to be trigger_target ({hex(addr_b)}), got {hex(dpc)}"

        # Verify x1 is 1 (Instruction B not executed yet)
        x1_val = await core_mini_axi.dm_read_reg(0x1001)
        assert x1_val == 1, f"Expected x1 to be 1, got {x1_val}"

        # Re-program trigger 0 to match end_target
        addr_end = core_mini_axi.lookup_symbol(f, "end_target")
        await core_mini_axi.dm_write_reg(0x7A0, 0)  # Select trigger 0
        await core_mini_axi.dm_write_reg(
            0x7A2, addr_end
        )  # Set match address (tdata2)

        # Resume
        await core_mini_axi.dm_request_resume()

        # Wait for trigger halt at end_target
        await core_mini_axi.dm_wait_for_halted()

        # Verify cause is trigger (2)
        dcsr = await core_mini_axi.dm_read_reg(0x7B0)
        dcsr_cause = (dcsr >> 6) & 0b111
        assert dcsr_cause == 2, f"Expected trigger cause (2), got {dcsr_cause}"

        # Verify dpc is AddrEnd
        dpc = await core_mini_axi.dm_read_reg(0x7B1)
        assert dpc == addr_end, f"Expected dpc to be end_target ({hex(addr_end)}), got {hex(dpc)}"

        # Verify final x1 is 3 (not 4)
        x1_val_final = await core_mini_axi.dm_read_reg(0x1001)
        assert x1_val_final == 3, f"Expected final x1 to be 3, got {x1_val_final} (Duplicate execution detected!)"
