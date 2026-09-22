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
"""Unified unit test suite for all CoralNPU sim_backends fixtures."""

import asyncio
import os
import pathlib
import re
import struct
import tempfile
import unittest
from unittest.mock import AsyncMock, MagicMock, patch
import numpy as np

from coralnpu_test_utils.sim_backends.common_utils import (
    BytesResult,
    WordResult,
    infer_read_size_bytes,
    parse_elf_symbols,
    reconstruct_read_data,
    resolve_runfile_path,
    resolve_symbol_address,
    to_uint8_array,
)
from coralnpu_test_utils.sim_backends.fpga_test_fixture import FpgaTestFixture
from coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture import MpactNpuSimTestFixture
from coralnpu_test_utils.sim_backends.uvm_test_fixture import UvmTestFixture
from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture


class CommonUtilsTest(unittest.TestCase):
    """Tests for shared ELF symbol parsing, tensor marshaling, and WordResult."""

    def test_word_result_compatibility(self):
        w = WordResult(0x12345678)
        self.assertIsInstance(w, int)
        self.assertEqual(w, 0x12345678)
        self.assertEqual(w.view(np.uint32)[0], 0x12345678)
        self.assertEqual(w.tobytes(), b"\x78\x56\x34\x12")
        self.assertEqual(bytes(w), b"\x78\x56\x34\x12")

        b = BytesResult(b"\x78\x56\x34\x12")
        self.assertIsInstance(b, bytes)
        self.assertEqual(b.view(np.uint32)[0], 0x12345678)
        self.assertEqual(b.tobytes(), b"\x78\x56\x34\x12")

    def test_to_uint8_array_and_reconstruct(self):
        scalar_arr = to_uint8_array(0x01020304)
        self.assertEqual(len(scalar_arr), 4)
        self.assertEqual(
            reconstruct_read_data(scalar_arr, dtype=np.uint32)[0], 0x01020304
        )

        self.assertEqual(len(to_uint8_array(np.uint8(7))), 1)
        self.assertEqual(len(to_uint8_array(np.int16(-2))), 2)
        self.assertEqual(len(to_uint8_array(np.uint64(0x1_0000_0000))), 8)

        mat = np.arange(6, dtype=np.float32).reshape((2, 3))
        raw = to_uint8_array(mat)
        restored = reconstruct_read_data(raw, dtype=np.float32, shape=(2, 3))
        np.testing.assert_array_equal(restored, mat)

    def test_infer_read_size_bytes(self):
        sym_sizes = {"my_buf": 64}
        self.assertEqual(infer_read_size_bytes("my_buf", sym_sizes), 64)
        self.assertEqual(
            infer_read_size_bytes(
                "other", sym_sizes, dtype=np.int32, shape=(4, 4)
            ),
            64,
        )
        self.assertEqual(
            infer_read_size_bytes("other", sym_sizes, size=128), 128
        )

    def test_parse_elf_symbols_three_tiers(self):
        elf_path = resolve_runfile_path(
            "tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf"
        )
        entry, syms, sizes = parse_elf_symbols(
            elf_path,
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
            optional_symbols=["nonexistent_sim_symbol"],
            strict=True,
        )
        self.assertGreaterEqual(entry, 0)
        self.assertIn("in_buf_1", syms)
        self.assertIn("out_buf", syms)
        self.assertNotIn("nonexistent_sim_symbol", syms)
        self.assertGreater(sizes["in_buf_1"], 0)

        with self.assertRaises(ValueError):
            parse_elf_symbols(
                elf_path, symbols=["missing_required_sym"], strict=True
            )

        _, lazy_syms, _ = parse_elf_symbols(
            elf_path, symbols=["missing_required_sym"], strict=False
        )
        with self.assertRaises(ValueError):
            resolve_symbol_address("missing_required_sym", lazy_syms)


class TestVerilatorTestFixture(unittest.IsolatedAsyncioTestCase):
    """Tests for VerilatorTestFixture."""

    def setUp(self):
        self.elf_path = resolve_runfile_path(
            "tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf"
        )
        self.mock_dut = MagicMock()
        self.mock_dut.io_fault.value = 0

    @patch(
        "coralnpu_test_utils.sim_backends.verilator_test_fixture.CoreMiniAxiInterface"
    )
    @patch("cocotb.start_soon")
    async def test_create_and_load_elf_lazy_symbols(
        self, mock_start_soon, mock_axi_cls
    ):
        mock_axi = MagicMock()
        mock_axi.init = AsyncMock()
        mock_axi.reset = AsyncMock()
        mock_axi.load_elf = AsyncMock(return_value=0x100)
        mock_axi_cls.return_value = mock_axi

        fixture = await VerilatorTestFixture.Create(
            self.mock_dut, highmem=True
        )
        mock_axi_cls.assert_called_once_with(
            self.mock_dut, csr_base_addr=0x200000
        )
        mock_axi.init.assert_awaited_once()
        mock_axi.reset.assert_awaited_once()
        mock_start_soon.assert_called_once()

        with self.assertRaises(ValueError):
            await fixture.load_elf_and_lookup_symbols(
                self.elf_path,
                symbols=["in_buf_1", "unused_missing_sym"],
                optional=False,
            )

        syms = await fixture.load_elf_and_lookup_symbols(
            self.elf_path,
            symbols=["in_buf_1", "in_buf_2", "out_buf", "unused_missing_sym"],
            optional=True,
        )
        self.assertIn("in_buf_1", syms)
        self.assertNotIn("unused_missing_sym", syms)
        self.assertTrue(fixture.has_symbol("in_buf_1"))
        self.assertFalse(fixture.has_symbol("unused_missing_sym"))

        with self.assertRaises(ValueError):
            await fixture.read_word("unused_missing_sym")

    @patch(
        "coralnpu_test_utils.sim_backends.verilator_test_fixture.CoreMiniAxiInterface"
    )
    async def test_read_write_and_execution(self, mock_axi_cls):
        mock_axi = MagicMock()
        mock_axi.dut = self.mock_dut
        mock_axi.write = AsyncMock()
        mock_axi.write_word = AsyncMock()
        mock_axi.read = AsyncMock(
            return_value=np.array([10, 20, 30, 40], dtype=np.int32
                                  ).view(np.uint8)
        )
        mock_axi.read_word = AsyncMock(
            return_value=np.
            frombuffer(struct.pack("<I", 0xDEADBEEF), dtype=np.uint8)
        )
        mock_axi.execute_from = AsyncMock()
        mock_axi.wait_for_halted = AsyncMock(return_value=250)
        mock_axi.wait_for_fault = AsyncMock(return_value=120)
        mock_axi_cls.return_value = mock_axi

        fixture = VerilatorTestFixture(self.mock_dut)
        fixture.entry_point = 0x100
        fixture.symbols = {"buf": 0x1000, "ptr": 0x2000}
        fixture.symbol_sizes = {"buf": 16}

        arr = np.array([1, 2, 3, 4], dtype=np.int32)
        await fixture.write("buf", arr)
        mock_axi.write.assert_awaited_once()
        self.assertEqual(mock_axi.write.call_args[0][0], 0x1000)

        await fixture.write_word("buf", 0xCAFEBABE, offset=4)
        mock_axi.write_word.assert_awaited_with(0x1004, 0xCAFEBABE)

        await fixture.write_ptr("ptr", "buf", offset=8)
        mock_axi.write_word.assert_awaited_with(0x2000, 0x1008)

        read_arr = await fixture.read("buf", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(
            read_arr, np.array([10, 20, 30, 40], dtype=np.int32)
        )

        word = await fixture.read_word("buf")
        self.assertEqual(word, 0xDEADBEEF)
        self.assertEqual(word.view(np.uint32)[0], 0xDEADBEEF)
        self.assertEqual(word.tobytes(), struct.pack("<I", 0xDEADBEEF))

        cycles = await fixture.run_to_halt(timeout_cycles=5000)
        self.assertEqual(cycles, 250)
        self.assertEqual(fixture.get_cycle_count(), 250)

        fault_cycles = await fixture.run_to_fault(timeout_cycles=1000)
        self.assertEqual(fault_cycles, 120)
        self.assertFalse(fixture.fault())
        self.mock_dut.io_fault.value = 1
        self.assertTrue(fixture.fault())


class TestMpactNpuSimTestFixture(unittest.IsolatedAsyncioTestCase):
    """Unit and real-ELF smoke tests for MpactNpuSimTestFixture."""

    def setUp(self):
        self.elf_path = resolve_runfile_path(
            "tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf"
        )

    async def test_end_to_end_rvv_add_int8_m1(self):
        fixture = await MpactNpuSimTestFixture.Create(highmem=True)
        await fixture.load_elf_and_lookup_symbols(
            self.elf_path,
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
        )

        in1 = np.arange(16, dtype=np.uint8)
        in2 = np.arange(16, dtype=np.uint8) * 2
        await fixture.write("in_buf_1", in1)
        await fixture.write("in_buf_2", in2)

        halted = await fixture.run_to_halt()
        self.assertTrue(halted)
        self.assertGreater(fixture.get_cycle_count(), 0)

        actual_out = await fixture.read(
            "out_buf", size=16, dtype=np.uint8, shape=(16, )
        )
        np.testing.assert_array_equal(actual_out, in1 + in2)

        first_word = await fixture.read_word("out_buf")
        expected_word = int.from_bytes((in1 + in2)[:4].tobytes(), "little")
        self.assertEqual(first_word, expected_word)
        self.assertEqual(first_word.view(np.uint32)[0], expected_word)

    async def test_write_word_np_uint32_and_offset(self):
        mock_sim = MagicMock()
        mock_sim.get_cycle_count.return_value = 42
        mock_sim.read_memory.return_value = np.array([0x78, 0x56, 0x34, 0x12],
                                                     dtype=np.uint8)

        fixture = MpactNpuSimTestFixture(sim=mock_sim)
        fixture.symbols = {"buf": 0x1000}

        await fixture.write_word("buf", 0x12345678, offset=4)
        mock_sim.write_word.assert_called_once()
        addr_arg, val_arg = mock_sim.write_word.call_args[0]
        self.assertEqual(addr_arg, 0x1004)
        self.assertEqual(val_arg.dtype, np.uint32)
        self.assertEqual(int(val_arg), 0x12345678)

        word = await fixture.read_word("buf", offset=4)
        self.assertEqual(word, 0x12345678)
        self.assertEqual(word.view(np.uint32)[0], 0x12345678)

    async def test_run_to_halt_timeout_cycles(self):
        mock_sim = MagicMock()
        mock_sim.step.side_effect = [1_000_000, 250]
        mock_sim.get_cycle_count.side_effect = [100, 1_000_350]

        fixture = MpactNpuSimTestFixture(sim=mock_sim)
        fixture.entry_point = 0x100
        cycles = await fixture.run_to_halt(timeout_cycles=2_000_000)
        self.assertEqual(cycles, 1_000_250)
        self.assertEqual(fixture.get_cycle_count(), 1_000_250)

        mock_sim_hang = MagicMock()
        mock_sim_hang.get_cycle_count.return_value = 0
        mock_sim_hang.step.side_effect = lambda n: n
        fixture_hang = MpactNpuSimTestFixture(sim=mock_sim_hang)
        with self.assertRaises(TimeoutError):
            await fixture_hang.run_to_halt(timeout_cycles=2_000)

        mock_sim_err = MagicMock()
        mock_sim_err.get_cycle_count.return_value = 0
        mock_sim_err.step.return_value = -1
        fixture_err = MpactNpuSimTestFixture(sim=mock_sim_err)
        with self.assertRaises(RuntimeError):
            await fixture_err.run_to_halt(timeout_cycles=2_000)


class TestUvmTestFixture(unittest.IsolatedAsyncioTestCase):
    """Tests for UvmTestFixture."""

    def setUp(self):
        self._temp_dir = tempfile.TemporaryDirectory()
        self._env_patcher = patch.dict(
            os.environ, {"TEST_UNDECLARED_OUTPUTS_DIR": self._temp_dir.name}
        )
        self._env_patcher.start()

    def tearDown(self):
        self._env_patcher.stop()
        self._temp_dir.cleanup()

    async def test_offline_memory_staging(self):
        fixture = UvmTestFixture()
        fixture.elf_path = "dummy.elf"
        fixture.symbols = {
            "my_var": 0x1000,
            "my_array": 0x2000,
            "tohost": 0x3000,
        }

        await fixture.write_word("my_var", 0xDEADBEEF)
        await fixture.write("my_var", 0xCAFEBABE, offset=4)

        arr = np.array([1, 2, 3, 4], dtype=np.int32)
        await fixture.write("my_array", arr)

        barr = bytearray(b"\x01\x02\x03\x04")
        await fixture.write("tohost", barr)

        self.assertIn(0x1000, fixture.staged_memory)
        self.assertIn(0x1004, fixture.staged_memory)
        self.assertIn(0x2000, fixture.staged_memory)
        self.assertIn(0x3000, fixture.staged_memory)
        self.assertEqual(fixture.staged_memory[0x1000], b"\xef\xbe\xad\xde")
        self.assertEqual(fixture.staged_memory[0x1004], b"\xbe\xba\xfe\xca")
        self.assertEqual(fixture.staged_memory[0x2000], arr.tobytes())
        self.assertEqual(fixture.staged_memory[0x3000], b"\x01\x02\x03\x04")

        # Partial write at offset 0 of my_array must update first word without truncating array
        await fixture.write_word("my_array", 99, offset=0)
        expected_arr = np.array([99, 2, 3, 4], dtype=np.int32)
        self.assertEqual(fixture.staged_memory[0x2000], expected_arr.tobytes())

        with self.assertRaises(TypeError):
            await fixture.write("my_var", 3.14)

    def test_uvm_timestamp_cycle_conversion(self):
        fixture = UvmTestFixture()
        log = "UVM_INFO @ 1250000 ps: reporter [TEST] done\n** UVM TEST PASSED **"
        fixture._parse_uvm_logs(log)
        self.assertTrue(fixture.test_passed)
        self.assertEqual(fixture.get_cycle_count(), 125)

    async def test_read_and_read_word_from_dump(self):
        fixture = UvmTestFixture()
        fixture.symbols = {"scalar_val": 0x1000, "tensor_val": 0x2000}
        dump_data = bytearray(8192)
        dump_data[0:4] = struct.pack("<I", 0x12345678)
        tensor = np.array([10, 20, 30, 40], dtype=np.int32)
        offset = 0x2000 - 0x1000
        dump_data[offset:offset + tensor.nbytes] = tensor.tobytes()

        fixture.dumped_memory = [(0x1000, bytes(dump_data))]

        val_word = await fixture.read_word("scalar_val")
        self.assertEqual(val_word, 0x12345678)
        self.assertEqual(val_word.view(np.uint32)[0], 0x12345678)

        val_word_offset = await fixture.read_word("tensor_val", offset=4)
        self.assertEqual(val_word_offset, 20)

        val_arr = await fixture.read("tensor_val", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(val_arr, tensor)

        val_arr_offset = await fixture.read(
            "tensor_val", offset=4, dtype=np.int32, shape=(3, )
        )
        np.testing.assert_array_equal(val_arr_offset, tensor[1:])

        val_bytes = await fixture.read("scalar_val", size=4)
        self.assertEqual(val_bytes, struct.pack("<I", 0x12345678))

        val_bytes_offset = await fixture.read("scalar_val", size=2, offset=2)
        self.assertEqual(val_bytes_offset, b"\x34\x12")

        val_bytes_alias = await fixture.read("scalar_val", size_bytes=4)
        self.assertEqual(val_bytes_alias, struct.pack("<I", 0x12345678))

        with self.assertRaises(KeyError):
            await fixture.read("tensor_val", size=8192)

    def test_log_parser_pass(self):
        fixture = UvmTestFixture()
        log = "UVM_INFO: ...\ncycle count: 12345\n** UVM TEST PASSED **"
        fixture._parse_uvm_logs(log)
        self.assertTrue(fixture.test_passed)
        self.assertEqual(fixture.get_cycle_count(), 12345)

    def test_log_parser_fail_uvm_test_failed(self):
        fixture = UvmTestFixture()
        log = "** UVM TEST FAILED **"
        with self.assertRaisesRegex(RuntimeError, "UVM execution failed"):
            fixture._parse_uvm_logs(log)

    def test_log_parser_fail_without_pass_confirmation(self):
        fixture = UvmTestFixture()
        log = "Simulation ended abruptly"
        with self.assertRaisesRegex(RuntimeError,
                                    "without a PASS confirmation"):
            fixture._parse_uvm_logs(log)

    def test_log_parser_fail_uvm_error(self):
        fixture = UvmTestFixture()
        log = "UVM_ERROR :    1\ntohost write detected: 0"
        with self.assertRaises(RuntimeError) as ctx:
            fixture._parse_uvm_logs(log)
        err_msg = str(ctx.exception)
        self.assertIn("Full simulation log dumped to:", err_msg)
        self.assertNotIn("Simulation Log Tail", err_msg)

        match = re.search(r"Full simulation log dumped to:\s*(\S+)", err_msg)
        self.assertIsNotNone(match)
        dump_path = match.group(1)
        self.assertTrue(os.path.exists(dump_path))
        try:
            with open(dump_path, "r", encoding="utf-8") as f:
                content = f.read()
            self.assertEqual(content, log)
        finally:
            if os.path.exists(dump_path):
                os.remove(dump_path)

    def test_dump_sim_log_direct(self):
        log = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
        msg = UvmTestFixture._dump_sim_log(log, reason="Custom Failure")
        self.assertIn("Custom Failure", msg)
        self.assertNotIn("Simulation Log Tail", msg)

        match = re.search(r"Full simulation log dumped to:\s*(\S+)", msg)
        self.assertIsNotNone(match)
        dump_path = match.group(1)
        self.assertTrue(os.path.exists(dump_path))
        try:
            with open(dump_path, "r", encoding="utf-8") as f:
                self.assertEqual(f.read(), log)
        finally:
            if os.path.exists(dump_path):
                os.remove(dump_path)

    def test_resolve_path(self):
        self.assertEqual(UvmTestFixture.resolve_path(__file__), __file__)
        self.assertEqual(UvmTestFixture.resolve_path(""), "")
        p = pathlib.Path(__file__)
        self.assertEqual(UvmTestFixture.resolve_path(p), str(p))

    def test_get_simulator_binary_resolves_path(self):
        fixture = UvmTestFixture()
        fixture.sim_binary_path = "custom/sim/binary"
        with patch.object(
                fixture, "resolve_path",
                return_value="/abs/path/custom/sim/binary") as mock_resolve:
            resolved = fixture._get_simulator_binary()
            mock_resolve.assert_called_once_with("custom/sim/binary")
            self.assertEqual(resolved, "/abs/path/custom/sim/binary")

    async def test_temp_file_cleanup_on_subprocess_failure(self):
        fixture = UvmTestFixture()
        fixture.elf_path = "dummy.elf"
        fixture.entry_point = 0x1000
        fixture.tohost_addr = 0x2000
        fixture.staged_memory[0x1000] = b"\x01\x02\x03\x04"

        created_patch = None
        orig_create_patch = fixture._create_patch_file

        def tracked_create_patch():
            nonlocal created_patch
            created_patch = orig_create_patch()
            return created_patch

        fixture._create_patch_file = tracked_create_patch

        with patch(
                "asyncio.create_subprocess_exec",
                side_effect=FileNotFoundError("Missing binary"),
        ):
            with self.assertRaises(FileNotFoundError):
                await fixture.run_to_halt()

        self.assertIsNotNone(created_patch)
        self.assertFalse(
            os.path.exists(created_patch),
            "Temporary memory patch file must be cleaned up on subprocess failure",
        )

    async def test_subprocess_crash_raises_runtime_error(self):
        fixture = UvmTestFixture()
        fixture.elf_path = "dummy.elf"
        fixture.entry_point = 0x1000
        fixture.tohost_addr = 0x2000

        mock_process = MagicMock()
        mock_process.communicate = AsyncMock(
            return_value=(
                b"Simulation line 1\nSimulation crashed: Segmentation fault\n",
                b"",
            )
        )
        mock_process.returncode = 139

        with patch("asyncio.create_subprocess_exec",
                   return_value=mock_process):
            with self.assertRaises(RuntimeError) as ctx:
                await fixture.run_to_halt()

        err_msg = str(ctx.exception)
        self.assertIn("crashed with exit code 139", err_msg)
        self.assertIn("Full simulation log dumped to:", err_msg)
        self.assertNotIn("Simulation Log Tail", err_msg)

    async def test_subprocess_killed_on_cancellation(self):
        fixture = UvmTestFixture()
        fixture.elf_path = "dummy.elf"
        fixture.entry_point = 0x1000
        fixture.tohost_addr = 0x2000

        mock_process = MagicMock()
        mock_process.returncode = None
        mock_process.kill = MagicMock()
        mock_process.wait = AsyncMock()
        mock_process.communicate = AsyncMock(
            side_effect=asyncio.CancelledError()
        )

        with patch("asyncio.create_subprocess_exec",
                   return_value=mock_process):
            with self.assertRaises(asyncio.CancelledError):
                await fixture.run_to_halt()

        mock_process.kill.assert_called_once()
        mock_process.wait.assert_awaited_once()

    def test_log_parser_returncode_priority(self):
        fixture = UvmTestFixture()
        log_with_error = "UVM_ERROR :    1\nsome info"
        with self.assertRaises(RuntimeError) as ctx:
            fixture._parse_uvm_logs(log_with_error, returncode=1)
        self.assertIn("UVM test failed: UVM_ERROR :    1", str(ctx.exception))

        log_crash = "Assertion failed in DUT at cycle 100"
        with self.assertRaises(RuntimeError) as ctx:
            fixture._parse_uvm_logs(log_crash, returncode=2)
        self.assertIn("crashed with exit code 2", str(ctx.exception))


class TestFpgaTestFixture(unittest.TestCase):
    """Tests for FpgaTestFixture."""

    @patch("coralnpu_test_utils.sim_backends.fpga_test_fixture.FtdiSpiMaster")
    def setUp(self, mock_ftdi_cls):
        self.mock_spi = mock_ftdi_cls.return_value
        self.fixture = FpgaTestFixture(
            usb_serial="Nexus-FTDI-12",
            csr_base_addr=0x30000,
            auto_recovery=False,
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
        self.mock_spi.read_word.side_effect = [0x12345678, 0x5A5A5A5A]
        self.assertTrue(
            self.fixture.check_memory_accessible(
                0x80000000, pattern=0x5A5A5A5A
            )
        )

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

        expected_write_to = FpgaTestFixture.calculate_write_timeout(
            len(input_arr.tobytes())
        )
        self.fixture.write("input_data", input_arr)
        self.mock_spi.load_data.assert_called_with(
            input_arr.tobytes(), 0x4000, timeout=expected_write_to
        )

        self.fixture.write("input_data", input_arr, timeout=45.0)
        self.mock_spi.load_data.assert_called_with(
            input_arr.tobytes(), 0x4000, timeout=45.0
        )

        expected_read_to = FpgaTestFixture.calculate_read_timeout(16)
        self.mock_spi.read_data.return_value = input_arr.tobytes()
        read_arr = self.fixture.read(
            "input_data", dtype=np.int32, shape=(2, 2)
        )
        self.mock_spi.read_data.assert_called_with(
            0x4000, 16, timeout=expected_read_to
        )
        np.testing.assert_array_equal(read_arr, input_arr.reshape((2, 2)))

        self.fixture.read(
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
        self.fixture.symbols["status_reg"] = 0x00100004
        self.mock_spi.read_word.return_value = 0x12345678
        res = self.fixture.read_word("status_reg")
        self.assertEqual(res, 0x12345678)
        self.assertEqual(res.view(np.uint32)[0], 0x12345678)
        self.mock_spi.read_word.assert_called_with(0x00100004)

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
        self.mock_spi.read_word.side_effect = (
            lambda addr: 0x434C4B54 if addr == 0x40001000 else 50
        )
        self.assertEqual(self.fixture.get_core_frequency_mhz(), 50)
        self.assertEqual(self.fixture.get_core_frequency_hz(), 50_000_000)

    def test_calculate_transfer_timeout(self):
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_write_timeout(0), 10.0
        )
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_write_timeout(2_000_000), 12.0
        )
        self.assertAlmostEqual(
            FpgaTestFixture.calculate_write_timeout(10_000_000), 20.0
        )

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
