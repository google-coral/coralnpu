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
import random
import collections
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, ClockCycles


class AxiBurstType:
    FIXED = 0
    INCR = 1
    WRAP = 2


async def reset_dut(dut):
    dut.reset.value = 1
    dut.io_in_valid.value = 0
    dut.io_in_bits_addr.value = 0
    dut.io_in_bits_id.value = 0
    dut.io_in_bits_len.value = 0
    dut.io_in_bits_size.value = 0
    dut.io_in_bits_burst.value = 0
    dut.io_in_bits_lock.value = 0
    dut.io_in_bits_cache.value = 0
    dut.io_in_bits_qos.value = 0
    dut.io_in_bits_region.value = 0
    dut.io_in_bits_prot.value = 0
    dut.io_out_ready.value = 0
    await ClockCycles(dut.clock, 2)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 2)


class ExpectedBeat:

    def __init__(self, addr, id, size, len):
        self.addr = addr
        self.id = id
        self.size = size
        self.len = len

    def __repr__(self):
        return f"ExpectedBeat(addr={hex(self.addr)}, id={self.id}, size={self.size}, len={self.len})"


@cocotb.test()
async def test_randomized_address_generator(dut):
    """Test AxiAddressGenerator with randomized bursts and backpressure."""
    clock = Clock(dut.clock, 10, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    num_transactions = 500
    golden_queue = collections.deque()

    tx_sent = 0
    tx_checked = 0

    driver_done = cocotb.triggers.Event()

    # Downstream ready generator (Backpressure)
    async def backpressure_gen():
        while not (driver_done.is_set() and len(golden_queue) == 0):
            # Update ready on RisingEdge, stable for the cycle
            dut.io_out_ready.value = 1 if random.random() < 0.5 else 0
            await RisingEdge(dut.clock)
        dut.io_out_ready.value = 1

    cocotb.start_soon(backpressure_gen())

    # Debug logger
    async def debug_log():
        while not (driver_done.is_set() and len(golden_queue) == 0):
            await FallingEdge(dut.clock)
            # Use safe conversion to hex, handles 'X' or 'Z' by converting to string if not integer
            try:
                addr_in = hex(int(dut.io_in_bits_addr.value))
            except ValueError:
                addr_in = str(dut.io_in_bits_addr.value)
            try:
                addr_out = hex(int(dut.io_out_bits_addr.value))
            except ValueError:
                addr_out = str(dut.io_out_bits_addr.value)

            dut._log.info(
                f"DEBUG: in[val={dut.io_in_valid.value} rdy={dut.io_in_ready.value} addr={addr_in}] "
                f"out[val={dut.io_out_valid.value} rdy={dut.io_out_ready.value} addr={addr_out} len={dut.io_out_bits_len.value}]"
            )

    cocotb.start_soon(debug_log())

    # Monitor Output (sampled on FallingEdge to avoid race conditions)
    async def monitor_output():
        nonlocal tx_checked
        while not (driver_done.is_set() and len(golden_queue) == 0):
            await FallingEdge(dut.clock)
            if dut.io_out_valid.value == 1 and dut.io_out_ready.value == 1:
                assert len(golden_queue) > 0, "Received unexpected output beat"
                expected = golden_queue.popleft()

                actual_addr = int(dut.io_out_bits_addr.value)
                actual_id = int(dut.io_out_bits_id.value)
                actual_size = int(dut.io_out_bits_size.value)
                actual_len = int(dut.io_out_bits_len.value)

                dut._log.info(
                    f"MATCH: Act [addr={hex(actual_addr)} id={actual_id} size={actual_size} len={actual_len}] "
                    f"Exp [addr={hex(expected.addr)} id={expected.id} size={expected.size} len={expected.len}]"
                )

                assert actual_addr == expected.addr, f"Addr mismatch: Act {hex(actual_addr)}, Exp {hex(expected.addr)}"
                assert actual_id == expected.id, f"ID mismatch: Act {actual_id}, Exp {expected.id}"
                assert actual_size == expected.size, f"Size mismatch: Act {actual_size}, Exp {expected.size}"
                assert actual_len == expected.len, f"Len mismatch: Act {actual_len}, Exp {expected.len}"

                if expected.len == 0:
                    tx_checked += 1

    cocotb.start_soon(monitor_output())

    # Driver
    for tx in range(num_transactions):
        burst = random.choice([
            AxiBurstType.FIXED,
            AxiBurstType.INCR,  #AxiBurstType.WRAP
        ])
        size = random.randint(0, 5)  # 1 to 32 bytes

        if burst == AxiBurstType.WRAP:
            len_val = random.choice([1, 3, 7, 15])
            align_mask = (1 << size) - 1
            addr = (random.randint(0, 0xFFFFFFFF) & ~align_mask) & 0xFFFFFFFF
        else:
            len_val = random.randint(0, 15)
            addr = random.randint(0, 0xFFFFFFFF)

        id_val = random.randint(0, 63)

        size_bytes = 1 << size
        total_len = len_val + 1

        expected_beats = []
        curr_addr = addr

        if burst == AxiBurstType.WRAP:
            total_size = size_bytes * total_len
            wrap_boundary = (addr // total_size) * total_size
            wrap_limit = wrap_boundary + total_size

            for beat in reversed(range(total_len)):
                expected_beats.append(
                    ExpectedBeat(curr_addr, id_val, size, beat)
                )
                curr_addr += size_bytes
                if curr_addr >= wrap_limit:
                    curr_addr = wrap_boundary
        elif burst == AxiBurstType.INCR:
            for beat in reversed(range(total_len)):
                expected_beats.append(
                    ExpectedBeat(curr_addr, id_val, size, beat)
                )
                curr_addr = (curr_addr + size_bytes) & 0xFFFFFFFF
        else:  # FIXED
            for beat in reversed(range(total_len)):
                expected_beats.append(ExpectedBeat(addr, id_val, size, beat))

        # Push to golden queue before driving
        golden_queue.extend(expected_beats)

        # Drive input (on RisingEdge)
        dut.io_in_valid.value = 1
        dut.io_in_bits_addr.value = addr
        dut.io_in_bits_id.value = id_val
        dut.io_in_bits_len.value = len_val
        dut.io_in_bits_size.value = size
        dut.io_in_bits_burst.value = burst

        dut._log.info(
            f"DRIVE TX {tx}: addr={hex(addr)} id={id_val} len={len_val} size={size} burst={burst}"
        )

        while True:
            await FallingEdge(dut.clock)
            if dut.io_in_ready.value == 1:
                break

        # Handshake completes on next RisingEdge
        await RisingEdge(dut.clock)
        dut.io_in_valid.value = 0

        # Random idle cycles between transactions
        idle_cycles = random.randint(0, 5)
        if idle_cycles > 0:
            await ClockCycles(dut.clock, idle_cycles)

        tx_sent += 1

    driver_done.set()

    # Wait for all checked
    while tx_checked < num_transactions:
        await RisingEdge(dut.clock)

    await ClockCycles(dut.clock, 10)
    assert len(
        golden_queue
    ) == 0, f"Golden queue not empty at end of test: {len(golden_queue)} beats remain"
    dut._log.info(
        f"Test completed successfully. Checked {tx_checked} transactions."
    )
