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
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge
from coralnpu_test_utils.spi_constants import SPI_V2_OP_READ, SPI_V2_OP_WRITE, SPI_V2_BEAT_BYTES


class SPIMaster:

    def __init__(self, clk, csb, mosi, miso, main_clk, log, width=1):
        self.clk = clk
        self.csb = csb
        self.mosi = mosi
        self.miso = miso
        self.main_clk = main_clk
        self.log = log
        self.width = width
        self.spi_clk_driver = Clock(
            self.clk, 26, "ns"
        )  # Must not divide evenly into sys clock (10ns)
        self.clock_task = None

        # Initialize signal values
        self.clk.value = 0
        self.csb.value = 1
        self.mosi.value = 0

    async def start_clock(self):
        if self.clock_task is None:
            self.clock_task = self.spi_clk_driver.start(start_high=False)

    async def stop_clock(self):
        if self.clock_task is not None:
            self.spi_clk_driver.stop()
            self.clock_task = None
            self.clk.value = 0

    # Maximum beats per Wide-SPI write sub-frame (matches Zynq WideSpiTx maxWriteChunkBeats).
    MAX_WIDE_WRITE_BEATS = 60

    async def _set_cs(self, active):
        self.csb.value = not active

    async def _clock_byte(self, data_out):
        """Transfer one 8-bit byte MSB-first across (8 // width) SPI clock cycles.

        Requires width <= 8 (1, 2, 4, or 8). Raises ValueError when width > 8
        because one 16-bit SPI clock transfers two bytes at once; callers in
        16-bit mode must use _clock_word16 instead.
        """
        if self.width > 8:
            raise ValueError(
                f"_clock_byte requires width <= 8 (got width={self.width}); "
                "use _clock_word16 for 16-bit transfers."
            )
        data_in = 0
        if self.width == 1:
            for i in range(8):
                self.mosi.value = (data_out >> (7 - i)) & 1
                await FallingEdge(self.clk)
                data_in = (data_in << 1) | int(self.miso.value)
        else:
            step = self.width
            mask = (1 << step) - 1
            for i in range(8 - step, -1, -step):
                self.mosi.value = (data_out >> i) & mask
                await FallingEdge(self.clk)
                data_in = (data_in << step) | (int(self.miso.value) & mask)
        return data_in

    async def _clock_word16(self, word_out):
        """Transfer one 16-bit halfword in a single SPI clock cycle (width == 16)."""
        if self.width != 16:
            raise ValueError(
                f"_clock_word16 requires width == 16 (got width={self.width}); "
                "use _clock_byte for narrow SPI transfers."
            )
        self.mosi.value = word_out & 0xFFFF
        await FallingEdge(self.clk)
        try:
            return int(self.miso.value) & 0xFFFF
        except ValueError:
            return 0

    async def _wait_write_ack_16(self, max_words=2048):
        """Clock dummy 0x0000 halfwords until MISO returns the 0x00AA write ack."""
        for _ in range(max_words):
            if await self._clock_word16(0x0000) == 0x00AA:
                return
        raise TimeoutError(
            f"Timed out waiting for 0x00AA write ack after {max_words} words."
        )

    async def idle_clocking(self, cycles):
        await self.start_clock()
        await ClockCycles(self.clk, cycles)
        await self.stop_clock()

    async def send_header(self, op, addr, length):
        """Send a V2 frame header (4x16b for width=16, 7x8b for width<=8)."""
        if self.width == 16:
            await self._clock_word16(op & 0xFF)
            await self._clock_word16(length & 0xFFFF)
            await self._clock_word16(addr & 0xFFFF)
            await self._clock_word16((addr >> 16) & 0xFFFF)
        else:
            await self._clock_byte(op & 0xFF)
            await self._clock_byte((addr >> 24) & 0xFF)
            await self._clock_byte((addr >> 16) & 0xFF)
            await self._clock_byte((addr >> 8) & 0xFF)
            await self._clock_byte(addr & 0xFF)
            await self._clock_byte((length >> 8) & 0xFF)
            await self._clock_byte(length & 0xFF)

    async def write_line(self, addr, data_128bit):
        """Write a single 128-bit line using V2 frame protocol."""
        self.mosi.value = 0
        # Clock dummy cycles while CSB is inactive (csb=1) so CDC AsyncQueue pointers sync
        await self.idle_clocking(10)
        await ClockCycles(self.main_clk, 10)
        await self._set_cs(True)
        await ClockCycles(self.main_clk, 2)
        await self.start_clock()

        # Send header: op=WRITE, len=0 (single beat)
        await self.send_header(SPI_V2_OP_WRITE, addr, 0)

        # Send 16 payload bytes (8x 16-bit halfwords for width=16), LSB first
        if self.width == 16:
            for i in range(8):
                await self._clock_word16((data_128bit >> (i * 16)) & 0xFFFF)
            self.mosi.value = 0
            try:
                await self._wait_write_ack_16()
            finally:
                await self.stop_clock()
                await ClockCycles(self.main_clk, 1)
                await self._set_cs(False)
                await ClockCycles(self.main_clk, 50)
            return

        for i in range(SPI_V2_BEAT_BYTES):
            await self._clock_byte((data_128bit >> (i * 8)) & 0xFF)

        self.mosi.value = 0

        # Keep SPI clock running so AsyncQueue CDC pipeline can drain
        # (both clocks must be active for the handshake protocol).
        await ClockCycles(self.main_clk, 100)
        await self.stop_clock()
        await ClockCycles(self.main_clk, 1)
        await self._set_cs(False)
        await ClockCycles(self.main_clk, 50)

    async def read_line(self, addr):
        """Read a single 128-bit line using V2 frame protocol.

        Returns the 128-bit data as an integer.
        """
        self.mosi.value = 0
        # Clock dummy cycles while CSB is inactive (csb=1) so CDC AsyncQueue pointers sync
        await self.idle_clocking(10)
        await ClockCycles(self.main_clk, 10)
        await self._set_cs(True)
        await ClockCycles(self.main_clk, 2)
        await self.start_clock()

        await self.send_header(SPI_V2_OP_READ, addr, 0)

        if self.width == 16:
            max_sync_words = 512
            try:
                for _ in range(max_sync_words):
                    if await self._clock_word16(0x0000) == 0x00FE:
                        result = 0
                        for i in range(8):
                            word = await self._clock_word16(0x0000)
                            result |= (word & 0xFFFF) << (i * 16)
                        return result
                raise TimeoutError(
                    f"Timed out waiting for 0x00FE read sync at 0x{addr:08x}."
                )
            finally:
                self.mosi.value = 0
                await self.stop_clock()
                await ClockCycles(self.main_clk, 1)
                await self._set_cs(False)
                await ClockCycles(self.main_clk, 50)

        # Collect MISO bits — V2 response has variable CDC latency.
        # Collect extra bits and search for the response data pattern.
        # We need 128 bits (16 bytes) of response data, but there's latency
        # through the CDC path, so we collect extra and search.
        num_extra_bytes = 128  # generous margin for AsyncQueue CDC latency
        total_bytes = SPI_V2_BEAT_BYTES + num_extra_bytes
        miso_bytes = []
        for _ in range(total_bytes):
            byte_in = await self._clock_byte(0x00)
            miso_bytes.append(byte_in)

        self.mosi.value = 0

        # Keep SPI clock running so AsyncQueue CDC can drain
        await ClockCycles(self.main_clk, 100)
        await self.stop_clock()
        await ClockCycles(self.main_clk, 1)
        await self._set_cs(False)
        await ClockCycles(self.main_clk, 50)

        # Fast path: Byte-level search (enabled by hardware byte-alignment).
        miso_bytes_raw = bytes(miso_bytes)
        sync_idx = miso_bytes_raw.find(b'\xfe')
        if sync_idx != -1 and sync_idx + 1 + 16 <= len(miso_bytes_raw):
            data_bytes = miso_bytes_raw[sync_idx + 1:sync_idx + 17]
            return int.from_bytes(data_bytes, 'little')

        # Fallback: Efficient bit-level search for 0xFE token (11111110) if misalignment occurs.
        # Convert byte array to a single large integer for bitwise operations.
        miso_int = int.from_bytes(miso_bytes_raw, 'big')
        total_bits = len(miso_bytes_raw) * 8

        # Sliding window search: mask 8 bits and compare to 0xFE.
        # We search from MSB to LSB (SPI order).
        for bit_off in range(total_bits - 8 - 128):
            shift = total_bits - 8 - bit_off
            if ((miso_int >> shift) & 0xFF) == 0xFE:
                # Found token. Extract 128 data bits following it.
                data_bits = (miso_int >> (shift - 128)) & ((1 << 128) - 1)

                # Reverse byte order: SPI shifts out MSB-first, but TileLink is little-endian.
                result = 0
                for i in range(16):
                    byte = (data_bits >> (i * 8)) & 0xFF
                    result |= byte << ((15 - i) * 8)
                return result

        return 0

    async def write_multi(self, addr, data_list):
        """Write multiple 128-bit beats using V2 frame protocol."""
        if not data_list:
            return

        if self.width == 16:
            # Segment into closed-loop sub-frames paced by 0x00AA write acks.
            for offset in range(0, len(data_list), self.MAX_WIDE_WRITE_BEATS):
                chunk = data_list[offset:offset + self.MAX_WIDE_WRITE_BEATS]
                chunk_addr = addr + offset * SPI_V2_BEAT_BYTES
                self.mosi.value = 0
                await self.idle_clocking(10)
                await ClockCycles(self.main_clk, 10)
                await self._set_cs(True)
                await ClockCycles(self.main_clk, 2)
                await self.start_clock()

                await self.send_header(
                    SPI_V2_OP_WRITE, chunk_addr,
                    len(chunk) - 1
                )
                for data_128bit in chunk:
                    for i in range(8):
                        await self._clock_word16((data_128bit >> (i * 16))
                                                 & 0xFFFF)
                self.mosi.value = 0
                try:
                    await self._wait_write_ack_16()
                finally:
                    await self.stop_clock()
                    await ClockCycles(self.main_clk, 1)
                    await self._set_cs(False)
                    await ClockCycles(self.main_clk, 50)
            return

        self.mosi.value = 0
        await self.idle_clocking(10)
        await ClockCycles(self.main_clk, 10)
        await self._set_cs(True)
        await ClockCycles(self.main_clk, 2)
        await self.start_clock()

        # Send header: len = num_beats - 1
        await self.send_header(SPI_V2_OP_WRITE, addr, len(data_list) - 1)

        # Send payload bytes for each beat, LSB first
        for data_128bit in data_list:
            for i in range(SPI_V2_BEAT_BYTES):
                await self._clock_byte((data_128bit >> (i * 8)) & 0xFF)

        self.mosi.value = 0
        await ClockCycles(self.main_clk, 100)
        await self.stop_clock()
        await ClockCycles(self.main_clk, 1)
        await self._set_cs(False)
        await ClockCycles(self.main_clk, 50)

    async def read_multi(self, addr, num_beats):
        """Read multiple 128-bit beats using V2 frame protocol.

        Returns a list of 128-bit integers.
        """
        results = []
        # For simplicity, do individual reads (multi-beat read response
        # parsing through CDC is complex in cocotb)
        for i in range(num_beats):
            beat_addr = addr + i * SPI_V2_BEAT_BYTES
            result = await self.read_line(beat_addr)
            results.append(result)
        return results
