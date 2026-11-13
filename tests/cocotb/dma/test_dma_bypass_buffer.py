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
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import random

DEPTH = 16
DATA_BITS = 128
MAX_WAIT_CYCLES = 100


def random_payload(tags):
    """One random 128-bit beat per tag."""
    return {t: random.getrandbits(DATA_BITS) for t in tags}


async def wait_for(dut, signal, expected_value: int):
    """Waits on clock falling edges until signal matches expected_value."""
    for _ in range(MAX_WAIT_CYCLES):
        await FallingEdge(dut.clock)
        if signal.value == expected_value:
            return
    assert False, f"timed out waiting for {signal._name} == {expected_value}"


async def reset_dut(dut):
    """Assert reset for 5 cycles, then deassert."""
    dut.reset.value = 1
    dut.io_alloc_ready.value = 0
    dut.io_write_valid.value = 0
    dut.io_out_ready.value = 0
    dut.io_clear.value = 0
    await ClockCycles(dut.clock, 5)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 2)


async def alloc_n(dut, n: int) -> list:
    """Takes n slots through io.alloc and returns their tags in grant order."""
    tags = []
    await RisingEdge(dut.clock)
    dut.io_alloc_ready.value = 1
    while len(tags) < n:
        await wait_for(dut, dut.io_alloc_valid, 1)
        tags.append(int(dut.io_alloc_bits.value))
        await RisingEdge(dut.clock)
    dut.io_alloc_ready.value = 0
    return tags


async def write_slots(dut, order, payload, in_use, already_written=()):
    """Writes payload[tag] for each tag in order, one per cycle.

    in_use lists the allocated slots oldest first, so in_use[0] is the head;
    already_written holds slots written before this call. Protocol check: with
    no pops, out.valid must follow whether the head slot has been written yet.
    """
    written = set(already_written)
    await RisingEdge(dut.clock)
    dut.io_write_valid.value = 1
    for tag in order:
        dut.io_write_bits_tag.value = tag
        dut.io_write_bits_data.value = payload[tag]
        await FallingEdge(dut.clock)
        head_written = in_use[0] in written
        assert dut.io_out_valid.value == head_written, (
            f"Protocol error: io.out.valid={int(dut.io_out_valid.value)} "
            f"with head slot {in_use[0]} written={head_written}"
        )
        await RisingEdge(dut.clock)
        written.add(tag)
    dut.io_write_valid.value = 0


async def pop_n(dut, n: int) -> list:
    """Pops n beats through io.out and returns their data in order."""
    beats = []
    await RisingEdge(dut.clock)
    dut.io_out_ready.value = 1
    while len(beats) < n:
        await wait_for(dut, dut.io_out_valid, 1)
        beats.append(int(dut.io_out_bits.value))
        await RisingEdge(dut.clock)
    dut.io_out_ready.value = 0
    return beats


async def clear(dut):
    """Pulses io.clear for one cycle; alloc and out must be held off during it."""
    await RisingEdge(dut.clock)
    dut.io_clear.value = 1
    await FallingEdge(dut.clock)
    assert dut.io_alloc_valid.value == 0, "Protocol error: io.alloc.valid during clear"
    assert dut.io_out_valid.value == 0, "Protocol error: io.out.valid during clear"
    await RisingEdge(dut.clock)
    dut.io_clear.value = 0
    await FallingEdge(dut.clock)
    assert dut.io_empty.value == 1, "not empty after clear"


async def stream_cycle(dut, write_tag, data):
    """Offers alloc, write and pop together for one cycle.

    Returns (allocated tag or None, popped data or None).
    """
    await RisingEdge(dut.clock)
    dut.io_alloc_ready.value = 1
    dut.io_out_ready.value = 1
    dut.io_write_valid.value = 1
    dut.io_write_bits_tag.value = write_tag
    dut.io_write_bits_data.value = data
    await FallingEdge(dut.clock)
    allocated = int(
        dut.io_alloc_bits.value
    ) if dut.io_alloc_valid.value == 1 else None
    popped = int(
        dut.io_out_bits.value
    ) if dut.io_out_valid.value == 1 else None
    await RisingEdge(dut.clock)
    dut.io_alloc_ready.value = 0
    dut.io_out_ready.value = 0
    dut.io_write_valid.value = 0
    return allocated, popped


async def assert_alloc_blocked(dut):
    await FallingEdge(dut.clock)
    assert dut.io_alloc_valid.value == 0, "io.alloc.valid high with all slots in use"


async def assert_out_idle(dut):
    await FallingEdge(dut.clock)
    assert dut.io_out_valid.value == 0, "io.out.valid high for a slot not yet written"


async def start(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset_dut(dut)


@cocotb.test()
async def test_bypass_fill_then_drain(dut):
    """Allocate all 16 slots, fill them, then drain them in order."""
    await start(dut)

    tags = await alloc_n(dut, DEPTH)
    assert tags == list(range(DEPTH)), f"alloc order {tags}"
    await assert_alloc_blocked(dut)

    payload = random_payload(tags)
    await write_slots(dut, tags, payload, tags)
    result = await pop_n(dut, DEPTH)
    assert result == [payload[t] for t in tags], "drain order or data mismatch"

    await FallingEdge(dut.clock)
    assert dut.io_empty.value == 1, "not empty after draining every slot"
    dut._log.info("=== test_bypass_fill_then_drain PASSED ===")


@cocotb.test()
async def test_bypass_out_of_order_writes(dut):
    """Writes land in a random order; output stays in allocation order."""
    await start(dut)

    for iteration in range(4):
        n = random.randint(4, DEPTH)
        tags = await alloc_n(dut, n)
        payload = random_payload(tags)

        order = tags[:]
        if iteration == 0:
            order.reverse()
        else:
            random.shuffle(order)

        dut._log.info(f"[Iter {iteration+1}] n={n} write order={order}")
        await write_slots(dut, order, payload, tags)
        result = await pop_n(dut, n)
        assert result == [
            payload[t] for t in tags
        ], (f"output not in allocation order for write order {order}")
    dut._log.info("=== test_bypass_out_of_order_writes PASSED ===")


@cocotb.test()
async def test_bypass_full_empty_edges(dut):
    """Empty after reset, one entry, full at 16, and wrap-around of both pointers."""
    await start(dut)

    await FallingEdge(dut.clock)
    assert dut.io_empty.value == 1, "not empty after reset"
    assert dut.io_alloc_valid.value == 1, "cannot allocate after reset"
    assert dut.io_out_valid.value == 0, "io.out.valid after reset"

    # One entry: allocated but unwritten must not be poppable.
    [t0] = await alloc_n(dut, 1)
    await FallingEdge(dut.clock)
    assert dut.io_empty.value == 0, "empty with one slot in use"
    await assert_out_idle(dut)
    payload = random_payload([t0])
    await write_slots(dut, [t0], payload, [t0])
    assert await pop_n(dut, 1) == [payload[t0]]
    await FallingEdge(dut.clock)
    assert dut.io_empty.value == 1, "not empty after the only slot was popped"

    # Fill to exactly 16; tail wraps from 15 to 0 on the way.
    tags = await alloc_n(dut, DEPTH)
    assert tags == [(t0 + 1 + k) % DEPTH
                    for k in range(DEPTH)], f"alloc order {tags}"
    await assert_alloc_blocked(dut)
    payload = random_payload(tags)
    await write_slots(dut, tags, payload, tags)

    # Drain past the wrap point.
    assert await pop_n(dut, DEPTH) == [
        payload[t] for t in tags
    ], "wrap-around drain mismatch"
    await FallingEdge(dut.clock)
    assert dut.io_empty.value == 1
    dut._log.info("=== test_bypass_full_empty_edges PASSED ===")


@cocotb.test()
async def test_bypass_realloc_after_pop(dut):
    """A popped slot is reallocated on the very next cycle; no ack is awaited."""
    await start(dut)

    in_use = await alloc_n(dut, DEPTH)
    payload = random_payload(in_use)
    await write_slots(dut, in_use, payload, in_use)
    await assert_alloc_blocked(dut)

    for k in range(DEPTH):
        head = in_use.pop(0)
        assert await pop_n(dut,
                           1) == [payload[head]], f"pop {k}: data mismatch"
        [tag] = await alloc_n(dut, 1)
        assert tag == head, f"pop {k}: reallocated slot {tag}, expected the popped slot {head}"
        in_use.append(tag)
        payload.update(random_payload([tag]))
        await write_slots(
            dut, [tag], payload, in_use, already_written=in_use[:-1]
        )
    dut._log.info("=== test_bypass_realloc_after_pop PASSED ===")


@cocotb.test()
async def test_bypass_alloc_write_pop_same_cycle(dut):
    """Steady streaming: alloc, write and pop all fire in the same cycle."""
    await start(dut)

    # Prime: two slots allocated, the head one written.
    in_use = await alloc_n(dut, 2)
    payload = random_payload(in_use)
    await write_slots(dut, in_use[:1], payload, in_use)
    written = {in_use[0]}

    expected, result = [], []
    for _ in range(200):
        write_tag = next(t for t in in_use if t not in written)
        data = random.getrandbits(DATA_BITS)
        allocated, popped = await stream_cycle(dut, write_tag, data)

        assert popped is not None, "head was written but io.out.valid was low"
        assert allocated is not None, "a slot was free but io.alloc.valid was low"
        expected.append(payload[in_use[0]])
        result.append(popped)

        payload[write_tag] = data
        written.add(write_tag)
        written.discard(in_use.pop(0))
        in_use.append(allocated)

    assert result == expected, "streamed data mismatch"
    dut._log.info("=== test_bypass_alloc_write_pop_same_cycle PASSED ===")


@cocotb.test()
async def test_bypass_clear(dut):
    """clear frees full slots and resets the pointers; next alloc is slot 0."""
    await start(dut)

    tags = await alloc_n(dut, 5)
    await write_slots(dut, tags, random_payload(tags), tags)
    await pop_n(dut, 2)

    await clear(dut)
    [tag] = await alloc_n(dut, 1)
    assert tag == 0, f"first alloc after clear got slot {tag}"
    await assert_out_idle(dut)
    dut._log.info("=== test_bypass_clear PASSED ===")


@cocotb.test()
async def test_bypass_randomized(dut):
    """Random bursts of alloc, out-of-order write and pop, with occasional clears."""
    await start(dut)

    in_use, payload, written = [], {}, set()
    tail = 0
    num_iterations = 300

    for _ in range(num_iterations):
        awaiting = [t for t in in_use if t not in written]

        if not awaiting and random.random() < 0.05:
            await clear(dut)
            in_use, payload, written, tail = [], {}, set(), 0
            continue

        n_alloc = random.randint(0, DEPTH - len(in_use))
        if n_alloc:
            tags = await alloc_n(dut, n_alloc)
            assert tags == [(tail + k) % DEPTH
                            for k in range(n_alloc)], f"alloc order {tags}"
            tail = (tail + n_alloc) % DEPTH
            in_use += tags
            awaiting += tags

        if awaiting:
            order = random.sample(awaiting, random.randint(1, len(awaiting)))
            payload.update(random_payload(order))
            await write_slots(
                dut, order, payload, in_use, already_written=written
            )
            written.update(order)

        ready = 0
        while ready < len(in_use) and in_use[ready] in written:
            ready += 1
        n_pop = random.randint(0, ready)
        if n_pop:
            result = await pop_n(dut, n_pop)
            assert result == [
                payload[t] for t in in_use[:n_pop]
            ], "randomized pop mismatch"
            for t in in_use[:n_pop]:
                written.discard(t)
            in_use = in_use[n_pop:]

    dut._log.info(
        f"=== test_bypass_randomized PASSED ({num_iterations} iterations) ==="
    )
