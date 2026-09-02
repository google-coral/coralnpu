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
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Event
import random
import numpy as np


def get_valid_dtypes(N: int) -> list:
    """Returns valid numpy dtypes for bus width N where G >= 2 and elem_size <= 8."""
    candidates = [np.uint8, np.uint16, np.uint32, np.uint64]
    return [dt for dt in candidates if (N // np.dtype(dt).itemsize) >= 2]


def set_vec_bytes(dut, prefix: str, byte_values):
    """Helper to drive a Chisel Vec(N, UInt(8.W)) from a byte array."""
    if hasattr(dut, prefix):
        vec_signal = getattr(dut, prefix)
        for i, b in enumerate(byte_values):
            vec_signal[i].value = int(b)
    else:
        for i, b in enumerate(byte_values):
            getattr(dut, f"{prefix}_{i}").value = int(b)


def get_vec_bytes(dut, prefix: str, N: int) -> np.ndarray:
    """Helper to sample a Chisel Vec(N, UInt(8.W)) into a numpy uint8 array."""
    res = np.zeros(N, dtype=np.uint8)
    if hasattr(dut, prefix):
        vec_signal = getattr(dut, prefix)
        for i in range(N):
            res[i] = int(vec_signal[i].value)
    else:
        for i in range(N):
            res[i] = int(getattr(dut, f"{prefix}_{i}").value)
    return res


async def wait_for(dut, signal, expected_value: int):
    """Waits on clock falling edges until signal matches expected_value."""
    while True:
        await FallingEdge(dut.clock)
        if signal.value == expected_value:
            return


async def reset_dut(dut):
    """Assert reset for 5 cycles, then deassert."""
    dut.reset.value = 1
    dut.io_cfg_valid.value = 0
    dut.io_in_valid.value = 0
    dut.io_out_ready.value = 0
    await ClockCycles(dut.clock, 5)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 2)


async def drive_config(dut, stride: int, elem_size: int):
    """Handshake configuration into io.cfg."""
    log_elem_size = int(np.log2(elem_size))
    await wait_for(dut, dut.io_cfg_ready, 1)

    await RisingEdge(dut.clock)
    dut.io_cfg_valid.value = 1
    dut.io_cfg_bits_stride.value = stride
    dut.io_cfg_bits_logElemSize.value = log_elem_size
    await RisingEdge(dut.clock)
    dut.io_cfg_valid.value = 0


async def drive_write_stream(dut, write_beats, N: int):
    """Drives s write beats back-to-back into io.in at peak throughput."""
    await RisingEdge(dut.clock)
    dut.io_in_valid.value = 1
    for beat_idx, beat in enumerate(write_beats):
        set_vec_bytes(dut, "io_in_bits", beat)

        while True:
            await FallingEdge(dut.clock)
            # Protocol check: out_valid must be 0 while fill is still underway
            if dut.io_fillDone.value == 0:
                assert dut.io_out_valid.value == 0, "Protocol error: io.out.valid asserted before fillDone!"
            if dut.io_in_ready.value == 1:
                break
        await RisingEdge(dut.clock)

    dut.io_in_valid.value = 0


async def random_ready_driver(dut, stop_event: Event, p_ready: float = 0.6):
    """Continuously randomizes io.out.ready at every single clock cycle."""
    while not stop_event.is_set():
        await RisingEdge(dut.clock)
        dut.io_out_ready.value = 1 if (random.random() < p_ready) else 0
    dut.io_out_ready.value = 0


async def collect_read_beats(dut, s: int, N: int) -> np.ndarray:
    """samples s beats on io.out when valid && ready handshake occurs.

    Returns an (s, N) uint8 array of  raw bus bytes.
    """
    beats = np.zeros((s, N), dtype=np.uint8)
    for beat_idx in range(s):
        while True:
            await FallingEdge(dut.clock)
            # Protocol check: cfg_ready must stay 0 while draining is still in progress
            if dut.io_drainDone.value == 0:
                assert dut.io_cfg_ready.value == 0, "Protocol error: io.cfg.ready asserted before drainDone!"

            # Handshake fires on valid && ready
            if dut.io_out_valid.value == 1 and dut.io_out_ready.value == 1:
                beats[beat_idx] = get_vec_bytes(dut, "io_out_bits", N)
                break
    return beats


async def transpose(
    dut, x: np.ndarray, N: int, p_ready: float = 0.6
) -> np.ndarray:
    """Push one tile through the buffer and return what came out.
    
    x is (G, s): G = N / elem_size lanes, s = stride = number of beats.
    Returns an (s, G) array, which should equal x.T
    """
    elem_size = x.dtype.itemsize
    G, s = x.shape
    assert G * elem_size == N, f"tile must fill the bus: {G} * {elem_size} != {N}"
    assert 1 <= s <= N, f"stride {s} outside [1, {N}] range"

    # Buffer must be idle before accepting a new tile
    await wait_for(dut, dut.io_drainDone, 1)
    await drive_config(dut, stride=s, elem_size=elem_size)

    raw = np.frombuffer(x.tobytes(), dtype=np.uint8)
    write_beats = [raw[i * N:(i + 1) * N] for i in range(s)]
    await drive_write_stream(dut, write_beats, N)

    await wait_for(dut, dut.io_fillDone, 1)

    stop_ready_event = Event()
    ready_task = cocotb.start_soon(
        random_ready_driver(dut, stop_ready_event, p_ready=p_ready)
    )
    out_beats = await collect_read_beats(dut, s, N)
    stop_ready_event.set()
    await ready_task

    await wait_for(dut, dut.io_drainDone, 1)

    return np.frombuffer(out_beats.tobytes(), dtype=x.dtype).reshape(s, G)


def random_tensor(dtype, shape) -> np.ndarray:
    """Random tensor over the full value range of dtype."""
    info = np.iinfo(dtype)
    n_bytes = int(np.prod(shape)) * info.dtype.itemsize
    raw = np.random.randint(0, 256, size=n_bytes, dtype=np.uint8)
    return raw.view(dtype).reshape(shape)


@cocotb.test()
async def test_transpose_buffer_randomized(dut):
    """Verifies randomized (dtype, stride) sweeps with backpressure."""
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset_dut(dut)

    N = 16
    dtypes = get_valid_dtypes(N)
    num_iterations = 40

    dut._log.info(f"Starting {num_iterations} randomized transpose tests...")

    for iteration in range(num_iterations):
        # 1. Randomize dtype and stride
        dtype = random.choice(dtypes)
        elem_size = np.dtype(dtype).itemsize
        G = N // elem_size
        s = random.randint(1, N)
        shape = (G, s)

        dut._log.info(
            f"[Iter {iteration+1:02d}/{num_iterations}] Testing {dtype.__name__}, "
            f"shape={shape} (stride={s}, elem_size={elem_size}B)"
        )

        # 2. Generate random input tensor
        input_data = random_tensor(dtype, shape)

        # 3. Expected output is simply the transpose
        expected_data = input_data.T

        # 4. Hardware execution via helper function
        result_data = await transpose(dut, input_data, N)

        # 5. Assertion
        assert np.array_equal(expected_data, result_data), (
            f"Mismatch on iteration {iteration+1} for {dtype.__name__} {shape}!"
        )

    dut._log.info("All randomized test iterations PASSED successfully!")
