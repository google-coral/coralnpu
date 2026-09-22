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
"""Unified integration test running the same ELF workloads across all 4 backend fixtures.

Workloads executed on every backend fixture:
  1. tests/cocotb/rvv/arithmetics/rvv_add_int32_m1.elf (RVV vector addition)
  2. tests/cocotb/rvv/ml_ops/rvv_matmul.elf (16x16 int8 -> int32 matrix multiply)

Backends tested in this single target (//coralnpu_test_utils/sim_backends:sim_backends_integration_test):
  - VerilatorTestFixture (Verilator Cocotb RTL RvvCoreMiniAxi)
  - MpactNpuSimTestFixture (MPACT C++ ISS)
  - UvmTestFixture (Verilator UVM RTL + Spike/MPACT 3-way co-simulation)
  - FpgaTestFixture (Physical FPGA if CORALNPU_FPGA_SERIAL is set, or SPI-to-MPACT loopback)
"""

import asyncio
import inspect
import os
import struct
import unittest
from unittest.mock import patch
import cocotb
import numpy as np

from coralnpu_v2_sim_utils import CoralNPUV2Simulator
from coralnpu_test_utils.sim_backends.fpga_test_fixture import FpgaTestFixture
from coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture import (
    MpactNpuSimTestFixture,
)
from coralnpu_test_utils.sim_backends.uvm_test_fixture import UvmTestFixture
from coralnpu_test_utils.sim_backends.verilator_test_fixture import (
    VerilatorTestFixture,
)


async def _call(fn, *args, **kwargs):
    """Calls a fixture method that may be either async/Cocotb coroutine or synchronous."""
    res = fn(*args, **kwargs)
    if inspect.isawaitable(res):
        return await res
    return res


async def run_unified_elf_workloads(fixture):
    """Runs the same rvv_add_int32_m1.elf and rvv_matmul.elf workloads on any fixture."""
    # -------------------------------------------------------------------------
    # Workload 1: RVV Int32 Vector Addition (rvv_add_int32_m1.elf)
    # -------------------------------------------------------------------------
    await _call(
        fixture.load_elf_and_lookup_symbols,
        "tests/cocotb/rvv/arithmetics/rvv_add_int32_m1.elf",
        symbols=["in_buf_1", "in_buf_2", "out_buf"],
    )

    in_buf_1 = np.array([100, -250, 4096, -1024], dtype=np.int32)
    in_buf_2 = np.array([23, 500, -1096, 2048], dtype=np.int32)
    expected_sum = in_buf_1 + in_buf_2

    await _call(fixture.write, "in_buf_1", in_buf_1)
    await _call(fixture.write, "in_buf_2", in_buf_2)

    halt_res = await _call(fixture.run_to_halt)
    assert halt_res, f"rvv_add_int32_m1 failed to halt on {type(fixture).__name__}"

    actual_sum = await _call(
        fixture.read, "out_buf", dtype=np.int32, shape=(4, )
    )
    np.testing.assert_array_equal(actual_sum, expected_sum)

    first_word = await _call(fixture.read_word, "out_buf")
    assert first_word.view(np.int32)[0] == expected_sum[0]

    # -------------------------------------------------------------------------
    # Workload 2: RVV 16x16 Int8 -> Int32 Matrix Multiply (rvv_matmul.elf)
    # -------------------------------------------------------------------------
    await _call(
        fixture.load_elf_and_lookup_symbols,
        "tests/cocotb/rvv/ml_ops/rvv_matmul.elf",
        symbols=[
            "lhs_input",
            "rhs_input",
            "result_output",
            "lhs_rows",
            "rhs_cols",
            "inner",
        ],
    )

    lhs_rows, inner, rhs_cols = 16, 16, 16
    await _call(fixture.write_word, "lhs_rows", lhs_rows)
    await _call(fixture.write_word, "rhs_cols", rhs_cols)
    await _call(fixture.write_word, "inner", inner)

    rng = np.random.default_rng(seed=42)
    lhs_input = rng.integers(-64, 64, size=(lhs_rows, inner), dtype=np.int8)
    rhs_input = rng.integers(-64, 64, size=(inner, rhs_cols), dtype=np.int8)
    golden_matmul = np.matmul(
        lhs_input.astype(np.int32), rhs_input.astype(np.int32)
    )

    await _call(fixture.write, "lhs_input", lhs_input)
    await _call(fixture.write, "rhs_input", rhs_input.flatten(order="F"))

    halt_res = await _call(fixture.run_to_halt)
    assert halt_res, f"rvv_matmul failed to halt on {type(fixture).__name__}"

    assert await _call(fixture.read_word, "lhs_rows") == lhs_rows
    assert await _call(fixture.read_word, "rhs_cols") == rhs_cols
    assert await _call(fixture.read_word, "inner") == inner

    actual_matmul = await _call(
        fixture.read,
        "result_output",
        dtype=np.int32,
        shape=(lhs_rows, rhs_cols),
    )
    np.testing.assert_array_equal(actual_matmul, golden_matmul)


class _SimulatorBackedSpiMaster:
    """SPI master adapter backed by CoralNPUV2Simulator for offline FpgaTestFixture testing."""

    def __init__(self, *args, **kwargs):
        self.sim = CoralNPUV2Simulator(highmem_ld=True)
        self.entry_point = 0

    def connect(self):
        pass

    def close(self):
        pass

    def soft_reset(self):
        pass

    def load_elf(
        self, elf_path: str, start_core: bool = False, verify: bool = False
    ):
        self.sim = CoralNPUV2Simulator(highmem_ld=True)
        self.entry_point, _ = self.sim.get_elf_entry_and_symbol(elf_path, [])
        self.sim.load_program(elf_path, self.entry_point)

    def load_data(self, data: bytes, address: int, timeout: float = 10.0):
        arr = np.frombuffer(data, dtype=np.uint8).copy()
        self.sim.write_memory(address, arr)

    def read_data(
        self, address: int, size: int, timeout: float = 10.0
    ) -> bytes:
        return self.sim.read_memory(address, size).tobytes()

    def write_word(self, address: int, value: int):
        self.sim.write_word(address, np.uint32(int(value) & 0xFFFFFFFF))

    def read_word(self, address: int) -> int:
        raw = self.sim.read_memory(address, 4)
        return struct.unpack("<I", raw.tobytes())[0]

    def set_entry_point(self, entry_point: int):
        self.entry_point = entry_point

    def start_core(self):
        self.sim.run()

    def poll_for_halt(self, timeout: float = 10.0) -> bool:
        self.sim.wait()
        return True


async def _run_mpact_integration():
    fixture = await MpactNpuSimTestFixture.Create(highmem=True)
    await run_unified_elf_workloads(fixture)
    assert fixture.get_cycle_count() > 0


async def _run_uvm_integration():
    fixture = await UvmTestFixture.Create(
        simulator="verilator", enable_spike_cosim=True
    )
    await run_unified_elf_workloads(fixture)
    assert fixture.get_cycle_count() > 0


async def _run_fpga_integration():
    usb_serial = os.environ.get("CORALNPU_FPGA_SERIAL")
    if usb_serial:
        with FpgaTestFixture(usb_serial=usb_serial) as fixture:
            await run_unified_elf_workloads(fixture)
    else:
        with patch(
                "coralnpu_test_utils.sim_backends.fpga_test_fixture.FtdiSpiMaster",
                new=_SimulatorBackedSpiMaster,
        ):
            with FpgaTestFixture(usb_serial="SIM-LOOPBACK",
                                 auto_recovery=False) as fixture:
                await run_unified_elf_workloads(fixture)


async def _run_async_or_cocotb(coro):
    """Executes an asyncio subprocess coroutine under either Cocotb 1.x or an active asyncio loop."""
    try:
        asyncio.get_running_loop()
        has_running_loop = True
    except RuntimeError:
        has_running_loop = False
    if has_running_loop:
        return await coro
    return asyncio.run(coro)


@cocotb.test()
async def test_verilator_fixture_integration(dut):
    """1. VerilatorTestFixture (Cocotb RTL RvvCoreMiniAxi)."""
    fixture = await VerilatorTestFixture.Create(dut)
    await run_unified_elf_workloads(fixture)
    assert fixture.get_cycle_count() > 0


@cocotb.test()
async def test_mpact_npusim_fixture_integration(_dut):
    """2. MpactNpuSimTestFixture (MPACT C++ ISS)."""
    await _run_mpact_integration()


@cocotb.test()
async def test_uvm_fixture_integration(_dut):
    """3. UvmTestFixture (Verilator UVM RTL + Spike/MPACT 3-way co-sim)."""
    await _run_async_or_cocotb(_run_uvm_integration())


@cocotb.test()
async def test_fpga_fixture_integration(_dut):
    """4. FpgaTestFixture (Nexus FPGA or SPI-to-MPACT loopback)."""
    await _run_fpga_integration()


class UnifiedSimBackendsIntegrationTest(unittest.IsolatedAsyncioTestCase):
    """Allows running directly via python3 / unittest outside Cocotb if desired."""

    async def test_mpact_npusim_fixture_integration(self):
        await _run_mpact_integration()

    async def test_uvm_fixture_integration(self):
        await _run_uvm_integration()

    async def test_fpga_fixture_integration(self):
        await _run_fpga_integration()


if __name__ == "__main__":
    unittest.main()
