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
"""Dumps Gemma 3 270M as int8 weights in the DUT layout plus bf16 HF reference
activations for a prompt. Companion of tests/cocotb/dump_gemma_tensors.py.

Outputs (in --out_dir):
  gemma3_weights.npz     per-layer int8 [K x N] weights + fp32 scales + norms,
                         final_norm, and the lm_head columns for the candidate
                         vocab (cand_ids / cand_lm_head_i8 / cand_lm_head_s).
                         ~100 MB. Not checked in.
  gemma3_lm_head_i8.npy  int8 [640 x 262144] full lm_head (only with
                         --full_lm_head; 168 MB) and gemma3_lm_head_s.npy.
  gemma3_prompt.npz      HF bf16 reference for --prompt: input ids, scaled
                         embeddings, hidden_states after every layer, final
                         logits for the last prompt position, top-k ids per
                         position, and the greedy continuation (ids +
                         embeddings) for --gen_tokens steps.

Run through Bazel so the pinned torch/transformers are used:
  bazel run //tests/cocotb/rvv/ml_ops/gemma_inference:dump_gemma3_model -- \
      --out_dir $PWD/tests/cocotb/rvv/ml_ops/gemma_inference/test_data
google/gemma-3-270m is gated on the Hub; pass --model_id to use a mirror.
"""

import argparse
import os

import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from tests.cocotb.rvv.ml_ops.gemma_inference import gemma3_ref as ref


def quantize_state_dict(model, cand_ids, full_lm_head):
    out = {}
    layers = model.model.layers
    assert len(layers) == ref.LAYERS
    for i, layer in enumerate(layers):
        attn, mlp = layer.self_attn, layer.mlp
        mods = {
            "q": attn.q_proj, "k": attn.k_proj, "v": attn.v_proj,
            "o": attn.o_proj, "gate": mlp.gate_proj, "up": mlp.up_proj,
            "down": mlp.down_proj
        }
        for p, mod in mods.items():
            w_i8, s = ref.quantize_weight(mod.weight.detach().float().numpy())
            assert w_i8.shape == ref.PROJ_SHAPES[p], (i, p, w_i8.shape)
            out[f"layer{i}.w{p}_i8"] = w_i8
            out[f"layer{i}.s{p}"] = s
        norms = {
            "input_norm": layer.input_layernorm,
            "post_attn_norm": layer.post_attention_layernorm,
            "pre_ffn_norm": layer.pre_feedforward_layernorm,
            "post_ffn_norm": layer.post_feedforward_layernorm,
            "q_norm": attn.q_norm,
            "k_norm": attn.k_norm,
        }
        for n, mod in norms.items():
            out[f"layer{i}.{n}"] = mod.weight.detach().float().numpy()
        assert bool(getattr(layer, "is_sliding", not ref.is_global_layer(i))) == (
            not ref.is_global_layer(i)), f"layer {i} attention type mismatch"
    out["final_norm"] = model.model.norm.weight.detach().float().numpy()

    # lm_head is tied to the embedding table: [VOCAB, HIDDEN].
    lm = model.lm_head.weight.detach().float().numpy()
    assert lm.shape == (ref.VOCAB, ref.HIDDEN)
    lm_i8, lm_s = ref.quantize_weight(lm)  # [HIDDEN, VOCAB], [VOCAB]
    out["cand_ids"] = cand_ids.astype(np.uint32)
    out["cand_lm_head_i8"] = np.ascontiguousarray(lm_i8[:, cand_ids])
    out["cand_lm_head_s"] = lm_s[cand_ids]
    return out, (lm_i8, lm_s) if full_lm_head else (None, None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model_id", default="google/gemma-3-270m")
    ap.add_argument("--out_dir", default=".")
    ap.add_argument("--prompt", default="The capital of France is")
    ap.add_argument("--gen_tokens", type=int, default=8)
    ap.add_argument("--topk", type=int, default=64)
    ap.add_argument("--n_random_cand", type=int, default=192)
    ap.add_argument("--full_lm_head", action="store_true")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    tok = AutoTokenizer.from_pretrained(args.model_id)
    # bf16 is the model's native dtype and the reference CLAUDE.md names.
    model = AutoModelForCausalLM.from_pretrained(
        args.model_id, torch_dtype=torch.bfloat16, device_map="cpu"
    )
    model.eval()
    cfg = model.config
    assert (cfg.hidden_size, cfg.intermediate_size, cfg.num_hidden_layers,
            cfg.num_attention_heads, cfg.num_key_value_heads, cfg.head_dim,
            cfg.vocab_size) == (ref.HIDDEN, ref.FFN, ref.LAYERS, ref.HEADS,
                                ref.KV_HEADS, ref.HEAD_DIM, ref.VOCAB), cfg
    assert cfg.query_pre_attn_scalar == ref.HEAD_DIM
    assert cfg.final_logit_softcapping is None and cfg.attn_logit_softcapping is None
    # transformers >= 5 keeps the RoPE bases per layer type in rope_parameters.
    rope_params = getattr(cfg, "rope_parameters", None)
    if isinstance(rope_params, dict) and "full_attention" in rope_params:
        rope_global = rope_params["full_attention"]["rope_theta"]
        rope_local = rope_params["sliding_attention"]["rope_theta"]
    else:
        rope_global, rope_local = cfg.rope_theta, cfg.rope_local_base_freq
    assert rope_global == ref.ROPE_GLOBAL_BASE
    assert rope_local == ref.ROPE_LOCAL_BASE

    ids = tok(args.prompt, return_tensors="pt").input_ids  # includes BOS
    with torch.no_grad():
        out = model(input_ids=ids, output_hidden_states=True)
        # hidden_states[0] is the scaled embedding; [i] is after layer i-1.
        hs = torch.stack(out.hidden_states, 0)[:, 0].float().numpy()
        logits_last = out.logits[0, -1].float().numpy()
        topk = torch.topk(out.logits[0].float(), args.topk, dim=-1).indices.numpy()
        gen = model.generate(ids, max_new_tokens=args.gen_tokens, do_sample=False)
        gen_ids = gen[0, ids.shape[1]:].numpy()
        gen_embeds = model.model.embed_tokens(gen[:, ids.shape[1]:])[0].float().numpy()

    rng = np.random.default_rng(args.seed)
    cand = set(topk.ravel().tolist()) | set(gen_ids.tolist())
    cand |= set(rng.choice(ref.VOCAB, size=args.n_random_cand, replace=False).tolist())
    cand_ids = np.array(sorted(cand), dtype=np.uint32)
    assert cand_ids.size <= ref.MAX_VOCAB_ROWS

    weights, (full_i8, full_s) = quantize_state_dict(model, cand_ids, args.full_lm_head)
    np.savez(os.path.join(args.out_dir, "gemma3_weights.npz"), **weights)
    if full_i8 is not None:
        np.save(os.path.join(args.out_dir, "gemma3_lm_head_i8.npy"), full_i8)
        np.save(os.path.join(args.out_dir, "gemma3_lm_head_s.npy"), full_s)
    np.savez(
        os.path.join(args.out_dir, "gemma3_prompt.npz"),
        prompt=np.array(args.prompt),
        input_ids=ids[0].numpy().astype(np.uint32),
        embeds=hs[0],  # [seq, HIDDEN], already scaled by sqrt(HIDDEN) in bf16
        hidden_states=hs,  # [LAYERS+1, seq, HIDDEN]
        logits_last=logits_last,  # [VOCAB]
        topk_ids=topk.astype(np.uint32),  # [seq, topk]
        gen_ids=gen_ids.astype(np.uint32),
        gen_embeds=gen_embeds,
        cand_ids=cand_ids,
    )
    print(f"prompt ids: {ids[0].tolist()}  greedy continuation: {gen_ids.tolist()} "
          f"-> {tok.decode(gen_ids)!r}")
    print(f"wrote {args.out_dir}: weights ({len(weights)} arrays), "
          f"{cand_ids.size} candidate vocab rows, full lm_head={args.full_lm_head}")


if __name__ == "__main__":
    main()
