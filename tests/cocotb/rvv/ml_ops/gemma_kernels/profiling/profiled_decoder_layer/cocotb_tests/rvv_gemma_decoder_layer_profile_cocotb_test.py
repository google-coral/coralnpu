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
"""End-to-end BF16 and cycle-comparison tests for one Gemma 3 270M decoder layer."""

import json
import os

import cocotb
import ml_dtypes
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture


HIDDEN_SIZE = 640
INTERMEDIATE_SIZE = 2048
NUM_QUERY_HEADS = 4
NUM_KV_HEADS = 1
HEAD_DIM = 256
QUERY_SIZE = NUM_QUERY_HEADS * HEAD_DIM
KV_SIZE = NUM_KV_HEADS * HEAD_DIM
MAX_CACHE_LENGTH = 64
EPSILON = np.float32(1e-6)
ROPE_THETA = np.float32(10000.0)

# Keep this order identical to the C++ DecoderLayerStage enum.
DECODER_STAGE_NAMES = (
    "input_rms_norm",
    "q_projection",
    "k_projection",
    "v_projection",
    "q_rms_norm",
    "k_rms_norm",
    "rope",
    "cache_append",
    "flash_attention",
    "output_projection",
    "post_attention_rms_norm",
    "post_attention_residual_add",
    "pre_feedforward_rms_norm",
    "gate_projection",
    "up_projection",
    "tanh_gelu_mul",
    "down_projection",
    "post_feedforward_rms_norm",
    "post_feedforward_residual_add",
)

RUN_MODE_WHOLE = 0
RUN_MODE_PROFILED_STAGES = 1
RUN_MODE_NAMES = {
    RUN_MODE_WHOLE: "whole_layer_without_internal_timers",
    RUN_MODE_PROFILED_STAGES: "individual_profiled_stages",
}


def _stage_macs(cache_length):
    """Return algorithmic MAC counts for matrix stages in layer 0.

    A matrix multiply has M*K*N MACs; decode uses M=1. FlashAttention
    includes both QK^T and probability*V, so its count is
    2*q_heads*q_len*kv_len*head_dim. RMSNorm, RoPE, GELU, and residual add
    are not pure matrix multiplies, so report them as cycles/element instead.
    """
    attention_length = cache_length + 1
    return {
        "q_projection": HIDDEN_SIZE * QUERY_SIZE,
        "k_projection": HIDDEN_SIZE * KV_SIZE,
        "v_projection": HIDDEN_SIZE * KV_SIZE,
        "flash_attention": (
            2 * NUM_QUERY_HEADS * attention_length * HEAD_DIM
        ),
        "output_projection": QUERY_SIZE * HIDDEN_SIZE,
        "gate_projection": HIDDEN_SIZE * INTERMEDIATE_SIZE,
        "up_projection": HIDDEN_SIZE * INTERMEDIATE_SIZE,
        "down_projection": INTERMEDIATE_SIZE * HIDDEN_SIZE,
    }


STAGE_ELEMENTS = {
    "input_rms_norm": HIDDEN_SIZE,
    "q_rms_norm": QUERY_SIZE,
    "k_rms_norm": KV_SIZE,
    "rope": QUERY_SIZE + KV_SIZE,
    "cache_append": 2 * KV_SIZE,
    "post_attention_rms_norm": HIDDEN_SIZE,
    "post_attention_residual_add": HIDDEN_SIZE,
    "pre_feedforward_rms_norm": HIDDEN_SIZE,
    "tanh_gelu_mul": INTERMEDIATE_SIZE,
    "post_feedforward_rms_norm": HIDDEN_SIZE,
    "post_feedforward_residual_add": HIDDEN_SIZE,
}


def _bf16(value):
    return np.asarray(value, dtype=np.float32).astype(ml_dtypes.bfloat16)


def _fp32(value):
    return np.asarray(value).astype(np.float32)


def _bf16_matmul(lhs, rhs):
    return _bf16(np.matmul(_fp32(lhs), _fp32(rhs)))


def _pack_bf16_segment2(value):
    """Pack a [K, N] projection for the segment-2 GeMV schedule."""
    bits = np.asarray(value).reshape(value.shape).view(np.uint16)
    K, N = bits.shape
    if N % 64:
        raise ValueError("segment-2 projection packing requires N divisible by 64")
    packed = np.empty_like(bits)
    for c in range(0, N, 64):
        packed[:, c:c + 64:2] = bits[:, c:c + 32]
        packed[:, c + 1:c + 64:2] = bits[:, c + 32:c + 64]
    return packed.view(ml_dtypes.bfloat16)


def _pack_bf16_block_segment2(value):
    """Pack a [K, N] projection into block-major segment-2 storage."""
    bits = np.asarray(value).reshape(value.shape).view(np.uint16)
    K, N = bits.shape
    if N % 64:
        raise ValueError(
            "block segment-2 projection packing requires N divisible by 64"
        )
    packed = np.empty((N // 64, K, 64), dtype=bits.dtype)
    for block, c in enumerate(range(0, N, 64)):
        packed[block, :, 0::2] = bits[:, c:c + 32]
        packed[block, :, 1::2] = bits[:, c + 32:c + 64]
    return packed.reshape(K, N).view(ml_dtypes.bfloat16)


def _rms_norm(value, weight):
    value_f32 = _fp32(value)
    weight_f32 = _fp32(weight)
    inv_rms = np.float32(1.0) / np.sqrt(
        np.mean(value_f32 * value_f32, axis=-1, keepdims=True) + EPSILON
    )
    return _bf16(value_f32 * inv_rms * (np.float32(1.0) + weight_f32))


def _apply_rope(q, k, position):
    index = np.arange(HEAD_DIM // 2, dtype=np.float32)
    inv_frequency = np.power(
        ROPE_THETA, -(np.float32(2.0) * index / np.float32(HEAD_DIM))
    )
    angle = np.float32(position) * inv_frequency
    cos_value = np.cos(angle).astype(np.float32)
    sin_value = np.sin(angle).astype(np.float32)

    def rotate(value):
        value_f32 = _fp32(value).reshape(-1, HEAD_DIM)
        first = value_f32[:, :HEAD_DIM // 2]
        second = value_f32[:, HEAD_DIM // 2:]
        return _bf16(
            np.concatenate(
                [
                    first * cos_value - second * sin_value,
                    second * cos_value + first * sin_value,
                ],
                axis=-1,
            )
        ).reshape(value.shape)

    return rotate(q), rotate(k)


def _approximate_exp(value):
    value = np.maximum(np.asarray(value, dtype=np.float32), np.float32(-88.0))
    scaled = value * np.float32(1.4426950408889634)
    exponent = np.rint(scaled).astype(np.int32)
    remainder = value - exponent.astype(np.float32) * np.float32(0.6931471805599453)
    polynomial = remainder * np.float32(0.16666667) + np.float32(0.5)
    polynomial = np.float32(1.0) + remainder * polynomial
    polynomial = np.float32(1.0) + remainder * polynomial
    return np.ldexp(polynomial, exponent).astype(np.float32)


def _flash_attention(q, k, v):
    q_f32 = _fp32(q).reshape(NUM_QUERY_HEADS, 1, HEAD_DIM)
    k_f32 = _fp32(k).reshape(NUM_KV_HEADS, -1, HEAD_DIM)
    v_f32 = _fp32(v).reshape(NUM_KV_HEADS, -1, HEAD_DIM)
    output = np.empty_like(q_f32)
    scale = np.float32(1.0 / np.sqrt(HEAD_DIM))

    for head in range(NUM_QUERY_HEADS):
        kv_head = head % NUM_KV_HEADS
        scores = np.matmul(q_f32[head], k_f32[kv_head].T) * scale
        scores -= np.max(scores, axis=-1, keepdims=True)
        probabilities = _approximate_exp(scores)
        probabilities /= np.sum(probabilities, axis=-1, keepdims=True)
        output[head] = np.matmul(probabilities, v_f32[kv_head])

    return _bf16(output.reshape(QUERY_SIZE))


def _tanh_gelu_mul(gate, up):
    gate_f32 = _fp32(gate)
    up_f32 = _fp32(up)
    z = gate_f32 * (
        np.float32(0.79788456)
        + np.float32(0.035677408) * gate_f32 * gate_f32
    )
    y = np.clip(z, np.float32(-3.0), np.float32(3.0))
    tanh_approx = y * (y * y + np.float32(27.0)) / (
        np.float32(9.0) * y * y + np.float32(27.0)
    )
    return _bf16(
        np.float32(0.5)
        * gate_f32
        * up_f32
        * (np.float32(1.0) + tanh_approx)
    )


def _residual_add(lhs, rhs):
    return _bf16(_fp32(lhs) + _fp32(rhs))


def _make_test_data():
    rng = np.random.default_rng(seed=42)

    def random_bf16(shape, scale):
        return _bf16(rng.normal(0.0, scale, shape).astype(np.float32))

    weights = {
        "gemma_input_layernorm_weight": random_bf16((HIDDEN_SIZE,), 0.02),
        "gemma_q_norm_weight": random_bf16((HEAD_DIM,), 0.02),
        "gemma_k_norm_weight": random_bf16((HEAD_DIM,), 0.02),
        "gemma_post_attention_layernorm_weight": random_bf16(
            (HIDDEN_SIZE,), 0.02
        ),
        "gemma_pre_feedforward_layernorm_weight": random_bf16(
            (HIDDEN_SIZE,), 0.02
        ),
        "gemma_post_feedforward_layernorm_weight": random_bf16(
            (HIDDEN_SIZE,), 0.02
        ),
        "gemma_q_proj_weight": random_bf16((HIDDEN_SIZE, QUERY_SIZE), 0.02),
        "gemma_k_proj_weight": random_bf16((HIDDEN_SIZE, KV_SIZE), 0.02),
        "gemma_v_proj_weight": random_bf16((HIDDEN_SIZE, KV_SIZE), 0.02),
        "gemma_o_proj_weight": random_bf16((QUERY_SIZE, HIDDEN_SIZE), 0.02),
        "gemma_gate_proj_weight": random_bf16(
            (HIDDEN_SIZE, INTERMEDIATE_SIZE), 0.02
        ),
        "gemma_up_proj_weight": random_bf16(
            (HIDDEN_SIZE, INTERMEDIATE_SIZE), 0.02
        ),
        "gemma_down_proj_weight": random_bf16(
            (INTERMEDIATE_SIZE, HIDDEN_SIZE), 0.02
        ),
    }
    hidden_input = random_bf16((HIDDEN_SIZE,), 0.2)
    cache_length = 3
    position = cache_length
    k_cache = np.zeros((MAX_CACHE_LENGTH, HEAD_DIM), dtype=ml_dtypes.bfloat16)
    v_cache = np.zeros((MAX_CACHE_LENGTH, HEAD_DIM), dtype=ml_dtypes.bfloat16)
    k_cache[:cache_length] = random_bf16((cache_length, HEAD_DIM), 0.4)
    v_cache[:cache_length] = random_bf16((cache_length, HEAD_DIM), 0.2)
    return weights, hidden_input, k_cache, v_cache, cache_length, position


def _golden_layer(weights, hidden_input, k_cache, v_cache, cache_length, position):
    expected = {}
    expected["gemma_input_norm"] = _rms_norm(
        hidden_input, weights["gemma_input_layernorm_weight"]
    )
    expected["gemma_q_projection"] = _bf16_matmul(
        expected["gemma_input_norm"], weights["gemma_q_proj_weight"]
    )
    expected["gemma_k_projection"] = _bf16_matmul(
        expected["gemma_input_norm"], weights["gemma_k_proj_weight"]
    )
    expected["gemma_v_projection"] = _bf16_matmul(
        expected["gemma_input_norm"], weights["gemma_v_proj_weight"]
    )

    q_norm = _rms_norm(
        expected["gemma_q_projection"].reshape(NUM_QUERY_HEADS, HEAD_DIM),
        weights["gemma_q_norm_weight"],
    )
    k_norm = _rms_norm(
        expected["gemma_k_projection"].reshape(NUM_KV_HEADS, HEAD_DIM),
        weights["gemma_k_norm_weight"],
    )
    q_rope, k_rope = _apply_rope(q_norm, k_norm, position)
    expected["gemma_q_rope"] = q_rope.reshape(QUERY_SIZE)
    expected["gemma_k_rope"] = k_rope.reshape(KV_SIZE)

    expected_k_cache = k_cache.copy()
    expected_v_cache = v_cache.copy()
    expected_k_cache[cache_length] = expected["gemma_k_rope"]
    expected_v_cache[cache_length] = expected["gemma_v_projection"]
    active_k_cache = expected_k_cache[:cache_length + 1]
    active_v_cache = expected_v_cache[:cache_length + 1]
    expected["gemma_k_cache"] = active_k_cache
    expected["gemma_v_cache"] = active_v_cache

    expected["gemma_attention_output"] = _flash_attention(
        expected["gemma_q_rope"], active_k_cache, active_v_cache
    )
    expected["gemma_attention_projection"] = _bf16_matmul(
        expected["gemma_attention_output"], weights["gemma_o_proj_weight"]
    )
    expected["gemma_post_attention_norm"] = _rms_norm(
        expected["gemma_attention_projection"],
        weights["gemma_post_attention_layernorm_weight"],
    )
    expected["gemma_post_attention_residual"] = _residual_add(
        hidden_input, expected["gemma_post_attention_norm"]
    )
    expected["gemma_pre_feedforward_norm"] = _rms_norm(
        expected["gemma_post_attention_residual"],
        weights["gemma_pre_feedforward_layernorm_weight"],
    )
    expected["gemma_gate_projection"] = _bf16_matmul(
        expected["gemma_pre_feedforward_norm"],
        weights["gemma_gate_proj_weight"],
    )
    expected["gemma_up_projection"] = _bf16_matmul(
        expected["gemma_pre_feedforward_norm"], weights["gemma_up_proj_weight"]
    )
    expected["gemma_gelu_output"] = _tanh_gelu_mul(
        expected["gemma_gate_projection"], expected["gemma_up_projection"]
    )
    expected["gemma_down_projection"] = _bf16_matmul(
        expected["gemma_gelu_output"], weights["gemma_down_proj_weight"]
    )
    expected["gemma_post_feedforward_norm"] = _rms_norm(
        expected["gemma_down_projection"],
        weights["gemma_post_feedforward_layernorm_weight"],
    )
    expected["gemma_layer_output"] = _residual_add(
        expected["gemma_post_attention_residual"],
        expected["gemma_post_feedforward_norm"],
    )
    return expected


def _write_extmem(fixture, symbol, value):
    """Write contiguous tensor bytes to simulated AXI DDR at an ELF symbol address."""
    byte_view = np.ascontiguousarray(value).view(np.uint8).reshape(-1)
    address = fixture.symbols[symbol]
    offset = address - fixture.core_mini_axi.memory_base_addr
    end = offset + byte_view.size
    assert offset >= 0 and end <= fixture.core_mini_axi.memory.size
    fixture.core_mini_axi.memory[offset:end] = byte_view


async def _read_bf16(fixture, symbol, element_count):
    data = await fixture.read(symbol, element_count * 2)
    return data.view(np.uint16).view(ml_dtypes.bfloat16)


async def _run_decoder_layer(
    dut,
    weights,
    hidden_input,
    k_cache,
    v_cache,
    cache_length,
    position,
    expected,
    label,
    hf_layer_output=None,
    run_modes=(RUN_MODE_PROFILED_STAGES,),
):
    """Run one or two timing modes with the same ELF, DDR addresses, and data.

    When ``run_modes`` contains both whole-layer and profiled-stage modes, reset
    the complete DUT and rewrite all inputs, real weights, initial K/V caches,
    and output buffers before each run. The only difference is then the C++
    entry path rather than weights or addresses.
    """
    r = runfiles.Create()
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024,
    )
    elf_name = os.environ.get(
        "GEMMA_PROFILE_ELF", "rvv_bf16_gemma_decoder_layer_profile.elf"
    )
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profiled_decoder_layer/"
        f"{elf_name}"
    )
    if not elf_path or not os.path.exists(elf_path):
        raise FileNotFoundError(f"Could not find ELF at {elf_path}")

    tensor_symbols = [
        "gemma_hidden_input",
        *weights.keys(),
        "gemma_k_cache",
        "gemma_v_cache",
        *expected.keys(),
    ]
    control_symbols = [
        "active_position",
        "active_cache_length",
        "active_epsilon",
        "active_rope_theta",
        "active_run_mode",
        "cycle_count",
        "cycle_count_corrected",
        "mcycle_read_overhead_cycles",
        "stage_cycle_sum_raw",
        "stage_cycle_sum_corrected",
        "layer_status",
        "gemma_stage_cycles",
    ]
    await fixture.load_elf_and_lookup_symbols(
        elf_path, list(dict.fromkeys(tensor_symbols + control_symbols))
    )

    tolerances = {
        "gemma_q_rope": 0.04,
        "gemma_k_rope": 0.04,
        "gemma_attention_output": 0.05,
        "gemma_attention_projection": 0.06,
        "gemma_post_attention_norm": 0.08,
        "gemma_post_attention_residual": 0.08,
        "gemma_pre_feedforward_norm": 0.08,
        "gemma_gate_projection": 0.08,
        "gemma_up_projection": 0.08,
        "gemma_gelu_output": 0.08,
        "gemma_down_projection": 0.10,
        "gemma_post_feedforward_norm": 0.15,
        "gemma_layer_output": 0.15,
    }
    results = {}
    stage_macs = _stage_macs(cache_length)

    for run_mode in run_modes:
        if run_mode not in RUN_MODE_NAMES:
            raise ValueError(f"Unknown decoder run mode: {run_mode}")
        mode_name = RUN_MODE_NAMES[run_mode]

        # A full reset clears core/cache state. Rewrite the same DDR contents and
        # explicitly clear output buffers so later runs see no stale data.
        await fixture.core_mini_axi.reset()
        _write_extmem(fixture, "gemma_hidden_input", hidden_input)
        pack_projections = bool(os.environ.get("GEMMA_PACKED_PROJECTIONS"))
        pack_block_projections = bool(
            os.environ.get("GEMMA_BLOCK_PACKED_PROJECTIONS")
        )
        for symbol, value in weights.items():
            value_to_write = value
            if pack_projections and symbol.endswith("_proj_weight"):
                value_to_write = _pack_bf16_segment2(value)
            if pack_block_projections and symbol.endswith("_proj_weight"):
                value_to_write = _pack_bf16_block_segment2(value)
            _write_extmem(fixture, symbol, value_to_write)
        _write_extmem(fixture, "gemma_k_cache", k_cache)
        _write_extmem(fixture, "gemma_v_cache", v_cache)
        for symbol, golden in expected.items():
            if symbol not in ("gemma_k_cache", "gemma_v_cache"):
                _write_extmem(
                    fixture,
                    symbol,
                    np.zeros(golden.shape, dtype=np.uint16),
                )

        await fixture.write(
            "active_position", np.array([position], dtype=np.uint32)
        )
        await fixture.write(
            "active_cache_length", np.array([cache_length], dtype=np.uint32)
        )
        await fixture.write(
            "active_epsilon", np.array([EPSILON], dtype=np.float32)
        )
        await fixture.write(
            "active_rope_theta", np.array([ROPE_THETA], dtype=np.float32)
        )
        await fixture.write(
            "active_run_mode", np.array([run_mode], dtype=np.uint32)
        )

        dut._log.info(f"Running {label}; mode={mode_name}")
        await fixture.run_to_halt(timeout_cycles=40000000)

        status = int(
            (await fixture.read_word("layer_status")).view(np.int32)[0]
        )
        cycles_raw = int(
            (await fixture.read_word("cycle_count")).view(np.uint32)[0]
        )
        cycles_corrected = int(
            (await fixture.read_word("cycle_count_corrected")).view(
                np.uint32
            )[0]
        )
        read_overhead = int(
            (await fixture.read_word("mcycle_read_overhead_cycles")).view(
                np.uint32
            )[0]
        )
        stage_sum_raw_from_elf = int(
            (await fixture.read_word("stage_cycle_sum_raw")).view(np.uint32)[0]
        )
        stage_sum_corrected = int(
            (await fixture.read_word("stage_cycle_sum_corrected")).view(
                np.uint32
            )[0]
        )
        stage_cycles = (
            await fixture.read(
                "gemma_stage_cycles", len(DECODER_STAGE_NAMES) * 4
            )
        ).view(np.uint32)
        assert status == 0
        assert cycles_corrected == max(cycles_raw - read_overhead, 0)

        dut._log.info(
            "REAL_GEMMA_RUN "
            f"mode={mode_name} cycles_raw={cycles_raw} "
            f"mcycle_read_overhead={read_overhead} "
            f"cycles_corrected={cycles_corrected}"
        )

        if run_mode == RUN_MODE_PROFILED_STAGES:
            stage_sum_raw = int(np.sum(stage_cycles, dtype=np.uint64))
            assert stage_sum_raw == stage_sum_raw_from_elf
            corrected_by_python = int(
                sum(max(int(value) - read_overhead, 0) for value in stage_cycles)
            )
            assert corrected_by_python == stage_sum_corrected
            for stage_name, stage_cycle in zip(
                DECODER_STAGE_NAMES, stage_cycles
            ):
                raw = int(stage_cycle)
                corrected = max(raw - read_overhead, 0)
                dut._log.info(
                    f"Decoder stage cycle: {stage_name}={raw}"
                )
                if stage_name in stage_macs:
                    macs = stage_macs[stage_name]
                    macs_per_cycle = macs / corrected if corrected else 0.0
                    dut._log.info(
                        "REAL_GEMMA_STAGE_METRIC "
                        f"stage={stage_name} cycles_raw={raw} "
                        f"cycles_corrected={corrected} macs={macs} "
                        f"macs_per_cycle={macs_per_cycle:.8f}"
                    )
                elif stage_name in STAGE_ELEMENTS:
                    elements = STAGE_ELEMENTS[stage_name]
                    cycles_per_element = (
                        corrected / elements if elements else 0.0
                    )
                    dut._log.info(
                        "REAL_GEMMA_STAGE_METRIC "
                        f"stage={stage_name} cycles_raw={raw} "
                        f"cycles_corrected={corrected} elements={elements} "
                        f"cycles_per_element={cycles_per_element:.8f}"
                    )
            dut._log.info(f"Decoder stage cycle sum: {stage_sum_raw}")
            dut._log.info(
                f"Decoder corrected stage cycle sum: {stage_sum_corrected}"
            )
            dut._log.info(
                "Decoder profiled-path unattributed cycles: "
                f"{cycles_corrected - stage_sum_corrected}"
            )

        actual_layer_output = None
        actual_layer_output_bits = None
        for symbol, golden in expected.items():
            actual = await _read_bf16(fixture, symbol, golden.size)
            actual_f32 = _fp32(actual).reshape(golden.shape)
            golden_f32 = _fp32(golden)
            max_error = float(np.max(np.abs(actual_f32 - golden_f32)))
            dut._log.info(
                f"mode={mode_name} {symbol}: max_abs_error={max_error:.6f}"
            )
            atol = tolerances.get(symbol, 0.03)
            if not os.environ.get("GEMMA_PROFILE_ONLY"):
                np.testing.assert_allclose(
                    actual_f32, golden_f32, rtol=0.03, atol=atol
                )
            if symbol == "gemma_layer_output":
                actual_layer_output = actual_f32.copy()
                actual_layer_output_bits = actual.view(np.uint16).copy()

        hf_metrics = None
        if hf_layer_output is not None:
            hf_output_f32 = _fp32(hf_layer_output).reshape(-1)
            npu_output_f32 = actual_layer_output.reshape(-1)
            max_error = float(
                np.max(np.abs(npu_output_f32 - hf_output_f32))
            )
            mean_error = float(
                np.mean(np.abs(npu_output_f32 - hf_output_f32))
            )
            cosine = float(
                np.dot(npu_output_f32, hf_output_f32)
                / (
                    np.linalg.norm(npu_output_f32)
                    * np.linalg.norm(hf_output_f32)
                )
            )
            hf_metrics = {
                "cosine": cosine,
                "mean_abs_error": mean_error,
                "max_abs_error": max_error,
            }
            dut._log.info(
                "CoralNPU vs Hugging Face layer output: "
                f"mode={mode_name} cosine={cosine:.8f}, "
                f"mean_abs_error={mean_error:.6f}, "
                f"max_abs_error={max_error:.6f}"
            )
            assert cosine > 0.99

        total_macs = sum(stage_macs.values())
        dut._log.info(
            "REAL_GEMMA_LAYER_METRIC "
            f"mode={mode_name} algorithmic_macs={total_macs} "
            f"cycles_corrected={cycles_corrected} "
            f"macs_per_cycle={total_macs / cycles_corrected:.8f}"
        )
        results[run_mode] = {
            "cycles_raw": cycles_raw,
            "cycles_corrected": cycles_corrected,
            "read_overhead": read_overhead,
            "stage_cycles": stage_cycles.copy(),
            "stage_sum_raw": stage_sum_raw_from_elf,
            "stage_sum_corrected": stage_sum_corrected,
            "layer_output_bits": actual_layer_output_bits,
            "hf_metrics": hf_metrics,
        }

    if (
        RUN_MODE_WHOLE in results
        and RUN_MODE_PROFILED_STAGES in results
    ):
        whole = results[RUN_MODE_WHOLE]
        profiled = results[RUN_MODE_PROFILED_STAGES]
        # Both paths invoke exactly the same kernels, so outputs must match bit
        # for bit. A small cycle difference from control flow is acceptable, but
        # numerical tolerances must not hide a path mismatch.
        np.testing.assert_array_equal(
            whole["layer_output_bits"], profiled["layer_output_bits"]
        )
        difference = (
            profiled["stage_sum_corrected"] - whole["cycles_corrected"]
        )
        relative = difference / whole["cycles_corrected"]
        profiling_bookkeeping = (
            profiled["cycles_corrected"]
            - profiled["stage_sum_corrected"]
        )
        dut._log.info(
            "REAL_GEMMA_COMPARISON "
            f"whole_corrected={whole['cycles_corrected']} "
            f"stage_sum_raw={profiled['stage_sum_raw']} "
            f"stage_sum_corrected={profiled['stage_sum_corrected']} "
            f"difference={difference} relative_difference={relative:.10f} "
            f"profiled_outer_corrected={profiled['cycles_corrected']} "
            f"profiling_bookkeeping={profiling_bookkeeping}"
        )
        # This guards performance consistency; mathematical zero cycles are not
        # required because function entry, configuration checks, and stage-array
        # writes do not all fall inside individual kernel timing windows.
        assert abs(relative) < 0.01

    return results


@cocotb.test()
async def core_mini_rvv_bf16_gemma_decoder_layer_profile_test(dut):
    if os.environ.get("GEMMA_LAYER0_DATA"):
        dut._log.info("Real Gemma data selected; skipping synthetic layer run")
        return

    weights, hidden_input, k_cache, v_cache, cache_length, position = (
        _make_test_data()
    )
    expected = _golden_layer(
        weights, hidden_input, k_cache, v_cache, cache_length, position
    )
    await _run_decoder_layer(
        dut,
        weights,
        hidden_input,
        k_cache,
        v_cache,
        cache_length,
        position,
        expected,
        "synthetic Gemma 3 270M decoder layer",
    )


def _load_bf16_npy(path):
    """Load uint16 data from the preparation script and reinterpret it as BF16 bits."""
    data = np.load(path)
    if data.dtype != np.uint16:
        raise ValueError(f"Expected uint16 BF16 data in {path}, got {data.dtype}")
    return data.view(ml_dtypes.bfloat16)


@cocotb.test()
async def core_mini_rvv_bf16_real_gemma_decoder_layer_test(dut):
    data_dir = os.environ.get("GEMMA_LAYER0_DATA")
    if not data_dir:
        dut._log.info("No real Gemma data selected; skipping real layer run")
        return

    manifest_path = os.path.join(data_dir, "manifest.json")
    with open(manifest_path) as manifest_file:
        manifest = json.load(manifest_file)

    weights = {
        symbol: _load_bf16_npy(
            os.path.join(data_dir, metadata["file"])
        )
        for symbol, metadata in manifest["weights"].items()
    }
    hidden_input = _load_bf16_npy(
        os.path.join(data_dir, "gemma_hidden_input.npy")
    )
    past_k_cache = _load_bf16_npy(
        os.path.join(data_dir, "gemma_k_cache.npy")
    ).reshape(-1, HEAD_DIM)
    past_v_cache = _load_bf16_npy(
        os.path.join(data_dir, "gemma_v_cache.npy")
    ).reshape(-1, HEAD_DIM)
    hf_layer_output = _load_bf16_npy(
        os.path.join(data_dir, "hf_layer_output.npy")
    )

    cache_length = int(manifest["prefix_length"])
    position = int(manifest["position"])
    assert cache_length == past_k_cache.shape[0]
    assert cache_length == past_v_cache.shape[0]
    assert np.isclose(float(manifest["rope_theta"]), float(ROPE_THETA))
    assert np.isclose(float(manifest["epsilon"]), float(EPSILON))

    k_cache = np.zeros(
        (MAX_CACHE_LENGTH, HEAD_DIM), dtype=ml_dtypes.bfloat16
    )
    v_cache = np.zeros(
        (MAX_CACHE_LENGTH, HEAD_DIM), dtype=ml_dtypes.bfloat16
    )
    k_cache[:cache_length] = past_k_cache
    v_cache[:cache_length] = past_v_cache
    expected = _golden_layer(
        weights, hidden_input, k_cache, v_cache, cache_length, position
    )

    dut._log.info(
        f"Real Gemma tokens: {manifest['decoded_tokens']}; "
        f"Torch {manifest['torch_version']}; "
        f"Transformers {manifest['transformers_version']}"
    )
    await _run_decoder_layer(
        dut,
        weights,
        hidden_input,
        k_cache,
        v_cache,
        cache_length,
        position,
        expected,
        "real Gemma 3 270M layer 0",
        hf_layer_output=hf_layer_output,
        run_modes=(RUN_MODE_WHOLE, RUN_MODE_PROFILED_STAGES),
    )
