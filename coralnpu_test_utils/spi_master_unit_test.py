#!/usr/bin/env python3
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
"""Unit tests for coralnpu_test_utils/spi_master.py."""

import unittest
from unittest import mock

from coralnpu_test_utils import spi_master
from coralnpu_test_utils.spi_constants import SPI_V2_BEAT_BYTES, SPI_V2_OP_READ, SPI_V2_OP_WRITE


class _FakeSignal:

    def __init__(self, value=0):
        self.value = value


async def _noop_trigger(*_args, **_kwargs):
    return None


class SPIMasterUnitTest(unittest.IsolatedAsyncioTestCase):

    def setUp(self):
        super().setUp()
        self.clock_patcher = mock.patch.object(spi_master, "Clock")
        self.cycles_patcher = mock.patch.object(
            spi_master, "ClockCycles", side_effect=_noop_trigger
        )
        self.falling_patcher = mock.patch.object(
            spi_master, "FallingEdge", side_effect=_noop_trigger
        )
        self.mock_clock_cls = self.clock_patcher.start()
        self.cycles_patcher.start()
        self.falling_patcher.start()
        self.addCleanup(self.clock_patcher.stop)
        self.addCleanup(self.cycles_patcher.stop)
        self.addCleanup(self.falling_patcher.stop)

    def _make_master(self, width):
        return spi_master.SPIMaster(
            clk=_FakeSignal(),
            csb=_FakeSignal(),
            mosi=_FakeSignal(),
            miso=_FakeSignal(),
            main_clk=_FakeSignal(),
            log=mock.MagicMock(),
            width=width,
        )

    async def test_width_guards_on_byte_and_word16_helpers(self):
        wide = self._make_master(width=16)
        with self.assertRaises(ValueError):
            await wide._clock_byte(0x12)

        for narrow_w in (1, 2, 4, 8):
            narrow = self._make_master(width=narrow_w)
            with self.assertRaises(ValueError):
                await narrow._clock_word16(0x1234)

    async def test_write_line_16_polls_ack_and_deasserts_csb(self):
        wide = self._make_master(width=16)
        tx_words = []
        rx_script = [0x0000] * 14 + [0x00AA]

        async def fake_clock_word16(word_out):
            tx_words.append(word_out)
            return rx_script.pop(0) if rx_script else 0x00AA

        wide._clock_word16 = fake_clock_word16
        payload = 0x100F0E0D0C0B0A090807060504030201
        await wide.write_line(0x80001230, payload)

        self.assertEqual(
            tx_words[:4], [SPI_V2_OP_WRITE, 0x0000, 0x1230, 0x8000]
        )
        self.assertEqual(
            tx_words[4:12],
            [0x0201, 0x0403, 0x0605, 0x0807, 0x0A09, 0x0C0B, 0x0E0D, 0x100F],
        )
        self.assertEqual(wide.csb.value, 1)

    async def test_write_line_16_raises_timeout_and_cleans_up_csb(self):
        wide = self._make_master(width=16)
        wide.miso.value = 0x0000
        with self.assertRaises(TimeoutError):
            await wide.write_line(0x80000000, 0x1234)
        self.assertEqual(wide.csb.value, 1)

    async def test_read_line_16_parses_sync_and_raises_on_timeout(self):
        wide = self._make_master(width=16)
        rx_words = [
            0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x00FE, 0x1100, 0x2211,
            0x3322, 0x4433, 0x5544, 0x6655, 0x7766, 0x8877
        ]

        async def fake_clock_word16(_word_out):
            return rx_words.pop(0) if rx_words else 0x0000

        wide._clock_word16 = fake_clock_word16
        val = await wide.read_line(0x80000000)
        self.assertEqual(val, 0x88777766665555444433332222111100)
        self.assertEqual(wide.csb.value, 1)

        # Verify timeout raises TimeoutError instead of returning 0 silently
        wide_timeout = self._make_master(width=16)
        wide_timeout.miso.value = 0x0000
        with self.assertRaises(TimeoutError):
            await wide_timeout.read_line(0x80000000)
        self.assertEqual(wide_timeout.csb.value, 1)

    async def test_write_multi_16_segments_into_60_beat_subframes(self):
        wide = self._make_master(width=16)
        headers = []
        orig_send_header = wide.send_header

        async def record_header(op, addr, length):
            headers.append((op, addr, length))
            await orig_send_header(op, addr, length)

        wide.send_header = record_header
        wide.miso.value = 0x00AA

        beats = [0xA000 + i for i in range(65)]
        await wide.write_multi(0x80000000, beats)

        self.assertEqual(
            headers,
            [
                (SPI_V2_OP_WRITE, 0x80000000, 59),
                (SPI_V2_OP_WRITE, 0x80000000 + 60 * SPI_V2_BEAT_BYTES, 4),
            ],
        )
        self.assertEqual(wide.csb.value, 1)


if __name__ == "__main__":
    unittest.main()
