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
"""Test suite for RVV ML operations using Cocotb.

This file contains testbenches to verify matrix multiplication operations
accelerated by RISC-V Vector (RVV) instructions on the Coral NPU.
It tests both integer (int8) and floating-point (float32) variants,
using both C intrinsics and raw assembly implementations.

The tests generate random input data, compute the expected result using NumPy,
load the corresponding ELF file onto the simulated core, and verify that the
hardware execution matches the software reference.
"""

import sys

sys.set_int_max_str_digits(100000)

import cocotb
import ml_dtypes
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_test_fixture import Fixture
from sw.utils.metrics import log_matmul_metrics


@cocotb.test()
async def core_mini_rvv_matmul_c_test(dut):
    """Test integer matmul with RVV C intrinsics."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_matmul.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file), [
            'lhs_input', 'rhs_input', 'result_output', 'lhs_rows', 'rhs_cols',
            'inner', 'csr_cycle_count'
        ]
    )

    shapes = [(16, 16, 48)]

    for LHS_ROWS, RHS_COLS, INNER in shapes:
        dut._log.info(
            f"Running shape: {LHS_ROWS}x{INNER} x {INNER}x{RHS_COLS}"
        )
        await fixture.core_mini_axi.reset()
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
        csr_cycle_count = (await fixture.read_word('csr_cycle_count')).view(
            np.uint32
        )[0]
        log_matmul_metrics(
            dut, f"core_mini_rvv_matmul_c_test_{LHS_ROWS}x{RHS_COLS}x{INNER}",
            csr_cycle_count, LHS_ROWS, RHS_COLS, INNER
        )
        output_matmul_result = (
            await fixture.read('result_output', LHS_ROWS * RHS_COLS * 4)
        ).view(dtype=np.int32).reshape([LHS_ROWS, RHS_COLS])

        assert ((result_data == output_matmul_result).all())


@cocotb.test()
async def core_mini_rvv_matmul_asm_test(dut):
    """Test integer matmul with RVV assembly."""

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_matmul_assembly.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file), [
            'lhs_input', 'rhs_input', 'result_output', 'lhs_rows', 'rhs_cols',
            'inner', 'csr_cycle_count'
        ]
    )

    shapes = [(16, 16, 48)]

    for LHS_ROWS, RHS_COLS, INNER in shapes:
        dut._log.info(
            f"Running shape: {LHS_ROWS}x{INNER} x {INNER}x{RHS_COLS}"
        )
        await fixture.core_mini_axi.reset()
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
        csr_cycle_count = (await fixture.read_word('csr_cycle_count')).view(
            np.uint32
        )[0]
        log_matmul_metrics(
            dut,
            f"core_mini_rvv_matmul_asm_test_{LHS_ROWS}x{RHS_COLS}x{INNER}",
            csr_cycle_count, LHS_ROWS, RHS_COLS, INNER
        )
        output_matmul_result = (
            await fixture.read('result_output', LHS_ROWS * RHS_COLS * 4)
        ).view(dtype=np.int32).reshape([LHS_ROWS, RHS_COLS])

        assert ((result_data == output_matmul_result).all())


@cocotb.test()
async def core_mini_rvv_float_matmul_c_test(dut):
    """Test FP32 matmul with RVV C intrinsics."""

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_float_matmul.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file), [
            'lhs_input', 'rhs_input', 'result_output', 'lhs_rows', 'rhs_cols',
            'inner', 'csr_cycle_count'
        ]
    )

    shapes = [(16, 16, 48)]

    for LHS_ROWS, RHS_COLS, INNER in shapes:
        dut._log.info(
            f"Running shape: {LHS_ROWS}x{INNER} x {INNER}x{RHS_COLS}"
        )
        await fixture.core_mini_axi.reset()
        await fixture.write_word('lhs_rows', LHS_ROWS)
        await fixture.write_word('rhs_cols', RHS_COLS)
        await fixture.write_word('inner', INNER)

        np_type = np.float32
        rng = np.random.default_rng()

        lhs_data = rng.uniform(-5.0, 5.0, [LHS_ROWS, INNER]).astype(np_type)
        rhs_data = rng.uniform(-5.0, 5.0, [INNER, RHS_COLS]).astype(np_type)
        result_data = np.matmul(lhs_data, rhs_data)

        await fixture.write('lhs_input', lhs_data.flatten())
        await fixture.write('rhs_input', rhs_data.transpose().flatten())
        await fixture.run_to_halt(timeout_cycles=1000000)
        csr_cycle_count = (await fixture.read_word('csr_cycle_count')).view(
            np.uint32
        )[0]
        log_matmul_metrics(
            dut,
            f"core_mini_rvv_float_matmul_c_test_{LHS_ROWS}x{RHS_COLS}x{INNER}",
            csr_cycle_count,
            LHS_ROWS,
            RHS_COLS,
            INNER,
        )
        output_matmul_result = (
            await fixture.read('result_output', LHS_ROWS * RHS_COLS * 4)
        ).view(dtype=np_type).reshape([LHS_ROWS, RHS_COLS])

        np.testing.assert_allclose(
            result_data, output_matmul_result, rtol=1e-4, atol=1e-4
        )


@cocotb.test()
async def core_mini_rvv_bf16_matmul_c_test(dut):
    """Test BFloat16 matmul with RVV C intrinsics (Zvfbfwma)."""

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_bf16_matmul.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file), [
            'lhs_input', 'rhs_input', 'result_output', 'lhs_rows', 'rhs_cols',
            'inner', 'csr_cycle_count'
        ]
    )

    shapes = [(16, 16, 48), (8, 32, 64)]

    for LHS_ROWS, RHS_COLS, INNER in shapes:
        dut._log.info(
            f"Running BFloat16 MatMul shape: {LHS_ROWS}x{INNER} x {INNER}x{RHS_COLS}"
        )
        await fixture.core_mini_axi.reset()
        await fixture.write_word('lhs_rows', LHS_ROWS)
        await fixture.write_word('rhs_cols', RHS_COLS)
        await fixture.write_word('inner', INNER)

        rng = np.random.default_rng(seed=42)

        lhs_fp32 = rng.uniform(-4.0, 4.0, [LHS_ROWS, INNER]).astype(np.float32)
        rhs_fp32 = rng.uniform(-4.0, 4.0, [INNER, RHS_COLS]).astype(np.float32)

        lhs_bf16 = lhs_fp32.astype(ml_dtypes.bfloat16)
        rhs_bf16 = rhs_fp32.astype(ml_dtypes.bfloat16)

        lhs_bf16_u16 = lhs_bf16.view(np.uint16)
        rhs_bf16_u16 = rhs_bf16.view(np.uint16)

        # Golden reference FP32 result using exact bfloat16 inputs
        result_golden = np.matmul(
            lhs_bf16.astype(np.float32), rhs_bf16.astype(np.float32)
        )

        await fixture.write('lhs_input', lhs_bf16_u16.flatten())
        await fixture.write('rhs_input', rhs_bf16_u16.transpose().flatten())
        await fixture.run_to_halt(timeout_cycles=1000000)

        csr_cycle_count = (await fixture.read_word('csr_cycle_count')).view(
            np.uint32
        )[0]
        log_matmul_metrics(
            dut,
            f"core_mini_rvv_bf16_matmul_c_test_{LHS_ROWS}x{RHS_COLS}x{INNER}",
            csr_cycle_count,
            LHS_ROWS,
            RHS_COLS,
            INNER,
        )

        output_matmul_result = (
            await fixture.read('result_output', LHS_ROWS * RHS_COLS * 4)
        ).view(dtype=np.float32).reshape([LHS_ROWS, RHS_COLS])

        np.testing.assert_allclose(
            output_matmul_result, result_golden, rtol=1e-3, atol=1e-3
        )


@cocotb.test()
async def core_mini_rvv_float_matmul_asm_test(dut):
    """Test FP32 matmul with RVV assembly."""

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_float_matmul_assembly.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file), [
            'lhs_input', 'rhs_input', 'result_output', 'lhs_rows', 'rhs_cols',
            'inner', 'csr_cycle_count'
        ]
    )

    shapes = [(16, 16, 48)]

    for LHS_ROWS, RHS_COLS, INNER in shapes:
        dut._log.info(
            f"Running shape: {LHS_ROWS}x{INNER} x {INNER}x{RHS_COLS}"
        )
        await fixture.core_mini_axi.reset()
        await fixture.write_word('lhs_rows', LHS_ROWS)
        await fixture.write_word('rhs_cols', RHS_COLS)
        await fixture.write_word('inner', INNER)

        np_type = np.float32
        rng = np.random.default_rng()

        lhs_data = rng.uniform(-5.0, 5.0, [LHS_ROWS, INNER]).astype(np_type)
        rhs_data = rng.uniform(-5.0, 5.0, [INNER, RHS_COLS]).astype(np_type)
        result_data = np.matmul(lhs_data, rhs_data)

        await fixture.write('lhs_input', lhs_data.flatten())
        await fixture.write('rhs_input', rhs_data.transpose().flatten())
        await fixture.run_to_halt(timeout_cycles=1000000)
        csr_cycle_count = (await fixture.read_word('csr_cycle_count')).view(
            np.uint32
        )[0]
        log_matmul_metrics(
            dut,
            f"core_mini_rvv_float_matmul_asm_test_{LHS_ROWS}x{RHS_COLS}x{INNER}",
            csr_cycle_count,
            LHS_ROWS,
            RHS_COLS,
            INNER,
        )
        output_matmul_result = (
            await fixture.read('result_output', LHS_ROWS * RHS_COLS * 4)
        ).view(dtype=np_type).reshape([LHS_ROWS, RHS_COLS])

        np.testing.assert_allclose(
            result_data, output_matmul_result, rtol=1e-4, atol=1e-4
        )


@cocotb.test()
async def core_mini_rvv_float_matmul_optimized_c_test(dut):
    """Test FP32 matmul with optimized RVV C intrinsics."""

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_float_matmul_optimized.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file), [
            'lhs_input', 'rhs_input', 'result_output', 'lhs_rows', 'rhs_cols',
            'inner', 'csr_cycle_count'
        ]
    )

    shapes = [(16, 16, 48)]

    for LHS_ROWS, RHS_COLS, INNER in shapes:
        dut._log.info(
            f"Running shape: {LHS_ROWS}x{INNER} x {INNER}x{RHS_COLS}"
        )
        await fixture.core_mini_axi.reset()
        await fixture.write_word('lhs_rows', LHS_ROWS)
        await fixture.write_word('rhs_cols', RHS_COLS)
        await fixture.write_word('inner', INNER)

        np_type = np.float32
        rng = np.random.default_rng()

        lhs_data = rng.uniform(-5.0, 5.0, [LHS_ROWS, INNER]).astype(np_type)
        rhs_data = rng.uniform(-5.0, 5.0, [INNER, RHS_COLS]).astype(np_type)
        result_data = np.matmul(lhs_data, rhs_data)

        await fixture.write('lhs_input', lhs_data.flatten())
        await fixture.write('rhs_input', rhs_data.transpose().flatten())
        await fixture.run_to_halt(timeout_cycles=1000000)
        csr_cycle_count = (await fixture.read_word('csr_cycle_count')).view(
            np.uint32
        )[0]
        log_matmul_metrics(
            dut,
            f"core_mini_rvv_float_matmul_optimized_c_test_{LHS_ROWS}x{RHS_COLS}x{INNER}",
            csr_cycle_count,
            LHS_ROWS,
            RHS_COLS,
            INNER,
        )
        output_matmul_result = (
            await fixture.read('result_output', LHS_ROWS * RHS_COLS * 4)
        ).view(dtype=np_type).reshape([LHS_ROWS, RHS_COLS])

        np.testing.assert_allclose(
            result_data, output_matmul_result, rtol=1e-4, atol=1e-4
        )
