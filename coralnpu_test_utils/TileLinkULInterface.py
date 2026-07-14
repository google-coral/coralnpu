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
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import FallingEdge, RisingEdge, with_timeout
import cocotb.result
import math
import random

from coralnpu_test_utils.secded_golden import get_cmd_intg, get_data_intg, get_rsp_intg


def create_a_channel_req(
    address,
    data=0,
    mask=0,
    source=1,
    size=None,
    param=0,
    width=32,
    is_read=False
):
    """Creates a standard TileLink-UL request dictionary."""
    num_bytes = width // 8
    if size is None:
        size = int(math.log2(num_bytes))

    if is_read:
        opcode = 4  # Get
        mask = 0
        data = 0
    else:
        full_mask = (1 << num_bytes) - 1
        opcode = 0 if mask == full_mask else 1  # PutFull vs PutPartial
    txn = {
        "opcode": opcode,
        "param": param,
        "size": size,
        "source": source,
        "address": address,
        "mask": mask,
        "data": data,
        "user": {
            "cmd_intg": 0,
            "data_intg": 0,
            "instr_type": 0,
            "rsvd": 0
        }
    }
    txn["user"]["cmd_intg"] = get_cmd_intg(txn, width=width)
    txn["user"]["data_intg"] = get_data_intg(txn["data"], width=width)
    return txn


class TileLinkULInterface:
    """A testbench interface for a TileLink-UL bus.

    This class provides a high-level, transaction-based interface to a TileLink-UL
    bus in the DUT. It uses cocotb queues and background coroutines ("agents")
    to handle the low-level signal handshaking.

    Args:
        dut: The cocotb DUT object.
        host_if_name (str, optional): The prefix for the host-side interface signals.
        device_if_name (str, optional): The prefix for the device-side interface signals.
    """

    def __init__(
        self,
        dut,
        host_if_name=None,
        device_if_name=None,
        clock_name="clock",
        reset_name="reset",
        reset_active_low=False,
        width=32,
        backpressure=False
    ):
        self.dut = dut
        self.clock = getattr(dut, clock_name)
        self.reset = getattr(dut, reset_name)
        self.reset_active_low = reset_active_low
        self.width = width
        self.name = host_if_name or device_if_name
        self.backpressure = backpressure

        if host_if_name is None and device_if_name is None:
            raise ValueError(
                "At least one of host_if_name or device_if_name must be provided."
            )

        self._agents = []

        if host_if_name:
            self.host_a_fifo = Queue()
            self.host_d_fifo = Queue()
            self._agents.append(
                cocotb.start_soon(self._host_a_driver(host_if_name))
            )
            self._agents.append(
                cocotb.start_soon(self._host_d_monitor(host_if_name))
            )

        if device_if_name:
            self.device_a_fifo = Queue()
            self.device_d_fifo = Queue()
            self._device_a_ready = True  # Default to being ready
            self._agents.append(
                cocotb.start_soon(self._device_a_monitor(device_if_name))
            )
            self._agents.append(
                cocotb.start_soon(self._device_d_driver(device_if_name))
            )

    def device_a_set_ready(self, value):
        """Set the ready signal for the device A channel monitor."""
        self._device_a_ready = value

    async def init(self):
        """Starts the agents."""
        # This method is currently a placeholder for starting agents.
        # In this implementation, agents are started in the constructor.
        # This can be extended if more complex initialization is needed.
        pass

    # --- Private Methods (Agents) ---

    # slave_a{r|w}agent
    async def _host_a_driver(self, prefix, timeout=4096):
        """Drives the host A channel from the host_a_fifo."""
        a_valid = getattr(self.dut, f"{prefix}_a_valid")
        a_ready = getattr(self.dut, f"{prefix}_a_ready")

        a_valid.value = 0
        for prop in ["opcode", "param", "size", "source", "address", "mask",
                     "data"]:
            getattr(self.dut, f"{prefix}_a_bits_{prop}").value = 0

        while True:
            while True:
                await RisingEdge(self.clock)
                a_valid.value = 0
                if self.host_a_fifo.qsize():
                    break
            txn = await self.host_a_fifo.get()
            a_valid.value = 1
            for prop in ["opcode", "param", "size", "source", "address",
                         "mask", "data"]:
                getattr(self.dut, f"{prefix}_a_bits_{prop}").value = txn[prop]
            for field, value in txn["user"].items():
                port_name = f"{prefix}_a_bits_user_{field}"
                if hasattr(self.dut, port_name):
                    getattr(self.dut, port_name).value = value
            await FallingEdge(self.clock)
            timeout_count = 0
            while a_ready.value == 0:
                await FallingEdge(self.clock)
                timeout_count += 1
                if timeout_count >= timeout:
                    assert False, "timeout waiting for a_ready"

    # slave_bagent
    async def _host_d_monitor(self, prefix):
        """Monitors the host D channel and puts transactions into host_d_fifo."""
        d_valid = getattr(self.dut, f"{prefix}_d_valid")
        d_ready = getattr(self.dut, f"{prefix}_d_ready")
        x_count = 0

        d_ready.value = 1
        while True:
            await RisingEdge(self.clock)
            if self.backpressure:
                d_ready.value = random.randint(0, 1)
            try:
                if d_valid.value and d_ready.value == 1:
                    # Capture the transaction
                    txn = {'user': {}}
                    for prop in ["opcode", "param", "size", "source", "sink",
                                 "data", "error"]:
                        txn[prop] = getattr(
                            self.dut, f"{prefix}_d_bits_{prop}"
                        ).value
                    user_fields = ["rsp_intg", "data_intg"]
                    for field in user_fields:
                        signal_name = f"{prefix}_d_bits_user_{field}"
                        if hasattr(self.dut, signal_name):
                            txn["user"][field] = getattr(
                                self.dut, signal_name
                            ).value

                    await self.host_d_fifo.put(txn)
            except Exception as e:
                try:
                    is_reset = (
                        self.reset.value == 0
                    ) if self.reset_active_low else (self.reset.value == 1)
                except Exception:
                    is_reset = True
                if is_reset:
                    x_count = 0
                else:
                    x_count += 1
                    self.dut._log.warning(
                        f"X seen in _host_d_monitor ({prefix}): {e} ({x_count}/3)"
                    )
                    if x_count >= 3:
                        assert False, f"Too many 'X' values detected in _host_d_monitor on {prefix}"

    # master_aragent
    async def _device_a_monitor(self, prefix):
        """Monitors the device A channel and puts transactions into device_a_fifo."""
        a_valid = getattr(self.dut, f"{prefix}_a_valid")
        a_ready = getattr(self.dut, f"{prefix}_a_ready")
        x_count = 0

        a_ready.value = 1
        while True:
            await RisingEdge(self.clock)
            try:
                if a_valid.value and a_ready.value == 1:
                    txn = {"user": {}}
                    for prop in ["opcode", "param", "size", "source",
                                 "address", "mask", "data"]:
                        txn[prop] = getattr(
                            self.dut, f"{prefix}_a_bits_{prop}"
                        ).value
                    user_fields = [
                        "cmd_intg", "data_intg", "instr_type", "rsvd"
                    ]
                    for field in user_fields:
                        signal_name = f"{prefix}_a_bits_user_{field}"
                        if hasattr(self.dut, signal_name):
                            txn["user"][field] = getattr(
                                self.dut, signal_name
                            ).value
                    await self.device_a_fifo.put(txn)
            except Exception as e:
                try:
                    is_reset = (
                        self.reset.value == 0
                    ) if self.reset_active_low else (self.reset.value == 1)
                except Exception:
                    is_reset = True
                if is_reset:
                    x_count = 0
                else:
                    x_count += 1
                    self.dut._log.warning(
                        f"X seen in _device_a_monitor ({prefix}): {e} ({x_count}/3)"
                    )
                    if x_count >= 3:
                        assert False, f"Too many 'X' values detected in _device_a_monitor on {prefix}"

    # master_bagent
    async def _device_d_driver(self, prefix, timeout=4096):
        """Drives the device D channel from the device_d_fifo."""
        d_valid = getattr(self.dut, f"{prefix}_d_valid")
        d_ready = getattr(self.dut, f"{prefix}_d_ready")

        d_valid.value = 0
        for prop in ["opcode", "param", "size", "source", "sink", "data",
                     "error"]:
            getattr(self.dut, f"{prefix}_d_bits_{prop}").value = 0

        while True:
            while True:
                await RisingEdge(self.clock)
                d_valid.value = 0
                if self.device_d_fifo.qsize():
                    break
            txn = await self.device_d_fifo.get()
            d_valid.value = 1
            for prop in ["opcode", "param", "size", "source", "sink", "data",
                         "error"]:
                getattr(self.dut, f"{prefix}_d_bits_{prop}").value = txn[prop]
            for field, value in txn["user"].items():
                port_name = f"{prefix}_d_bits_user_{field}"
                if hasattr(self.dut, port_name):
                    getattr(self.dut, port_name).value = value
            await FallingEdge(self.clock)
            timeout_count = 0
            while d_ready.value == 0:
                await FallingEdge(self.clock)
                timeout_count += 1
                if timeout_count >= timeout:
                    assert False, "timeout waiting for d_ready"

    # --- Public API Methods ---

    async def host_put(self, txn):
        """Send a PutFullData or PutPartialData request from the host."""
        await self.host_a_fifo.put(txn)

    async def host_get_response(self):
        """Get a response from the host D channel."""
        return await self.host_d_fifo.get()

    async def device_get_request(self):
        """Get a request from the device A channel."""
        return await self.device_a_fifo.get()

    async def device_respond(
        self,
        opcode,
        param,
        size,
        source,
        sink=0,
        data=0,
        error=0,
        width=None
    ):
        """Send a response from the device."""
        if width is None:
            width = self.width
        txn = {
            "opcode": opcode,
            "param": param,
            "size": size,
            "source": source,
            "sink": sink,
            "data": data,
            "error": error,
            "user": {
                "rsp_intg": 0,
                "data_intg": 0
            }
        }
        txn["user"]["rsp_intg"] = get_rsp_intg(txn, width)
        txn["user"]["data_intg"] = get_data_intg(txn["data"], width)
        await self.device_d_fifo.put(txn)
