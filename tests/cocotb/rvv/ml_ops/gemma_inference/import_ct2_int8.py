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
"""Import a CTranslate2 int8 Gemma 3 270M checkpoint into the DUT layout.

Reads `model.bin` of jncraton/gemma-3-270m-ct2-int8 (or any CT2 int8
conversion of google/gemma-3-270m) and writes the same files as
dump_gemma3_model.py, so the cocotb tests, gemma3_ref.py and the F2 blob
builder use CTranslate2's int8 weights instead of quantizing HF bf16 here.

CT2 conventions handled:
  * `weight` is int8 [N_out x K_in], `weight_scale` is the *inverse* per-row
    scale (dequant = w / weight_scale). The DUT wants [K x N] and a
    multiplicative scale, so both are transposed / inverted.
  * self_attention/linear_0 packs Q, K, V rows; ffn/linear_0 is gate,
    ffn/linear_0_noact is up, ffn/linear_1 is down, self_attention/linear_1 is
    o_proj.
  * RMSNorm gammas are stored as (1 + w) in bf16; the kernels apply 1 + w, so
    w = gamma - 1 is stored.
  * lm_head is tied to the int8 embedding table.

Outputs (in --out_dir):
  gemma3_weights.npz   same keys as dump_gemma3_model.py (+ "source")
  gemma3_embed_i8.npy  int8 [VOCAB x HIDDEN] embedding / lm_head table
  gemma3_embed_s.npy   fp32 [VOCAB] multiplicative scales
  gemma3_lm_head_i8.npy / gemma3_lm_head_s.npy  (--full_lm_head) the
                       [HIDDEN x VOCAB] view used by the full-vocab test
  gemma3_vocab.txt     one token piece per line (from vocabulary.json)

Usage:
  PYTHONPATH=<repo> python3 import_ct2_int8.py --out_dir test_data [--full_lm_head]
"""

import argparse
import json
import os
import struct

import numpy as np

from tests.cocotb.rvv.ml_ops.gemma_inference import gemma3_ref as ref

DTYPES = {0: np.float32, 1: np.int8, 2: np.int16, 3: np.int32, 4: np.float16, 5: "bf16"}


class Ct2Model:
    """Minimal reader for the CTranslate2 model.bin container (binary v6)."""

    def __init__(self, path):
        self.path = path
        self.vars = {}
        with open(path, "rb") as f:
            (version,) = struct.unpack("<I", f.read(4))
            (n,) = struct.unpack("<H", f.read(2))
            self.spec = f.read(n).decode().rstrip("\x00")
            (self.revision,) = struct.unpack("<I", f.read(4))
            (count,) = struct.unpack("<I", f.read(4))
            for _ in range(count):
                (n,) = struct.unpack("<H", f.read(2))
                name = f.read(n).decode().rstrip("\x00")
                (rank,) = struct.unpack("<B", f.read(1))
                dims = struct.unpack("<%dI" % rank, f.read(4 * rank))
                (dtype,) = struct.unpack("<B", f.read(1))
                (size,) = struct.unpack("<I", f.read(4))
                self.vars[name] = (dims, dtype, f.tell(), size)
                f.seek(size, 1)
        self.version = version

    def __contains__(self, name):
        return name in self.vars

    def get(self, name):
        dims, dtype, off, size = self.vars[name]
        with open(self.path, "rb") as f:
            f.seek(off)
            raw = f.read(size)
        if DTYPES[dtype] == "bf16":
            u = np.frombuffer(raw, dtype=np.uint16).astype(np.uint32) << 16
            arr = u.view(np.float32)
        else:
            arr = np.frombuffer(raw, dtype=DTYPES[dtype])
        return arr.reshape(dims) if dims else arr[0]


def norm_w(m, name):
    return (m.get(name).astype(np.float32) - 1.0).astype(np.float32)


def linear(m, name):
    """Return int8 [K x N] weights and fp32 [N] multiplicative scales."""
    w = m.get(name + "/weight")  # [N, K]
    s_inv = m.get(name + "/weight_scale").astype(np.float32)
    return np.ascontiguousarray(w.T), (1.0 / s_inv).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model_id", default="jncraton/gemma-3-270m-ct2-int8")
    ap.add_argument("--model_bin", default=None, help="local model.bin (skips download)")
    ap.add_argument("--out_dir", default=".")
    ap.add_argument("--cand_from", default=None,
                    help="npz providing cand_ids (default: existing gemma3_prompt.npz or "
                         "gemma3_weights.npz in out_dir; else 512 fixed rows)")
    ap.add_argument("--full_lm_head", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    if args.model_bin:
        model_bin, vocab_json = args.model_bin, os.path.join(os.path.dirname(args.model_bin), "vocabulary.json")
    else:
        from huggingface_hub import hf_hub_download
        model_bin = hf_hub_download(args.model_id, "model.bin")
        vocab_json = hf_hub_download(args.model_id, "vocabulary.json")
    m = Ct2Model(model_bin)
    print(f"{args.model_id}: spec {m.spec} rev {m.revision}, {len(m.vars)} variables")

    weights = {"source": np.array(args.model_id)}
    for i in range(ref.LAYERS):
        p = f"decoder/layer_{i}"
        qkv, sqkv = linear(m, f"{p}/self_attention/linear_0")  # [K, 1536]
        assert qkv.shape == (ref.HIDDEN, ref.Q_DIM + 2 * ref.KV_DIM), qkv.shape
        parts = {
            "q": (qkv[:, :ref.Q_DIM], sqkv[:ref.Q_DIM]),
            "k": (qkv[:, ref.Q_DIM:ref.Q_DIM + ref.KV_DIM], sqkv[ref.Q_DIM:ref.Q_DIM + ref.KV_DIM]),
            "v": (qkv[:, ref.Q_DIM + ref.KV_DIM:], sqkv[ref.Q_DIM + ref.KV_DIM:]),
            "o": linear(m, f"{p}/self_attention/linear_1"),
            "gate": linear(m, f"{p}/ffn/linear_0"),
            "up": linear(m, f"{p}/ffn/linear_0_noact"),
            "down": linear(m, f"{p}/ffn/linear_1"),
        }
        for name, (w, s) in parts.items():
            assert w.shape == ref.PROJ_SHAPES[name], (i, name, w.shape)
            weights[f"layer{i}.w{name}_i8"] = np.ascontiguousarray(w, dtype=np.int8)
            weights[f"layer{i}.s{name}"] = s.astype(np.float32)
        norms = {
            "input_norm": "input_layer_norm", "post_attn_norm": "post_attention_layer_norm",
            "pre_ffn_norm": "pre_feedforward_layer_norm", "post_ffn_norm": "post_feedforward_layer_norm",
            "q_norm": "self_attention/q_norm", "k_norm": "self_attention/k_norm",
        }
        for ours, theirs in norms.items():
            weights[f"layer{i}.{ours}"] = norm_w(m, f"{p}/{theirs}/gamma")
        base = float(m.get(f"{p}/self_attention/rotary_base"))
        want = ref.ROPE_GLOBAL_BASE if ref.is_global_layer(i) else ref.ROPE_LOCAL_BASE
        assert base == want, (i, base, want)
    weights["final_norm"] = norm_w(m, "decoder/layer_norm/gamma")

    emb_i8 = m.get("decoder/embeddings/weight")  # [VOCAB, HIDDEN] int8
    emb_s = (1.0 / m.get("decoder/embeddings/weight_scale").astype(np.float32)).astype(np.float32)
    assert emb_i8.shape == (ref.VOCAB, ref.HIDDEN)
    assert "decoder/projection/weight" not in m, "untied lm_head not handled"

    cand_ids = None
    for cand in ([args.cand_from] if args.cand_from else
                 [os.path.join(args.out_dir, "gemma3_prompt.npz"), os.path.join(args.out_dir, "gemma3_weights.npz")]):
        if cand and os.path.exists(cand):
            z = np.load(cand)
            if "cand_ids" in z:
                cand_ids = np.asarray(z["cand_ids"], dtype=np.uint32)
                print(f"candidate vocab rows from {cand}: {cand_ids.size}")
                break
    if cand_ids is None:
        cand_ids = np.arange(0, ref.VOCAB, ref.VOCAB // 512, dtype=np.uint32)[:512]
        print("no candidate list found; using 512 evenly spaced vocab rows")
    weights["cand_ids"] = cand_ids
    weights["cand_lm_head_i8"] = np.ascontiguousarray(emb_i8[cand_ids].T)  # [HIDDEN, n]
    weights["cand_lm_head_s"] = emb_s[cand_ids]

    old = os.path.join(args.out_dir, "gemma3_weights.npz")
    if os.path.exists(old):
        z = np.load(old)
        if str(z["source"]) != args.model_id if "source" in z else True:
            os.replace(old, os.path.join(args.out_dir, "gemma3_weights.hf.npz"))
            print("kept previous HF-quantized weights as gemma3_weights.hf.npz")
    np.savez(old, **weights)
    np.save(os.path.join(args.out_dir, "gemma3_embed_i8.npy"), emb_i8)
    np.save(os.path.join(args.out_dir, "gemma3_embed_s.npy"), emb_s)
    if args.full_lm_head:
        np.save(os.path.join(args.out_dir, "gemma3_lm_head_i8.npy"), np.ascontiguousarray(emb_i8.T))
        np.save(os.path.join(args.out_dir, "gemma3_lm_head_s.npy"), emb_s)
    if os.path.exists(vocab_json):
        vocab = json.load(open(vocab_json))
        with open(os.path.join(args.out_dir, "gemma3_vocab.txt"), "w") as f:
            for tok in vocab:
                f.write(tok.replace("\n", "\\n") + "\n")
        print(f"vocab: {len(vocab)} pieces")
    print(f"wrote {args.out_dir}: {len(weights)} arrays, embed table {emb_i8.nbytes / 2**20:.0f} MiB")


if __name__ == "__main__":
    main()
