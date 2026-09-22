# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import cocotb
import glob
import numpy as np
import os
import tqdm
import random

from coralnpu_test_utils.core_mini_axi_interface import AxiBurst, AxiResp, CoreMiniAxiInterface
from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture
from bazel_tools.tools.python.runfiles import runfiles


@cocotb.test()
async def core_mini_axi_run_wfi_in_all_slots_highmem(dut):
    """Tests the WFI instruction in each of the 4 issue slots with custom memory."""
    fixture = await VerilatorTestFixture.Create(dut, highmem=True)
    core_mini_axi = fixture.core_mini_axi
    r = runfiles.Create()

    for slot in range(0, 4):
        with open(r.Rlocation(
                f"coralnpu_hw/tests/cocotb/wfi_slot_{slot}_highmem.elf"),
                  "rb") as f:
            await core_mini_axi.reset()
            entry_point = await core_mini_axi.load_elf(f)
            await core_mini_axi.execute_from(entry_point)

            await core_mini_axi.wait_for_wfi()
            await core_mini_axi.raise_irq()
            await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_rvv_matmul_test(dut):
    """Testbench to test matmul with rvv intrinsics using custom memory.

    This test performs matmul in M1 4x64 M2 64x4 matrices.
    Compares results with native numpy matmul.
    """

    LHS_ROWS = 4
    RHS_COLS = 4
    INNER = 64

    fixture = await VerilatorTestFixture.Create(dut, highmem=True)
    r = runfiles.Create()
    elf_files = ['rvv_matmul_highmem.elf', 'rvv_matmul_assembly_highmem.elf']
    for elf_file in elf_files:

        await fixture.load_elf_and_lookup_symbols(
            r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file), [
                'lhs_input', 'rhs_input', 'result_output', 'lhs_rows',
                'rhs_cols', 'inner'
            ]
        )
        await fixture.write_word('lhs_rows', LHS_ROWS)
        await fixture.write_word('rhs_cols', RHS_COLS)
        await fixture.write_word('inner', INNER)
        np_type = np.int8
        min_value = np.iinfo(np_type).min
        max_value = np.iinfo(np_type).max + 1  # One above.
        lhs_data = np.random.randint(
            min_value, max_value, [LHS_ROWS, INNER], dtype=np_type
        )
        rhs_data = np.random.randint(
            min_value, max_value, [INNER, RHS_COLS], dtype=np_type
        )
        result_data = np.matmul(
            lhs_data.astype(np.int32), rhs_data.astype(np.int32)
        )

        await fixture.write('lhs_input', lhs_data.flatten())
        await fixture.write('rhs_input', rhs_data.transpose().flatten())
        await fixture.run_to_halt(timeout_cycles=1000000)
        output_matmul_result = (
            await fixture.read('result_output', LHS_ROWS * RHS_COLS * 4)
        ).view(dtype=np.int32).reshape([LHS_ROWS, RHS_COLS])

        assert ((result_data == output_matmul_result).all())


@cocotb.test()
async def core_mini_axi_basic_write_read_memory(dut):
    """Basic test to check if TCM memory can be written and read back."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    # Test reading/writing words
    await core_mini_axi.write_word(0x100, 0x42)
    await core_mini_axi.write_word(0x104, 0x43)
    rdata = (await core_mini_axi.read(0x100, 16)).view(np.uint32)
    assert (rdata[0:2] == np.array([0x42, 0x43])).all()

    # Three write/read data burst
    wdata = np.arange(48, dtype=np.uint8)
    await core_mini_axi.write(0x0, wdata)

    # Unaligned read, taking two bursts
    rdata = await core_mini_axi.read(0x8, 16)
    assert (np.arange(8, 24, dtype=np.uint8) == rdata).all()

    # Unaligned write, taking two bursts
    wdata = np.arange(20, dtype=np.uint8)
    await core_mini_axi.write(0x204, wdata)
    rdata = await core_mini_axi.read(0x200, 32)
    assert (wdata == rdata[4:24]).all()

    # NOTE: The following loop iterates over the top 1KB and bottom 1KB of ITCM and DTCM.
    # ITCM and DTCM starting addresses are configured in `Parameters.scala`.
    for size in range(11):
        txn_bytes = 2**size
        wdata = np.random.randint(0, 255, txn_bytes, dtype=np.uint8)

        # ITCM Bottom 1KB
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            await core_mini_axi.write(i * txn_bytes, wdata)
        # ITCM Top 1KB (1024KB = 0x100000)
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            await core_mini_axi.write(0x100000 - 1024 + (i * txn_bytes), wdata)

        # DTCM Bottom 1KB (Starts at 0x100000)
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            await core_mini_axi.write(0x100000 + (i * txn_bytes), wdata)
        # DTCM Top 1KB (1024KB = 0x100000; End = 0x100000 + 0x100000 = 0x200000)
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            await core_mini_axi.write(0x200000 - 1024 + (i * txn_bytes), wdata)

        # Readback Verification
        # ITCM Bottom 1KB
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            rdata = await core_mini_axi.read(i * txn_bytes, txn_bytes)
            assert (rdata == wdata).all()
        # ITCM Top 1KB
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            rdata = await core_mini_axi.read(
                0x100000 - 1024 + (i * txn_bytes), txn_bytes
            )
            assert (rdata == wdata).all()

        # DTCM Bottom 1KB
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            rdata = await core_mini_axi.read(
                0x100000 + (i * txn_bytes), txn_bytes
            )
            assert (rdata == wdata).all()
        # DTCM Top 1KB
        for i in tqdm.tqdm(range(1024 // txn_bytes)):
            rdata = await core_mini_axi.read(
                0x200000 - 1024 + (i * txn_bytes), txn_bytes
            )
            assert (rdata == wdata).all()


@cocotb.test()
async def core_mini_axi_wrap_burst_highmem_test(dut):
    """Test using highmem addresses"""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    wrap_boundary = 0x001FD200
    start_addr = 0x001FD210

    zeros = np.zeros(32, dtype=np.uint8)
    await core_mini_axi.write(wrap_boundary, zeros, burst=AxiBurst.INCR)

    beat0 = np.full(16, 0xAA, dtype=np.uint8)
    beat1 = np.full(16, 0x55, dtype=np.uint8)
    wdata = np.concatenate([beat0, beat1])

    await core_mini_axi.write(start_addr, wdata, burst=AxiBurst.WRAP)

    rdata_200 = await core_mini_axi.read(
        wrap_boundary, 16, burst=AxiBurst.INCR
    )
    rdata_210 = await core_mini_axi.read(start_addr, 16, burst=AxiBurst.INCR)

    assert (rdata_200 == beat1).all(), (
        f"Expected 0x55..55 at wrap boundary {hex(wrap_boundary)}, "
        f"got {rdata_200.tobytes().hex()}"
    )
    assert (rdata_210 == beat0).all(), (
        f"Expected 0xAA..AA at start addr {hex(start_addr)}, "
        f"got {rdata_210.tobytes().hex()}"
    )
