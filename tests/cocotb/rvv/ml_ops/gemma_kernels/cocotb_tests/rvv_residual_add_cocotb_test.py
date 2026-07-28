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
"""Unified Test suite for FP32 & BFloat16 RVV Gemma Residual Addition Kernels using Cocotb."""

import os
import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture
from sw.utils.metrics import log_vector_metrics


@cocotb.test()
async def core_mini_rvv_residual_add_test(dut):
    """FP32 Residual Add Test."""
    r = runfiles.Create()

    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

    elf_name = "rvv_residual_add.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    dut._log.info(f"Loading ELF: {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path, ["A", "B", "Y", "active_elements", "cycle_count"]
    )

    await fixture.core_mini_axi.reset()

    test_shapes = [
        (11, 640),
        (1, 640),
        (5, 643),
        (1, 2048),
        (2, 2048),
    ]

    rng = np.random.default_rng(seed=42)

    for token_count, hidden_size in test_shapes:
        dut._log.info(
            f"\nRunning FP32 Residual Add shape: [{token_count}, {hidden_size}]"
        )
        total_elements = token_count * hidden_size

        A_data = rng.uniform(-1.0, 1.0,
                             (token_count, hidden_size)).astype(np.float32)
        B_data = rng.uniform(-0.5, 0.5,
                             (token_count, hidden_size)).astype(np.float32)

        expected_output = np.add(A_data, B_data)

        await fixture.write(
            'active_elements', np.array([total_elements], dtype=np.uint32)
        )
        await fixture.write('A', A_data.flatten())
        await fixture.write('B', B_data.flatten())
        await fixture.write('Y', np.zeros_like(expected_output).flatten())

        sim_cycles = await fixture.run_to_halt(timeout_cycles=20000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])

        output_size_bytes = total_elements * 4
        actual_output = (await fixture.read('Y', output_size_bytes)).view(
            dtype=np.float32
        ).reshape(token_count, hidden_size)

        np.testing.assert_allclose(
            expected_output, actual_output, rtol=1e-5, atol=1e-5
        )

        log_vector_metrics(
            dut, f"FP32 Residual Add Shape: [{token_count}, {hidden_size}]",
            npu_cycles, total_elements
        )


@cocotb.test()
async def core_mini_rvv_bf16_residual_add_test(dut):
    """BFloat16 Residual Add Test using ml_dtypes."""
    import ml_dtypes

    r = runfiles.Create()
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

    elf_name = "rvv_bf16_residual_add.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    dut._log.info(f"Loading ELF: {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path, ["A", "B", "Y", "active_elements", "cycle_count"]
    )

    await fixture.core_mini_axi.reset()

    test_shapes = [
        (11, 640),
        (1, 640),
        (5, 643),
        (1, 2048),
        (2, 2048),
    ]

    rng = np.random.default_rng(seed=42)

    for seq_len, hidden_size in test_shapes:
        total_elements = seq_len * hidden_size
        dut._log.info(
            f"\nRunning BF16 Residual Add shape: {seq_len}x{hidden_size} ({total_elements} elements)"
        )

        a_fp32 = rng.uniform(-5.0, 5.0, total_elements).astype(np.float32)
        b_fp32 = rng.uniform(-5.0, 5.0, total_elements).astype(np.float32)

        a_bf16 = a_fp32.astype(ml_dtypes.bfloat16)
        b_bf16 = b_fp32.astype(ml_dtypes.bfloat16)

        expected_fp32 = a_bf16.astype(np.float32) + b_bf16.astype(np.float32)

        a_u16 = a_bf16.view(np.uint16)
        b_u16 = b_bf16.view(np.uint16)

        await fixture.write(
            'active_elements', np.array([total_elements], dtype=np.uint32)
        )

        await fixture.write('A', a_u16)
        await fixture.write('B', b_u16)
        await fixture.write('Y', np.zeros(total_elements, dtype=np.uint16))

        await fixture.run_to_halt(timeout_cycles=10000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])

        output_bytes = total_elements * 2
        actual_u16 = (await fixture.read('Y',
                                         output_bytes)).view(dtype=np.uint16)
        actual_fp32 = actual_u16.view(ml_dtypes.bfloat16).astype(np.float32)

        np.testing.assert_allclose(
            actual_fp32, expected_fp32, rtol=1e-2, atol=1e-2
        )

        log_vector_metrics(
            dut, f"BF16 Residual Add Shape: {seq_len}x{hidden_size}",
            npu_cycles, total_elements
        )
