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

import asyncio
import os
import re
import struct
import tempfile
import unittest
import numpy as np
from unittest.mock import patch, MagicMock, AsyncMock

from coralnpu_test_utils.uvm_test_fixture import UvmTestFixture


class TestUvmTestFixtureUnit(unittest.IsolatedAsyncioTestCase):

    async def test_offline_memory_staging(self):
        fixture = UvmTestFixture()
        fixture.elf_path = "dummy.elf"
        fixture.symbols = {
            "my_var": 0x1000,
            "my_array": 0x2000,
            "tohost": 0x3000,
        }

        # Test scalar write
        await fixture.write_word("my_var", 0xDEADBEEF)

        # Test scalar write via write (int) and write with offset
        await fixture.write("my_var", 0xCAFEBABE, offset=4)

        # Test array write
        arr = np.array([1, 2, 3, 4], dtype=np.int32)
        await fixture.write("my_array", arr)

        # Test bytearray write
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

        # Test invalid write type
        with self.assertRaises(TypeError):
            await fixture.write("my_var", 3.14)

    async def test_read_and_read_word_from_dump(self):
        fixture = UvmTestFixture()
        fixture.symbols = {"scalar_val": 0x1000, "tensor_val": 0x2000}
        # Simulate dumped memory block from 0x1000 to 0x3000 (8192 bytes)
        dump_data = bytearray(8192)
        # scalar_val at 0x1000 = 0x12345678
        dump_data[0:4] = struct.pack("<I", 0x12345678)
        # tensor_val at 0x2000 = [10, 20, 30, 40] int32
        tensor = np.array([10, 20, 30, 40], dtype=np.int32)
        offset = 0x2000 - 0x1000
        dump_data[offset:offset + tensor.nbytes] = tensor.tobytes()

        fixture.dumped_memory = [(0x1000, bytes(dump_data))]

        # Test scalar read_word
        val_word = await fixture.read_word("scalar_val")
        self.assertEqual(val_word, 0x12345678)

        # Test scalar read_word with offset
        val_word_offset = await fixture.read_word("tensor_val", offset=4)
        self.assertEqual(val_word_offset, 20)

        # Test array read
        val_arr = await fixture.read("tensor_val", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(val_arr, tensor)

        # Test array read with offset
        val_arr_offset = await fixture.read(
            "tensor_val", offset=4, dtype=np.int32, shape=(3, )
        )
        np.testing.assert_array_equal(val_arr_offset, tensor[1:])

        # Test raw bytes read
        val_bytes = await fixture.read("scalar_val", size=4)
        self.assertEqual(val_bytes, struct.pack("<I", 0x12345678))

        # Test raw bytes read with offset
        val_bytes_offset = await fixture.read("scalar_val", size=2, offset=2)
        self.assertEqual(val_bytes_offset, b"\x34\x12")

        # Test size_bytes alias
        val_bytes_alias = await fixture.read("scalar_val", size_bytes=4)
        self.assertEqual(val_bytes_alias, struct.pack("<I", 0x12345678))

        # Test out-of-bounds read raises KeyError
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
        # 1. Existing absolute file returns directly
        self.assertEqual(UvmTestFixture.resolve_path(__file__), __file__)
        # 2. Empty string returns empty
        self.assertEqual(UvmTestFixture.resolve_path(""), "")
        # 3. PathLike object is resolved
        import pathlib
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

        with patch("asyncio.create_subprocess_exec",
                   side_effect=FileNotFoundError("Missing binary")):
            with self.assertRaises(FileNotFoundError):
                await fixture.run_to_halt()

        self.assertIsNotNone(created_patch)
        self.assertFalse(
            os.path.exists(created_patch),
            "Temporary memory patch file must be cleaned up on subprocess failure"
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
        # If UVM_ERROR exists, it should take precedence even if returncode != 0
        log_with_error = "UVM_ERROR :    1\nsome info"
        with self.assertRaises(RuntimeError) as ctx:
            fixture._parse_uvm_logs(log_with_error, returncode=1)
        self.assertIn("UVM test failed: UVM_ERROR :    1", str(ctx.exception))

        # If no explicit UVM error is found and returncode != 0, crash is raised
        log_crash = "Assertion failed in DUT at cycle 100"
        with self.assertRaises(RuntimeError) as ctx:
            fixture._parse_uvm_logs(log_crash, returncode=2)
        self.assertIn("crashed with exit code 2", str(ctx.exception))


if __name__ == '__main__':
    unittest.main()
