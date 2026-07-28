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
"""Unit tests for FpgaTestFixture."""

import unittest
from unittest.mock import patch

import numpy as np

from coralnpu_test_utils.fpga_test_fixture import FpgaTestFixture


class FpgaTestFixtureTest(unittest.TestCase):

    @patch("coralnpu_test_utils.fpga_test_fixture.FtdiSpiMaster")
    def setUp(self, mock_ftdi_cls):
        self.mock_spi = mock_ftdi_cls.return_value
        self.fixture = FpgaTestFixture(
            usb_serial="Nexus-FTDI-12",
            csr_base_addr=0x30000,
            auto_recovery=False
        )

    def test_resolve_address(self):
        self.assertEqual(
            self.fixture.resolve_address(0x1000, offset=4), 0x1004
        )
        self.fixture.symbols["test_sym"] = 0x5000
        self.assertEqual(
            self.fixture.resolve_address("test_sym", offset=8), 0x5008
        )
        with self.assertRaises(ValueError):
            self.fixture.resolve_address("unknown_symbol")

    def test_check_memory_accessible(self):
        # Successful probe
        self.mock_spi.read_word.side_effect = [0x12345678, 0x5A5A5A5A]
        self.assertTrue(
            self.fixture.check_memory_accessible(
                0x80000000, pattern=0x5A5A5A5A
            )
        )

        # Failed probe
        self.mock_spi.read_word.side_effect = [0x12345678, 0xDEADBEEF]
        self.assertFalse(
            self.fixture.check_memory_accessible(
                0x80000000, pattern=0x5A5A5A5A
            )
        )

    def test_write_and_read_numpy(self):
        self.fixture.symbols["input_data"] = 0x4000
        self.fixture.symbol_sizes["input_data"] = 16
        input_arr = np.array([1, 2, 3, 4], dtype=np.int32)

        # Write with default calculated timeout (~2 MB/s rate)
        expected_write_to = FpgaTestFixture.calculate_write_timeout(
            len(input_arr.tobytes())
        )
        self.fixture.write("input_data", input_arr)
        self.mock_spi.load_data.assert_called_with(
            input_arr.tobytes(), 0x4000, timeout=expected_write_to
        )

        # Write with explicit timeout override
        self.fixture.write("input_data", input_arr, timeout=45.0)
        self.mock_spi.load_data.assert_called_with(
            input_arr.tobytes(), 0x4000, timeout=45.0
        )

        # Read with default calculated timeout (~500 kB/s rate)
        expected_read_to = FpgaTestFixture.calculate_read_timeout(16)
        self.mock_spi.read_data.return_value = input_arr.tobytes()
        read_arr = self.fixture.read(
            "input_data", dtype=np.int32, shape=(2, 2)
        )
        self.mock_spi.read_data.assert_called_with(
            0x4000, 16, timeout=expected_read_to
        )
        np.testing.assert_array_equal(read_arr, input_arr.reshape((2, 2)))

        # Read with explicit timeout override
        read_arr_custom = self.fixture.read(
            "input_data", dtype=np.int32, shape=(2, 2), timeout=60.0
        )
        self.mock_spi.read_data.assert_called_with(0x4000, 16, timeout=60.0)

    def test_write_and_read_scalars(self):
        self.fixture.symbols["test_var"] = 0x6000
        self.fixture.write("test_var", 42)
        self.mock_spi.write_word.assert_called_with(0x6000, 42)

        self.mock_spi.read_word.return_value = 42
        self.assertEqual(self.fixture.read_word("test_var"), 42)

    def test_read_word(self):
        # Reading by symbol name
        self.fixture.symbols["status_reg"] = 0x00100004
        self.mock_spi.read_word.return_value = 0x12345678
        self.assertEqual(self.fixture.read_word("status_reg"), 0x12345678)
        self.mock_spi.read_word.assert_called_with(0x00100004)

        # Reading by direct physical address
        self.mock_spi.read_word.return_value = 0xCAFEBABE
        self.assertEqual(self.fixture.read_word(0x40001000), 0xCAFEBABE)
        self.mock_spi.read_word.assert_called_with(0x40001000)

    def test_write_ptr(self):
        self.fixture.symbols["ptr_var"] = 0x5000
        self.fixture.symbols["data_buf"] = 0x80000000
        self.fixture.write_ptr("ptr_var", "data_buf", offset=16)
        self.mock_spi.write_word.assert_called_with(0x5000, 0x80000010)

    def test_run_to_halt(self):
        self.fixture.entry_point = 0x1000
        self.mock_spi.poll_for_halt.return_value = True
        self.assertTrue(self.fixture.run_to_halt(timeout_sec=10.0))
        self.mock_spi.set_entry_point.assert_called_once_with(0x1000)
        self.mock_spi.start_core.assert_called_once()
        self.mock_spi.poll_for_halt.assert_called_once_with(timeout=10.0)

    def test_reset_hardware(self):
        self.fixture.reset_hardware()
        self.mock_spi.soft_reset.assert_called_once()
        self.fixture.soft_reset()
        self.assertEqual(self.mock_spi.soft_reset.call_count, 2)

    def test_get_core_frequency(self):
        self.mock_spi.read_word.side_effect = lambda addr: 0x434C4B54 if addr == 0x40001000 else 50
        self.assertEqual(self.fixture.get_core_frequency_mhz(), 50)
        self.assertEqual(self.fixture.get_core_frequency_hz(), 50_000_000)

    def test_calculate_transfer_timeout(self):
        # Write timeout: base 10s + (bytes / 2_000_000) * 2.0
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_write_timeout(0), 10.0
        )
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_write_timeout(2_000_000), 12.0
        )
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_write_timeout(10_000_000), 20.0
        )

        # Read timeout: base 10s + (bytes / 500_000) * 2.0
        self.assertAlmostEqual(FpgaTestFixture.calculate_read_timeout(0), 10.0)
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_read_timeout(500_000), 12.0
        )
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_read_timeout(5_000_000), 30.0
        )

    def test_get_cycle_count(self):
        self.fixture.symbols["cycle_count"] = 0x1000
        self.mock_spi.read_word.return_value = 12345
        self.assertEqual(self.fixture.get_cycle_count(), 12345)

    def test_resolve_path_xlen(self):
        with (
                patch.dict("os.environ", {"TEST_XLEN": "64"}),
                patch("os.path.exists") as mock_exists,
        ):
            mock_exists.side_effect = lambda p: p == "/path/to/binary_64.elf"
            resolved = FpgaTestFixture.resolve_path("/path/to/binary.elf")
            self.assertEqual(resolved, "/path/to/binary_64.elf")

        with (
                patch.dict("os.environ", {"TEST_XLEN": "32"}),
                patch("os.path.exists") as mock_exists,
        ):
            mock_exists.side_effect = lambda p: p == "/path/to/binary.elf"
            resolved = FpgaTestFixture.resolve_path("/path/to/binary.elf")
            self.assertEqual(resolved, "/path/to/binary.elf")


if __name__ == "__main__":
    unittest.main()
