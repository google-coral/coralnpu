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
"""Test suite for Int8 RVV Gemma MatMul Kernels using Cocotb."""

import os
import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture
from sw.utils.metrics import log_matmul_metrics


async def _impl(dut, shapes, test_label_prefix):
    """Unified test runner for Int8 MatMul & GeMV variants."""
    r = runfiles.Create()
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/rvv_int8_matmul.elf"
    )

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "lhs_input", "rhs_input", "result_output", "active_m", "active_k",
            "active_n", "cycle_count"
        ]
    )

    await fixture.core_mini_axi.reset()

    random_seed = os.environ.get("RANDOM_SEED")
    seed = int(random_seed) if random_seed is not None else 42
    rng = np.random.default_rng(seed=seed)

    for M, K, N in shapes:
        lhs = rng.integers(-127, 128, size=(M, K), dtype=np.int8)
        rhs = rng.integers(-127, 128, size=(K, N), dtype=np.int8)
        golden_output = np.matmul(lhs, rhs, dtype=np.int32)

        dut._log.info(f"Running {test_label_prefix}: {M}x{K} x {K}x{N}")

        await fixture.write_word('active_m', M)
        await fixture.write_word('active_k', K)
        await fixture.write_word('active_n', N)

        await fixture.write('lhs_input', lhs.flatten())
        await fixture.write('rhs_input', rhs.flatten())
        await fixture.write('result_output', np.zeros(M * N, dtype=np.int32))

        await fixture.run_to_halt(timeout_cycles=100000)

        npu_cycles = int((await
                          fixture.read_word('cycle_count')).view(np.uint32)[0])
        actual_output = (await fixture.read('result_output',
                                            M * N * 4)).view(dtype=np.int32
                                                             ).reshape(M, N)

        assert (actual_output == golden_output).all()
        log_matmul_metrics(
            dut, f"{test_label_prefix}: {M}x{K}x{N}", npu_cycles, M, N, K
        )


@cocotb.test()
async def gemv(dut):
    """Unified Test for 1D Int8 GeMV kernels (Decode phase)."""
    await _impl(
        dut,
        shapes=[
            # Main loop is 1x4x(e8m4) per iteration
            (1, 64, 64),
            (1, 64, 1024),
            (1, 1024, 64),
            # Tail on K
            (1, 1, 64),
            (1, 5, 64),
            # Tail on N
            (1, 4, 1),
            (1, 4, 32),
            (1, 4, 33),
            (1, 4, 65),
            (1, 4, 96),
            (1, 4, 97),
            # Tail on both K and N
            (1, 1, 1),
            (1, 1, 32),
            (1, 1, 33),
            (1, 1, 65),
            (1, 1, 96),
            (1, 1, 97),
            (1, 5, 1),
            (1, 5, 32),
            (1, 5, 33),
            (1, 5, 65),
            (1, 5, 96),
            (1, 5, 97),
        ],
        test_label_prefix="INT8 GeMV 1D"
    )


@cocotb.test()
async def matmul(dut):
    """Unified Test for 2D BFloat16 MatMul kernels (Prefill phase)."""
    await _impl(
        dut,
        shapes=[
            # Main loop is 1x4x(e8m4) per iteration
            (4, 64, 64),
            (4, 64, 1024),
            (4, 1024, 64),
            # Tail on K
            (4, 1, 64),
            (4, 5, 64),
            # Tail on N
            (4, 4, 1),
            (4, 4, 32),
            (4, 4, 33),
            (4, 4, 65),
            (4, 4, 96),
            (4, 4, 97),
            # Tail on both K and N
            (4, 1, 1),
            (4, 1, 32),
            (4, 1, 33),
            (4, 1, 65),
            (4, 1, 96),
            (4, 1, 97),
            (4, 5, 1),
            (4, 5, 32),
            (4, 5, 33),
            (4, 5, 65),
            (4, 5, 96),
            (4, 5, 97),
        ],
        test_label_prefix="INT8 MatMul 2D"
    )
