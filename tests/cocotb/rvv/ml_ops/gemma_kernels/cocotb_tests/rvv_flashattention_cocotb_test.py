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
"""Test suite for RVV Gemma Kernels using Cocotb."""

import os
import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture
from sw.utils.metrics import log_matmul_metrics


def calculate_cosine_similarity(
    actual: np.ndarray, expected: np.ndarray
) -> float:
    dot_products = np.sum(actual * expected, axis=-1)
    norm_actual = np.linalg.norm(actual, axis=-1)
    norm_expected = np.linalg.norm(expected, axis=-1)
    similarities = dot_products / (norm_actual * norm_expected + 1e-9)
    return float(np.mean(similarities))


def load_real_attention_data(
    q_heads: int, kv_heads: int, q_seq_len: int, kv_seq_len: int, d_model: int,
    dut, r
):
    q_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/test_data/gemma_q.npy"
    )
    k_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/test_data/gemma_k.npy"
    )
    v_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/test_data/gemma_v.npy"
    )

    if (q_path and os.path.exists(q_path) and os.path.exists(k_path)
            and os.path.exists(v_path)):
        dut._log.info(
            "SUCCESS: Real Gemma tensors found! Calculating UNMASKED Multi-Head Golden Model..."
        )

        def safe_load_and_reshape(path, heads, seq, d):
            raw = np.load(path).astype(np.float32)
            target_size = heads * seq * d
            resized = np.resize(raw.flatten(), target_size)
            return resized.reshape((heads, seq, d))

        q_data = safe_load_and_reshape(q_path, q_heads, q_seq_len, d_model)
        k_data = safe_load_and_reshape(k_path, kv_heads, kv_seq_len, d_model)
        v_data = safe_load_and_reshape(v_path, kv_heads, kv_seq_len, d_model)

        k_golden = k_data
        v_golden = v_data
        if q_heads != kv_heads:
            repeats = q_heads // kv_heads
            k_golden = np.repeat(k_data, repeats, axis=0)
            v_golden = np.repeat(v_data, repeats, axis=0)

        # Golden Model Math
        scores = np.matmul(q_data, k_golden.transpose(0, 2,
                                                      1)) / np.sqrt(d_model)
        m = np.max(scores, axis=-1, keepdims=True)
        p = np.exp(scores - m)
        p /= np.sum(p, axis=-1, keepdims=True)
        expected_output = np.matmul(p, v_golden)

        return q_data, k_data, v_data, expected_output
    else:
        dut._log.info(
            "Real Gemma tensors not found. Generating synthetic data for attention test..."
        )
        np.random.seed(42)
        q_data = np.random.normal(
            scale=0.1, size=(q_heads, q_seq_len, d_model)
        ).astype(np.float32)
        k_data = np.random.normal(
            scale=0.1, size=(kv_heads, kv_seq_len, d_model)
        ).astype(np.float32)
        v_data = np.random.normal(
            scale=0.1, size=(kv_heads, kv_seq_len, d_model)
        ).astype(np.float32)

        k_golden = k_data
        v_golden = v_data
        if q_heads != kv_heads:
            repeats = q_heads // kv_heads
            k_golden = np.repeat(k_data, repeats, axis=0)
            v_golden = np.repeat(v_data, repeats, axis=0)

        # Golden Model Math
        scores = np.matmul(q_data, k_golden.transpose(0, 2,
                                                      1)) / np.sqrt(d_model)
        m = np.max(scores, axis=-1, keepdims=True)
        p = np.exp(scores - m)
        p /= np.sum(p, axis=-1, keepdims=True)
        expected_output = np.matmul(p, v_golden)

        return q_data, k_data, v_data, expected_output


async def run_flashattention_test(
    fixture, dut, r, elf_path, q_heads: int, kv_heads: int, q_seq_len: int,
    kv_seq_len: int, dim: int
):
    dut._log.info(
        f"========== RUNNING ATTENTION TEST: Q:{q_heads}x{q_seq_len}x{dim}, KV:{kv_heads}x{kv_seq_len}x{dim} =========="
    )
    try:
        q_data, k_data, v_data, expected_output = load_real_attention_data(
            q_heads, kv_heads, q_seq_len, kv_seq_len, dim, dut, r
        )
    except FileNotFoundError as e:
        dut._log.warning(f"Skipping test: {e}")
        return

    await fixture.core_mini_axi.reset()

    # Write configuration variables
    await fixture.write(
        'active_num_heads', np.array([q_heads], dtype=np.uint32)
    )
    await fixture.write(
        'active_num_kv_heads', np.array([kv_heads], dtype=np.uint32)
    )
    await fixture.write(
        'active_q_seq_len', np.array([q_seq_len], dtype=np.uint32)
    )
    await fixture.write(
        'active_kv_seq_len', np.array([kv_seq_len], dtype=np.uint32)
    )
    await fixture.write('active_dim', np.array([dim], dtype=np.uint32))

    await fixture.write("q_buf", q_data.flatten())
    await fixture.write("k_buf", k_data.flatten())
    await fixture.write("v_buf", v_data.flatten())
    await fixture.write("o_buf", np.zeros_like(expected_output).flatten())

    await fixture.run_to_halt(timeout_cycles=40000000)

    csr_cycle_count = (await
                       fixture.read_word('csr_cycle_count')).view(np.uint32)[0]

    total_macs = 2 * q_heads * q_seq_len * kv_seq_len * dim
    log_matmul_metrics(
        dut,
        f"core_mini_rvv_flashattention_Q{q_heads}KV{kv_heads}_Sq{q_seq_len}Skv{kv_seq_len}_D{dim}",
        csr_cycle_count,
        macs=total_macs,
    )

    num_bytes = q_heads * q_seq_len * dim * 4
    actual_packed = await fixture.read("o_buf", num_bytes)
    actual_output = actual_packed.view(np.float32
                                       ).reshape(q_heads, q_seq_len, dim)

    cos_sim = calculate_cosine_similarity(actual_output, expected_output)
    dut._log.info(
        f"Average Cosine Similarity to Multi-Head Golden Model: {cos_sim:.6f}"
    )

    assert cos_sim > 0.999, "Accuracy failure against model!"


@cocotb.test()
async def core_mini_rvv_flashattention_prefill_test(dut):
    r = runfiles.Create()

    # Highmem configuration maps CSRs dynamically via highmem flag
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

    elf_name = "rvv_flashattention_test.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    if not elf_path or not os.path.exists(elf_path):
        dut._log.info(
            f"Skipping test because ELF not found in sandbox: {elf_name}"
        )
        return

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "q_buf", "k_buf", "v_buf", "o_buf", "csr_cycle_count",
            "active_num_heads", "active_num_kv_heads", "active_q_seq_len",
            "active_kv_seq_len", "active_dim"
        ]
    )

    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=2,
        kv_heads=1,
        q_seq_len=8,
        kv_seq_len=8,
        dim=32
    )
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=2,
        kv_heads=1,
        q_seq_len=32,
        kv_seq_len=32,
        dim=32
    )
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=4,
        kv_heads=1,
        q_seq_len=8,
        kv_seq_len=8,
        dim=32
    )
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=4,
        kv_heads=1,
        q_seq_len=32,
        kv_seq_len=32,
        dim=32
    )


@cocotb.test()
async def core_mini_rvv_flashattention_decode_test(dut):
    r = runfiles.Create()

    # Highmem configuration maps CSRs dynamically via highmem flag
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

    elf_name = "rvv_flashattention_test.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    if not elf_path or not os.path.exists(elf_path):
        dut._log.info(
            f"Skipping test because ELF not found in sandbox: {elf_name}"
        )
        return

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "q_buf", "k_buf", "v_buf", "o_buf", "csr_cycle_count",
            "active_num_heads", "active_num_kv_heads", "active_q_seq_len",
            "active_kv_seq_len", "active_dim"
        ]
    )

    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=2,
        kv_heads=1,
        q_seq_len=1,
        kv_seq_len=8,
        dim=32
    )
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=2,
        kv_heads=1,
        q_seq_len=1,
        kv_seq_len=32,
        dim=32
    )
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=4,
        kv_heads=1,
        q_seq_len=1,
        kv_seq_len=8,
        dim=32
    )
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=4,
        kv_heads=1,
        q_seq_len=1,
        kv_seq_len=32,
        dim=32
    )
