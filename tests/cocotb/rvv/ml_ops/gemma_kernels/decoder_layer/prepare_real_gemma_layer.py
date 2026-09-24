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
"""Prepare real Gemma 3 270M layer-0 data for the CoralNPU test."""

import argparse
import json
import os

import numpy as np
import torch
import transformers
from transformers import AutoModelForCausalLM, AutoTokenizer


WEIGHT_MAP = {
    "gemma_input_layernorm_weight":
        "model.layers.0.input_layernorm.weight",
    "gemma_q_norm_weight": "model.layers.0.self_attn.q_norm.weight",
    "gemma_k_norm_weight": "model.layers.0.self_attn.k_norm.weight",
    "gemma_post_attention_layernorm_weight":
        "model.layers.0.post_attention_layernorm.weight",
    "gemma_pre_feedforward_layernorm_weight":
        "model.layers.0.pre_feedforward_layernorm.weight",
    "gemma_post_feedforward_layernorm_weight":
        "model.layers.0.post_feedforward_layernorm.weight",
    "gemma_q_proj_weight": "model.layers.0.self_attn.q_proj.weight",
    "gemma_k_proj_weight": "model.layers.0.self_attn.k_proj.weight",
    "gemma_v_proj_weight": "model.layers.0.self_attn.v_proj.weight",
    "gemma_o_proj_weight": "model.layers.0.self_attn.o_proj.weight",
    "gemma_gate_proj_weight": "model.layers.0.mlp.gate_proj.weight",
    "gemma_up_proj_weight": "model.layers.0.mlp.up_proj.weight",
    "gemma_down_proj_weight": "model.layers.0.mlp.down_proj.weight",
}

MATRIX_SYMBOLS = {
    "gemma_q_proj_weight",
    "gemma_k_proj_weight",
    "gemma_v_proj_weight",
    "gemma_o_proj_weight",
    "gemma_gate_proj_weight",
    "gemma_up_proj_weight",
    "gemma_down_proj_weight",
}


def _to_bf16_u16(tensor):
    """Return a NumPy uint16 array containing the tensor's BF16 bits."""
    tensor = tensor.detach().to(torch.bfloat16).contiguous().cpu()
    return tensor.view(torch.int16).numpy().view(np.uint16)


def _extract_layer_cache(cache, layer_index):
    if hasattr(cache, "layers"):
        layer = cache.layers[layer_index]
        for key_name, value_name in (
            ("keys", "values"),
            ("key_cache", "value_cache"),
        ):
            if hasattr(layer, key_name) and hasattr(layer, value_name):
                return getattr(layer, key_name), getattr(layer, value_name)

    if hasattr(cache, "key_cache") and hasattr(cache, "value_cache"):
        return cache.key_cache[layer_index], cache.value_cache[layer_index]

    layer = cache[layer_index]
    return layer[0], layer[1]


def _validate_config(config):
    expected = {
        "hidden_size": 640,
        "intermediate_size": 2048,
        "num_attention_heads": 4,
        "num_key_value_heads": 1,
        "head_dim": 256,
    }
    for name, value in expected.items():
        actual = getattr(config, name)
        if actual != value:
            raise ValueError(f"Expected {name}={value}, got {actual}")


def prepare_layer(model_dir, output_dir, prompt):
    with open(os.path.join(model_dir, "config.json")) as config_file:
        raw_config = json.load(config_file)

    tokenizer = AutoTokenizer.from_pretrained(
        model_dir, local_files_only=True
    )
    causal_lm = AutoModelForCausalLM.from_pretrained(
        model_dir,
        local_files_only=True,
        dtype=torch.bfloat16,
        attn_implementation="eager",
    )
    causal_lm.eval()
    _validate_config(causal_lm.config)

    encoded = tokenizer(prompt, return_tensors="pt", add_special_tokens=True)
    input_ids = encoded["input_ids"]
    if input_ids.shape[1] < 4:
        raise ValueError("Prompt must produce at least four tokens")
    input_ids = input_ids[:, :4]
    prefix_ids = input_ids[:, :3]
    decode_id = input_ids[:, 3:4]

    backbone = causal_lm.model
    with torch.no_grad():
        prefix_output = backbone(
            input_ids=prefix_ids,
            attention_mask=torch.ones_like(prefix_ids),
            use_cache=True,
            output_hidden_states=True,
            return_dict=True,
        )
        layer0_k_cache, layer0_v_cache = _extract_layer_cache(
            prefix_output.past_key_values, 0
        )
        layer0_k_cache = layer0_k_cache.clone()
        layer0_v_cache = layer0_v_cache.clone()

        decode_output = backbone(
            input_ids=decode_id,
            attention_mask=torch.ones(
                (1, input_ids.shape[1]), dtype=torch.long
            ),
            past_key_values=prefix_output.past_key_values,
            use_cache=True,
            output_hidden_states=True,
            return_dict=True,
        )

    hidden_input = decode_output.hidden_states[0][0, 0]
    hf_layer_output = decode_output.hidden_states[1][0, 0]

    os.makedirs(output_dir, exist_ok=True)
    state_dict = causal_lm.state_dict()
    manifest_weights = {}
    for symbol, state_name in WEIGHT_MAP.items():
        tensor = state_dict[state_name]
        source_shape = list(tensor.shape)
        if symbol in MATRIX_SYMBOLS:
            tensor = tensor.transpose(0, 1).contiguous()
        data = _to_bf16_u16(tensor)
        filename = f"{symbol}.npy"
        np.save(os.path.join(output_dir, filename), data)
        manifest_weights[symbol] = {
            "file": filename,
            "source": state_name,
            "source_shape": source_shape,
            "kernel_shape": list(data.shape),
        }

    np.save(
        os.path.join(output_dir, "gemma_hidden_input.npy"),
        _to_bf16_u16(hidden_input),
    )
    np.save(
        os.path.join(output_dir, "gemma_k_cache.npy"),
        _to_bf16_u16(layer0_k_cache[0]),
    )
    np.save(
        os.path.join(output_dir, "gemma_v_cache.npy"),
        _to_bf16_u16(layer0_v_cache[0]),
    )
    np.save(
        os.path.join(output_dir, "hf_layer_output.npy"),
        _to_bf16_u16(hf_layer_output),
    )
    np.save(
        os.path.join(output_dir, "token_ids.npy"),
        input_ids.cpu().numpy().astype(np.int64),
    )

    manifest = {
        "model_dir": os.path.abspath(model_dir),
        "prompt": prompt,
        "token_ids": input_ids[0].tolist(),
        "decoded_tokens": [
            tokenizer.decode([token_id]) for token_id in input_ids[0].tolist()
        ],
        "prefix_length": 3,
        "position": 3,
        "rope_theta": raw_config["rope_local_base_freq"],
        "epsilon": causal_lm.config.rms_norm_eps,
        "torch_version": torch.__version__,
        "transformers_version": transformers.__version__,
        "weights": manifest_weights,
    }
    with open(os.path.join(output_dir, "manifest.json"), "w") as handle:
        json.dump(manifest, handle, indent=2)

    print(f"Prepared real Gemma layer-0 data in {output_dir}")
    print(f"Token IDs: {manifest['token_ids']}")
    print(f"Decoded tokens: {manifest['decoded_tokens']}")
    print(f"Layer-0 K cache shape: {list(layer0_k_cache[0].shape)}")
    print(f"Layer-0 V cache shape: {list(layer0_v_cache[0].shape)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model_dir", required=True)
    parser.add_argument("--output_dir", required=True)
    parser.add_argument(
        "--prompt",
        default="The Coral NPU is designed for efficient neural inference.",
    )
    args = parser.parse_args()
    prepare_layer(args.model_dir, args.output_dir, args.prompt)


if __name__ == "__main__":
    main()
