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

import cocotb
import numpy as np
import sys
import os

sys.set_int_max_str_digits(100000)

from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles

def log_matmul_metrics(dut, test_name: str, cycles: int, num_heads: int, lhs_rows: int, rhs_cols: int, inner: int):
    total_macs = num_heads * lhs_rows * rhs_cols * inner
    cycles_per_mac = cycles / total_macs if total_macs > 0 else 0
    banner = (f"\n{'='*60}\n PERFORMANCE METRICS: {test_name}\n{'-'*60}\n"
              f"  Total Cycles   : {cycles:,}\n  Total MACs     : {total_macs:,}\n"
              f"  Cycles / MAC   : {cycles_per_mac:.2f}\n{'='*60}")
    dut._log.info(banner)

def calculate_cosine_similarity(actual: np.ndarray, expected: np.ndarray) -> float:
    dot_products = np.sum(actual * expected, axis=-1)
    norm_actual = np.linalg.norm(actual, axis=-1)
    norm_expected = np.linalg.norm(expected, axis=-1)
    similarities = dot_products / (norm_actual * norm_expected + 1e-9)
    return float(np.mean(similarities))

def load_real_attention_data(num_heads: int, seq_len: int, d_model: int, dut, r):
    q_path = r.Rlocation("coralnpu_hw/tests/cocotb/gemma_q.npy")
    k_path = r.Rlocation("coralnpu_hw/tests/cocotb/gemma_k.npy")
    v_path = r.Rlocation("coralnpu_hw/tests/cocotb/gemma_v.npy")

    if (q_path and os.path.exists(q_path) and os.path.exists(k_path) and os.path.exists(v_path)):
        dut._log.info("SUCCESS: Real Gemma tensors found! Calculating UNMASKED Multi-Head Golden Model...")

        # Helper to safely force any .npy file into target shape
        def safe_load_and_reshape(path):
            raw = np.load(path).astype(np.float32)
            target_size = num_heads * seq_len * d_model
            # np.resize flattens the array and automatically repeats the data 
            resized = np.resize(raw.flatten(), target_size)
            return resized.reshape((num_heads, seq_len, d_model))

        q_data = safe_load_and_reshape(q_path)
        k_data = safe_load_and_reshape(k_path)
        v_data = safe_load_and_reshape(v_path)

        # Golden Model Math
        scores = np.matmul(q_data, k_data.transpose(0, 2, 1)) / np.sqrt(d_model)
        m = np.max(scores, axis=-1, keepdims=True)
        p = np.exp(scores - m)
        p /= np.sum(p, axis=-1, keepdims=True)
        expected_output = np.matmul(p, v_data)

        return q_data, k_data, v_data, expected_output
    else:
        raise FileNotFoundError("CRITICAL: Real Gemma tensors not found.")

@cocotb.test()
async def core_mini_rvv_flashattention_test(dut):
    r = runfiles.Create()
    
    # The 512KB memory map shifts CSRs to 0x200000
    fixture = await Fixture.Create(dut, csr_base_addr=0x200000)

    elf_name = "rvv_flashattention_test.elf"
    elf_path = r.Rlocation(f"coralnpu_hw/tests/cocotb/rvv/ml_ops/{elf_name}")

    await fixture.load_elf_and_lookup_symbols(
        elf_path, ["q_buf", "k_buf", "v_buf", "o_buf", "csr_cycle_count"]
    )

    num_heads_val = 4
    seq_len_val = 32
    d_val = 32

    dut._log.info(f"Loading tensors for shape: {num_heads_val}x{seq_len_val}x{d_val}")
    q_data, k_data, v_data, expected_output = load_real_attention_data(num_heads_val, seq_len_val, d_val, dut, r)

    await fixture.core_mini_axi.reset()

    await fixture.write("q_buf", q_data.flatten())
    await fixture.write("k_buf", k_data.flatten())
    await fixture.write("v_buf", v_data.flatten())
    await fixture.write("o_buf", np.zeros_like(q_data).flatten())

    await fixture.run_to_halt(timeout_cycles=4000000)

    csr_cycle_count = (await fixture.read_word('csr_cycle_count')).view(np.uint32)[0]

    log_matmul_metrics(dut, f"core_mini_rvv_flashattention_{num_heads_val}x{seq_len_val}x{d_val}", 
                       csr_cycle_count, num_heads_val, 2 * seq_len_val, d_val, seq_len_val)

    num_bytes = num_heads_val * seq_len_val * d_val * 4
    actual_packed = await fixture.read("o_buf", num_bytes)
    actual_output = actual_packed.view(np.float32).reshape(num_heads_val, seq_len_val, d_val)

    cos_sim = calculate_cosine_similarity(actual_output, expected_output)
    dut._log.info(f"Average Cosine Similarity to Multi-Head Golden Model: {cos_sim:.6f}")

    assert cos_sim > 0.999, "Accuracy failure against model!"
