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

import os
import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture
from sw.utils.metrics import log_matmul_metrics


async def _run_f32_matmul_test_impl(dut, shapes, test_label_prefix):
    """Unified test runner for FP32 MatMul & GeMV variants."""
    r = runfiles.Create()
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

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

    await fixture.core_mini_axi.reset()

    rng = np.random.default_rng(seed=42)

    for M, K, N in shapes:
        dut._log.info(f"Running {test_label_prefix}: {M}x{K} x {K}x{N}")

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

        # 256x256x512 的 FP32 MatMul 约有 3,355 万次 MAC，实测预期运行
        # 时间会超过原来的 2,000 万 cycle 限制；留出余量以避免正常大矩阵
        # 被误判为仿真超时。
        await fixture.run_to_halt(timeout_cycles=40000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])
        actual_output = (await fixture.read('result_output',
                                            M * N * 4)).view(dtype=np.float32
                                                             ).reshape(M, N)

        np.testing.assert_allclose(
            golden_output, actual_output, rtol=1e-3, atol=1e-3
        )

        log_matmul_metrics(
            dut, f"{test_label_prefix}: {M}x{K}x{N}", npu_cycles, M, N, K
        )


def fp32_to_bf16_u16(arr):
    import ml_dtypes
    return arr.astype(ml_dtypes.bfloat16).view(np.uint16)


def bf16_u16_to_fp32(arr):
    import ml_dtypes
    return arr.view(ml_dtypes.bfloat16).astype(np.float32)


def pack_bf16_segment2(rhs_u16):
    """Pack each 64-column row block for vlseg2e16.v.

    The first segment receives columns c..c+31 and the second receives
    c+32..c+63. The interleaved memory layout preserves the original matrix
    mathematically while allowing one segment load to reconstruct both
    vectors.
    """
    K, N = rhs_u16.shape
    if N % 64:
        raise ValueError("segment-2 BF16 packing requires N divisible by 64")
    packed = np.empty_like(rhs_u16)
    for c in range(0, N, 64):
        packed[:, c:c + 64:2] = rhs_u16[:, c:c + 32]
        packed[:, c + 1:c + 64:2] = rhs_u16[:, c + 32:c + 64]
    return packed


def pack_bf16_block_segment2(rhs_u16):
    """Pack [K, N] into block-major 64-column segment-2 blocks.

    The resulting flat layout is [column_block][k][0, 32, 1, 33, ...].
    It is intentionally distinct from ``pack_bf16_segment2``, which keeps
    each original K row contiguous and therefore retains an N-byte stride.
    """
    K, N = rhs_u16.shape
    if N % 64:
        raise ValueError("block segment-2 BF16 packing requires N divisible by 64")
    packed = np.empty((N // 64, K, 64), dtype=rhs_u16.dtype)
    for block, c in enumerate(range(0, N, 64)):
        packed[block, :, 0::2] = rhs_u16[:, c:c + 32]
        packed[block, :, 1::2] = rhs_u16[:, c + 32:c + 64]
    return packed.reshape(K, N)


async def _run_bf16_matmul_test_impl(dut, shapes, test_label_prefix):
    """Unified test runner for BFloat16 MatMul & GeMV variants."""
    r = runfiles.Create()
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

    # The experimental target can select an alternate software schedule while
    # reusing the exact same input, reference and Cocotb checks.
    elf_name = os.environ.get("BF16_MATMUL_ELF", "rvv_bf16_matmul.elf")
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "lhs_input", "rhs_input", "result_output", "active_m", "active_k",
            "active_n", "cycle_count"
        ]
    )

    await fixture.core_mini_axi.reset()

    rng = np.random.default_rng(seed=42)

    for M, K, N in shapes:
        lhs_fp32 = rng.uniform(-2.0, 2.0, (M, K)).astype(np.float32)
        rhs_fp32 = rng.uniform(-2.0, 2.0, (K, N)).astype(np.float32)

        lhs_u16 = fp32_to_bf16_u16(lhs_fp32)
        rhs_u16 = fp32_to_bf16_u16(rhs_fp32)
        rhs_to_write = rhs_u16
        if (
            os.environ.get("BF16_MATMUL_PACKED_B")
            and M == 1
            and N % 64 == 0
        ):
            rhs_to_write = pack_bf16_segment2(rhs_u16)
        if (
            os.environ.get("BF16_MATMUL_BLOCK_PACKED_B")
            and M == 1
            and N % 64 == 0
        ):
            rhs_to_write = pack_bf16_block_segment2(rhs_u16)

        lhs_exact = bf16_u16_to_fp32(lhs_u16)
        rhs_exact = bf16_u16_to_fp32(rhs_u16)
        golden_output = np.matmul(lhs_exact, rhs_exact)

        dut._log.info(f"Running {test_label_prefix}: {M}x{K} x {K}x{N}")

        await fixture.write('active_m', np.array([M], dtype=np.uint32))
        await fixture.write('active_k', np.array([K], dtype=np.uint32))
        await fixture.write('active_n', np.array([N], dtype=np.uint32))

        await fixture.write('lhs_input', lhs_u16.flatten())
        await fixture.write('rhs_input', rhs_to_write.flatten())
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
            dut, f"{test_label_prefix}: {M}x{K}x{N}", npu_cycles, M, N, K
        )


@cocotb.test()
async def core_mini_rvv_bf16_matmul_lhs_1d_test(dut):
    """Unified Test for 1D BFloat16 GeMV kernels (Decode phase)."""
    shapes = [
        (1, 64, 64),
        (1, 1024, 64),
        (1, 256, 512),
        # 以下五个唯一形状覆盖 Gemma 3 270M Decoder Layer 的七次投影；
        # K/V 投影和 Gate/Up 投影各自共享一个形状，汇总时按调用次数计入。
        (1, 640, 1024),
        (1, 640, 256),
        (1, 1024, 640),
        (1, 640, 2048),
        (1, 2048, 640),
    ]
    if os.environ.get("GEMMA_PROFILE_ONLY"):
        shapes = shapes[3:]
    await _run_bf16_matmul_test_impl(
        dut,
        shapes=shapes,
        test_label_prefix="BF16 GeMV 1D"
    )


@cocotb.test()
async def core_mini_rvv_bf16_matmul_2d_test(dut):
    """Unified Test for 2D BFloat16 MatMul kernels (Prefill phase)."""
    await _run_bf16_matmul_test_impl(
        dut,
        shapes=[
            (16, 48, 16),
            (12, 32, 32),
            (32, 48, 32),
        ],
        test_label_prefix="BF16 MatMul 2D"
    )


@cocotb.test()
async def core_mini_rvv_matmul_lhs_1d_test(dut):
    """Test 1D x 2D FP32 GeMV kernel (Decode phase)."""
    await _run_f32_matmul_test_impl(
        dut,
        shapes=[
            (1, 64, 64),
            (1, 1024, 64),
            (1, 640, 512),  # Gemma 3 270M Single-Token Decode
        ],
        test_label_prefix="FP32 GeMV 1D Shape"
    )


@cocotb.test()
async def core_mini_rvv_matmul_2d_test(dut):
    """Test 2D x 2D FP32 Tiled MatMul kernel (Prefill phase)."""
    await _run_f32_matmul_test_impl(
        dut,
        shapes=[
            (32, 32, 32),
            (12, 640, 512),
            (256, 256, 512),
        ],
        test_label_prefix="FP32 MatMul 2D Shape"
    )
