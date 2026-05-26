"""Test suite for RVV ML operations using Cocotb.

This file contains testbenches to verify matrix multiplication operations
accelerated by RISC-V Vector (RVV) instructions on the Coral NPU.
It tests both integer (int8) and floating-point (float32) variants,
using both C intrinsics and raw assembly implementations.

The tests generate random input data, compute the expected result using NumPy,
load the corresponding ELF file onto the simulated core, and verify that the
hardware execution matches the software reference.
"""
import cocotb
import numpy as np
import argparse

from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles


@cocotb.test()
async def core_mini_rvv_matmul_c_test(dut):
    """Test integer matmul with RVV C intrinsics.

    Dimensions:
    - Left Hand Side (LHS) matrix: 16 rows x 48 columns
    - Right Hand Side (RHS) matrix: 48 rows x 16 columns
    - Result matrix: 16 rows x 16 columns
    """

    LHS_ROWS = 16
    RHS_COLS = 16
    INNER = 48

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_matmul.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file),
        ['lhs_input', 'rhs_input', 'result_output'])
    np_type = np.int8
    min_value = np.iinfo(np_type).min
    max_value = np.iinfo(np_type).max + 1  # One above.
    lhs_data = np.random.randint(min_value,
                                 max_value, [LHS_ROWS, INNER],
                                 dtype=np_type)
    rhs_data = np.random.randint(min_value,
                                 max_value, [INNER, RHS_COLS],
                                 dtype=np_type)
    result_data = np.matmul(lhs_data.astype(np.int32),
                            rhs_data.astype(np.int32))

    await fixture.write('lhs_input', lhs_data.flatten())
    await fixture.write('rhs_input', rhs_data.transpose().flatten())
    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")
    output_matmul_result = (await fixture.read(
        'result_output', LHS_ROWS * RHS_COLS *
        4)).view(dtype=np.int32).reshape([LHS_ROWS, RHS_COLS])

    assert ((result_data == output_matmul_result).all())


@cocotb.test()
async def core_mini_rvv_matmul_asm_test(dut):
    """Test integer matmul with RVV assembly.

    Dimensions:
    - Left Hand Side (LHS) matrix: 16 rows x 48 columns
    - Right Hand Side (RHS) matrix: 48 rows x 16 columns
    - Result matrix: 16 rows x 16 columns
    """

    LHS_ROWS = 16
    RHS_COLS = 16
    INNER = 48

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_matmul_assembly.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file),
        ['lhs_input', 'rhs_input', 'result_output'])
    np_type = np.int8
    min_value = np.iinfo(np_type).min
    max_value = np.iinfo(np_type).max + 1  # One above.
    lhs_data = np.random.randint(min_value,
                                 max_value, [LHS_ROWS, INNER],
                                 dtype=np_type)
    rhs_data = np.random.randint(min_value,
                                 max_value, [INNER, RHS_COLS],
                                 dtype=np_type)
    result_data = np.matmul(lhs_data.astype(np.int32),
                            rhs_data.astype(np.int32))

    await fixture.write('lhs_input', lhs_data.flatten())
    await fixture.write('rhs_input', rhs_data.transpose().flatten())
    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")
    output_matmul_result = (await fixture.read(
        'result_output', LHS_ROWS * RHS_COLS *
        4)).view(dtype=np.int32).reshape([LHS_ROWS, RHS_COLS])

    assert ((result_data == output_matmul_result).all())


@cocotb.test()
async def core_mini_rvv_float_matmul_c_test(dut):
    """Test FP32 matmul with RVV C intrinsics.

    Dimensions:
    - Left Hand Side (LHS) matrix: 16 rows x 48 columns
    - Right Hand Side (RHS) matrix: 48 rows x 16 columns
    - Result matrix: 16 rows x 16 columns
    """

    LHS_ROWS = 16
    RHS_COLS = 16
    INNER = 48

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_float_matmul.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file),
        ['lhs_input', 'rhs_input', 'result_output'])
    np_type = np.float32
    rng = np.random.default_rng()

    lhs_data = rng.uniform(-5.0, 5.0, [LHS_ROWS, INNER]).astype(np_type)
    rhs_data = rng.uniform(-5.0, 5.0, [INNER, RHS_COLS]).astype(np_type)
    result_data = np.matmul(lhs_data, rhs_data)

    await fixture.write('lhs_input', lhs_data.flatten())
    await fixture.write('rhs_input', rhs_data.transpose().flatten())
    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")
    output_matmul_result = (await fixture.read(
        'result_output', LHS_ROWS * RHS_COLS * 4)).view(dtype=np_type).reshape(
            [LHS_ROWS, RHS_COLS])

    np.testing.assert_allclose(result_data,
                               output_matmul_result,
                               rtol=1e-4,
                               atol=1e-4)


@cocotb.test()
async def core_mini_rvv_float_matmul_asm_test(dut):
    """Test FP32 matmul with RVV assembly.

    Dimensions:
    - Left Hand Side (LHS) matrix: 16 rows x 48 columns
    - Right Hand Side (RHS) matrix: 48 rows x 16 columns
    - Result matrix: 16 rows x 16 columns
    """

    LHS_ROWS = 16
    RHS_COLS = 16
    INNER = 48

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_float_matmul_assembly.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file),
        ['lhs_input', 'rhs_input', 'result_output'])
    np_type = np.float32
    rng = np.random.default_rng()

    lhs_data = rng.uniform(-5.0, 5.0, [LHS_ROWS, INNER]).astype(np_type)
    rhs_data = rng.uniform(-5.0, 5.0, [INNER, RHS_COLS]).astype(np_type)
    result_data = np.matmul(lhs_data, rhs_data)

    await fixture.write('lhs_input', lhs_data.flatten())
    await fixture.write('rhs_input', rhs_data.transpose().flatten())
    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")
    output_matmul_result = (await fixture.read(
        'result_output', LHS_ROWS * RHS_COLS * 4)).view(dtype=np_type).reshape(
            [LHS_ROWS, RHS_COLS])

    np.testing.assert_allclose(result_data,
                               output_matmul_result,
                               rtol=1e-4,
                               atol=1e-4)


@cocotb.test()
async def core_mini_rvv_float_matmul_optimized_c_test(dut):
    """Test FP32 matmul with optimized RVV C intrinsics.

    Dimensions:
    - Left Hand Side (LHS) matrix: 16 rows x 48 columns
    - Right Hand Side (RHS) matrix: 48 rows x 16 columns
    - Result matrix: 16 rows x 16 columns
    """

    LHS_ROWS = 16
    RHS_COLS = 16
    INNER = 48

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_float_matmul_optimized.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/ml_ops/' + elf_file),
        ['lhs_input', 'rhs_input', 'result_output'])
    np_type = np.float32
    rng = np.random.default_rng()

    lhs_data = rng.uniform(-5.0, 5.0, [LHS_ROWS, INNER]).astype(np_type)
    rhs_data = rng.uniform(-5.0, 5.0, [INNER, RHS_COLS]).astype(np_type)
    result_data = np.matmul(lhs_data, rhs_data)

    await fixture.write('lhs_input', lhs_data.flatten())
    await fixture.write('rhs_input', rhs_data.transpose().flatten())
    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")
    output_matmul_result = (await fixture.read(
        'result_output', LHS_ROWS * RHS_COLS * 4)).view(dtype=np_type).reshape(
            [LHS_ROWS, RHS_COLS])

    np.testing.assert_allclose(result_data,
                               output_matmul_result,
                               rtol=1e-4,
                               atol=1e-4)
