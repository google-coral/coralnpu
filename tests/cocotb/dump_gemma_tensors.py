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
"""Manual utility to extract reference Attention and RMSNorm tensors from Gemma.

Why this script is not executed via Bazel:
    During the pure Bzlmod airgap migration (September 2026), the `@gemma_deps`
    pip hub and its manual Bazel targets were de-Bazel'd. Because `bazel vendor //...`
    vendors all declared dependencies across the workspace for offline airgapped
    CI, keeping PyTorch and Hugging Face Transformers in the
    Bazel build graph would unnecessarily bloat the vendored dataset by multiple
    gigabytes for dependencies never used by CI (which uses deterministic synthetic
    vectors). Furthermore, this script downloads weights from Hugging Face over
    the public internet, which cannot function in airgapped environments.

Manual Execution Instructions:
    1. Create and activate a Python virtual environment:
       python3 -m venv .venv
       source .venv/bin/activate

    2. Install pinned dependencies:
       pip install -r third_party/gemma_requirements.txt

    3. Run this script to extract sample tensors:
       python3 tests/cocotb/dump_gemma_tensors.py --out_dir tests/cocotb/rvv/ml_ops/gemma_kernels/test_data

    The generated .npy files (gemma_q.npy, gemma_k.npy, gemma_v.npy, gemma_o.npy,
    etc.) will be automatically detected by `rvv_flashattention_cocotb_test.py`
    when present.
"""

import argparse
import os
import torch
import numpy as np
import types
from transformers import AutoModelForCausalLM, AutoTokenizer
from unittest.mock import patch


def extract_gemma_attention_block(out_dir):
    """Extracts and saves the Q, K, V inputs and O output of the first
    scaled_dot_product_attention layer from a Gemma model.

    Loads a pre-trained Gemma model, performs a forward pass with a sample
    prompt, and uses a mock to intercept the tensors passed to the
    `torch.nn.functional.scaled_dot_product_attention` function for the first
    attention block. The Q, K, V, and the resulting O tensors (for batch 0,
    head 0) are saved as numpy files in the specified output directory.

    Args:
        out_dir: The directory to save the extracted numpy tensors.
    """
    model_id = "google/gemma-3-270m-it"
    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForCausalLM.from_pretrained(
        model_id, device_map="cpu", torch_dtype=torch.float32
    )

    prompt = "The architecture of the Coral NPU is designed for"
    inputs = tokenizer(prompt, return_tensors="pt")

    extracted_data = {}
    original_sdpa = torch.nn.functional.scaled_dot_product_attention

    # Define interceptor hook
    def sdpa_hook(
        query,
        key,
        value,
        attn_mask=None,
        dropout_p=0.0,
        is_causal=False,
        **kwargs
    ):
        # Only want to capture the very first layer to keep it simple
        if "q" not in extracted_data:
            # Gemma tensors shape: (batch, num_heads, seq_len, head_dim)
            # Batch 0, Head 0 for NPU test
            extracted_data["q"] = query[0, 0, :, :].cpu().detach().numpy()
            extracted_data["k"] = key[0, 0, :, :].cpu().detach().numpy()
            extracted_data["v"] = value[0, 0, :, :].cpu().detach().numpy()

            output = original_sdpa(
                query, key, value, attn_mask, dropout_p, is_causal, **kwargs
            )

            extracted_data["o"] = output[0, 0, :, :].cpu().detach().numpy()
            return output

        return original_sdpa(
            query, key, value, attn_mask, dropout_p, is_causal, **kwargs
        )

    # Add RMS Norm Hook
    rms_extracted = {}
    first_layernorm = model.model.layers[0].input_layernorm
    original_rms_forward = first_layernorm.forward

    def rms_hook(self, hidden_states, *args, **kwargs):
        if "input" not in rms_extracted:
            rms_extracted["input"] = hidden_states.cpu().detach().numpy()
            rms_extracted["weight"] = self.weight.cpu().detach().numpy()
            out = original_rms_forward(hidden_states, *args, **kwargs)
            if isinstance(out, tuple):
                rms_extracted["output"] = out[0].cpu().detach().numpy()
            else:
                rms_extracted["output"] = out.cpu().detach().numpy()
            return out
        return original_rms_forward(hidden_states, *args, **kwargs)

    first_layernorm.forward = types.MethodType(rms_hook, first_layernorm)

    print("Running forward pass and intercepting Attention & RMSNorm I/O...")
    # Hook into the forward pass
    with patch("torch.nn.functional.scaled_dot_product_attention",
               side_effect=sdpa_hook):
        model(**inputs)

    print(f"Extracted Attention Shapes: Q {extracted_data['q'].shape}")
    print(
        f"Extracted RMSNorm Shapes: Input {rms_extracted['input'].shape}, Weight {rms_extracted['weight'].shape}"
    )

    # Save the exact tensors to disk
    os.makedirs(out_dir, exist_ok=True)
    np.save(os.path.join(out_dir, "gemma_q.npy"), extracted_data["q"])
    np.save(os.path.join(out_dir, "gemma_k.npy"), extracted_data["k"])
    np.save(os.path.join(out_dir, "gemma_v.npy"), extracted_data["v"])
    np.save(os.path.join(out_dir, "gemma_o.npy"), extracted_data["o"])

    np.save(
        os.path.join(out_dir, "gemma_rms_input.npy"), rms_extracted["input"]
    )
    np.save(
        os.path.join(out_dir, "gemma_rms_weight.npy"), rms_extracted["weight"]
    )
    np.save(
        os.path.join(out_dir, "gemma_rms_output.npy"), rms_extracted["output"]
    )
    print(
        f"Successfully saved exact Gemma Attention and RMSNorm tensors to {out_dir}!"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out_dir",
        default=".",
        help="Output directory for generated tensors"
    )
    args = parser.parse_args()
    extract_gemma_attention_block(args.out_dir)
