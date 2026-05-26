# Copyright 2025 Google LLC
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

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, RisingEdge, FallingEdge, with_timeout
from elftools.elf.elffile import ELFFile
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.TileLinkULInterface import TileLinkULInterface, create_a_channel_req
from coralnpu_test_utils.axi_slave import AxiSlave
from coralnpu_test_utils.backdoor import backdoor_load
from coralnpu_test_utils.spi_master import SPIMaster

# --- Constants ---
BUS_WIDTH_BITS = 128
BUS_WIDTH_BYTES = 16

async def setup_dut(dut, boot_addr=0):
    """Common setup logic for all tests."""
    # Default all TL-UL input signals to a safe state
    for dev in ["rom", "uart0", "uart1", "i2c_master"]:
        getattr(dut, f"io_external_devices_{dev}_d_valid").value = 0

    getattr(dut, f"io_external_ports_dm_req_valid").value = 0 # DM req valid
    getattr(dut, f"io_external_ports_dm_rsp_ready").value = 0 # DM rsp ready
    dut.io_external_ports_boot_addr.value = boot_addr

    # Start the main clock
    clock = Clock(dut.io_clk_i, 10, "ns")
    cocotb.start_soon(clock.start())

    # Start the asynchronous test clock
    test_clock = Clock(dut.io_async_ports_hosts_test_clock, 20, "ns")
    cocotb.start_soon(test_clock.start())

    # Reset the DUT
    dut.io_rst_ni.value = 0
    dut.io_async_ports_hosts_test_reset.value = 1
    await ClockCycles(dut.io_clk_i, 5)
    dut.io_rst_ni.value = 1
    dut.io_async_ports_hosts_test_reset.value = 0
    await ClockCycles(dut.io_clk_i, 5)

    # Add a final delay to ensure all reset synchronizers have settled
    await ClockCycles(dut.io_clk_i, 10)

    return clock

async def load_elf(dut, elf_file, host_if=None, backdoor: bool = True):
    """Loads an ELF into DUT memory and returns the entry point.

    Defaults to the fast `load_elf_backdoor` path. Pass `backdoor=False` (and
    a `host_if`) to force the classic TLUL host bus-write path
    (`load_elf_tlul_host`) for tests that specifically exercise frontdoor
    loading. Tests that exercise the spi2tlul frontdoor path should call
    `load_elf_via_spi` directly.
    """
    if backdoor:
        return await load_elf_backdoor(dut, elf_file)
    assert host_if is not None, "frontdoor TLUL load requires host_if"
    return await load_elf_tlul_host(dut, elf_file, host_if)


async def load_elf_backdoor(dut, elf_file):
    """Loads an ELF into DUT memory via the sram_backdoor DPI.

    Skips bus traffic entirely; reaches into Chisel-emitted SRAMs through
    the same `sram_backdoor_load_c` symbol used by `CoreMiniAxiInterface`.
    """
    elf = ELFFile(elf_file)
    entry_point = elf.header.e_entry
    for segment in elf.iter_segments(type='PT_LOAD'):
        paddr = segment.header.p_paddr
        data = np.frombuffer(segment.data(), dtype=np.uint8)
        if len(data) == 0:
            continue
        dut._log.info(f"Backdoor loading {len(data)} bytes to 0x{paddr:08x}")
        backdoor_load(paddr, data)
    return entry_point


async def load_elf_tlul_host(dut, elf_file, host_if):
    """Parses an ELF file and loads its segments into memory via TileLink."""
    elf = ELFFile(elf_file)
    entry_point = elf.header.e_entry

    for segment in elf.iter_segments():
        if segment.header.p_type == 'PT_LOAD':
            paddr = segment.header.p_paddr
            data = segment.data()
            dut._log.info(f"Loading segment at 0x{paddr:08x}, size {len(data)} bytes")

            # Write segment data in bus-width chunks (128 bits)
            for i in range(0, len(data), BUS_WIDTH_BYTES):
                line_addr = paddr + i
                # Handle potentially short final line
                line_data = data[i:i+BUS_WIDTH_BYTES]
                current_len = len(line_data)
                while len(line_data) < BUS_WIDTH_BYTES:
                    line_data += b'\x00'

                # Convert bytes to integer for the transaction
                int_data = int.from_bytes(line_data, byteorder='little')

                # Calculate mask based on actual data length
                mask = (1 << current_len) - 1

                # Create and send the write transaction
                write_txn = create_a_channel_req(
                    address=line_addr,
                    data=int_data,
                    mask=mask,
                    width=BUS_WIDTH_BITS # 128
                )
                if host_if.width == 32:
                   for j in range(0, current_len, 4):
                       word_addr = line_addr + j
                       word_data = line_data[j:j+4]
                       int_word = int.from_bytes(word_data, byteorder='little')
                       mask = (1 << len(word_data)) - 1
                       write_txn_32 = create_a_channel_req(
                           address=word_addr,
                           data=int_word,
                           mask=mask,
                           width=32
                       )
                       await host_if.host_put(write_txn_32)
                       resp = await host_if.host_get_response()
                       assert resp["error"] == 0, f"Error writing to 0x{word_addr:08x}"
                else:
                    await host_if.host_put(write_txn)
                    # Wait for the acknowledgment
                    resp = await host_if.host_get_response()
                    assert resp["error"] == 0, f"Received error response while writing to 0x{line_addr:08x}"

    return entry_point

async def load_elf_via_spi(dut, elf_file, spi_master):
    """Parses an ELF file and loads its segments into memory via SPI."""
    elf = ELFFile(elf_file)
    entry_point = elf.header.e_entry

    for segment in elf.iter_segments():
        if segment.header.p_type == 'PT_LOAD':
            paddr = segment.header.p_paddr
            data = segment.data()
            dut._log.info(f"Loading segment at 0x{paddr:08x}, size {len(data)} bytes via SPI")

            # Load data line by line
            for i in range(0, len(data), BUS_WIDTH_BYTES):
                line_addr = paddr + i
                line_data = data[i:i+BUS_WIDTH_BYTES]
                while len(line_data) < BUS_WIDTH_BYTES:
                    line_data += b'\x00'
                int_data = int.from_bytes(line_data, byteorder='little')
                dut._log.info(f"Loading line at 0x{line_addr:08x}")
                await write_line_via_spi(spi_master, line_addr, int_data)

    return entry_point


async def read_line_via_spi(spi_master, address):
    """Reads a full 128-bit bus line from a given address via the SPI bridge."""
    assert address % BUS_WIDTH_BYTES == 0, f"Address 0x{address:X} is not aligned to the bus width of {BUS_WIDTH_BYTES} bytes"
    return await spi_master.read_line(address)


async def update_line_via_spi(spi_master, address, data, mask):
    """Performs a read-modify-write to update a 128-bit line via SPI."""
    assert address % BUS_WIDTH_BYTES == 0, f"Address 0x{address:X} is not aligned to the bus width of {BUS_WIDTH_BYTES} bytes"
    line_data = await read_line_via_spi(spi_master, address)

    updated_data = 0
    for i in range(BUS_WIDTH_BYTES):
        byte_mask = (mask >> i) & 1
        if byte_mask:
            updated_data |= ((data >> (i * 8)) & 0xFF) << (i * 8)
        else:
            updated_data |= ((line_data >> (i * 8)) & 0xFF) << (i * 8)

    await write_line_via_spi(spi_master, address, updated_data)


async def write_line_via_spi(spi_master, address, data):
    """Writes a 128-bit bus line to a given address via the SPI bridge."""
    assert address % BUS_WIDTH_BYTES == 0, f"Address 0x{address:X} is not aligned to the bus width of {BUS_WIDTH_BYTES} bytes"
    await spi_master.write_line(address, data)


async def write_word_via_spi(spi_master, address, data):
    """Writes a 32-bit value to a specific address using the SPI bridge.

    Note: This function performs a read-modify-write operation on the underlying
    128-bit bus. It is not suitable for writing to memory-mapped registers
    where the read operation has side effects.
    """
    line_addr = (address // BUS_WIDTH_BYTES) * BUS_WIDTH_BYTES
    offset = address % BUS_WIDTH_BYTES
    mask = 0xF << offset
    shifted_data = data << (offset * 8)
    await update_line_via_spi(spi_master, line_addr, shifted_data, mask)

@cocotb.test()
async def test_tlul_passthrough(dut):
    """Drives a TL-UL transaction through an external host and device port."""
    clock = await setup_dut(dut)

    # Instantiate a TL-UL host to drive the first external host port (ibex_core_i)
    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)

    # Instantiate a TL-UL device to act as the first external device (rom)
    device_if = TileLinkULInterface(
        dut,
        device_if_name="io_external_devices_rom",
        clock_name="io_clk_i",
        reset_name="io_rst_ni",
        width=32)

    # Initialize the interfaces
    await host_if.init()
    await device_if.init()

    # --- Device Responder Task ---
    # This task mimics the behavior of the external ROM device.
    ROM_BASE_ADDR = 0x10000000
    TEST_SOURCE_ID = 5
    TEST_DATA = 0xCAFED00D

    async def device_responder():
        """A mock responder for the external ROM."""
        req = await device_if.device_get_request()

        # Verify the incoming request
        assert (req["opcode"] == 0) or (req["opcode"] == 1), f"Expected Put-type opcode (0 or 1), got {req['opcode']}"
        assert req["address"] == ROM_BASE_ADDR, f"Expected address {ROM_BASE_ADDR:X}, got {req['address']:X}"
        assert req["data"] == TEST_DATA, f"Expected data {TEST_DATA:X}, got {req['data']:X}"

        # Send an AccessAck response
        await device_if.device_respond(
            opcode=0,  # AccessAck
            param=0,
            size=req["size"],
            source=req["source"],
            error=0
        )

    # Start the device responder coroutine
    responder_task = cocotb.start_soon(device_responder())

    # --- Host Stimulus ---
    # Create and send a 'PutFullData' request from the host.
    write_txn = create_a_channel_req(
        address=ROM_BASE_ADDR,
        source=TEST_SOURCE_ID,
        data=TEST_DATA,
        mask=0xF, # Full mask for 32 bits
        width=host_if.width
    )
    await host_if.host_put(write_txn)

    # Wait for and verify the response.
    resp = await host_if.host_get_response()
    assert resp["error"] == 0, "Response indicated an error"
    assert resp["source"] == TEST_SOURCE_ID, f"Expected source ID {TEST_SOURCE_ID}, got {resp['source']}"
    assert resp["opcode"] == 0, f"Expected AccessAck opcode (0), got {resp['opcode']}"

    # Ensure the responder task finished cleanly.
    await responder_task

@cocotb.test()
async def test_program_execution_via_host(dut):
    """Loads and executes a program via an external host port.

    Pinned to the frontdoor TLUL-host load path: this is the regression
    test for `load_elf_tlul_host`. Other tests in this file silently use
    the backdoor default.
    """
    clock = await setup_dut(dut)

    # Instantiate a TL-UL host
    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)

    # Initialize the interface
    await host_if.init()

    # Find and load the ELF file
    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/arithmetics/rvv_add_int32_m1.elf")
    assert elf_path, "Could not find ELF file"

    with open(elf_path, "rb") as f:
        entry_point = await load_elf(dut, f, host_if, backdoor=False)

    dut._log.info(f"Program loaded. Entry point: 0x{entry_point:08x}")

    # --- Execute Program ---
    # From the integration guide:
    # 1. Program the start PC
    # 2. Release clock gate
    # 3. Release reset

    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    # Program the start PC
    dut._log.info(f"Programming start PC to 0x{entry_point:08x}")
    write_txn = create_a_channel_req(
        address=coralnpu_pc_csr_addr,
        data=entry_point,
        mask=0xF,
        width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # Release clock gate
    dut._log.info("Releasing clock gate...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr,
        data=1,
        mask=0xF,
        width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    await ClockCycles(dut.io_clk_i, 1)

    # Release reset
    dut._log.info("Releasing reset...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr,
        data=0,
        mask=0xF,
        width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # --- Wait for Completion ---
    dut._log.info("Waiting for program to halt...")
    timeout_cycles = 100000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:  # This else belongs to the for loop, executed if the loop finishes without break
        assert False, f"Timeout: Program did not halt within {timeout_cycles} cycles."

    dut._log.info("Program halted.")
    assert dut.io_external_ports_fault.value == 0, "Program halted with fault!"

@cocotb.test()
async def test_program_execution_via_spi(dut):
    """Loads and executes a program via the SPI to TL-UL bridge."""
    clock = await setup_dut(dut)

    spi_master = SPIMaster(
        clk=dut.io_external_ports_spi_clk,
        csb=dut.io_external_ports_spi_csb,
        mosi=dut.io_external_ports_spi_mosi,
        miso=dut.io_external_ports_spi_miso,
        main_clk=dut.io_clk_i,
        log=dut._log
    )
    await spi_master.idle_clocking(20)

    # Find and load the ELF file
    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/arithmetics/rvv_add_int32_m1.elf")
    assert elf_path, "Could not find ELF file"

    with open(elf_path, "rb") as f:
        entry_point = await load_elf_via_spi(dut, f, spi_master)

    dut._log.info(f"Program loaded via SPI. Entry point: 0x{entry_point:08x}")

    # --- Execute Program ---
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    # Program the start PC
    dut._log.info(f"Programming start PC to 0x{entry_point:08x}")
    await write_word_via_spi(spi_master, coralnpu_pc_csr_addr, entry_point)

    # Release clock gate
    dut._log.info("Releasing clock gate...")
    await write_word_via_spi(spi_master, coralnpu_reset_csr_addr, 1)

    await ClockCycles(dut.io_clk_i, 1)

    # Release reset
    dut._log.info("Releasing reset...")
    await write_word_via_spi(spi_master, coralnpu_reset_csr_addr, 0)

    # --- Wait for Completion ---
    dut._log.info("Waiting for program to halt...")
    timeout_cycles = 100000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:  # This else belongs to the for loop, executed if the loop finishes without break
        assert False, f"Timeout: Program did not halt within {timeout_cycles} cycles."

    dut._log.info("Program halted.")
    assert dut.io_external_ports_fault.value == 0, "Program halted with fault!"

@cocotb.test()
async def test_ddr_access(dut):
    """Tests TileLink transactions to the DDR domain."""
    await setup_dut(dut)

    # --- DDR Clock and Reset Setup ---
    ddr_clk_signal = dut.io_async_ports_devices_ddr_clock
    ddr_rst_signal = dut.io_async_ports_devices_ddr_reset
    ddr_rst_signal.value = 1

    ddr_clock = Clock(ddr_clk_signal, 2, "ns")
    cocotb.start_soon(ddr_clock.start())

    ddr_rst_signal.value = 0
    await ClockCycles(dut.io_clk_i, 5)
    ddr_rst_signal.value = 1
    await ClockCycles(dut.io_clk_i, 5)
    ddr_rst_signal.value = 0
    await ClockCycles(dut.io_clk_i, 5)

    # Instantiate a TL-UL host to drive transactions
    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # --- AXI Responder Models ---
    DDR_CTRL_BASE = 0x70000000
    DDR_MEM_BASE = 0x80000000
    TEST_DATA = 0x12345678

    ddr_ctrl_slave = AxiSlave(dut, "ddr_ctrl_axi", ddr_clk_signal, ddr_rst_signal, dut._log, has_memory=True, mem_base_addr=DDR_CTRL_BASE)
    ddr_mem_slave = AxiSlave(dut, "ddr_mem_axi", ddr_clk_signal, ddr_rst_signal, dut._log, has_memory=True, mem_base_addr=DDR_MEM_BASE)
    ddr_ctrl_slave.start()
    ddr_mem_slave.start()

    # Allow the AXI slave coroutines to start and initialize signals
    await RisingEdge(ddr_clk_signal)

    # --- Stimulus ---
    # Write to ddr_ctrl
    dut._log.info("Sending write to ddr_ctrl...")
    write_txn = create_a_channel_req(address=DDR_CTRL_BASE, data=TEST_DATA, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await with_timeout(host_if.host_get_response(), 10000, "ns")
    assert resp["error"] == 0, "ddr_ctrl write response indicated an error"
    dut._log.info("Write to ddr_ctrl successful.")

    # Write to ddr_mem
    dut._log.info("Sending write to ddr_mem...")
    write_txn = create_a_channel_req(address=DDR_MEM_BASE, data=TEST_DATA, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0, "ddr_mem write response indicated an error"
    dut._log.info("Write to ddr_mem successful.")

    dut._log.info("Sending read to ddr_ctrl...")
    read_txn = create_a_channel_req(address=DDR_CTRL_BASE, width=host_if.width, is_read=True)
    await host_if.host_put(read_txn)
    resp = await with_timeout(host_if.host_get_response(), 10000, "ns")
    assert resp["error"] == 0, "ddr_ctrl read response had error"
    dut._log.info("Read from ddr_ctrl successful.")

    dut._log.info("Sending read to ddr_mem...")
    read_txn = create_a_channel_req(address=DDR_MEM_BASE, width=host_if.width, is_read=True)
    await host_if.host_put(read_txn)
    resp = await with_timeout(host_if.host_get_response(), 10000, "ns")
    assert resp["error"] == 0, "ddr_mem read response had error"
    dut._log.info("Read from ddr_mem successful.")

    await ClockCycles(dut.io_clk_i, 20)

@cocotb.test()
async def test_ddr_access_via_spi(dut):
    clock = await setup_dut(dut)

    spi_master = SPIMaster(
        clk=dut.io_external_ports_spi_clk,
        csb=dut.io_external_ports_spi_csb,
        mosi=dut.io_external_ports_spi_mosi,
        miso=dut.io_external_ports_spi_miso,
        main_clk=dut.io_clk_i,
        log=dut._log
    )
    await spi_master.idle_clocking(20)

    # --- DDR Clock and Reset Setup ---
    ddr_clk_signal = dut.io_async_ports_devices_ddr_clock
    ddr_rst_signal = dut.io_async_ports_devices_ddr_reset
    ddr_rst_signal.value = 1

    ddr_clock = Clock(ddr_clk_signal, 2, "ns")
    cocotb.start_soon(ddr_clock.start())

    ddr_rst_signal.value = 0
    await ClockCycles(dut.io_clk_i, 5)
    ddr_rst_signal.value = 1
    await ClockCycles(dut.io_clk_i, 5)
    ddr_rst_signal.value = 0
    await ClockCycles(dut.io_clk_i, 5)

    # --- AXI Responder Models ---
    DDR_MEM_BASE = 0x80000000
    ddr_mem_slave = AxiSlave(dut, "ddr_mem_axi", ddr_clk_signal, ddr_rst_signal, dut._log, has_memory=True, mem_base_addr=DDR_MEM_BASE)
    ddr_mem_slave.start()

    # Allow the AXI slave coroutines to start and initialize signals
    await RisingEdge(ddr_clk_signal)


    data0 = 0x00112233445566778899AABBCCDDEEFF
    data1 = 0xFFEEDDCCBBAA99887766554433221100
    await write_line_via_spi(spi_master, DDR_MEM_BASE, data0)
    await write_line_via_spi(spi_master, DDR_MEM_BASE + 0x10, data1)

    rdata0 = await read_line_via_spi(spi_master, DDR_MEM_BASE)
    rdata1 = await read_line_via_spi(spi_master, DDR_MEM_BASE + 0x10)

    assert (data0 == rdata0)
    assert (data1 == rdata1)


@cocotb.test()
async def test_tlul_width_bridge_bug_reproduction(dut):
    """Reproduces the TlulWidthBridge bug by running a C++ program that performs 16-bit writes."""
    clock = await setup_dut(dut)

    # 1. Instantiate Host Interface (test_host_32)
    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # 2. Instantiate Device Interfaces
    # UART1 responder (port 3) for logging
    uart1_if = TileLinkULInterface(
        dut,
        device_if_name="io_external_devices_uart1",
        clock_name="io_clk_i",
        reset_name="io_rst_ni",
        width=32,
    )
    await uart1_if.init()

    # 3. Implement Responders
    async def uart1_responder():
        while True:
            req = await uart1_if.device_get_request()
            if int(req["opcode"]) in [0, 1]:
                # Simply ack writes to UART
                char = int(req["data"]) & 0xFF
                if char != 0:
                    import sys

                    sys.stdout.write(chr(char))
                    sys.stdout.flush()
                await uart1_if.device_respond(
                    opcode=0, param=0, size=req["size"], source=req["source"]
                )
            elif int(req["opcode"]) == 4:
                # Return status=0 (not full) for UART
                await uart1_if.device_respond(
                    opcode=1, param=0, size=req["size"], source=req["source"], data=0
                )

    cocotb.start_soon(uart1_responder())

    # 4. Load ELF
    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/rvv/arithmetics/rvv_add_int32_m1.elf"
    )
    assert elf_path, "Could not find rvv_add_int32_m1.elf"

    with open(elf_path, "rb") as f:
        entry_point = await load_elf(dut, f, host_if)

    dut._log.info(f"Program loaded. Entry point: 0x{entry_point:08x}")

    # 5. Execute Program
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    await host_if.host_put(
        create_a_channel_req(
            address=coralnpu_pc_csr_addr, data=entry_point, mask=0xF, width=32
        )
    )
    await host_if.host_get_response()

    await host_if.host_put(
        create_a_channel_req(
            address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=32
        )
    )
    await host_if.host_get_response()

    await ClockCycles(dut.io_clk_i, 1)

    await host_if.host_put(
        create_a_channel_req(
            address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=32
        )
    )
    await host_if.host_get_response()

    # 6. Wait for Completion
    dut._log.info("Waiting for program to halt...")
    timeout_cycles = 1000000  # Larger timeout for bug reproduction
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Program did not halt within {timeout_cycles} cycles."

    dut._log.info("Program halted.")
    # Check fault (port 1)
    assert dut.io_external_ports_fault.value == 0, "Program halted with fault!"


@cocotb.test()
async def test_timer_interrupt(dut):
    """Loads and executes the timer interrupt test. Verifies CLINT mtime/mtimecmp
    triggers a machine timer interrupt that is handled via mtvec."""
    clock = await setup_dut(dut)

    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # --- Sanity check: read CLINT mtime via test host ---
    CLINT_MTIME_LO = 0x0200BFF8
    read_txn = create_a_channel_req(
        address=CLINT_MTIME_LO, width=host_if.width, is_read=True)
    await host_if.host_put(read_txn)
    resp = await host_if.host_get_response()
    dut._log.info(f"CLINT mtime_lo read: data=0x{int(resp['data']):08x}, error={resp['error']}")
    assert resp["error"] == 0, "CLINT mtime read failed"
    mtime_val1 = resp["data"]

    await ClockCycles(dut.io_clk_i, 10)

    read_txn = create_a_channel_req(
        address=CLINT_MTIME_LO, width=host_if.width, is_read=True)
    await host_if.host_put(read_txn)
    resp = await host_if.host_get_response()
    dut._log.info(f"CLINT mtime_lo read (2nd): data=0x{int(resp['data']):08x}, error={resp['error']}")
    assert int(resp["data"]) > int(mtime_val1), "CLINT mtime is not incrementing"

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/timer_interrupt_test.elf")
    assert elf_path, "Could not find timer_interrupt_test.elf"

    with open(elf_path, "rb") as f:
        entry_point = await load_elf(dut, f, host_if)

    dut._log.info(f"Timer interrupt test loaded. Entry point: 0x{entry_point:08x}")

    # Program start PC, release clock gate, release reset
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    write_txn = create_a_channel_req(
        address=coralnpu_pc_csr_addr, data=entry_point, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    await ClockCycles(dut.io_clk_i, 1)

    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    dut._log.info("Waiting for timer interrupt test to complete...")
    timeout_cycles = 1_000_000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Program did not halt within {timeout_cycles} cycles."

    dut._log.info("Program halted.")
    # Check fault (port 1)
    assert dut.io_external_ports_fault.value == 0, "Program halted with fault!"
    dut._log.info("Timer interrupt test passed.")


@cocotb.test()
async def test_software_interrupt(dut):
    """Loads and executes the software interrupt test. Verifies CLINT msip
    triggers a machine software interrupt that is handled via mtvec."""
    clock = await setup_dut(dut)

    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/software_interrupt_test.elf")
    assert elf_path, "Could not find software_interrupt_test.elf"

    with open(elf_path, "rb") as f:
        entry_point = await load_elf(dut, f, host_if)

    dut._log.info(f"Software interrupt test loaded. Entry point: 0x{entry_point:08x}")

    # Program start PC, release clock gate, release reset
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    write_txn = create_a_channel_req(
        address=coralnpu_pc_csr_addr, data=entry_point, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    await ClockCycles(dut.io_clk_i, 1)

    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # Wait for program to reach the spin-wait loop
    await ClockCycles(dut.io_clk_i, 1000)

    # --- Trigger Software Interrupt ---
    CLINT_MSIP = 0x02000000
    dut._log.info("Triggering software interrupt via CLINT msip...")
    write_txn = create_a_channel_req(
        address=CLINT_MSIP, data=1, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    dut._log.info("Waiting for software interrupt test to complete...")
    timeout_cycles = 1_000_000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Program did not halt within {timeout_cycles} cycles."

    dut._log.info("Program halted.")
    # Check fault (port 1)
    assert dut.io_external_ports_fault.value == 0, "Program halted with fault!"
    dut._log.info("Software interrupt test passed.")


@cocotb.test()
async def test_plic(dut):
    """Loads and executes the PLIC test. Verifies PLIC can handle both level
    and edge triggered interrupts."""
    clock = await setup_dut(dut)

    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # UART1 responder for logging
    uart1_if = TileLinkULInterface(
        dut,
        device_if_name="io_external_devices_uart1",
        clock_name="io_clk_i",
        reset_name="io_rst_ni",
        width=32,
    )
    await uart1_if.init()

    async def uart1_responder():
        while True:
            req = await uart1_if.device_get_request()
            if int(req["opcode"]) in [0, 1]:
                char = int(req["data"]) & 0xFF
                if char != 0:
                    import sys
                    sys.stdout.write(chr(char))
                    sys.stdout.flush()
                await uart1_if.device_respond(
                    opcode=0, param=0, size=req["size"], source=req["source"]
                )
            elif int(req["opcode"]) == 4:
                await uart1_if.device_respond(
                    opcode=1, param=0, size=req["size"], source=req["source"], data=0
                )

    cocotb.start_soon(uart1_responder())

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/plic_test.elf")
    assert elf_path, "Could not find plic_test.elf"

    with open(elf_path, "rb") as f:
        entry_point = await load_elf(dut, f, host_if)

    dut._log.info(f"PLIC test loaded. Entry point: 0x{entry_point:08x}")

    # Program start PC, release clock gate, release reset
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    write_txn = create_a_channel_req(
        address=coralnpu_pc_csr_addr, data=entry_point, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    await host_if.host_get_response()

    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    await host_if.host_get_response()

    await ClockCycles(dut.io_clk_i, 1)

    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=host_if.width)
    await host_if.host_put(write_txn)
    await host_if.host_get_response()

    # Wait for program to configure PLIC
    await ClockCycles(dut.io_clk_i, 2000)

    # --- Trigger Source 1 (Level) ---
    dut._log.info("Triggering PLIC Source 1 (Level)...")
    dut.io_external_ports_ext_intrs.value = 1
    await ClockCycles(dut.io_clk_i, 100)
    # Level source stays high, but gateway should be 'waiting' after claim

    # --- Trigger Source 2 (Edge) ---
    dut._log.info("Triggering PLIC Source 2 (Edge)...")
    dut.io_external_ports_ext_intrs.value = 3 # bits [1:0] high. source 2 is bit 1.
    await ClockCycles(dut.io_clk_i, 10)
    dut.io_external_ports_ext_intrs.value = 1 # pulse source 2

    # Clear all sources eventually
    await ClockCycles(dut.io_clk_i, 1000)
    dut.io_external_ports_ext_intrs.value = 0

    dut._log.info("Waiting for PLIC test to complete...")
    timeout_cycles = 1_000_000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Program did not halt within {timeout_cycles} cycles."

    dut._log.info("Program halted.")
    # Check fault (port 1)
    assert dut.io_external_ports_fault.value == 0, "Program halted with fault!"
    dut._log.info("PLIC test passed.")


@cocotb.test()
async def test_ibus_fetch_from_sram(dut):
    """Tests instruction fetch via AXI bus from SRAM (execute from external memory).

    Loads a small hand-assembled program into SRAM at 0x20000000, sets pcStart
    to that address, and verifies the core can fetch and execute instructions
    via the ibus AXI path through the crossbar.
    """
    clock = await setup_dut(dut)

    # Host interface for programming CSRs and loading data
    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # --- Load a small RISC-V program into SRAM ---
    SRAM_BASE = 0x20000000
    DTCM_BASE = 0x00010000

    # Program:
    #   0x20000000: LUI  x1, 0x12345      # x1 = 0x12345000
    #   0x20000004: LUI  x2, 0x10         # x2 = 0x00010000 (DTCM base)
    #   0x20000008: SW   x1, 0(x2)        # Store 0x12345000 at DTCM[0]
    #   0x2000000C: MPAUSE                # Halt (halted=1, no fault)
    program = [
        0x123450B7,  # LUI x1, 0x12345
        0x00010137,  # LUI x2, 0x10
        0x00112023,  # SW  x1, 0(x2)
        0x08000073,  # MPAUSE
    ]

    for i, instr in enumerate(program):
        write_txn = create_a_channel_req(
            address=SRAM_BASE + i * 4,
            data=instr,
            mask=0xF,
            width=host_if.width
        )
        await host_if.host_put(write_txn)
        resp = await host_if.host_get_response()
        assert resp["error"] == 0, f"Error writing instruction {i} to SRAM"

    dut._log.info("Program loaded into SRAM.")

    # --- Execute program from SRAM ---
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    # Program the start PC to SRAM base
    dut._log.info(f"Programming start PC to 0x{SRAM_BASE:08x}")
    write_txn = create_a_channel_req(
        address=coralnpu_pc_csr_addr, data=SRAM_BASE, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # Release clock gate
    dut._log.info("Releasing clock gate...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    await ClockCycles(dut.io_clk_i, 1)

    # Release reset
    dut._log.info("Releasing reset...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # --- Wait for completion ---
    dut._log.info("Waiting for core to halt...")
    timeout_cycles = 10000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Core did not halt within {timeout_cycles} cycles."

    dut._log.info("Core halted.")
    assert dut.io_external_ports_fault.value == 0, "Core halted with fault!"

    # --- Verify the program wrote to DTCM ---
    # Read DTCM[0] via the test host -> crossbar -> coralnpu_device -> DTCM
    dut._log.info("Verifying DTCM write...")
    read_txn = create_a_channel_req(
        address=DTCM_BASE, width=host_if.width, is_read=True
    )
    await host_if.host_put(read_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0, "Error reading DTCM"

    read_data = int(resp["data"])
    expected = 0x12345000
    dut._log.info(f"DTCM[0] = 0x{read_data:08x} (expected 0x{expected:08x})")
    assert read_data == expected, \
        f"DTCM verification failed: got 0x{read_data:08x}, expected 0x{expected:08x}"

    dut._log.info("Test passed: instruction fetch from SRAM via AXI bus works correctly.")


@cocotb.test()
async def test_boot_addr_sram(dut):
    """Tests that the boot_addr wire sets pcStart on reset.

    Same as test_ibus_fetch_from_sram, but instead of writing pcStartReg
    via the test host CSR, relies on the boot_addr input wire to set the
    initial PC on system reset. This verifies the boot_addr → pcStartReg
    path that FPGA uses to boot from ROM.

    Uses SRAM (0x20000000) as the boot target since the test harness has
    a SRAM device port we can respond to.
    """
    SRAM_BASE = 0x20000000
    DTCM_BASE = 0x00010000

    # Pass boot_addr to setup_dut so it's driven before reset
    clock = await setup_dut(dut, boot_addr=SRAM_BASE)

    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # Load program into SRAM via test host (same program as test_ibus_fetch_from_sram)
    program = [
        0x123450B7,  # LUI x1, 0x12345
        0x00010137,  # LUI x2, 0x10
        0x00112023,  # SW  x1, 0(x2)
        0x08000073,  # MPAUSE
    ]

    for i, instr in enumerate(program):
        write_txn = create_a_channel_req(
            address=SRAM_BASE + i * 4, data=instr, mask=0xF, width=host_if.width
        )
        await host_if.host_put(write_txn)
        resp = await host_if.host_get_response()
        assert resp["error"] == 0, f"Error writing instruction {i} to SRAM"

    dut._log.info("Program loaded into SRAM.")

    # Do NOT write pcStartReg — it should already be SRAM_BASE from boot_addr wire.
    # Just release clock gate and reset.
    coralnpu_reset_csr_addr = 0x30000

    dut._log.info("Releasing clock gate...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    await ClockCycles(dut.io_clk_i, 1)

    dut._log.info("Releasing reset...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # Wait for completion
    dut._log.info("Waiting for core to halt...")
    timeout_cycles = 10000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Core did not halt within {timeout_cycles} cycles."

    dut._log.info("Core halted.")
    assert dut.io_external_ports_fault.value == 0, "Core halted with fault!"

    # Verify the program wrote to DTCM
    dut._log.info("Verifying DTCM write...")
    read_txn = create_a_channel_req(
        address=DTCM_BASE, width=host_if.width, is_read=True
    )
    await host_if.host_put(read_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0, "Error reading DTCM"

    read_data = int(resp["data"])
    expected = 0x12345000
    dut._log.info(f"DTCM[0] = 0x{read_data:08x} (expected 0x{expected:08x})")
    assert read_data == expected, \
        f"DTCM verification failed: got 0x{read_data:08x}, expected 0x{expected:08x}"

    dut._log.info("Test passed: boot_addr wire correctly sets pcStart on reset.")


@cocotb.test()
async def test_boot_addr_override(dut):
    """Tests that pcStartReg can be overridden by a CSR write.

    Verifies that even if boot_addr is set to one value (e.g. 0x12340000),
    writing to the pcStart CSR (offset 0x4) after system reset allows the
    core to boot from a different address (e.g. SRAM_BASE).
    """
    SRAM_BASE = 0x20000000
    DTCM_BASE = 0x00010000
    DUMMY_ADDR = 0x12340000

    # Pass dummy boot_addr to setup_dut so it's captured on reset
    clock = await setup_dut(dut, boot_addr=DUMMY_ADDR)

    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # Load program into SRAM via test host
    program = [
        0x123450B7,  # LUI x1, 0x12345
        0x00010137,  # LUI x2, 0x10
        0x00112023,  # SW  x1, 0(x2)
        0x08000073,  # MPAUSE
    ]

    for i, instr in enumerate(program):
        write_txn = create_a_channel_req(
            address=SRAM_BASE + i * 4, data=instr, mask=0xF, width=host_if.width
        )
        await host_if.host_put(write_txn)
        resp = await host_if.host_get_response()
        assert resp["error"] == 0, f"Error writing instruction {i} to SRAM"

    dut._log.info("Program loaded into SRAM.")

    # Override pcStartReg via CSR write
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    dut._log.info(f"Overriding pcStartReg with 0x{SRAM_BASE:08x}...")
    write_txn = create_a_channel_req(
        address=coralnpu_pc_csr_addr, data=SRAM_BASE, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # Release clock gate and reset
    dut._log.info("Releasing clock gate...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    await ClockCycles(dut.io_clk_i, 1)

    # Release reset
    dut._log.info("Releasing reset...")
    write_txn = create_a_channel_req(
        address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=host_if.width
    )
    await host_if.host_put(write_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0

    # Wait for completion
    dut._log.info("Waiting for core to halt...")
    timeout_cycles = 10000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Core did not halt within {timeout_cycles} cycles."

    dut._log.info("Core halted.")
    assert dut.io_external_ports_fault.value == 0, "Core halted with fault!"

    # Verify the program wrote to DTCM
    dut._log.info("Verifying DTCM write...")
    read_txn = create_a_channel_req(
        address=DTCM_BASE, width=host_if.width, is_read=True
    )
    await host_if.host_put(read_txn)
    resp = await host_if.host_get_response()
    assert resp["error"] == 0, "Error reading DTCM"

    read_data = int(resp["data"])
    expected = 0x12345000
    dut._log.info(f"DTCM[0] = 0x{read_data:08x} (expected 0x{expected:08x})")
    assert read_data == expected, \
        f"DTCM verification failed: got 0x{read_data:08x}, expected 0x{expected:08x}"

    dut._log.info("Test passed: pcStartReg CSR override works correctly.")

@cocotb.test()
async def test_ddr_burst_pattern_repro(dut):
    """Tests DDR burst patterns from the CPU's perspective."""
    clock = await setup_dut(dut)

    # 1. DDR Clock and Reset Setup
    ddr_clk_signal = dut.io_async_ports_devices_ddr_clock
    ddr_rst_signal = dut.io_async_ports_devices_ddr_reset
    ddr_rst_signal.value = 1
    ddr_clock = Clock(ddr_clk_signal, 2, "ns")
    cocotb.start_soon(ddr_clock.start())
    ddr_rst_signal.value = 0
    await ClockCycles(dut.io_clk_i, 5)
    ddr_rst_signal.value = 1
    await ClockCycles(dut.io_clk_i, 5)
    ddr_rst_signal.value = 0
    await ClockCycles(dut.io_clk_i, 5)

    # 2. Instantiate Host Interface (for loading ELF and programming CSRs)
    host_if = TileLinkULInterface(
        dut,
        host_if_name="io_external_hosts_test_host_32",
        clock_name="io_async_ports_hosts_test_clock",
        reset_name="io_async_ports_hosts_test_reset",
        width=32)
    await host_if.init()

    # 3. AXI Responder for DDR (0x80000000)
    DDR_MEM_BASE = 0x80000000
    ddr_mem_slave = AxiSlave(dut, "ddr_mem_axi", ddr_clk_signal, ddr_rst_signal, dut._log, has_memory=True, mem_base_addr=DDR_MEM_BASE)
    ddr_mem_slave.start()
    await RisingEdge(ddr_clk_signal)

    # 4. Load ddr_test.elf
    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/ddr_test.elf")
    assert elf_path, "Could not find ddr_test.elf"
    with open(elf_path, "rb") as f:
        entry_point = await load_elf(dut, f, host_if)
    dut._log.info(f"ddr_test.elf loaded. Entry point: 0x{entry_point:08x}")

    # 5. Execute Program
    coralnpu_pc_csr_addr = 0x30004
    coralnpu_reset_csr_addr = 0x30000

    # Program PC
    await host_if.host_put(create_a_channel_req(address=coralnpu_pc_csr_addr, data=entry_point, mask=0xF, width=32))
    await host_if.host_get_response()
    # Release clock gate
    await host_if.host_put(create_a_channel_req(address=coralnpu_reset_csr_addr, data=1, mask=0xF, width=32))
    await host_if.host_get_response()
    await ClockCycles(dut.io_clk_i, 1)
    # Release reset
    await host_if.host_put(create_a_channel_req(address=coralnpu_reset_csr_addr, data=0, mask=0xF, width=32))
    await host_if.host_get_response()

    # 6. Wait for Halt
    dut._log.info("Waiting for core to halt...")
    timeout_cycles = 100000
    for i in range(timeout_cycles):
        if dut.io_external_ports_halted.value == 1:
            break
        await ClockCycles(dut.io_clk_i, 1)
    else:
        assert False, f"Timeout: Core did not halt within {timeout_cycles} cycles."

    dut._log.info("Core halted. Checking DDR memory...")

    # 7. Verify DDR contents (First 16 words of 0x81000000)
    TEST_BASE_OFFSET = 0x01000000
    for i in range(16):
        expected = 0xA0000000 | (i << 8) | i
        addr = TEST_BASE_OFFSET + (i * 4)

        read_bytes = bytearray()
        for b in range(4):
            read_bytes.append(ddr_mem_slave.memory.get(addr + b, 0x00))
        actual = int.from_bytes(read_bytes, byteorder='little')

        if actual != expected:
            dut._log.error(f"DDR Mismatch at Offset {i*4:02x}: Expected {expected:08x}, Got {actual:08x}")
        else:
            dut._log.info(f"DDR Match at Offset {i*4:02x}: {actual:08x}")

    assert dut.io_external_ports_fault.value == 0, "Program halted with fault!"
    dut._log.info("DDR Burst Pattern Reproduction Test Finished.")
