"""End-to-end BF16 test for one Gemma 3 270M decoder layer."""

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


def _bf16(value):
    return np.asarray(value, dtype=np.float32).astype(ml_dtypes.bfloat16)


def _fp32(value):
    return np.asarray(value).astype(np.float32)


def _bf16_matmul(lhs, rhs):
    return _bf16(np.matmul(_fp32(lhs), _fp32(rhs)))


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
    # Keep the operation grouping aligned with rvv_tanh_gelu_mul.cc. The
    # kernel widens BF16 inputs, forms x^2, uses an FMA for the polynomial,
    # and then accumulates 0.5*x*up*(1+tanh) from an intermediate product.
    gate_squared = gate_f32 * gate_f32
    z_polynomial = np.float32(0.79788456) + np.float32(0.035677408) * gate_squared
    z = gate_f32 * z_polynomial
    y = np.clip(z, np.float32(-3.0), np.float32(3.0))
    tanh_approx = y * (y * y + np.float32(27.0)) / (
        np.float32(9.0) * y * y + np.float32(27.0)
    )
    product = gate_f32 * up_f32
    product = product * np.float32(0.5)
    return _bf16(product + product * tanh_approx)


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
    """Write a large tensor directly to the simulated AXI memory array."""
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
):
    r = runfiles.Create()
    fixture = await Fixture.Create(
        dut,
        highmem=True,
        ext_mem_base_addr=0x80000000,
        ext_mem_size=32 * 1024 * 1024,
    )
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_kernels/decoder_layer/"
        "rvv_bf16_gemma_decoder_layer.elf"
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
        "cycle_count",
        "layer_status",
    ]
    await fixture.load_elf_and_lookup_symbols(
        elf_path, list(dict.fromkeys(tensor_symbols + control_symbols))
    )
    await fixture.core_mini_axi.reset()

    _write_extmem(fixture, "gemma_hidden_input", hidden_input)
    for symbol, value in weights.items():
        _write_extmem(fixture, symbol, value)
    _write_extmem(fixture, "gemma_k_cache", k_cache)
    _write_extmem(fixture, "gemma_v_cache", v_cache)

    await fixture.write(
        "active_position", np.array([position], dtype=np.uint32)
    )
    await fixture.write(
        "active_cache_length", np.array([cache_length], dtype=np.uint32)
    )
    await fixture.write("active_epsilon", np.array([EPSILON], dtype=np.float32))
    await fixture.write(
        "active_rope_theta", np.array([ROPE_THETA], dtype=np.float32)
    )

    dut._log.info(f"Running {label}")
    await fixture.run_to_halt(timeout_cycles=40000000)

    status = int((await fixture.read_word("layer_status")).view(np.int32)[0])
    cycles = int((await fixture.read_word("cycle_count")).view(np.uint32)[0])
    assert status == 0
    dut._log.info(f"Full decoder layer completed in {cycles} NPU cycles")

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
    actual_layer_output = None
    actual_values = {}
    for symbol, golden in expected.items():
        actual = await _read_bf16(fixture, symbol, golden.size)
        actual_f32 = _fp32(actual).reshape(golden.shape)
        golden_f32 = _fp32(golden)
        actual_values[symbol] = actual_f32
        max_error = float(np.max(np.abs(actual_f32 - golden_f32)))
        dut._log.info(f"{symbol}: max_abs_error={max_error:.6f}")
        atol = tolerances.get(symbol, 0.03)
        if max_error > atol + 0.03 * float(np.max(np.abs(golden_f32))):
            mismatch = np.argwhere(
                np.abs(actual_f32 - golden_f32)
                > atol + 0.03 * np.abs(golden_f32)
            )
            dut._log.warning(
                f"{symbol}: first mismatches="
                f"{mismatch[:8].reshape(-1).tolist()}"
            )
            for index in mismatch[:8].reshape(-1):
                flat_index = int(index)
                dut._log.warning(
                    f"{symbol}[{flat_index}]: "
                    f"actual={actual_f32.flat[flat_index]:.8f}, "
                    f"golden={golden_f32.flat[flat_index]:.8f}, "
                    f"abs_error={abs(actual_f32.flat[flat_index] - golden_f32.flat[flat_index]):.8f}"
                )
                if symbol == "gemma_gelu_output":
                    dut._log.warning(
                        f"  gate={actual_values['gemma_gate_projection'].flat[flat_index]:.8f}, "
                        f"up={actual_values['gemma_up_projection'].flat[flat_index]:.8f}"
                    )
        np.testing.assert_allclose(
            actual_f32, golden_f32, rtol=0.03, atol=atol
        )
        if symbol == "gemma_layer_output":
            actual_layer_output = actual_f32

    if hf_layer_output is not None:
        hf_output_f32 = _fp32(hf_layer_output).reshape(-1)
        npu_output_f32 = actual_layer_output.reshape(-1)
        max_error = float(np.max(np.abs(npu_output_f32 - hf_output_f32)))
        mean_error = float(np.mean(np.abs(npu_output_f32 - hf_output_f32)))
        cosine = float(
            np.dot(npu_output_f32, hf_output_f32)
            / (
                np.linalg.norm(npu_output_f32)
                * np.linalg.norm(hf_output_f32)
            )
        )
        dut._log.info(
            "CoralNPU vs Hugging Face layer output: "
            f"cosine={cosine:.8f}, mean_abs_error={mean_error:.6f}, "
            f"max_abs_error={max_error:.6f}"
        )
        assert cosine > 0.99


@cocotb.test()
async def core_mini_rvv_bf16_gemma_decoder_layer_test(dut):
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
    )
