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
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Combine
import random

from coralnpu_test_utils.TileLinkULInterface import create_a_channel_req
from coralnpu_test_utils.TlulVerificationEnv import TlulVerificationEnv


async def setup_dut(dut):
    """Common setup for all tests."""
    clock = Clock(dut.clock, 10, unit="ns")
    cocotb.start_soon(clock.start())
    dut.reset.value = 1
    await ClockCycles(dut.clock, 5)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


async def start_device_responders(env):
    """Starts background responder tasks for all discovered devices."""

    async def device_responder(device):
        while True:
            req = await device.device_get_request()
            opcode = 1 if req["opcode"
                              ] == 4 else 0  # 1=AccessAckData, 0=AccessAck
            await device.device_respond(
                opcode=opcode,
                param=0,
                size=req["size"],
                source=req["source"],
                data=0xabcdef00 + int(req["source"])  # Convert source to int
            )

    tasks = [cocotb.start_soon(device_responder(dev)) for dev in env.devices]
    return tasks


@cocotb.test()
async def test_concurrent_access(dut):
    """Verify that multiple hosts can access different banks concurrently without blocking."""
    await setup_dut(dut)

    # Disjoint ID mapping: Host i uses IDs starting at i * 16
    def get_master_from_source(source_id):
        return source_id // 16

    env = TlulVerificationEnv(dut, get_master_from_source)
    M = env.M
    N = env.N
    assert M == 3, f"Expected 3 hosts, got {M}"
    assert N == 8, f"Expected 8 banks, got {N}"

    StIdW = (M - 1).bit_length()  # log2Ceil(M)
    env.scoreboard.device_to_host_source_cb = lambda src: src >> StIdW
    await env.start()

    responder_tasks = await start_device_responders(env)

    try:
        base_addr = 0x10000
        bank_size = 0x1000

        # Host 0 -> Bank 0 (0x10000)
        # Host 1 -> Bank 1 (0x11000)
        # Host 2 -> Bank 2 (0x12000)

        req0 = create_a_channel_req(
            address=base_addr + 0 * bank_size, source=0 * 16 + 1, width=128
        )
        req1 = create_a_channel_req(
            address=base_addr + 1 * bank_size, source=1 * 16 + 1, width=128
        )
        req2 = create_a_channel_req(
            address=base_addr + 2 * bank_size, source=2 * 16 + 1, width=128
        )

        await env.hosts[0].host_put(req0)
        await env.hosts[1].host_put(req1)
        await env.hosts[2].host_put(req2)

        # Wait for drivers to assert valid
        await RisingEdge(dut.clock)
        await FallingEdge(dut.clock)

        # Verify they are all active and ready concurrently
        assert dut.io_tl_h_0_a_valid.value == 1, "Host 0 valid not asserted"
        assert dut.io_tl_h_0_a_ready.value == 1, "Host 0 ready not asserted (concurrency failure)"
        assert dut.io_tl_h_1_a_valid.value == 1, "Host 1 valid not asserted"
        assert dut.io_tl_h_1_a_ready.value == 1, "Host 1 ready not asserted (concurrency failure)"
        assert dut.io_tl_h_2_a_valid.value == 1, "Host 2 valid not asserted"
        assert dut.io_tl_h_2_a_ready.value == 1, "Host 2 ready not asserted (concurrency failure)"

        # Next cycle: they should all complete
        await RisingEdge(dut.clock)
        await FallingEdge(dut.clock)

        assert dut.io_tl_h_0_a_valid.value == 0, "Host 0 valid not deasserted"
        assert dut.io_tl_h_1_a_valid.value == 0, "Host 1 valid not deasserted"
        assert dut.io_tl_h_2_a_valid.value == 0, "Host 2 valid not deasserted"

        # Wait for responses to propagate to scoreboard
        resp0 = await env.hosts[0].host_get_response()
        resp1 = await env.hosts[1].host_get_response()
        resp2 = await env.hosts[2].host_get_response()

        assert resp0["source"] == 0 * 16 + 1
        assert resp1["source"] == 1 * 16 + 1
        assert resp2["source"] == 2 * 16 + 1

        assert env.scoreboard.errors == 0, f"Scoreboard detected errors: {env.scoreboard.errors}"

    finally:
        for task in responder_tasks:
            task.cancel()
        await env.stop()


@cocotb.test()
async def test_mixed_arbitration(dut):
    """Verify arbitration at one bank does not block concurrent access to another bank."""
    await setup_dut(dut)

    def get_master_from_source(source_id):
        return source_id // 16

    env = TlulVerificationEnv(dut, get_master_from_source)
    M = env.M
    N = env.N
    StIdW = (M - 1).bit_length()
    env.scoreboard.device_to_host_source_cb = lambda src: src >> StIdW
    await env.start()

    responder_tasks = await start_device_responders(env)

    try:
        base_addr = 0x10000
        bank_size = 0x1000

        # Host 0 -> Bank 0 (0x10000) - conflict (wins)
        # Host 1 -> Bank 0 (0x10000) - conflict (loses)
        # Host 2 -> Bank 1 (0x11000) - clean path

        req0 = create_a_channel_req(
            address=base_addr + 0 * bank_size, source=0 * 16 + 1, width=128
        )
        req1 = create_a_channel_req(
            address=base_addr + 0 * bank_size, source=1 * 16 + 1, width=128
        )
        req2 = create_a_channel_req(
            address=base_addr + 1 * bank_size, source=2 * 16 + 1, width=128
        )

        await env.hosts[0].host_put(req0)
        await env.hosts[1].host_put(req1)
        await env.hosts[2].host_put(req2)

        # Cycle 1: Drivers assert valid
        await RisingEdge(dut.clock)
        await FallingEdge(dut.clock)

        assert dut.io_tl_h_0_a_valid.value == 1
        assert dut.io_tl_h_0_a_ready.value == 1, "Host 0 should win arbitration"

        assert dut.io_tl_h_1_a_valid.value == 1
        assert dut.io_tl_h_1_a_ready.value == 0, "Host 1 should lose arbitration and be blocked"

        assert dut.io_tl_h_2_a_valid.value == 1
        assert dut.io_tl_h_2_a_ready.value == 1, "Host 2 should be accepted concurrently on Bank 1"

        # Cycle 2: Host 0 and 2 should have completed. Host 1 should now be accepted.
        await RisingEdge(dut.clock)
        await FallingEdge(dut.clock)

        assert dut.io_tl_h_0_a_valid.value == 0, "Host 0 should have finished"
        assert dut.io_tl_h_2_a_valid.value == 0, "Host 2 should have finished"

        assert dut.io_tl_h_1_a_valid.value == 1, "Host 1 should still be valid"
        assert dut.io_tl_h_1_a_ready.value == 1, "Host 1 should now be accepted"

        # Cycle 3: Host 1 should have completed.
        await RisingEdge(dut.clock)
        await FallingEdge(dut.clock)
        assert dut.io_tl_h_1_a_valid.value == 0, "Host 1 should have finished"

        # Get all responses
        resp0 = await env.hosts[0].host_get_response()
        resp1 = await env.hosts[1].host_get_response()
        resp2 = await env.hosts[2].host_get_response()

        assert resp0["source"] == 0 * 16 + 1
        assert resp1["source"] == 1 * 16 + 1
        assert resp2["source"] == 2 * 16 + 1

        assert env.scoreboard.errors == 0, f"Scoreboard detected errors: {env.scoreboard.errors}"

    finally:
        for task in responder_tasks:
            task.cancel()
        await env.stop()


@cocotb.test()
async def test_random_backpressure(dut):
    """Verify operation under random routing and random backpressure."""
    await setup_dut(dut)

    def get_master_from_source(source_id):
        return source_id // 16

    env = TlulVerificationEnv(dut, get_master_from_source)
    M = env.M
    N = env.N
    StIdW = (M - 1).bit_length()
    env.scoreboard.device_to_host_source_cb = lambda src: src >> StIdW
    await env.start()

    # Configure random backpressure
    env.backpressure_enabled = True
    env.host_bp_prob = 0.3
    env.device_bp_prob = 0.3

    responder_tasks = await start_device_responders(env)

    num_txns_per_host = 15
    base_addr = 0x10000
    bank_size = 0x1000

    async def host_traffic(host_idx):
        host = env.hosts[host_idx]
        for j in range(num_txns_per_host):
            source = (host_idx * 16) + j
            # Target a random bank
            bank_idx = random.randint(0, N - 1)
            addr = base_addr + bank_idx * bank_size + random.randint(
                0, 100
            ) * 8

            req = create_a_channel_req(
                address=addr,
                data=0x10000000 + source,
                mask=0xffff,
                source=source,
                width=128
            )
            await host.host_put(req)
            await ClockCycles(dut.clock, random.randint(1, 5))

    try:
        traffic_tasks = [cocotb.start_soon(host_traffic(i)) for i in range(M)]
        await Combine(*traffic_tasks)

        # Wait for completion of all transactions
        total_txns = M * num_txns_per_host
        cycles = 0
        while len(env.scoreboard.global_response_order
                  ) < total_txns and cycles < 1000:
            await ClockCycles(dut.clock, 1)
            cycles += 1

        assert len(env.scoreboard.global_response_order) == total_txns, \
            f"Timeout: only completed {len(env.scoreboard.global_response_order)}/{total_txns} transactions"

        assert env.scoreboard.errors == 0, f"Scoreboard detected {env.scoreboard.errors} errors"

    finally:
        for task in responder_tasks:
            task.cancel()
        await env.stop()
