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
"""CoralFlow single-source port of tests/cocotb/rvv_ml_ops_cocotb_test.py.

Verifies INT8, FP32, and BFloat16 RVV matrix multiplication kernels (both C
intrinsics and assembly) across NPUSim, Verilator, UVM, and Nexus FPGA.
"""

import ml_dtypes
import numpy as np

from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.coralflow.runner import (
    coralflow_test,
    get_target_environment,
)

_MATMUL_SYMBOLS = [
    "lhs_input",
    "rhs_input",
    "result_output",
    "lhs_rows",
    "rhs_cols",
    "inner",
]


async def _run_int8_matmul(
    fixture: BaseCoralNPUFixture, elf_name: str
) -> None:
    """Runs and verifies an INT8 -> INT32 matrix multiplication ELF."""
    await fixture.load_elf_and_lookup_symbols(
        f"tests/cocotb/rvv/ml_ops/{elf_name}",
        _MATMUL_SYMBOLS,
    )

    lhs_rows, rhs_cols, inner = 16, 16, 48
    rng = np.random.default_rng(seed=42)
    lhs_data = rng.integers(-128, 128, size=(lhs_rows, inner), dtype=np.int8)
    rhs_data = rng.integers(-128, 128, size=(inner, rhs_cols), dtype=np.int8)
    expected = np.matmul(lhs_data.astype(np.int32), rhs_data.astype(np.int32))

    await fixture.write_word("lhs_rows", lhs_rows)
    await fixture.write_word("rhs_cols", rhs_cols)
    await fixture.write_word("inner", inner)
    await fixture.write("lhs_input", lhs_data.flatten())
    await fixture.write("rhs_input", rhs_data.transpose().flatten())

    halted = await fixture.run_to_halt(timeout_cycles=1_000_000)
    assert halted, f"Timed out waiting for {elf_name} to halt"
    actual = await fixture.read(
        "result_output", dtype=np.int32, shape=(lhs_rows, rhs_cols)
    )
    np.testing.assert_array_equal(actual, expected)


async def _run_fp32_matmul(
    fixture: BaseCoralNPUFixture, elf_name: str
) -> None:
    """Runs and verifies an FP32 matrix multiplication ELF."""
    await fixture.load_elf_and_lookup_symbols(
        f"tests/cocotb/rvv/ml_ops/{elf_name}",
        _MATMUL_SYMBOLS,
    )

    lhs_rows, rhs_cols, inner = 16, 16, 48
    rng = np.random.default_rng(seed=42)
    lhs_data = rng.uniform(
        -5.0, 5.0, size=(lhs_rows, inner)
    ).astype(np.float32)
    rhs_data = rng.uniform(
        -5.0, 5.0, size=(inner, rhs_cols)
    ).astype(np.float32)
    expected = np.matmul(lhs_data, rhs_data)

    await fixture.write_word("lhs_rows", lhs_rows)
    await fixture.write_word("rhs_cols", rhs_cols)
    await fixture.write_word("inner", inner)
    await fixture.write("lhs_input", lhs_data.flatten())
    await fixture.write("rhs_input", rhs_data.transpose().flatten())

    halted = await fixture.run_to_halt(timeout_cycles=1_000_000)
    assert halted, f"Timed out waiting for {elf_name} to halt"
    actual = await fixture.read(
        "result_output", dtype=np.float32, shape=(lhs_rows, rhs_cols)
    )
    np.testing.assert_allclose(actual, expected, rtol=1e-4, atol=1e-4)


@coralflow_test
async def rvv_matmul_c_test(fixture: BaseCoralNPUFixture) -> None:
    """Test INT8 matmul with RVV C intrinsics."""
    await _run_int8_matmul(fixture, "rvv_matmul.elf")


@coralflow_test
async def rvv_matmul_asm_test(fixture: BaseCoralNPUFixture) -> None:
    """Test INT8 matmul with RVV assembly."""
    await _run_int8_matmul(fixture, "rvv_matmul_assembly.elf")


@coralflow_test
async def rvv_float_matmul_c_test(fixture: BaseCoralNPUFixture) -> None:
    """Test FP32 matmul with RVV C intrinsics."""
    await _run_fp32_matmul(fixture, "rvv_float_matmul.elf")


@coralflow_test
async def rvv_float_matmul_asm_test(fixture: BaseCoralNPUFixture) -> None:
    """Test FP32 matmul with RVV assembly."""
    await _run_fp32_matmul(fixture, "rvv_float_matmul_assembly.elf")


@coralflow_test
async def rvv_float_matmul_optimized_c_test(
    fixture: BaseCoralNPUFixture,
) -> None:
    """Test FP32 matmul with optimized RVV C intrinsics."""
    await _run_fp32_matmul(fixture, "rvv_float_matmul_optimized.elf")


@coralflow_test
async def rvv_bf16_matmul_c_test(fixture: BaseCoralNPUFixture) -> None:
    """Test BFloat16 matmul with RVV C intrinsics (Zvfbfwma)."""
    rng = np.random.default_rng(seed=42)
    for lhs_rows, rhs_cols, inner in [(16, 16, 48), (8, 32, 64)]:
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/ml_ops/rvv_bf16_matmul.elf",
            _MATMUL_SYMBOLS,
        )

        lhs_bf16 = rng.uniform(
            -4.0, 4.0, size=(lhs_rows, inner)
        ).astype(ml_dtypes.bfloat16)
        rhs_bf16 = rng.uniform(
            -4.0, 4.0, size=(inner, rhs_cols)
        ).astype(ml_dtypes.bfloat16)
        expected = np.matmul(
            lhs_bf16.astype(np.float32), rhs_bf16.astype(np.float32)
        )

        await fixture.write_word("lhs_rows", lhs_rows)
        await fixture.write_word("rhs_cols", rhs_cols)
        await fixture.write_word("inner", inner)
        await fixture.write("lhs_input", lhs_bf16.view(np.uint16).flatten())
        await fixture.write(
            "rhs_input",
            rhs_bf16.view(np.uint16).transpose().flatten()
        )

        halted = await fixture.run_to_halt(timeout_cycles=1_000_000)
        assert halted, "Timed out waiting for rvv_bf16_matmul.elf to halt"
        actual = await fixture.read(
            "result_output", dtype=np.float32, shape=(lhs_rows, rhs_cols)
        )
        np.testing.assert_allclose(actual, expected, rtol=1e-3, atol=1e-3)


if __name__ == "__main__":
    target = get_target_environment()
    rvv_matmul_c_test()
    rvv_matmul_asm_test()
    # MpactNpuSim (CoralNPUV2Simulator) defaults to kV2 (integer-only RVV)
    # without Zve32f or Zvfbfwma, and the standard UVM core_mini_axi RTL build
    # does not enable Zvfbfwma (see rules/uvm_denylist.bzl).
    if target != "npusim":
        rvv_float_matmul_c_test()
        rvv_float_matmul_asm_test()
        rvv_float_matmul_optimized_c_test()
    if target not in ("npusim", "uvm"):
        rvv_bf16_matmul_c_test()
