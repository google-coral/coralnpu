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

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, ClockCycles, Combine, Timer, with_timeout
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


@cocotb.test()
async def test_steering_and_locking(dut):
    """Verify routing steering and ordering lock behavior (blocking requests to new device)."""
    await setup_dut(dut)

    def get_master_from_source(source_id):
        return 0

    env = TlulVerificationEnv(dut, get_master_from_source)

    expected_devices = {}  # source -> expected_device_idx

    # Dynamically hook into the scoreboard to verify steering
    orig_write_device_request = env.scoreboard.write_device_request

    def check_routing(device_idx, txn):
        source = txn["source"]
        assert source in expected_devices, f"Scoreboard Error: Untracked source {source} at device {device_idx}"
        expected_dev = expected_devices.pop(source)
        assert device_idx == expected_dev, f"Routing Error: Request with source {source} went to Device {device_idx}, expected Device {expected_dev}"
        orig_write_device_request(device_idx, txn)

    env.scoreboard.write_device_request = check_routing

    await env.start()
    await ClockCycles(dut.clock, 1)

    assert env.N > 1, "This test requires at least 2 device ports"
    host = env.hosts[0]
    device0 = env.devices[0]
    device1 = env.devices[1]

    # Helper to wait for host request handshake to complete
    async def wait_host_handshake():
        while True:
            await RisingEdge(dut.clock)
            if dut.io_tl_h_a_valid.value == 1 and dut.io_tl_h_a_ready.value == 1:
                return

    try:
        # 1. Send Request 0 to Device 0
        dut.io_dev_select_i.value = 0
        req0 = create_a_channel_req(address=0x1000, data=0x111, source=0)
        expected_devices[0] = 0
        await host.host_put(req0)
        await wait_host_handshake()

        # 2. Send Request 1 to Device 0 (outstanding count on Device 0 becomes 2)
        dut.io_dev_select_i.value = 0
        req1 = create_a_channel_req(address=0x1004, data=0x222, source=1)
        expected_devices[1] = 0
        await host.host_put(req1)
        await wait_host_handshake()

        # 3. Send Request 2 to Device 1 (Should complete handshake immediately without blocking)
        dut.io_dev_select_i.value = 1
        req2 = create_a_channel_req(address=0x2000, data=0x333, source=2)
        expected_devices[2] = 1

        await host.host_put(req2)
        await wait_host_handshake()  # Handshake completes immediately!

        # 4. Verify all requests are outstanding at their respective devices
        dev0_req0 = await device0.device_get_request()
        dev0_req1 = await device0.device_get_request()
        dev1_req2 = await device1.device_get_request()

        assert dev0_req0["source"] == 0
        assert dev0_req1["source"] == 1
        assert dev1_req2["source"] == 2

        # 5. Respond to Request 2 on Device 1 first
        await device1.device_respond(
            opcode=0,
            param=0,
            size=dev1_req2["size"],
            source=dev1_req2["source"]
        )
        resp2 = await host.host_get_response()
        assert resp2[
            "source"
        ] == 2, f"Expected response with source 2 (Device 1), got {resp2['source']}"

        # 6. Respond to Request 0 and 1 on Device 0
        await device0.device_respond(
            opcode=0,
            param=0,
            size=dev0_req0["size"],
            source=dev0_req0["source"]
        )
        await device0.device_respond(
            opcode=0,
            param=0,
            size=dev0_req1["size"],
            source=dev0_req1["source"]
        )

        resp0 = await host.host_get_response()
        resp1 = await host.host_get_response()
        assert resp0["source"] == 0
        assert resp1["source"] == 1

        assert env.scoreboard.errors == 0, f"Scoreboard detected {env.scoreboard.errors} errors"

    finally:
        await env.stop()


@cocotb.test()
async def test_error_response(dut):
    """Verify error response for out-of-bounds dev_select."""
    await setup_dut(dut)

    def get_master_from_source(source_id):
        return 0

    env = TlulVerificationEnv(dut, get_master_from_source)
    await env.start()
    await ClockCycles(dut.clock, 1)

    host = env.hosts[0]
    N = env.N

    # Set selection out of bounds (index N) to trigger internal ErrorResponder
    dut.io_dev_select_i.value = N
    req = create_a_channel_req(address=0xBAD, data=0xBAD, mask=0xF, source=42)

    try:
        await host.host_put(req)
        response = await host.host_get_response()

        assert response["error"] == 1, "Expected error bit to be set"
        assert response["source"] == 42
        assert env.scoreboard.errors == 0, f"Scoreboard detected {env.scoreboard.errors} errors"
    finally:
        await env.stop()


def _init_direct_drive(dut, n):
    """Puts every socket input in a known idle state, with no agents attached."""
    dut.io_tl_h_a_valid.value = 0
    dut.io_tl_h_d_ready.value = 1
    dut.io_dev_select_i.value = n
    for i in range(n):
        getattr(dut, f"io_tl_d_{i}_a_ready").value = 1
        getattr(dut, f"io_tl_d_{i}_d_valid").value = 0


def _num_devices(dut):
    n = 0
    while hasattr(dut, f"io_tl_d_{n}_a_valid"):
        n += 1
    return n


def _drive_host_a(dut, req):
    dut.io_tl_h_a_valid.value = 1
    for prop in ["opcode", "param", "size", "source", "address", "mask",
                 "data"]:
        getattr(dut, f"io_tl_h_a_bits_{prop}").value = req[prop]


async def _sample_host_d(dut):
    """Lets combinational logic settle after a falling-edge drive, then samples."""
    await Timer(1, "ns")
    return {
        "valid": int(dut.io_tl_h_d_valid.value),
        "ready": int(dut.io_tl_h_d_ready.value),
        "opcode": int(dut.io_tl_h_d_bits_opcode.value),
        "source": int(dut.io_tl_h_d_bits_source.value),
        "error": int(dut.io_tl_h_d_bits_error.value),
    }


async def _fire_host_request(dut, req):
    """Drives one request across a rising edge and returns after it has fired."""
    _drive_host_a(dut, req)
    await Timer(1, "ns")
    assert dut.io_tl_h_a_ready.value == 1, "control: request was not accepted"
    await FallingEdge(dut.clock)
    dut.io_tl_h_a_valid.value = 0


@cocotb.test()
async def test_error_response_get_opcode(dut):
    """A Get routed to the error responder must be answered with AccessAckData."""
    await setup_dut(dut)
    n = _num_devices(dut)
    _init_direct_drive(dut, n)
    await FallingEdge(dut.clock)

    req = create_a_channel_req(address=0xBAD0, source=42, is_read=True)
    await _fire_host_request(dut, req)
    d = await _sample_host_d(dut)

    assert d["valid"] == 1, f"control: no error response observed: {d}"
    assert d["source"] == 42 and d["error"] == 1, f"control: {d}"
    assert d["opcode"] == 1, (
        f"Get answered with D opcode {d['opcode']}, expected AccessAckData (1)"
    )


@cocotb.test()
async def test_error_response_held_under_backpressure(dut):
    """An error response must stay valid until the host accepts it."""
    await setup_dut(dut)
    n = _num_devices(dut)
    _init_direct_drive(dut, n)
    dut.io_tl_h_d_ready.value = 0
    await FallingEdge(dut.clock)

    req = create_a_channel_req(address=0xBAD0, data=0xBAD, mask=0xF, source=42)
    await _fire_host_request(dut, req)

    stall_cycles = 8
    trace = []
    for _ in range(stall_cycles):
        trace.append((await _sample_host_d(dut))["valid"])
        await FallingEdge(dut.clock)

    assert trace[0] == 1, f"control: no error response observed: {trace}"
    assert trace == [1] * stall_cycles, (
        f"d_valid dropped while d_ready=0, per-cycle d_valid={trace}"
    )

    dut.io_tl_h_d_ready.value = 1
    d = await _sample_host_d(dut)
    assert d["valid"] == 1 and d["source"] == 42 and d["error"] == 1, f"{d}"
    await FallingEdge(dut.clock)
    d = await _sample_host_d(dut)
    assert d["valid"] == 0, "error response delivered more than once"


@cocotb.test()
async def test_error_response_survives_arbitration(dut):
    """An error response that loses D arbitration must not be lost."""
    await setup_dut(dut)
    n = _num_devices(dut)
    _init_direct_drive(dut, n)
    await FallingEdge(dut.clock)

    # An outstanding request to device 0, which has not responded yet.
    dut.io_dev_select_i.value = 0
    await _fire_host_request(
        dut,
        create_a_channel_req(address=0x1000, data=1, mask=0xF, source=1),
    )

    # A second request to an unmapped target.
    dut.io_dev_select_i.value = n
    await _fire_host_request(
        dut,
        create_a_channel_req(address=0xBAD0, data=2, mask=0xF, source=42),
    )

    # Device 0 responds in the cycle the error response first becomes valid.
    dut.io_tl_d_0_d_valid.value = 1
    dut.io_tl_d_0_d_bits_opcode.value = 0
    dut.io_tl_d_0_d_bits_source.value = 1
    dut.io_tl_d_0_d_bits_size.value = 2

    delivered = []
    for _ in range(8):
        d = await _sample_host_d(dut)
        if d["valid"] and d["ready"]:
            delivered.append(d["source"])
        await FallingEdge(dut.clock)
        dut.io_tl_d_0_d_valid.value = 0

    assert delivered.count(1) == 1, f"control: device response: {delivered}"
    assert delivered.count(42) == 1, (
        f"responses delivered to host by source: {delivered}, "
        "error response for source 42 was lost"
    )


@cocotb.test()
async def test_random_backpressure(dut):
    """Verify correct routing and lock recovery under randomized backpressure."""
    await setup_dut(dut)

    def get_master_from_source(source_id):
        return 0

    env = TlulVerificationEnv(dut, get_master_from_source)

    expected_devices = {}

    # Hook into scoreboard
    orig_write_device_request = env.scoreboard.write_device_request

    def check_routing(device_idx, txn):
        source = txn["source"]
        assert source in expected_devices, f"Scoreboard Error: Untracked source {source} at device {device_idx}"
        expected_dev = expected_devices.pop(source)
        assert device_idx == expected_dev, f"Routing Error: Request with source {source} went to Device {device_idx}, expected Device {expected_dev}"
        orig_write_device_request(device_idx, txn)

    env.scoreboard.write_device_request = check_routing

    await env.start()
    await ClockCycles(dut.clock, 1)

    # Configure backpressure
    env.backpressure_enabled = True
    env.host_bp_prob = 0.3
    env.device_bp_prob = 0.3

    def bp_condition(cycle_count):
        return 20 <= cycle_count <= 150

    env.bp_condition_cb = bp_condition

    N = env.N
    num_txns = 15
    host = env.hosts[0]

    # Device Responders with random delay
    async def device_responder(dev_idx):
        device = env.devices[dev_idx]
        while True:
            req = await device.device_get_request()
            await ClockCycles(dut.clock, random.randint(0, 4))
            await device.device_respond(
                opcode=0, param=0, size=req["size"], source=req["source"]
            )

    responder_tasks = [
        cocotb.start_soon(device_responder(j)) for j in range(N)
    ]

    try:
        for i in range(num_txns):
            dev_select = random.randint(0, N - 1)
            dut.io_dev_select_i.value = dev_select

            source = i
            expected_devices[source] = dev_select

            req = create_a_channel_req(
                address=0x1000 + i * 4,
                data=0x11223344 + i,
                mask=0xF,
                source=source
            )

            await host.host_put(req)

            # Wait for handshake to propagate to the device
            cycles = 0
            while source in expected_devices and cycles < 100:
                await ClockCycles(dut.clock, 1)
                cycles += 1

            assert source not in expected_devices, f"Transaction {source} timed out under backpressure"

            # Consume response
            resp = await host.host_get_response()
            assert resp["source"] == source

        # Wait for all remaining responses to propagate
        await ClockCycles(dut.clock, 20)
        assert env.scoreboard.errors == 0, f"Scoreboard detected {env.scoreboard.errors} errors"

    finally:
        for r_task in responder_tasks:
            r_task.cancel()
        await env.stop()
