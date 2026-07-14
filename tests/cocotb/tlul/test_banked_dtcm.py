# Copyright 2026 Google LLC
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
import random
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, ClockCycles
from coralnpu_test_utils.TileLinkULInterface import TileLinkULInterface, create_a_channel_req
from coralnpu_test_utils.TlulVerificationEnv import TlulVerificationEnv

# Banked DTCM Parameters (matching Chisel configuration)
NUM_BANKS = 8
NUM_HOSTS = 3
BANK_SIZE = 0x1000  # 4kB
DTCM_BASE = 0x10000
DTCM_SIZE = NUM_BANKS * BANK_SIZE  # 32kB
DATA_WIDTH = 128
FULL_MASK = (1 << (DATA_WIDTH // 8)) - 1  # 0xFFFF for 128-bit


async def setup_dut(dut):
    """Common setup for all tests."""
    clock = Clock(dut.clock, 10, unit="ns")
    cocotb.start_soon(clock.start())
    dut.reset.value = 1
    await ClockCycles(dut.clock, 5)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


def get_bank_addr_range(bank_idx):
    start = DTCM_BASE + bank_idx * BANK_SIZE
    end = start + BANK_SIZE
    return start, end


@cocotb.test()
async def test_basic_read_write(dut):
    """Write and read from each bank to verify basic functionality."""
    await setup_dut(dut)
    env = TlulVerificationEnv(dut, get_master_from_source_cb=lambda src: 0)
    await env.start()

    # We have 3 hosts
    assert len(env.hosts) == NUM_HOSTS

    for i in range(NUM_BANKS):
        # Route bank i accesses through host i % NUM_HOSTS
        host = env.hosts[i % NUM_HOSTS]
        start_addr, _ = get_bank_addr_range(i)

        # Test offset 0, 16, 32 within the bank
        for offset in [0, 16, 32]:
            addr = start_addr + offset
            wdata = random.randint(0, 2**DATA_WIDTH - 1)

            dut._log.info(
                f"Bank {i} (via Host {i % NUM_HOSTS}): Writing to addr 0x{addr:x} with data 0x{wdata:x}"
            )
            # Write
            req = create_a_channel_req(
                address=addr,
                data=wdata,
                mask=FULL_MASK,
                width=DATA_WIDTH,
                is_read=False
            )
            await host.host_put(req)
            resp = await host.host_get_response()
            assert resp[
                "opcode"
            ] == 0, f"Expected AccessAck (0) for write to addr 0x{addr:x}, got {resp['opcode']}"
            assert resp["error"] == 0, f"Write error at addr 0x{addr:x}"

            # Read back
            dut._log.info(
                f"Bank {i} (via Host {i % NUM_HOSTS}): Reading from addr 0x{addr:x}"
            )
            req = create_a_channel_req(
                address=addr, width=DATA_WIDTH, is_read=True
            )
            await host.host_put(req)
            resp = await host.host_get_response()
            assert resp[
                "opcode"
            ] == 1, f"Expected AccessAckData (1) for read from addr 0x{addr:x}, got {resp['opcode']}"
            assert resp["error"] == 0, f"Read error at addr 0x{addr:x}"
            assert int(
                resp["data"]
            ) == wdata, f"Data mismatch at addr 0x{addr:x}: got 0x{int(resp['data']):x}, expected 0x{wdata:x}"
    await env.stop()


@cocotb.test()
async def test_isolation(dut):
    """Verify that writing to one bank does not affect other banks (isolation)."""
    await setup_dut(dut)
    env = TlulVerificationEnv(dut, get_master_from_source_cb=lambda src: 0)
    await env.start()

    # Write unique pattern to each bank at offset 0
    patterns = []
    for i in range(NUM_BANKS):
        patterns.append(random.randint(0, 2**DATA_WIDTH - 1))

    # Write to all banks
    for i in range(NUM_BANKS):
        host = env.hosts[i % NUM_HOSTS]
        addr, _ = get_bank_addr_range(i)
        req = create_a_channel_req(
            address=addr,
            data=patterns[i],
            mask=FULL_MASK,
            width=DATA_WIDTH,
            is_read=False
        )
        await host.host_put(req)
        resp = await host.host_get_response()
        assert resp["opcode"] == 0
        assert resp["error"] == 0

    # Read back and verify they are still isolated
    for i in range(NUM_BANKS):
        host = env.hosts[i % NUM_HOSTS]
        addr, _ = get_bank_addr_range(i)
        req = create_a_channel_req(
            address=addr, width=DATA_WIDTH, is_read=True
        )
        await host.host_put(req)
        resp = await host.host_get_response()
        assert resp["opcode"] == 1
        assert resp["error"] == 0
        assert int(resp["data"]) == patterns[
            i
        ], f"Bank {i} was corrupted! Got 0x{int(resp['data']):x}, expected 0x{patterns[i]:x}"
    await env.stop()


@cocotb.test()
async def test_concurrency(dut):
    """Verify concurrent accesses to 3 different banks simultaneously."""
    await setup_dut(dut)
    env = TlulVerificationEnv(dut, get_master_from_source_cb=lambda src: src)
    await env.start()

    # Prepare transactions for 3 selected banks
    patterns = {}
    selected_banks = [0, 3, 6]
    for bank_idx in selected_banks:
        patterns[bank_idx] = random.randint(0, 2**DATA_WIDTH - 1)

    async def drive_write(host, addr, data, source):
        req = create_a_channel_req(
            address=addr,
            data=data,
            mask=FULL_MASK,
            width=DATA_WIDTH,
            is_read=False,
            source=source
        )
        await host.host_put(req)
        resp = await host.host_get_response()
        return resp

    # Launch 3 writes concurrently to 3 different banks from 3 different hosts
    tasks = []
    for i, bank_idx in enumerate(selected_banks):
        addr, _ = get_bank_addr_range(bank_idx)
        tasks.append(
            cocotb.start_soon(
                drive_write(env.hosts[i], addr, patterns[bank_idx], source=i)
            )
        )

    # Wait for all writes to finish
    for task in tasks:
        resp = await task
        assert resp["opcode"] == 0
        assert resp["error"] == 0

    # Now launch 3 reads concurrently
    async def drive_read(host, addr, source):
        req = create_a_channel_req(
            address=addr, width=DATA_WIDTH, is_read=True, source=source
        )
        await host.host_put(req)
        resp = await host.host_get_response()
        return resp

    read_tasks = []
    for i, bank_idx in enumerate(selected_banks):
        addr, _ = get_bank_addr_range(bank_idx)
        read_tasks.append(
            cocotb.start_soon(drive_read(env.hosts[i], addr, source=i))
        )

    # Verify read data
    for i, bank_idx in enumerate(selected_banks):
        resp = await read_tasks[i]
        assert resp["opcode"] == 1
        assert resp["error"] == 0
        assert int(resp["data"]) == patterns[
            bank_idx
        ], f"Concurrency mismatch in bank {bank_idx}: got 0x{int(resp['data']):x}, expected 0x{patterns[bank_idx]:x}"
    await env.stop()


@cocotb.test()
async def test_out_of_bounds(dut):
    """Verify that out-of-bounds accesses return error responses."""
    await setup_dut(dut)
    env = TlulVerificationEnv(dut, get_master_from_source_cb=lambda src: 0)
    await env.start()

    host = env.hosts[0]

    # Write to out of bounds address (e.g. 0x18000)
    oob_addr = DTCM_BASE + DTCM_SIZE
    dut._log.info(f"OOB Test: Writing to out-of-bounds address 0x{oob_addr:x}")
    req = create_a_channel_req(
        address=oob_addr,
        data=0xDEADBEEF,
        mask=FULL_MASK,
        width=DATA_WIDTH,
        is_read=False
    )
    await host.host_put(req)
    resp = await host.host_get_response()
    assert resp["opcode"] == 0
    assert resp[
        "error"
    ] == 1, f"Expected error response for OOB write to 0x{oob_addr:x}"

    # Read from out of bounds address
    dut._log.info(
        f"OOB Test: Reading from out-of-bounds address 0x{oob_addr:x}"
    )
    req = create_a_channel_req(
        address=oob_addr, width=DATA_WIDTH, is_read=True
    )
    await host.host_put(req)
    resp = await host.host_get_response()
    assert resp["opcode"] == 1
    assert resp[
        "error"
    ] == 1, f"Expected error response for OOB read from 0x{oob_addr:x}"

    await env.stop()
