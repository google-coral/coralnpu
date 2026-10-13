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
"""Unified Test suite for FP32 & BFloat16 RVV Gemma TanhGELU x Up Mul Kernels using Cocotb."""

import logging
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
import numpy as np

from sw.utils.metrics import log_vector_metrics


def golden_tanh_gelu_mul(gate_fp32, up_fp32):
    ca = np.float32(np.sqrt(2.0 / np.pi))
    cb = np.float32(0.044715)
    z = ca * (gate_fp32 + cb * (gate_fp32**3))
    tanh_z = np.tanh(z)
    gelu = np.float32(0.5) * gate_fp32 * (np.float32(1.0) + tanh_z)
    return gelu * up_fp32


@coralflow_test(
    highmem=True,
    ext_mem_base_addr=0x80000000,
    ext_mem_size=32 * 1024 * 1024,
)
async def core_mini_rvv_tanh_gelu_mul_test(fixture):
    """FP32 TanhGELU x Up Mul Test."""
    r = runfiles.Create()

    elf_name = "rvv_tanh_gelu_mul.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    logging.info(f"Loading ELF: {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path, ["Gate", "Up", "Output", "active_elements", "cycle_count"]
    )

    test_shapes = [
        (11, 640),
        (1, 640),
        (5, 643),
        (1, 2048),
        (2, 2048),
    ]

    rng = np.random.default_rng(seed=42)

    for token_count, hidden_size in test_shapes:
        logging.info(
            f"\nRunning FP32 TanhGELU x Up Mul shape: [{token_count}, {hidden_size}]"
        )
        total_elements = token_count * hidden_size

        Gate_data = rng.uniform(-1.0, 1.0,
                                (token_count, hidden_size)).astype(np.float32)
        Up_data = rng.uniform(-1.0, 1.0,
                              (token_count, hidden_size)).astype(np.float32)

        expected_output = golden_tanh_gelu_mul(Gate_data, Up_data)

        await fixture.write(
            'active_elements', np.array([total_elements], dtype=np.uint32)
        )
        await fixture.write('Gate', Gate_data.flatten())
        await fixture.write('Up', Up_data.flatten())
        await fixture.write('Output', np.zeros_like(expected_output).flatten())

        await fixture.run_to_halt(timeout_cycles=30000000)
        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])

        output_size_bytes = total_elements * 4
        actual_output = (await fixture.read('Output', output_size_bytes)).view(
            dtype=np.float32
        ).reshape(token_count, hidden_size)

        np.testing.assert_allclose(
            expected_output, actual_output, rtol=1e-2, atol=1e-2
        )

        log_vector_metrics(
            fixture,
            f"FP32 Tanh-GELU Mul Shape: [{token_count}, {hidden_size}]",
            npu_cycles, total_elements
        )


@coralflow_test(
    highmem=True,
    ext_mem_base_addr=0x80000000,
    ext_mem_size=32 * 1024 * 1024,
)
async def core_mini_rvv_bf16_tanh_gelu_mul_test(fixture):
    """BFloat16 TanhGELU x Up Mul Test using ml_dtypes."""
    import ml_dtypes

    r = runfiles.Create()

    elf_name = "rvv_bf16_tanh_gelu_mul.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    logging.info(f"Loading ELF: {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path, ["Gate", "Up", "Output", "active_elements", "cycle_count"]
    )

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
        logging.info(
            f"\nRunning BF16 TanhGELU x Up Mul shape: {seq_len}x{hidden_size} ({total_elements} elements)"
        )

        gate_fp32 = rng.uniform(-3.0, 3.0, total_elements).astype(np.float32)
        up_fp32 = rng.uniform(-3.0, 3.0, total_elements).astype(np.float32)

        gate_bf16 = gate_fp32.astype(ml_dtypes.bfloat16)
        up_bf16 = up_fp32.astype(ml_dtypes.bfloat16)

        expected_fp32 = golden_tanh_gelu_mul(
            gate_bf16.astype(np.float32), up_bf16.astype(np.float32)
        )

        gate_u16 = gate_bf16.view(np.uint16)
        up_u16 = up_bf16.view(np.uint16)

        await fixture.write(
            'active_elements', np.array([total_elements], dtype=np.uint32)
        )

        await fixture.write('Gate', gate_u16)
        await fixture.write('Up', up_u16)
        await fixture.write(
            'Output', np.zeros(total_elements, dtype=np.uint16)
        )

        await fixture.run_to_halt(timeout_cycles=10000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])

        output_bytes = total_elements * 2
        actual_u16 = (await fixture.read('Output',
                                         output_bytes)).view(dtype=np.uint16)
        actual_fp32 = actual_u16.view(ml_dtypes.bfloat16).astype(np.float32)

        np.testing.assert_allclose(
            actual_fp32, expected_fp32, rtol=3e-2, atol=8e-2
        )

        log_vector_metrics(
            fixture, f"BF16 TanhGELU x Up Mul Shape: {seq_len}x{hidden_size}",
            npu_cycles, total_elements
        )


if __name__ == "__main__":
    coralflow_main()
