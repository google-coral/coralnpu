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
"""为 CoralNPU 测试准备真实 Gemma 3 270M 第 0 层数据。

本脚本只从 ``--model_dir`` 指定的本地 Hugging Face 模型目录读取数据，不会从
网络下载权重。输出目录中的权重、hidden input、K/V cache 和参考输出全部保存为
NumPy 文件；``manifest.json`` 同时记录每个文件来自哪个 Hugging Face 参数。
"""

import argparse
import json
import os

import numpy as np
import torch
import transformers
from transformers import AutoModelForCausalLM, AutoTokenizer


# 左边是 C++ ELF 中的全局符号名，右边是 Hugging Face state_dict 的参数名。
# 这个映射是所有真实权重的来源清单，测试不会再用随机权重覆盖这些数据。
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

# Hugging Face Linear 层的权重 shape 是 [out_features, in_features]，而当前
# CoralNPU BF16 matmul kernel 按 [K, N] 连续读取。这里列出的矩阵在保存前必须
# 转置；RMSNorm 权重是一维向量，不需要转置。
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
    """把 PyTorch tensor 转成连续 BF16，并返回完全相同位型的 uint16 数组。

    ``view`` 只重新解释底层 16 bit，不进行第二次数值转换。因此写入 ``.npy`` 的
    每个 uint16 就是随后写入模拟 DDR 的 BF16 bit pattern。
    """
    tensor = tensor.detach().to(torch.bfloat16).contiguous().cpu()
    return tensor.view(torch.int16).numpy().view(np.uint16)


def _extract_layer_cache(cache, layer_index):
    """兼容不同 Transformers 版本的 cache 容器并取出指定层 K/V。

    Transformers 的 cache API 曾使用 ``layers[i].keys/values``、
    ``key_cache/value_cache`` 或 tuple 三种布局。这里只改变容器访问方式，不改变
    cache 张量内容。
    """
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
    """确认本地模型 shape 与 C++ Gemma 270M 固定缓冲区完全一致。"""
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
    """读取本地模型，生成单 token decode 所需的第 0 层完整测试夹具。

    前三个 token 用 Hugging Face 执行得到历史 K/V cache；第四个 token 再进行
    decode。decode 的 ``hidden_states[0]`` 是进入第 0 层之前的输入，
    ``hidden_states[1]`` 是离开第 0 层后的参考输出。这样 CoralNPU 接收到的层输入
    和 cache 与 Hugging Face 在同一个 token、同一个 position 上完全对应。
    """
    with open(os.path.join(model_dir, "config.json")) as config_file:
        raw_config = json.load(config_file)

    # local_files_only=True 是数据来源约束：只允许读取 model_dir，不访问网络。
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
        # 第一次运行前三个 token，专门取得第 0 层的历史 K/V cache。
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

        # 第二次只输入第四个 token，同时复用前三个 token 的 cache。这里得到的
        # hidden_states[0]/[1] 正好包住 decoder layer 0。
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
            # [out, in] -> [K=in, N=out]，匹配 CoralNPU matmul 的内存布局。
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

    # manifest 是可审计的数据索引：测试通过它查到每个 .npy 文件，同时可反查
    # Hugging Face state_dict 参数名和转置前后的 shape。
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
