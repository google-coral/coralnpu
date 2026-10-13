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
"""Test suite for FP32 RVV Gemma MatMul Kernels using Cocotb."""

import logging
import os
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
import numpy as np

from sw.utils.metrics import log_matmul_metrics


async def _run_f32_matmul_test_impl(fixture, shapes, test_label_prefix):
    """Unified test runner for FP32 MatMul & GeMV variants."""
    r = runfiles.Create()

    elf_name = "rvv_matmul.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    if not elf_path or not os.path.exists(elf_path):
        raise FileNotFoundError(f"Could not find ELF at {elf_path}")

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "lhs_input", "rhs_input", "result_output", "active_m", "active_k",
            "active_n", "cycle_count"
        ]
    )

    rng = np.random.default_rng(seed=42)

    for M, K, N in shapes:
        logging.info(f"Running {test_label_prefix}: {M}x{K} x {K}x{N}")

        lhs_fp32 = rng.uniform(-2.0, 2.0, (M, K)).astype(np.float32)
        rhs_fp32 = rng.uniform(-2.0, 2.0, (K, N)).astype(np.float32)

        golden_output = np.matmul(lhs_fp32, rhs_fp32)

        await fixture.write('active_m', np.array([M], dtype=np.uint32))
        await fixture.write('active_k', np.array([K], dtype=np.uint32))
        await fixture.write('active_n', np.array([N], dtype=np.uint32))

        await fixture.write('lhs_input', lhs_fp32.flatten())
        await fixture.write('rhs_input', rhs_fp32.flatten())
        await fixture.write(
            'result_output',
            np.zeros_like(golden_output).flatten()
        )

        await fixture.run_to_halt(timeout_cycles=20000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])
        actual_output = (await fixture.read('result_output',
                                            M * N * 4)).view(dtype=np.float32
                                                             ).reshape(M, N)

        np.testing.assert_allclose(
            golden_output, actual_output, rtol=1e-3, atol=1e-3
        )

        log_matmul_metrics(
            fixture, f"{test_label_prefix}: {M}x{K}x{N}", npu_cycles, M, N, K
        )


def fp32_to_bf16_u16(arr):
    import ml_dtypes
    return arr.astype(ml_dtypes.bfloat16).view(np.uint16)


def bf16_u16_to_fp32(arr):
    import ml_dtypes
    return arr.view(ml_dtypes.bfloat16).astype(np.float32)


async def _run_bf16_matmul_test_impl(fixture, shapes, test_label_prefix):
    """Unified test runner for BFloat16 MatMul & GeMV variants."""
    r = runfiles.Create()

    elf_name = "rvv_bf16_matmul.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "lhs_input", "rhs_input", "result_output", "active_m", "active_k",
            "active_n", "cycle_count"
        ]
    )

    rng = np.random.default_rng(seed=42)

    for M, K, N in shapes:
        lhs_fp32 = rng.uniform(-2.0, 2.0, (M, K)).astype(np.float32)
        rhs_fp32 = rng.uniform(-2.0, 2.0, (K, N)).astype(np.float32)

        lhs_u16 = fp32_to_bf16_u16(lhs_fp32)
        rhs_u16 = fp32_to_bf16_u16(rhs_fp32)

        lhs_exact = bf16_u16_to_fp32(lhs_u16)
        rhs_exact = bf16_u16_to_fp32(rhs_u16)
        golden_output = np.matmul(lhs_exact, rhs_exact)

        logging.info(f"Running {test_label_prefix}: {M}x{K} x {K}x{N}")

        await fixture.write('active_m', np.array([M], dtype=np.uint32))
        await fixture.write('active_k', np.array([K], dtype=np.uint32))
        await fixture.write('active_n', np.array([N], dtype=np.uint32))

        await fixture.write('lhs_input', lhs_u16.flatten())
        await fixture.write('rhs_input', rhs_u16.flatten())
        await fixture.write('result_output', np.zeros(M * N, dtype=np.uint16))

        await fixture.run_to_halt(timeout_cycles=25000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])
        actual_u16 = (await fixture.read('result_output',
                                         M * N * 2)).view(dtype=np.uint16
                                                          ).reshape(M, N)
        actual_output = bf16_u16_to_fp32(actual_u16)

        np.testing.assert_allclose(
            golden_output, actual_output, rtol=1e-2, atol=1e-2
        )
        log_matmul_metrics(
            fixture, f"{test_label_prefix}: {M}x{K}x{N}", npu_cycles, M, N, K
        )


@coralflow_test(
    highmem=True,
    ext_mem_base_addr=0x80000000,
    ext_mem_size=32 * 1024 * 1024,
)
async def core_mini_rvv_bf16_matmul_lhs_1d_test(fixture):
    """Unified Test for 1D BFloat16 GeMV kernels (Decode phase)."""
    await _run_bf16_matmul_test_impl(
        fixture,
        shapes=[(1, 64, 64), (1, 1024, 64), (1, 256, 512)],
        test_label_prefix="BF16 GeMV 1D"
    )


@coralflow_test(
    highmem=True,
    ext_mem_base_addr=0x80000000,
    ext_mem_size=32 * 1024 * 1024,
)
async def core_mini_rvv_bf16_matmul_2d_test(fixture):
    """Unified Test for 2D BFloat16 MatMul kernels (Prefill phase)."""
    await _run_bf16_matmul_test_impl(
        fixture,
        shapes=[
            (16, 48, 16),
            (12, 32, 32),
            (32, 48, 32),
        ],
        test_label_prefix="BF16 MatMul 2D"
    )


@coralflow_test(
    highmem=True,
    ext_mem_base_addr=0x80000000,
    ext_mem_size=32 * 1024 * 1024,
)
async def core_mini_rvv_matmul_lhs_1d_test(fixture):
    """Test 1D x 2D FP32 GeMV kernel (Decode phase)."""
    await _run_f32_matmul_test_impl(
        fixture,
        shapes=[
            (1, 64, 64),
            (1, 1024, 64),
            (1, 640, 512),  # Gemma 3 270M Single-Token Decode
        ],
        test_label_prefix="FP32 GeMV 1D Shape"
    )


@coralflow_test(
    highmem=True,
    ext_mem_base_addr=0x80000000,
    ext_mem_size=32 * 1024 * 1024,
)
async def core_mini_rvv_matmul_2d_test(fixture):
    """Test 2D x 2D FP32 Tiled MatMul kernel (Prefill phase)."""
    await _run_f32_matmul_test_impl(
        fixture,
        shapes=[
            (32, 32, 32),
            (12, 640, 512),
            (256, 256, 512),
        ],
        test_label_prefix="FP32 MatMul 2D Shape"
    )


if __name__ == "__main__":
    coralflow_main()
