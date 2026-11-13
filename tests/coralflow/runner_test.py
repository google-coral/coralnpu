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
"""Unit tests for CoralFlow runner decorator and fixture dispatch."""

import asyncio
import logging
import os
import sys
import unittest
from unittest import mock
import numpy as np

from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.coralflow.runner import (
    _AsyncFixtureWrapper,
    _REGISTERED_TESTS,
    _create_fixture,
    coralflow_main,
    coralflow_test,
    get_target_environment,
    is_cocotb_simulation,
)


class MockFixture(BaseCoralNPUFixture):

    def __init__(self):
        super().__init__()
        self.loaded = False
        self.executed = False
        self.closed = False

    async def load_elf_and_lookup_symbols(
        self, elf_path, symbols, optional_symbols=None
    ):
        self.loaded = True
        self.symbols = {s: 0x1000 for s in symbols}
        return self.symbols

    async def write(self, symbol, data, offset=0):
        pass

    async def write_word(self, symbol, data, offset=0):
        pass

    async def write_ptr(self, addr_symbol, data_symbol, offset=0):
        pass

    async def read(self, symbol, size=None, dtype=None, shape=None, offset=0):
        return np.zeros(shape or (1, ), dtype=dtype or np.int32)

    async def read_word(self, symbol, offset=0):
        return 0

    async def run_to_halt(self, timeout_sec=60.0, timeout_cycles=None):
        self.executed = True
        return True

    def get_cycle_count(self):
        return 42

    def close(self):
        self.closed = True


class MockSyncFpgaFixture:
    """Mock FPGA fixture exhibiting synchronous methods."""

    def __init__(self, usb_serial="FTDI-123", highmem=False):
        self.usb_serial = usb_serial
        self.highmem = highmem
        self.closed = False
        self.symbols = {"in": 0x1000, "out": 0x2000}

    def load_elf_and_lookup_symbols(
        self, elf_path, symbols, optional_symbols=None
    ):
        return self.symbols

    def write(self, symbol, data, offset=0):
        pass

    def write_word(self, symbol, data, offset=0):
        pass

    def write_ptr(self, addr_symbol, data_symbol, offset=0):
        pass

    def read(self, symbol, size=None, dtype=None, shape=None, offset=0):
        return np.zeros(shape or (1, ), dtype=dtype or np.int32)

    def read_word(self, symbol, offset=0):
        return 0

    def run_to_halt(self, timeout_sec=60.0, timeout_cycles=None):
        return True

    def get_cycle_count(self):
        return 100

    def close(self):
        self.closed = True


class RunnerTest(unittest.IsolatedAsyncioTestCase):

    def setUp(self):
        super().setUp()
        from coralnpu_test_utils.coralflow.telemetry import (
            reset_telemetry_session,
        )

        reset_telemetry_session()
        self.addCleanup(reset_telemetry_session)
        self._orig_env = dict(os.environ)
        _REGISTERED_TESTS.clear()

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._orig_env)
        _REGISTERED_TESTS.clear()
        super().tearDown()

    def test_is_cocotb_simulation(self):
        os.environ.pop("COCOTB_SIM", None)
        if "cocotb" in sys.modules:
            del sys.modules["cocotb"]
        self.assertFalse(is_cocotb_simulation())

        os.environ["COCOTB_SIM"] = "1"
        self.assertTrue(is_cocotb_simulation())

    def test_get_target_environment_default(self):
        os.environ.pop("COCOTB_SIM", None)
        os.environ.pop("CORALFLOW_TARGET", None)
        self.assertEqual(get_target_environment(), "npusim")

    def test_get_target_environment_override(self):
        os.environ["CORALFLOW_TARGET"] = "uvm"
        self.assertEqual(get_target_environment(), "uvm")

        os.environ["CORALFLOW_TARGET"] = "NEXUS_FPGA"
        self.assertEqual(get_target_environment(), "nexus_fpga")

    async def test_async_fixture_wrapper(self):
        sync_inst = MockSyncFpgaFixture()
        wrapped = _AsyncFixtureWrapper(sync_inst)

        # Verify synchronous fixture methods can be awaited
        elf_res = await wrapped.load_elf_and_lookup_symbols(
            "dummy.elf", ["in", "out"]
        )
        self.assertIn("in", elf_res)

        await wrapped.write("in", np.ones((4, ), dtype=np.int32))
        halted = await wrapped.run_to_halt()
        self.assertTrue(halted)

        # Verify non-async methods / properties work directly
        self.assertEqual(wrapped.get_cycle_count(), 100)
        self.assertEqual(wrapped.usb_serial, "FTDI-123")
        wrapped.close()
        self.assertTrue(sync_inst.closed)

    async def test_create_fixture_npusim(self):
        mock_mod = mock.MagicMock()
        mock_fixture = mock.MagicMock()
        mock_mod.MpactNpuSimTestFixture.Create = mock.AsyncMock(
            return_value=mock_fixture
        )

        with mock.patch("importlib.import_module",
                        return_value=mock_mod) as mock_import:
            inst = await _create_fixture("npusim", highmem=True)
            mock_import.assert_called_once_with(
                "coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture"
            )
            mock_mod.MpactNpuSimTestFixture.Create.assert_awaited_once_with(
                highmem=True
            )
            self.assertEqual(inst, mock_fixture)

    async def test_create_fixture_verilator(self):
        mock_mod = mock.MagicMock()
        mock_fixture = mock.MagicMock()
        mock_mod.VerilatorTestFixture.Create = mock.AsyncMock(
            return_value=mock_fixture
        )

        with mock.patch("importlib.import_module",
                        return_value=mock_mod) as mock_import:
            inst = await _create_fixture("verilator", dut="mock_dut")
            mock_import.assert_called_once_with(
                "coralnpu_test_utils.sim_backends.verilator_test_fixture"
            )
            mock_mod.VerilatorTestFixture.Create.assert_awaited_once_with(
                dut="mock_dut"
            )
            self.assertEqual(inst, mock_fixture)

    async def test_create_fixture_uvm(self):
        mock_mod = mock.MagicMock()
        mock_fixture = mock.MagicMock()
        mock_mod.UvmTestFixture.Create = mock.AsyncMock(
            return_value=mock_fixture
        )

        with mock.patch("importlib.import_module",
                        return_value=mock_mod) as mock_import:
            inst = await _create_fixture("uvm", simulator="verilator")
            mock_import.assert_called_once_with(
                "coralnpu_test_utils.sim_backends.uvm_test_fixture"
            )
            mock_mod.UvmTestFixture.Create.assert_awaited_once_with(
                simulator="verilator"
            )
            self.assertEqual(inst, mock_fixture)

    async def test_create_fixture_fpga(self):
        mock_mod = mock.MagicMock()
        mock_sync_fpga = MockSyncFpgaFixture()
        mock_mod.FpgaTestFixture.create = mock.MagicMock(
            return_value=mock_sync_fpga
        )
        os.environ["CORALNPU_FPGA_SERIAL"] = "FTDI-999"

        with mock.patch("importlib.import_module",
                        return_value=mock_mod) as mock_import:
            inst = await _create_fixture("nexus_fpga", highmem=False)
            mock_import.assert_called_once_with(
                "coralnpu_test_utils.sim_backends.fpga_test_fixture"
            )
            mock_mod.FpgaTestFixture.create.assert_called_once_with(
                usb_serial="FTDI-999", highmem=False
            )
            self.assertIsInstance(inst, _AsyncFixtureWrapper)

    async def test_create_fixture_fpga_defaults_highmem(self):
        mock_mod = mock.MagicMock()
        mock_sync_fpga = MockSyncFpgaFixture()
        mock_mod.FpgaTestFixture.create = mock.MagicMock(
            return_value=mock_sync_fpga
        )
        os.environ["CORALNPU_FPGA_SERIAL"] = "FTDI-999"
        if "CORALFLOW_HIGHMEM" in os.environ:
            del os.environ["CORALFLOW_HIGHMEM"]

        with mock.patch("importlib.import_module",
                        return_value=mock_mod) as mock_import, \
             mock.patch.object(sys, "argv", ["test.py"]):
            inst = await _create_fixture("nexus_fpga")
            mock_import.assert_called_once_with(
                "coralnpu_test_utils.sim_backends.fpga_test_fixture"
            )
            mock_mod.FpgaTestFixture.create.assert_called_once_with(
                usb_serial="FTDI-999", highmem=True
            )
            self.assertIsInstance(inst, _AsyncFixtureWrapper)

    async def test_create_fixture_fpga_cli_flags(self):
        mock_mod = mock.MagicMock()
        mock_sync_fpga = MockSyncFpgaFixture()
        mock_mod.FpgaTestFixture.create = mock.MagicMock(
            return_value=mock_sync_fpga
        )
        os.environ["CORALFLOW_HIGHMEM"] = "0"

        with mock.patch("importlib.import_module", return_value=mock_mod), \
             mock.patch.object(sys, "argv", ["test_matmul.py", "--usb-serial", "Nexus-FTDI-16", "--highmem", "--verify"]):
            inst = await _create_fixture("nexus_fpga")
            mock_mod.FpgaTestFixture.create.assert_called_once_with(
                usb_serial="Nexus-FTDI-16", highmem=True, verify=True
            )
            self.assertIsInstance(inst, _AsyncFixtureWrapper)

    async def test_create_fixture_fpga_cli_lowmem(self):
        mock_mod = mock.MagicMock()
        mock_sync_fpga = MockSyncFpgaFixture()
        mock_mod.FpgaTestFixture.create = mock.MagicMock(
            return_value=mock_sync_fpga
        )
        os.environ["CORALFLOW_HIGHMEM"] = "1"

        with mock.patch("importlib.import_module", return_value=mock_mod), \
             mock.patch.object(sys, "argv", ["test_matmul.py", "--usb-serial", "Nexus-FTDI-16", "--lowmem"]):
            inst = await _create_fixture("nexus_fpga")
            mock_mod.FpgaTestFixture.create.assert_called_once_with(
                usb_serial="Nexus-FTDI-16", highmem=False
            )
            self.assertIsInstance(inst, _AsyncFixtureWrapper)

    async def test_create_fixture_unknown_raises(self):
        with self.assertRaises(ValueError) as ctx:
            await _create_fixture("unknown_backend")
        self.assertIn("Supported targets are", str(ctx.exception))

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_standalone_runner_success(self, mock_create):
        mock_inst = MockFixture()
        mock_create.return_value = mock_inst

        executed_steps = []

        @coralflow_test(highmem=True)
        async def sample_test(fixture: BaseCoralNPUFixture):
            await fixture.load_elf_and_lookup_symbols(
                "dummy.elf", ["in", "out"]
            )
            await fixture.run_to_halt()
            executed_steps.append("done")

        # Invoke the test
        sample_test()
        self.assertEqual(executed_steps, ["done"])
        self.assertTrue(mock_inst.loaded)
        self.assertTrue(mock_inst.executed)
        self.assertTrue(mock_inst.closed)
        mock_create.assert_awaited_once_with("npusim", highmem=True)

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_standalone_runner_exception(self, mock_create):
        mock_inst = MockFixture()
        mock_create.return_value = mock_inst

        @coralflow_test
        async def failing_test(fixture: BaseCoralNPUFixture):
            raise RuntimeError("Expected test failure")

        with self.assertRaises(RuntimeError):
            failing_test()
        self.assertTrue(mock_inst.closed)

    def test_cocotb_simulation_runner(self):
        mock_cocotb = mock.MagicMock()

        # Mock cocotb.test decorator
        def mock_test_decorator(**kwargs):

            def wrap(f):
                f._is_cocotb_test = True
                f._cocotb_skip = kwargs.get("skip", False)
                return f

            return wrap

        mock_cocotb.test = mock_test_decorator

        with mock.patch.dict("sys.modules", {"cocotb": mock_cocotb}), \
             mock.patch("coralnpu_test_utils.coralflow.runner.is_cocotb_simulation", return_value=True), \
             mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture", new_callable=mock.AsyncMock) as mock_create:
            mock_inst = MockFixture()
            mock_create.return_value = mock_inst

            executed_steps = []

            @coralflow_test
            async def my_cocotb_test(fixture: BaseCoralNPUFixture):
                await fixture.run_to_halt()
                executed_steps.append("cocotb_ok")

            self.assertTrue(getattr(my_cocotb_test, "_is_cocotb_test", False))
            self.assertFalse(getattr(my_cocotb_test, "_cocotb_skip", True))
            asyncio.run(my_cocotb_test("mock_dut"))
            self.assertEqual(executed_steps, ["cocotb_ok"])
            self.assertTrue(mock_inst.closed)
            mock_create.assert_awaited_once_with("verilator", dut="mock_dut")

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_coralflow_main_and_filtering(self, mock_create):
        mock_create.side_effect = lambda *args, **kwargs: MockFixture()
        ran = []

        @coralflow_test
        async def core_mini_rvv_memcpy_test(fixture: BaseCoralNPUFixture):
            await fixture.run_to_halt()
            ran.append("memcpy")

        @coralflow_test
        async def rvv_matmul_f32(fixture: BaseCoralNPUFixture):
            await fixture.run_to_halt()
            ran.append("f32")

        @coralflow_test
        async def rvv_matmul_f32_gemv(fixture: BaseCoralNPUFixture):
            await fixture.run_to_halt()
            ran.append("f32_gemv")

        # 1. Default run executes all registered tests
        coralflow_main(argv=[])
        self.assertEqual(ran, ["memcpy", "f32", "f32_gemv"])

        # 2. Exact match selects only exact test even if it is a prefix of another
        ran.clear()
        coralflow_main(argv=["--testcase", "rvv_matmul_f32"])
        self.assertEqual(ran, ["f32"])

        # 3. Substring fallback matches when exact name is not present (like COCOTB_TEST_FILTER)
        ran.clear()
        os.environ["CORALFLOW_TESTCASE"] = "rvv_memcpy_test"
        coralflow_main(argv=[])
        self.assertEqual(ran, ["memcpy"])
        del os.environ["CORALFLOW_TESTCASE"]

        # 4. Unknown testcase raises ValueError
        with self.assertRaises(ValueError):
            coralflow_main(argv=["--testcase", "non_existent_test"])

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_coralflow_main_sharding(self, mock_create):
        import tempfile

        mock_create.side_effect = lambda *args, **kwargs: MockFixture()
        ran = []

        for idx in range(4):

            def _make_test(i):

                @coralflow_test
                async def _test_fn(fixture: BaseCoralNPUFixture):
                    await fixture.run_to_halt()
                    ran.append(f"t{i}")

                _test_fn.__name__ = f"test_{i}"
                _REGISTERED_TESTS[f"test_{i}"] = _REGISTERED_TESTS.pop(
                    "_test_fn"
                )

            _make_test(idx)

        with tempfile.TemporaryDirectory() as tmpdir:
            status_path = os.path.join(tmpdir, "shard_status")
            os.environ["TEST_SHARD_STATUS_FILE"] = status_path
            os.environ["TEST_TOTAL_SHARDS"] = "2"

            os.environ["TEST_SHARD_INDEX"] = "0"
            coralflow_main(argv=[])
            self.assertTrue(os.path.exists(status_path))
            self.assertEqual(ran, ["t0", "t2"])

            ran.clear()
            os.environ["TEST_SHARD_INDEX"] = "1"
            coralflow_main(argv=[])
            self.assertEqual(ran, ["t1", "t3"])

            os.environ["TEST_SHARD_INDEX"] = "5"
            with self.assertRaises(ValueError):
                coralflow_main(argv=[])

            # Verify CORALFLOW_EXCLUDE_TESTCASE interaction with sharding
            ran.clear()
            os.environ["CORALFLOW_EXCLUDE_TESTCASE"] = "test_0"
            os.environ["TEST_SHARD_INDEX"] = "0"
            coralflow_main(argv=[])
            self.assertEqual(ran, ["t1", "t3"])

            ran.clear()
            os.environ["TEST_SHARD_INDEX"] = "1"
            coralflow_main(argv=[])
            self.assertEqual(ran, ["t2"])

    def test_cocotb_sharding_and_testcase_filtering(self):
        import coralnpu_test_utils.coralflow.runner as runner_mod

        mock_cocotb = mock.MagicMock()

        def mock_test_decorator(**kwargs):

            def wrap(f):
                f._cocotb_skip = kwargs.get("skip", False)
                return f

            return wrap

        mock_cocotb.test = mock_test_decorator

        with mock.patch.dict("sys.modules", {"cocotb": mock_cocotb}), \
             mock.patch("coralnpu_test_utils.coralflow.runner.is_cocotb_simulation", return_value=True):
            runner_mod._COCOTB_TEST_COUNTS.clear()
            os.environ["CORALFLOW_TESTCASE"] = "tc_b,tc_c,tc_d"
            os.environ["CORALFLOW_EXCLUDE_TESTCASE"] = "tc_c"
            os.environ["TEST_TOTAL_SHARDS"] = "2"
            os.environ["TEST_SHARD_INDEX"] = "1"

            @coralflow_test
            async def tc_a(fixture):
                pass

            @coralflow_test
            async def tc_b(fixture):
                pass

            @coralflow_test
            async def tc_c(fixture):
                pass

            @coralflow_test
            async def tc_d(fixture):
                pass

            # tc_a is not in CORALFLOW_TESTCASE -> skipped without incrementing shard counter
            self.assertTrue(tc_a._cocotb_skip)
            # tc_b is enabled index 0 -> skipped on shard 1
            self.assertTrue(tc_b._cocotb_skip)
            # tc_c is in CORALFLOW_EXCLUDE_TESTCASE -> skipped without incrementing shard counter
            self.assertTrue(tc_c._cocotb_skip)
            # tc_d is enabled index 1 -> runs on shard 1!
            self.assertFalse(tc_d._cocotb_skip)

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_coralflow_main_uvm_batch(self, mock_create):
        batch_calls = []

        class BatchMockFixture(MockFixture):

            async def run_batch(self, elf_paths, timeout_cycles=100000):
                batch_calls.append((list(elf_paths), timeout_cycles))
                return True

        mock_create.side_effect = lambda *args, **kwargs: BatchMockFixture()

        os.environ["CORALFLOW_TARGET"] = "uvm"
        os.environ["CORALFLOW_UVM_BATCH"] = "1"
        os.environ["CORALFLOW_DATA_ELFS"] = (
            "pkg/b_test.elf pkg/b_test_highmem.elf pkg/b_test.bin pkg/a_test.elf "
            "pkg/rvv_bf16_add.elf pkg/fault_test.elf "
            "pkg/rv32ui-p-add pkg/rv32ui-p-add.dump"
        )
        os.environ["CORALFLOW_EXCLUDE_TESTCASE"] = "fault_test,*bf16*"

        coralflow_main(argv=[])
        self.assertEqual(len(batch_calls), 1)
        self.assertEqual(
            batch_calls[0][0],
            ["pkg/a_test.elf", "pkg/b_test.elf", "pkg/rv32ui-p-add"],
        )

        # Filtering by --testcase stem
        batch_calls.clear()
        coralflow_main(argv=["--testcase", "b_test"])
        self.assertEqual(len(batch_calls), 1)
        self.assertEqual(batch_calls[0][0], ["pkg/b_test.elf"])

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_telemetry_nested_json_via_cli_and_env(self, mock_create):
        import json
        import tempfile
        from coralnpu_test_utils.coralflow.telemetry import (
            is_telemetry_enabled,
            record_test_telemetry,
        )

        class FpgaMockFixture(MockFixture):
            usb_serial = "NEXUS-0042"

        mock_create.side_effect = lambda *args, **kwargs: FpgaMockFixture()

        @coralflow_test
        async def test_alpha(fixture: BaseCoralNPUFixture):
            await fixture.run_to_halt()

        @coralflow_test
        async def test_beta(fixture: BaseCoralNPUFixture):
            await fixture.run_to_halt()

        with tempfile.TemporaryDirectory() as tmpdir:
            out_file = os.path.join(tmpdir, "custom_telemetry.json")
            base_env = {
                "GIT_COMMIT": "b6bf557f",
                "CORALFLOW_TELEMETRY": "0",
                "CORALFLOW_TELEMETRY_OUTPUT": "",
                "BUILD_ID": "",
                "TEST_UNDECLARED_OUTPUTS_DIR": "",
            }
            with mock.patch.dict(os.environ, base_env):
                self.assertFalse(is_telemetry_enabled(argv=[]))
                coralflow_main(
                    argv=["--telemetry", "--telemetry-output", out_file]
                )
                # coralflow_main must not leak env mutations
                self.assertEqual(os.environ["CORALFLOW_TELEMETRY"], "0")
                self.assertEqual(os.environ["CORALFLOW_TELEMETRY_OUTPUT"], "")

            self.assertTrue(os.path.exists(out_file))
            # No stray .lock files in output directory
            self.assertEqual(os.listdir(tmpdir), ["custom_telemetry.json"])

            with open(out_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            self.assertEqual(data["git_commit"], "b6bf557f")
            self.assertEqual(data["target"], "npusim")
            self.assertEqual(data["board_id"], "NEXUS-0042")
            self.assertNotIn("<locals>", data["suite"])
            self.assertNotIn("is_cycle_accurate", data)
            self.assertIn("timestamp", data)
            self.assertIn("tests", data)
            self.assertIn("test_alpha", data["tests"])
            self.assertIn("test_beta", data["tests"])
            self.assertEqual(data["tests"]["test_alpha"]["status"], "PASSED")
            self.assertEqual(data["tests"]["test_alpha"]["cycles"], 42)
            self.assertIsInstance(
                data["tests"]["test_alpha"]["wall_time_sec"], float
            )
            self.assertEqual(data["tests"]["test_beta"]["status"], "PASSED")
            self.assertEqual(data["tests"]["test_beta"]["cycles"], 42)

            # Verify a failing test in the same session updates the report
            record_test_telemetry(
                suite=data["suite"],
                test_name="test_gamma",
                target="npusim",
                status="FAILED",
                cycles=None,
                wall_time_sec=0.12,
                output_path=out_file,
                error="AssertionError: mismatch",
            )

            with open(out_file, "r", encoding="utf-8") as f:
                updated = json.load(f)

            self.assertIn("test_alpha", updated["tests"])
            self.assertIn("test_beta", updated["tests"])
            self.assertEqual(
                updated["tests"]["test_gamma"]["status"], "FAILED"
            )
            self.assertIsNone(updated["tests"]["test_gamma"]["cycles"])
            self.assertEqual(
                updated["tests"]["test_gamma"]["error"],
                "AssertionError: mismatch",
            )

    @mock.patch("coralnpu_test_utils.coralflow.runner.record_test_telemetry")
    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_telemetry_error_does_not_skip_fixture_close(
        self, mock_create, mock_record
    ):
        fixture_inst = MockFixture()
        mock_create.return_value = fixture_inst
        mock_record.side_effect = OSError("disk full")

        @coralflow_test
        async def test_failing_with_telemetry_io_error(
            fixture: BaseCoralNPUFixture,
        ):
            raise RuntimeError("expected test failure")

        with mock.patch.dict(os.environ, {"CORALFLOW_TELEMETRY": "1"}):
            with self.assertRaisesRegex(RuntimeError, "expected test failure"):
                coralflow_main(argv=[])

        self.assertTrue(fixture_inst.closed)

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_telemetry_malformed_cli_args_do_not_mask_test_error(
        self, mock_create
    ):
        for bad_argv in (
            ["--telemetry=1"],
            ["--telemetry-output"],
            ["--tel"],
        ):
            _REGISTERED_TESTS.clear()
            fixture_inst = MockFixture()
            mock_create.return_value = fixture_inst

            @coralflow_test
            async def test_real_failure(fixture: BaseCoralNPUFixture):
                raise RuntimeError("real test failure")

            with mock.patch.dict(
                    os.environ,
                {
                    "CORALFLOW_TELEMETRY": "0",
                    "CORALFLOW_TELEMETRY_OUTPUT": "",
                },
            ):
                with self.assertRaisesRegex(RuntimeError, "real test failure"):
                    coralflow_main(argv=bad_argv)
            self.assertTrue(fixture_inst.closed)

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_telemetry_cli_scope_overrides_sys_argv_without_env_leak(
        self, mock_create
    ):
        import tempfile

        mock_create.side_effect = lambda *args, **kwargs: MockFixture()

        @coralflow_test
        async def test_scoped(fixture: BaseCoralNPUFixture):
            await fixture.run_to_halt()

        with tempfile.TemporaryDirectory() as tmpdir:
            old_file = os.path.join(tmpdir, "old.json")
            new_file = os.path.join(tmpdir, "new.json")
            with mock.patch.object(
                    sys, "argv",
                ["prog.py", "--telemetry-output", old_file]), mock.patch.dict(
                    os.environ,
                    {
                        "CORALFLOW_TELEMETRY": "0",
                        "CORALFLOW_TELEMETRY_OUTPUT": "",
                        "TEST_UNDECLARED_OUTPUTS_DIR": "",
                    },
                ):
                coralflow_main(argv=["--telemetry-output", new_file])
                self.assertEqual(os.environ["CORALFLOW_TELEMETRY"], "0")
                self.assertEqual(os.environ["CORALFLOW_TELEMETRY_OUTPUT"], "")

            self.assertFalse(os.path.exists(old_file))
            self.assertTrue(os.path.exists(new_file))

    def test_telemetry_default_paths_sandbox_vs_workspace(self):
        import tempfile
        from coralnpu_test_utils.coralflow.telemetry import (
            _format_display_path,
            get_default_telemetry_path,
            record_test_telemetry,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            undeclared_dir = os.path.join(tmpdir, "undeclared_outputs")
            ws_dir = os.path.join(tmpdir, "workspace")
            work_dir = os.path.join(tmpdir, "working_dir")
            os.makedirs(undeclared_dir, exist_ok=True)
            os.makedirs(ws_dir, exist_ok=True)
            os.makedirs(work_dir, exist_ok=True)

            # In `bazel test` (TEST_UNDECLARED_OUTPUTS_DIR set, no BUILD_WORKSPACE_DIRECTORY):
            with mock.patch.dict(
                    os.environ,
                {
                    "TEST_UNDECLARED_OUTPUTS_DIR": undeclared_dir,
                    "BUILD_WORKSPACE_DIRECTORY": "",
                    "BUILD_WORKING_DIRECTORY": "",
                    "CORALFLOW_TELEMETRY": "1",
                    "CORALFLOW_TELEMETRY_OUTPUT": "",
                },
            ):
                self.assertEqual(
                    get_default_telemetry_path(
                        suite="test_rvv_add", target="npusim", argv=[]
                    ),
                    os.path.join(undeclared_dir, "test_telemetry.json"),
                )
                # Non-path CORALFLOW_TELEMETRY values like 'enabled' or 'y'
                # must NOT be treated as filenames.
                for truthy in ("enabled", "y"):
                    with mock.patch.dict(os.environ,
                                         {"CORALFLOW_TELEMETRY": truthy}):
                        self.assertEqual(
                            get_default_telemetry_path(
                                suite="test_rvv_add", target="npusim", argv=[]
                            ),
                            os.path.join(
                                undeclared_dir, "test_telemetry.json"
                            ),
                        )

                # Explicit path outside workspace/undeclared_dir mirrors to
                # undeclared_dir and returns undeclared_file (with no .lock files).
                ephemeral = os.path.join(tmpdir, "ephemeral.json")
                returned = record_test_telemetry(
                    suite="test_rvv_add",
                    test_name="test_one",
                    target="npusim",
                    status="PASSED",
                    cycles=10,
                    wall_time_sec=0.01,
                    output_path=ephemeral,
                )
                expected_undeclared = os.path.join(
                    undeclared_dir, "test_telemetry.json"
                )
                self.assertEqual(returned, expected_undeclared)
                self.assertTrue(os.path.exists(expected_undeclared))
                self.assertEqual(
                    os.listdir(undeclared_dir), ["test_telemetry.json"]
                )

            # In `bazel run` (BUILD_WORKSPACE_DIRECTORY & BUILD_WORKING_DIRECTORY set):
            with mock.patch.dict(
                    os.environ,
                {
                    "TEST_UNDECLARED_OUTPUTS_DIR": "",
                    "BUILD_WORKSPACE_DIRECTORY": ws_dir,
                    "BUILD_WORKING_DIRECTORY": work_dir,
                    "CORALFLOW_TELEMETRY": "1",
                    "CORALFLOW_TELEMETRY_OUTPUT": "",
                },
            ):
                self.assertEqual(
                    get_default_telemetry_path(
                        suite="test_rvv_add", target="npusim", argv=[]
                    ),
                    os.path.join(
                        ws_dir,
                        "telemetry_reports",
                        "test_rvv_add_npusim.json",
                    ),
                )
                # Relative CLI output resolves against BUILD_WORKING_DIRECTORY
                self.assertEqual(
                    get_default_telemetry_path(
                        suite="test_rvv_add",
                        target="npusim",
                        argv=["--telemetry-output", "report.json"],
                    ),
                    os.path.join(work_dir, "report.json"),
                )
                # Path-like CORALFLOW_TELEMETRY resolves against BUILD_WORKING_DIRECTORY
                with mock.patch.dict(os.environ,
                                     {"CORALFLOW_TELEMETRY": "sub/out.json"}):
                    self.assertEqual(
                        get_default_telemetry_path(
                            suite="test_rvv_add", target="npusim", argv=[]
                        ),
                        os.path.join(work_dir, "sub", "out.json"),
                    )
                # Filename sanitization prevents traversal and angle brackets
                sanitized = get_default_telemetry_path(
                    suite="../../etc/foo.<locals>",
                    target="../npusim",
                    argv=[],
                )
                self.assertTrue(
                    sanitized.startswith(
                        os.path.join(ws_dir, "telemetry_reports") + os.sep
                    )
                )
                self.assertNotIn("..", os.path.basename(sanitized))
                self.assertNotIn("<", os.path.basename(sanitized))
                self.assertNotIn(">", os.path.basename(sanitized))

            # Verify sandbox execroot path formatting to bazel-testlogs/
            sandbox_path = (
                "/tmp/sandbox/execroot/_main/bazel-out/k8-fastbuild/"
                "testlogs/tests/coralflow/test_rvv_add_npusim/test.outputs/test_telemetry.json"
            )
            self.assertEqual(
                _format_display_path(sandbox_path),
                "bazel-testlogs/tests/coralflow/test_rvv_add_npusim/test.outputs/test_telemetry.json",
            )

    def test_telemetry_suite_resolution_and_cache_isolation(self):
        import json
        import tempfile
        from coralnpu_test_utils.coralflow.runner import _split_suite_and_test
        from coralnpu_test_utils.coralflow.telemetry import (
            record_test_telemetry,
            reset_telemetry_session,
        )

        # CORALFLOW_SUITE takes highest priority
        with mock.patch.dict(
                os.environ,
            {
                "CORALFLOW_SUITE": "rvv_core_mini_axi_sim_cocotb",
                "TEST_TARGET": "//tests/cocotb:other_target_verilator",
            },
        ):
            self.assertEqual(
                _split_suite_and_test("core_mini_axi_sim.test_add"),
                ("rvv_core_mini_axi_sim_cocotb", "test_add"),
            )

        # TEST_TARGET strips backend suffix when CORALFLOW_SUITE is unset
        with mock.patch.dict(
                os.environ,
            {
                "CORALFLOW_SUITE": "",
                "TEST_TARGET":
                "//tests/cocotb:rvv_core_mini_axi_sim_cocotb_verilator",
            },
        ):
            self.assertEqual(
                _split_suite_and_test("core_mini_axi_sim.test_add"),
                ("rvv_core_mini_axi_sim_cocotb", "test_add"),
            )

        # Fallback strips <locals> when both env vars are unset
        with mock.patch.dict(os.environ,
                             {"CORALFLOW_SUITE": "", "TEST_TARGET": ""}):
            suite, test = _split_suite_and_test(
                "runner_test.RunnerTest.fn.<locals>.test_add"
            )
            self.assertNotIn("<locals>", suite)
            self.assertEqual(test, "test_add")

        with tempfile.TemporaryDirectory() as tmpdir:
            out_file = os.path.join(tmpdir, "shared.json")
            with mock.patch.dict(
                    os.environ,
                {
                    "GIT_COMMIT": "newcommit",
                    "TEST_UNDECLARED_OUTPUTS_DIR": "",
                },
            ):
                record_test_telemetry(
                    suite="suite_a",
                    test_name="fresh_test",
                    target="npusim",
                    status="PASSED",
                    cycles=10,
                    wall_time_sec=0.02,
                    output_path=out_file,
                )
                # Writing a different suite to the same path must not collide
                # with suite_a's _PROCESS_REPORTS cache entry.
                record_test_telemetry(
                    suite="suite_b",
                    test_name="other_test",
                    target="verilator",
                    status="PASSED",
                    cycles=20,
                    wall_time_sec=0.05,
                    output_path=out_file,
                )
                with open(out_file, "r", encoding="utf-8") as f:
                    other = json.load(f)
                self.assertEqual(other["suite"], "suite_b")
                self.assertEqual(other["target"], "verilator")
                self.assertEqual(list(other["tests"].keys()), ["other_test"])

            reset_telemetry_session()

    @mock.patch("coralnpu_test_utils.coralflow.runner._create_fixture")
    def test_telemetry_single_cycle_read_and_early_pass_classification(
        self, mock_create
    ):
        import json
        import tempfile

        class CountingFixture(MockFixture):

            def __init__(self):
                super().__init__()
                self.cycle_reads = 0

            def get_cycle_count(self):
                self.cycle_reads += 1
                return 123

        fixture_inst = CountingFixture()
        mock_create.return_value = fixture_inst

        @coralflow_test
        async def test_single_read(fixture: BaseCoralNPUFixture):
            await fixture.run_to_halt()

        with tempfile.TemporaryDirectory() as tmpdir:
            out_file = os.path.join(tmpdir, "cycles.json")
            with mock.patch.dict(
                    os.environ,
                {
                    "TEST_UNDECLARED_OUTPUTS_DIR": "",
                    "CORALFLOW_SUITE": "cycle_suite",
                },
            ):
                coralflow_main(argv=["--telemetry-output", out_file])
            # Hardware cycle counter must only be read once (not duplicated by banner)
            self.assertEqual(fixture_inst.cycle_reads, 1)

            # Verify cocotb.pass_test() TestSuccess BaseException records PASSED
            _REGISTERED_TESTS.clear()
            pass_fixture = CountingFixture()
            mock_create.return_value = pass_fixture

            TestSuccess = type(
                "TestSuccess",
                (BaseException, ),
                {"__module__": "cocotb._test_functions"},
            )

            @coralflow_test
            async def test_early_pass(fixture: BaseCoralNPUFixture):
                raise TestSuccess("done early")

            with mock.patch.dict(
                    os.environ,
                {
                    "TEST_UNDECLARED_OUTPUTS_DIR": "",
                    "CORALFLOW_SUITE": "cycle_suite",
                },
            ):
                with self.assertRaises(TestSuccess):
                    coralflow_main(argv=["--telemetry-output", out_file])

            with open(out_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            self.assertEqual(
                data["tests"]["test_early_pass"]["status"], "PASSED"
            )
            self.assertEqual(data["tests"]["test_early_pass"]["cycles"], 123)
            self.assertNotIn("error", data["tests"]["test_early_pass"])
            self.assertTrue(pass_fixture.closed)

    def test_telemetry_atomic_write_cleans_tmp_on_failure(self):
        import stat
        import tempfile
        from coralnpu_test_utils.coralflow.telemetry import _atomic_write_json

        with tempfile.TemporaryDirectory() as tmpdir:
            ok_file = os.path.join(tmpdir, "ok.json")
            _atomic_write_json(ok_file, {"suite": "s"})
            self.assertEqual(stat.S_IMODE(os.stat(ok_file).st_mode), 0o644)

            out_file = os.path.join(tmpdir, "fail.json")
            with mock.patch("os.replace",
                            side_effect=OSError("rename failed")):
                with self.assertRaises(OSError):
                    _atomic_write_json(out_file, {"suite": "s"})
            self.assertEqual(os.listdir(tmpdir), ["ok.json"])


if __name__ == "__main__":
    unittest.main()
