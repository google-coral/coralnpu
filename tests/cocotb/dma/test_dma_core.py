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
"""Cocotb testbench for DmaCore (memcopy).

Structure mirrors the flow the DMA will be driven with from C:

    1. write SRC_ADDR, DST_ADDR, LEN_FLAGS over the TL-UL device port
    2. write CTRL.start
    3. a memory agent on the host port serves Gets and absorbs Puts
    4. poll STATUS until done
    5. compare the agent's memory against the expected result
"""

import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

# DLENB in bytes. p.w = dataBits / 8; lsuDataBits = 256 -> 32 bytes.
N = 32
GMAX = N.bit_length() - 1  # log2(N) = 5
BUF_BYTES = N * N  # one chunk = N beats of N bytes

CLK_PERIOD_NS = 10

CTRL = 0x00
STATUS = 0x04
SRC_ADDR = 0x08
DST_ADDR = 0x0C
LEN_FLAGS = 0x10

CTRL_ENABLE = 1 << 0
CTRL_START = 1 << 1

STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 1
STATUS_ERROR = 1 << 2
STATUS_ALIGN_ERR = 1 << 3
STATUS_CFG_ERR = 1 << 4

# If DmaCsr places read data at the LSBs of the beat (as CoreTlulCSR does)
# rather than in the lane implied by the address, set this False.
CSR_READ_DATA_IN_LANE = True

OP_A_PUT_FULL = 0
OP_A_PUT_PARTIAL = 1
OP_A_GET = 4

OP_D_ACCESS_ACK = 0
OP_D_ACCESS_ACK_DATA = 1

SRC_BASE = 0x8000_0000
DST_BASE = 0x2000_0000


def make_len_flags(length, width_log2=GMAX, src_fixed=0, dst_fixed=0):
    """Pack LEN_FLAGS. Mirrors coralnpu_dma_make_len_flags() in the C header."""
    return ((length & 0x00FFFFFF)
            | ((width_log2 & 0x7) << 24)
            | ((1 if src_fixed else 0) << 27)
            | ((1 if dst_fixed else 0) << 28))


async def csr_write(dut, addr, value):
    """32-bit register write. One PutPartialData beat with a 4-byte mask.

    All five registers live in one aligned N-byte beat, so the byte offset
    inside the beat selects which lane carries the data. DmaCsr extracts that
    lane statically per register, the same way CoreTlulCSR does.
    """
    byte_off = addr % N
    await RisingEdge(dut.clock)
    dut.io_tl_device_a_valid.value = 1
    dut.io_tl_device_a_bits_opcode.value = OP_A_PUT_PARTIAL
    dut.io_tl_device_a_bits_param.value = 0
    dut.io_tl_device_a_bits_size.value = 2  # 4 bytes
    dut.io_tl_device_a_bits_source.value = 0
    dut.io_tl_device_a_bits_address.value = addr
    dut.io_tl_device_a_bits_mask.value = 0xF << byte_off
    dut.io_tl_device_a_bits_data.value = (value & 0xFFFFFFFF) << (8 * byte_off)

    while True:
        await FallingEdge(dut.clock)
        if dut.io_tl_device_a_ready.value == 1:
            break
    await RisingEdge(dut.clock)
    dut.io_tl_device_a_valid.value = 0

    await _await_csr_response(dut)


async def csr_read(dut, addr):
    """32-bit register read. One Get beat."""
    byte_off = addr % N
    await RisingEdge(dut.clock)
    dut.io_tl_device_a_valid.value = 1
    dut.io_tl_device_a_bits_opcode.value = OP_A_GET
    dut.io_tl_device_a_bits_param.value = 0
    dut.io_tl_device_a_bits_size.value = 2
    dut.io_tl_device_a_bits_source.value = 0
    dut.io_tl_device_a_bits_address.value = addr
    dut.io_tl_device_a_bits_mask.value = 0xF << byte_off
    dut.io_tl_device_a_bits_data.value = 0

    while True:
        await FallingEdge(dut.clock)
        if dut.io_tl_device_a_ready.value == 1:
            break
    await RisingEdge(dut.clock)
    dut.io_tl_device_a_valid.value = 0

    data = await _await_csr_response(dut)
    if CSR_READ_DATA_IN_LANE:
        return (data >> (8 * byte_off)) & 0xFFFFFFFF
    return data & 0xFFFFFFFF


async def _await_csr_response(dut):
    """Wait for the D beat, check error, return the raw data word."""
    dut.io_tl_device_d_ready.value = 1
    while True:
        await FallingEdge(dut.clock)
        if dut.io_tl_device_d_valid.value == 1:
            data = int(dut.io_tl_device_d_bits_data.value)
            err = int(dut.io_tl_device_d_bits_error.value)
            assert err == 0, "CSR access returned error (unmapped address?)"
            await RisingEdge(dut.clock)
            dut.io_tl_device_d_ready.value = 0
            return data


class TlulMemoryAgent:
    """Device-side TL-UL responder backed by a sparse byte dict.

    Serves Get with AccessAckData and PutFullData/PutPartialData with
    AccessAck. Response latency and ordering are configurable so the DUT is
    exercised with several requests in flight and, optionally, with responses
    returned out of order.
    """

    def __init__(
        self,
        dut,
        prefix="io_tl_host",
        data_bytes=N,
        min_latency=1,
        max_latency=1,
        reorder=False,
        p_a_ready=1.0,
        max_outstanding=64,
    ):
        self.dut = dut
        self.prefix = prefix
        self.data_bytes = data_bytes
        self.min_latency = min_latency
        self.max_latency = max_latency
        self.reorder = reorder
        self.p_a_ready = p_a_ready
        self.max_outstanding = max_outstanding

        self.mem = {}  # addr -> byte
        self.pending = []  # queued responses
        self.cycle = 0
        self.gets = 0
        self.puts = 0
        self.error_addrs = set()

    # ------------------------------------------------------------- signals

    def _sig(self, suffix):
        return getattr(self.dut, f"{self.prefix}_{suffix}")

    def _has(self, suffix):
        return hasattr(self.dut, f"{self.prefix}_{suffix}")

    # ---------------------------------------------------------- memory API

    def preload(self, addr, data):
        for i, b in enumerate(bytes(data)):
            self.mem[addr + i] = b

    def preload_random(self, addr, n_bytes):
        data = np.random.randint(0, 256, size=n_bytes, dtype=np.uint8)
        self.preload(addr, data.tobytes())
        return data

    def read(self, addr, n_bytes):
        return np.array([self.mem.get(addr + i, 0) for i in range(n_bytes)],
                        dtype=np.uint8)

    def touched(self, addr, n_bytes):
        """True if any byte in the range has ever been written."""
        return any((addr + i) in self.mem for i in range(n_bytes))

    # ----------------------------------------------------------- internals

    def _read_word(self, addr):
        word = 0
        for i in range(self.data_bytes):
            word |= self.mem.get(addr + i, 0) << (8 * i)
        return word

    def _write_word(self, addr, data, mask):
        for i in range(self.data_bytes):
            if (mask >> i) & 1:
                self.mem[addr + i] = (data >> (8 * i)) & 0xFF

    def _accept(self):
        opcode = int(self._sig("a_bits_opcode").value)
        size = int(self._sig("a_bits_size").value)
        source = int(self._sig("a_bits_source").value)
        addr = int(self._sig("a_bits_address").value)
        mask = int(self._sig("a_bits_mask").value)

        expected_size = self.data_bytes.bit_length() - 1
        assert size == expected_size, (
            f"expected full-beat size={expected_size}, got {size} "
            f"at addr 0x{addr:08x}"
        )
        assert addr % self.data_bytes == 0, (
            f"unaligned bus address 0x{addr:08x}"
        )

        error = addr in self.error_addrs
        latency = random.randint(self.min_latency, self.max_latency)

        if opcode == OP_A_GET:
            self.gets += 1
            self.pending.append({
                "source": source,
                "opcode": OP_D_ACCESS_ACK_DATA,
                "size": size,
                "data": self._read_word(addr),
                "error": error,
                "ready_at": self.cycle + latency,
            })
        elif opcode in (OP_A_PUT_FULL, OP_A_PUT_PARTIAL):
            self.puts += 1
            data = int(self._sig("a_bits_data").value)
            if opcode == OP_A_PUT_FULL:
                full = (1 << self.data_bytes) - 1
                assert mask == full, (
                    f"PutFullData with partial mask 0x{mask:x} "
                    f"at addr 0x{addr:08x}"
                )
            if not error:
                self._write_word(addr, data, mask)
            self.pending.append({
                "source": source,
                "opcode": OP_D_ACCESS_ACK,
                "size": size,
                "data": 0,
                "error": error,
                "ready_at": self.cycle + latency,
            })
        else:
            raise AssertionError(f"unsupported A opcode {opcode}")

    def _pick(self):
        eligible = [r for r in self.pending if r["ready_at"] <= self.cycle]
        if not eligible:
            return None
        if self.reorder:
            return random.choice(eligible)
        oldest = self.pending[0]
        return oldest if oldest in eligible else None

    def _drive_d(self, resp):
        if resp is None:
            self._sig("d_valid").value = 0
            return
        self._sig("d_valid").value = 1
        self._sig("d_bits_opcode").value = resp["opcode"]
        self._sig("d_bits_param").value = 0
        self._sig("d_bits_size").value = resp["size"]
        self._sig("d_bits_source").value = resp["source"]
        self._sig("d_bits_data").value = resp["data"]
        self._sig("d_bits_error").value = 1 if resp["error"] else 0
        if self._has("d_bits_sink"):
            self._sig("d_bits_sink").value = 0

    # ---------------------------------------------------------------- main

    async def run(self):
        self._sig("a_ready").value = 0
        self._drive_d(None)
        offered = None

        while True:
            await FallingEdge(self.dut.clock)

            if (int(self._sig("a_valid").value) == 1
                    and int(self._sig("a_ready").value) == 1):
                self._accept()

            if (int(self._sig("d_valid").value) == 1
                    and int(self._sig("d_ready").value) == 1):
                assert offered is not None, "d fired with no offer"
                self.pending.remove(offered)
                offered = None

            await RisingEdge(self.dut.clock)
            self.cycle += 1

            room = len(self.pending) < self.max_outstanding
            self._sig("a_ready").value = (
                1 if (room and random.random() < self.p_a_ready) else 0
            )

            offered = self._pick()
            self._drive_d(offered)

    # ----------------------------------------------------------- diagnostics

    def assert_quiescent(self):
        assert not self.pending, (
            f"{len(self.pending)} responses still pending: "
            f"{[r['source'] for r in self.pending]}"
        )


async def reset_dut(dut):
    dut.reset.value = 1
    dut.io_tl_device_a_valid.value = 0
    dut.io_tl_device_d_ready.value = 0
    await ClockCycles(dut.clock, 5)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 2)


async def wait_done(dut, timeout_cycles):
    """Poll STATUS until done or error. Returns the status word."""
    polls = 0
    while True:
        status = await csr_read(dut, STATUS)
        if status & (STATUS_DONE | STATUS_ERROR):
            return status
        polls += 1
        assert polls * 8 < timeout_cycles, (
            f"DMA did not complete within {timeout_cycles} cycles "
            f"(last status 0x{status:02x})"
        )


def timeout_for(length, agent):
    """Generous cycle bound: beats * worst-case latency, plus slack."""
    beats = (length + N - 1) // N
    return beats * (agent.max_latency + 8) + 500


async def dma_memcpy(dut, agent, src, dst, length, width_log2=GMAX):
    """Drive one full transfer the way the C library will.

    Returns the STATUS word read at completion.
    """
    await csr_write(dut, SRC_ADDR, src)
    await csr_write(dut, DST_ADDR, dst)
    await csr_write(dut, LEN_FLAGS, make_len_flags(length, width_log2))
    await csr_write(dut, CTRL, CTRL_ENABLE | CTRL_START)
    return await wait_done(dut, timeout_for(length, agent))


async def run_and_check(dut, agent, length, src=SRC_BASE, dst=DST_BASE):
    """Preload, transfer, verify. The common body of most tests."""
    expected = agent.preload_random(src, length)
    status = await dma_memcpy(dut, agent, src, dst, length)

    assert status & STATUS_DONE, f"expected done, got status 0x{status:02x}"
    assert not (
        status & STATUS_ERROR
    ), f"unexpected error, status 0x{status:02x}"

    actual = agent.read(dst, length)
    if not np.array_equal(actual, expected):
        diff = np.where(actual != expected)[0]
        dut._log.error(f"len={length}: {len(diff)} bytes differ")
        dut._log.error(f"  first diff at byte {diff[0]}")
        dut._log.error(f"  expected {expected[diff[0]:diff[0]+8].tolist()}")
        dut._log.error(f"  actual   {actual[diff[0]:diff[0]+8].tolist()}")
        assert False, f"data mismatch for len={length}"

    agent.assert_quiescent()
    assert dut.io_busy.value == 0, "busy still asserted after done"


async def setup(dut, **agent_kwargs):
    """Start the clock, reset, launch the memory agent."""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, unit="ns").start())
    agent = TlulMemoryAgent(dut, **agent_kwargs)
    cocotb.start_soon(agent.run())
    await reset_dut(dut)
    return agent


@cocotb.test()
async def test_dma_smoke(dut):
    """Single beat, single chunk. If this fails nothing else matters."""
    agent = await setup(dut)
    await run_and_check(dut, agent, length=N)
    dut._log.info("smoke PASSED")


@cocotb.test()
async def test_dma_single_chunk(dut):
    """Multiple beats, still one chunk. Exercises one fill-drain cycle."""
    agent = await setup(dut)
    for beats in (2, 4, N // 2, N):
        await run_and_check(dut, agent, length=beats * N)
        dut._log.info(f"single chunk, {beats} beats PASSED")


@cocotb.test()
async def test_dma_partial_tail(dut):
    """len not a multiple of N. Proves lastMask on the final Put."""
    agent = await setup(dut)
    for length in (1, 2, N - 1, N + 1, 3 * N + 7):
        dst = DST_BASE + 0x1000 * length  # fresh region each time
        expected = agent.preload_random(SRC_BASE, length)
        status = await dma_memcpy(dut, agent, SRC_BASE, dst, length)
        assert status & STATUS_DONE

        actual = agent.read(dst, length)
        assert np.array_equal(actual, expected), f"data mismatch, len={length}"

        # Bytes past len inside the final beat must not have been written.
        tail = (N - (length % N)) % N
        if tail:
            assert not agent.touched(dst + length, tail), (
                f"drain wrote {tail} bytes past len={length}"
            )
        agent.assert_quiescent()
        dut._log.info(f"partial tail len={length} PASSED")


@cocotb.test()
async def test_dma_multi_chunk(dut):
    """len > buffer capacity. Proves the chunk loop and the done condition.

    This is the test that catches a done condition gated only on the drain
    engine: remaining hits zero when fill ACCEPTS the last chunk, at which
    point drain has not started and is therefore idle.
    """
    agent = await setup(dut)
    for chunks in (2, 3, 5):
        length = chunks * BUF_BYTES
        await run_and_check(dut, agent, length=length)
        dut._log.info(f"multi chunk, {chunks} chunks PASSED")


@cocotb.test()
async def test_dma_multi_chunk_partial(dut):
    """Multiple chunks with a ragged tail. Both paths at once."""
    agent = await setup(dut)
    for length in (BUF_BYTES + 1, 2 * BUF_BYTES + N + 5, 3 * BUF_BYTES - 1):
        dst = DST_BASE + 0x10000 * (length % 7)
        expected = agent.preload_random(SRC_BASE, length)
        status = await dma_memcpy(dut, agent, SRC_BASE, dst, length)
        assert status & STATUS_DONE
        assert np.array_equal(agent.read(dst, length),
                              expected), (f"data mismatch, len={length}")
        agent.assert_quiescent()
        dut._log.info(f"multi chunk partial len={length} PASSED")


@cocotb.test()
async def test_dma_back_to_back(dut):
    """Several transfers with no reset between. Proves counters clear."""
    agent = await setup(dut)
    for i in range(8):
        length = random.choice([N, 3 * N, BUF_BYTES, BUF_BYTES + N + 3])
        src = SRC_BASE + i * 0x10000
        dst = DST_BASE + i * 0x10000
        await run_and_check(dut, agent, length=length, src=src, dst=dst)
    dut._log.info("back to back PASSED")


@cocotb.test()
async def test_dma_align_error(dut):
    """Misaligned src or dst sets align_error and issues no bus traffic."""
    agent = await setup(dut)

    for src, dst in ((SRC_BASE + 1, DST_BASE), (SRC_BASE, DST_BASE + 4)):
        gets_before, puts_before = agent.gets, agent.puts
        status = await dma_memcpy(dut, agent, src, dst, N)

        assert status & STATUS_ERROR, "expected error"
        assert status & STATUS_ALIGN_ERR, "expected align_error bit"
        assert not (status & STATUS_DONE), "done set on a rejected transfer"
        assert agent.gets == gets_before and agent.puts == puts_before, (
            "rejected transfer still issued bus traffic"
        )
        dut._log.info(f"align error src=0x{src:x} dst=0x{dst:x} PASSED")


@cocotb.test()
async def test_dma_cfg_error(dut):
    """Unsupported LEN_FLAGS configurations set cfg_error."""
    agent = await setup(dut)

    cases = [
        ("len == 0", make_len_flags(0)),
        ("wrong width_log2", make_len_flags(N, width_log2=GMAX - 1)),
        ("src_fixed", make_len_flags(N, src_fixed=1)),
        ("dst_fixed", make_len_flags(N, dst_fixed=1)),
    ]

    for name, flags in cases:
        gets_before, puts_before = agent.gets, agent.puts
        await csr_write(dut, SRC_ADDR, SRC_BASE)
        await csr_write(dut, DST_ADDR, DST_BASE)
        await csr_write(dut, LEN_FLAGS, flags)
        await csr_write(dut, CTRL, CTRL_ENABLE | CTRL_START)
        status = await wait_done(dut, 500)

        assert status & STATUS_ERROR, f"{name}: expected error"
        assert status & STATUS_CFG_ERR, f"{name}: expected cfg_error bit"
        assert agent.gets == gets_before and agent.puts == puts_before, (
            f"{name}: rejected transfer still issued bus traffic"
        )
        dut._log.info(f"cfg error [{name}] PASSED")


@cocotb.test()
async def test_dma_source_integrity(dut):
    """The source region is unchanged after a transfer."""
    agent = await setup(dut)
    length = 2 * BUF_BYTES + N + 9
    expected = agent.preload_random(SRC_BASE, length)

    status = await dma_memcpy(dut, agent, SRC_BASE, DST_BASE, length)
    assert status & STATUS_DONE

    assert np.array_equal(agent.read(SRC_BASE, length),
                          expected), ("source region was modified")
    dut._log.info("source integrity PASSED")


@cocotb.test()
async def test_dma_randomized(dut):
    """Random lengths and addresses, latency and reordering enabled."""
    agent = await setup(
        dut,
        min_latency=4,
        max_latency=40,
        reorder=True,
        p_a_ready=0.7,
    )

    num_iterations = 30
    for i in range(num_iterations):
        length = random.randint(1, 4 * BUF_BYTES)
        src = SRC_BASE + random.randint(0, 64) * N
        dst = DST_BASE + (i + 1) * 0x20000

        dut._log.info(
            f"[{i+1:02d}/{num_iterations}] len={length} "
            f"src=0x{src:08x} dst=0x{dst:08x}"
        )
        await run_and_check(dut, agent, length=length, src=src, dst=dst)

    dut._log.info("randomized PASSED")
