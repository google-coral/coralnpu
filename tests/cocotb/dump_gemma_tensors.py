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

import torch
import numpy as np
from transformers import AutoModelForCausalLM, AutoTokenizer
from unittest.mock import patch

def extract_gemma_attention_block():
    model_id = "google/gemma-3-270m-it"
    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForCausalLM.from_pretrained(model_id, device_map="cpu", torch_dtype=torch.float32)
    
    prompt = "The architecture of the Coral NPU is designed for"
    inputs = tokenizer(prompt, return_tensors="pt")
    
    extracted_data = {}
    original_sdpa = torch.nn.functional.scaled_dot_product_attention
    
    # Define interceptor hook
    def sdpa_hook(query, key, value, attn_mask=None, dropout_p=0.0, is_causal=False, **kwargs):
        # Only want to capture the very first layer to keep it simple
        if "q" not in extracted_data:
            # Gemma tensors shape: (batch, num_heads, seq_len, head_dim)
            # Batch 0, Head 0 for NPU test
            extracted_data["q"] = query[0, 0, :, :].detach().numpy()
            extracted_data["k"] = key[0, 0, :, :].detach().numpy()
            extracted_data["v"] = value[0, 0, :, :].detach().numpy()
            
            output = original_sdpa(query, key, value, attn_mask, dropout_p, is_causal, **kwargs)
            
            extracted_data["o"] = output[0, 0, :, :].detach().numpy()
            return output
            
        return original_sdpa(query, key, value, attn_mask, dropout_p, is_causal, **kwargs)

    print("Running forward pass and intercepting Attention I/O...")
    # Hook into the forward pass
    with patch("torch.nn.functional.scaled_dot_product_attention", side_effect=sdpa_hook):
        model(**inputs)

    print(f"Extracted Matrix Shapes: {extracted_data['q'].shape}")
    
    # Save the 4 exact tensors to disk
    np.save("gemma_q.npy", extracted_data["q"])
    np.save("gemma_k.npy", extracted_data["k"])
    np.save("gemma_v.npy", extracted_data["v"])
    np.save("gemma_o.npy", extracted_data["o"])
    print("Successfully saved exact Gemma Q, K, V, and Golden O to disk!")

if __name__ == "__main__":
    extract_gemma_attention_block()
