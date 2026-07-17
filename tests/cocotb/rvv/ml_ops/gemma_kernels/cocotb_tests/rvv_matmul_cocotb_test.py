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
            dut, f"{test_label_prefix}: {M}x{K}x{N}", npu_cycles, M, N, K
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
