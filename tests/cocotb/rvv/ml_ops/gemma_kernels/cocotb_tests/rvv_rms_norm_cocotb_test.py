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
"""Unified Test suite for FP32 & BFloat16 RVV Gemma RMSNorm Kernels using Cocotb."""

import os
import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture
from sw.utils.metrics import log_vector_metrics


def golden_rms_norm(x, w, eps=1e-6):
    # PyTorch/Gemma style RMS Norm: x * rsqrt(mean(x^2) + eps) * (1 + w)
    rms = np.sqrt(np.mean(x**2, axis=-1, keepdims=True) + eps)
    return x / rms * (1.0 + w)


@cocotb.test()
async def core_mini_rvv_rms_norm_test(dut):
    """FP32 RMSNorm Test."""
    r = runfiles.Create()
    # RMSNorm 张量与完整 Decoder 一样位于 0x80000000 起始的 DDR 区域。
    # 必须显式告诉 Fixture 该地址窗口，否则 AXI 访问会返回 DECERR(0b10)。
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024,
    )

    elf_name = "rvv_rms_norm.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    dut._log.info(f"Loading ELF: {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "rms_input", "rms_weight", "rms_output", "active_seq_len",
            "active_hidden_size", "active_epsilon", "cycle_count"
        ]
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
        dut._log.info(f"\nRunning FP32 RMSNorm shape: {seq_len}x{hidden_size}")

        input_data = rng.uniform(-1.0, 1.0,
                                 (seq_len, hidden_size)).astype(np.float32)
        weight_data = rng.uniform(-0.5, 0.5,
                                  (hidden_size, )).astype(np.float32)

        expected_output = golden_rms_norm(input_data, weight_data, eps=1e-6)

        await fixture.write(
            'active_seq_len', np.array([seq_len], dtype=np.uint32)
        )
        await fixture.write(
            'active_hidden_size', np.array([hidden_size], dtype=np.uint32)
        )
        await fixture.write(
            'active_epsilon', np.array([1e-6], dtype=np.float32)
        )

        await fixture.write('rms_input', input_data.flatten())
        await fixture.write('rms_weight', weight_data.flatten())
        await fixture.write(
            'rms_output',
            np.zeros_like(expected_output).flatten()
        )

        await fixture.run_to_halt(timeout_cycles=10000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])

        output_size_bytes = seq_len * hidden_size * 4
        actual_output = (await fixture.read('rms_output',
                                            output_size_bytes)).view(
                                                dtype=np.float32
                                            ).reshape(seq_len, hidden_size)

        np.testing.assert_allclose(
            expected_output, actual_output, rtol=1e-6, atol=1e-6
        )

        total_elements = seq_len * hidden_size
        log_vector_metrics(
            dut, f"FP32 RMS Norm Shape: {seq_len}x{hidden_size}", npu_cycles,
            total_elements
        )


@cocotb.test()
async def core_mini_rvv_bf16_rms_norm_test(dut):
    """BFloat16 RMSNorm Test using ml_dtypes."""
    import ml_dtypes

    r = runfiles.Create()
    # RMSNorm 张量与完整 Decoder 一样位于 0x80000000 起始的 DDR 区域。
    # 必须显式告诉 Fixture 该地址窗口，否则 AXI 访问会返回 DECERR(0b10)。
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024,
    )

    elf_name = "rvv_bf16_rms_norm.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    dut._log.info(f"Loading ELF: {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "rms_input", "rms_weight", "rms_output", "active_seq_len",
            "active_hidden_size", "active_epsilon", "cycle_count"
        ]
    )

    await fixture.core_mini_axi.reset()

    test_shapes = [
        (11, 640),
        (1, 640),
        # Decoder Layer 中 Q/K 归一化使用的精确形状。
        (4, 256),
        (1, 256),
        (5, 643),
        (1, 2048),
        (2, 2048),
    ]
    if os.environ.get("GEMMA_PROFILE_ONLY"):
        test_shapes = [(1, 640), (4, 256), (1, 256)]

    rng = np.random.default_rng(seed=42)

    for seq_len, hidden_size in test_shapes:
        dut._log.info(f"\nRunning BF16 RMSNorm shape: {seq_len}x{hidden_size}")

        input_fp32 = rng.uniform(-1.0, 1.0,
                                 (seq_len, hidden_size)).astype(np.float32)
        weight_fp32 = rng.uniform(-0.5, 0.5,
                                  (hidden_size, )).astype(np.float32)

        input_bf16 = input_fp32.astype(ml_dtypes.bfloat16)
        weight_bf16 = weight_fp32.astype(ml_dtypes.bfloat16)

        expected_fp32 = golden_rms_norm(
            input_bf16.astype(np.float32),
            weight_bf16.astype(np.float32),
            eps=1e-6
        )

        input_u16 = input_bf16.view(np.uint16)
        weight_u16 = weight_bf16.view(np.uint16)

        await fixture.write(
            'active_seq_len', np.array([seq_len], dtype=np.uint32)
        )
        await fixture.write(
            'active_hidden_size', np.array([hidden_size], dtype=np.uint32)
        )
        await fixture.write(
            'active_epsilon', np.array([1e-6], dtype=np.float32)
        )

        await fixture.write('rms_input', input_u16.flatten())
        await fixture.write('rms_weight', weight_u16.flatten())
        await fixture.write(
            'rms_output', np.zeros(seq_len * hidden_size, dtype=np.uint16)
        )

        await fixture.run_to_halt(timeout_cycles=10000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])

        output_bytes = seq_len * hidden_size * 2
        actual_u16 = (await fixture.read('rms_output', output_bytes)).view(
            dtype=np.uint16
        ).reshape(seq_len, hidden_size)
        actual_fp32 = actual_u16.view(ml_dtypes.bfloat16).astype(np.float32)

        np.testing.assert_allclose(
            expected_fp32, actual_fp32, rtol=1e-2, atol=1e-2
        )

        total_elements = seq_len * hidden_size
        log_vector_metrics(
            dut, f"BF16 RMS Norm Shape: {seq_len}x{hidden_size}", npu_cycles,
            total_elements
        )
