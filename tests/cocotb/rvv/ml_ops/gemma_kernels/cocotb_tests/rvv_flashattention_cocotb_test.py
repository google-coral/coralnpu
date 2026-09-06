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


def golden_flash_attention(q, k, v):
    """NumPy Golden Reference for FlashAttention."""
    d = q.shape[-1]

    # Handle both 2D (seq, d) and 3D (heads, seq, d) matrices
    if q.ndim == 3:
        scores = np.matmul(q, k.transpose(0, 2, 1)) / np.sqrt(d)
    else:
        scores = np.matmul(q, k.T) / np.sqrt(d)

    # Safe Softmax
    m = np.max(scores, axis=-1, keepdims=True)
    p = np.exp(scores - m)
    p /= np.sum(p, axis=-1, keepdims=True)

    # O = P * V
    return np.matmul(p, v)


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
        expected_output = golden_flash_attention(q_data, k_golden, v_golden)

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
        expected_output = golden_flash_attention(q_data, k_golden, v_golden)

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

    cycle_count = (await fixture.read_word('cycle_count')).view(np.uint32)[0]

    total_macs = 2 * q_heads * q_seq_len * kv_seq_len * dim
    log_matmul_metrics(
        dut,
        f"core_mini_rvv_flashattention_Q{q_heads}KV{kv_heads}_Sq{q_seq_len}Skv{kv_seq_len}_D{dim}",
        cycle_count,
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

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "q_buf", "k_buf", "v_buf", "o_buf", "cycle_count",
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

    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "q_buf", "k_buf", "v_buf", "o_buf", "cycle_count",
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
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=4,
        kv_heads=1,
        q_seq_len=1,
        kv_seq_len=32,
        dim=640
    )
    await run_flashattention_test(
        fixture,
        dut,
        r,
        elf_path,
        q_heads=4,
        kv_heads=1,
        q_seq_len=1,
        kv_seq_len=256,
        dim=640
    )


def golden_flash_attention_bf16(
    q_bf16, k_bf16, v_bf16, q_heads, kv_heads, q_seq_len, kv_seq_len, dim
):
    # Cast to FP32 for reference calculation
    q = q_bf16.astype(np.float32).reshape(q_heads, q_seq_len, dim)
    k = k_bf16.astype(np.float32).reshape(kv_heads, kv_seq_len, dim)
    v = v_bf16.astype(np.float32).reshape(kv_heads, kv_seq_len, dim)

    output = np.zeros((q_heads, q_seq_len, dim), dtype=np.float32)
    scale = 1.0 / np.sqrt(dim)

    for h in range(q_heads):
        kv_h = h % kv_heads if kv_heads > 0 else 0
        q_h = q[h]  # [q_seq_len, dim]
        k_h = k[kv_h]  # [kv_seq_len, dim]
        v_h = v[kv_h]  # [kv_seq_len, dim]

        # S = Q * K^T * scale
        scores = np.matmul(q_h, k_h.T) * scale  # [q_seq_len, kv_seq_len]
        scores_max = np.max(scores, axis=-1, keepdims=True)
        exp_scores = np.exp(scores - scores_max)
        probs = exp_scores / np.sum(exp_scores, axis=-1, keepdims=True)

        output[h] = np.matmul(probs, v_h)

    return output.flatten()


@cocotb.test()
async def core_mini_rvv_bf16_flashattention_test(dut):
    """BFloat16 FlashAttention MQA Test using ml_dtypes."""
    import ml_dtypes

    r = runfiles.Create()
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024
    )

    elf_name = "rvv_bf16_flashattention.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/{elf_name}"
    )

    dut._log.info(f"Loading ELF: {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path, [
            "q_buf", "k_buf", "v_buf", "o_buf", "active_num_heads",
            "active_num_kv_heads", "active_q_seq_len", "active_kv_seq_len",
            "active_dim", "cycle_count"
        ]
    )

    await fixture.core_mini_axi.reset()

    # Test configs for Gemma 3 (Prefill and Decode)
    test_configs = [
        {
            # The decoder-layer shape uses cache_length=3; appending the current
            # token produces a KV sequence length of 4.
            "name": "Decoder Layer Exact Shape",
            "q_heads": 4,
            "kv_heads": 1,
            "q_seq": 1,
            "kv_seq": 4,
            "dim": 256
        },
        {
            "name": "Decode Fast Path (Dim <= 32)",
            "q_heads": 4,
            "kv_heads": 1,
            "q_seq": 1,
            "kv_seq": 32,
            "dim": 32
        },
        {
            "name": "Decode Phase",
            "q_heads": 4,
            "kv_heads": 1,
            "q_seq": 1,
            "kv_seq": 64,
            "dim": 256
        },
        {
            "name": "Decode Step 32",
            "q_heads": 4,
            "kv_heads": 1,
            "q_seq": 1,
            "kv_seq": 256,
            "dim": 256
        },
        {
            "name": "Prefill Phase",
            "q_heads": 4,
            "kv_heads": 1,
            "q_seq": 11,
            "kv_seq": 11,
            "dim": 256
        },
    ]
    if os.environ.get("GEMMA_PROFILE_ONLY"):
        test_configs = test_configs[:1]

    rng = np.random.default_rng(seed=42)

    for cfg in test_configs:
        q_heads, kv_heads = cfg["q_heads"], cfg["kv_heads"]
        q_seq, kv_seq, dim = cfg["q_seq"], cfg["kv_seq"], cfg["dim"]

        dut._log.info(
            f"\nRunning BF16 FlashAttention ({cfg['name']}): Q_heads={q_heads}, KV_heads={kv_heads}, Q_len={q_seq}, KV_len={kv_seq}, Dim={dim}"
        )

        q_size = q_heads * q_seq * dim
        kv_size = kv_heads * kv_seq * dim
        o_size = q_heads * q_seq * dim

        q_fp32 = rng.uniform(-1.0, 1.0, q_size).astype(np.float32)
        k_fp32 = rng.uniform(-1.0, 1.0, kv_size).astype(np.float32)
        v_fp32 = rng.uniform(-1.0, 1.0, kv_size).astype(np.float32)

        q_bf16 = q_fp32.astype(ml_dtypes.bfloat16)
        k_bf16 = k_fp32.astype(ml_dtypes.bfloat16)
        v_bf16 = v_fp32.astype(ml_dtypes.bfloat16)

        expected_fp32 = golden_flash_attention_bf16(
            q_bf16, k_bf16, v_bf16, q_heads, kv_heads, q_seq, kv_seq, dim
        )

        await fixture.write(
            'active_num_heads', np.array([q_heads], dtype=np.uint32)
        )
        await fixture.write(
            'active_num_kv_heads', np.array([kv_heads], dtype=np.uint32)
        )
        await fixture.write(
            'active_q_seq_len', np.array([q_seq], dtype=np.uint32)
        )
        await fixture.write(
            'active_kv_seq_len', np.array([kv_seq], dtype=np.uint32)
        )
        await fixture.write('active_dim', np.array([dim], dtype=np.uint32))

        await fixture.write('q_buf', q_bf16.view(np.uint16))
        await fixture.write('k_buf', k_bf16.view(np.uint16))
        await fixture.write('v_buf', v_bf16.view(np.uint16))
        await fixture.write('o_buf', np.zeros(o_size, dtype=np.uint16))

        await fixture.run_to_halt(timeout_cycles=20000000)

        npu_cycles = int((await fixture.read('cycle_count',
                                             4)).view(dtype=np.uint32)[0])

        actual_u16 = (await fixture.read('o_buf',
                                         o_size * 2)).view(dtype=np.uint16)
        actual_fp32 = actual_u16.view(ml_dtypes.bfloat16).astype(np.float32)

        np.testing.assert_allclose(
            actual_fp32, expected_fp32, rtol=1e-2, atol=1e-2
        )

        total_macs = q_heads * q_seq * kv_seq * dim * 2
        log_matmul_metrics(
            dut,
            f"BF16 FlashAttention ({cfg['name']})",
            npu_cycles,
            macs=total_macs
        )
