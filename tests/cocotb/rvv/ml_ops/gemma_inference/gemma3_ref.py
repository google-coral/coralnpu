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
"""NumPy model of exactly what gemma3_runner.cc computes, plus the DDR image
and descriptor packer the cocotb test uses to hand the model to the DUT.

Two references are used by the tests:
  * this module ("strict" reference): same int8 weights, same activation
    quantizer, same op order, fp32 everywhere else, exact exp/tanh. The DUT
    must match it to fp32-ish tolerance; int8 GEMV results are bit-exact.
  * the HF bf16 model ("loose" reference, produced by dump_gemma3_model.py):
    the DUT is checked against it by cosine similarity and top-1 agreement.
    This is the numerics gate CLAUDE.md asks for.
"""

import struct
from dataclasses import dataclass

import numpy as np

# --- Gemma 3 270M constants, mirrored from gemma3_model.h ---------------------
MAGIC = 0x47334D30
HIDDEN = 640
FFN = 2048
HEADS = 4
KV_HEADS = 1
HEAD_DIM = 256
LAYERS = 18
Q_DIM = HEADS * HEAD_DIM
KV_DIM = KV_HEADS * HEAD_DIM
RMS_EPS = 1e-6
VOCAB = 262144
MAX_VOCAB_ROWS = 4096
ROPE_LOCAL_BASE = 10000.0
ROPE_GLOBAL_BASE = 1000000.0
SLIDING_WINDOW = 512
MAX_SEQ = 1024


@dataclass(frozen=True)
class ModelConfig:
    name: str = "gemma3"
    magic: int = MAGIC
    hidden: int = HIDDEN
    ffn: int = FFN
    heads: int = HEADS
    kv_heads: int = KV_HEADS
    head_dim: int = HEAD_DIM
    layers: int = LAYERS
    vocab: int = VOCAB
    eos: int = 1

    @property
    def proj_shapes(self):
        h, f, q, k = self.hidden, self.ffn, self.heads * self.head_dim, self.kv_heads * self.head_dim
        return dict(q=(h, q), k=(h, k), v=(h, k), o=(q, h),
                    gate=(h, f), up=(h, f), down=(f, h))

    def is_global(self, i):
        return self.name == "qwen3" or is_global_layer(i)


MODELS = {
    "gemma3": ModelConfig(),
    "qwen3": ModelConfig("qwen3", 0x51334D30, 1024, 3072, 16, 8, 128, 28, 151936, 151645),
}

CMD_LAYERS, CMD_LM_HEAD, CMD_FORWARD = 0, 1, 2
STATUS_NAMES = {
    0: "IDLE", 1: "OK", 2: "BAD_MAGIC", 3: "BAD_SHAPE", 4: "BAD_CMD",
    5: "POS_OVERFLOW"
}
OP_NAMES = [
    "norm", "quant", "qkv_gemv", "rope", "attention", "o_gemv",
    "gate_up_gemv", "gelu_mul", "down_gemv", "dequant", "residual", "lm_head"
]
NUM_OPS = len(OP_NAMES)

# Word layout of the C structs (all uint32).
LAYER_FIELDS = [
    "wq", "sq", "wk", "sk", "wv", "sv", "wo", "so", "wgate", "sgate", "wup",
    "sup", "wdown", "sdown", "input_norm", "post_attn_norm", "pre_ffn_norm",
    "post_ffn_norm", "q_norm", "k_norm", "k_cache", "v_cache", "is_global"
]
MODEL_FIELDS = [
    "magic", "n_layers", "hidden", "ffn", "n_heads", "n_kv_heads", "head_dim",
    "max_seq", "vocab_rows", "rope_cos_local", "rope_sin_local",
    "rope_cos_global", "rope_sin_global", "final_norm", "lm_head",
    "lm_head_scale", "logits"
]
CTRL_FIELDS = [
    "cmd", "pos", "layer_lo", "layer_hi", "status", "argmax", "total_cycles"
] + [f"op_{n}" for n in OP_NAMES] + ["max_logit"]
MODEL_WORDS = len(MODEL_FIELDS) + LAYERS * len(LAYER_FIELDS)
CTRL_WORDS = len(CTRL_FIELDS)

# HF weight names -> (descriptor field prefix, transpose to [K x N]).
PROJ = {
    "q_proj": "q", "k_proj": "k", "v_proj": "v", "o_proj": "o",
    "gate_proj": "gate", "up_proj": "up", "down_proj": "down"
}
PROJ_SHAPES = {  # (K_in, N_out)
    "q": (HIDDEN, Q_DIM), "k": (HIDDEN, KV_DIM), "v": (HIDDEN, KV_DIM),
    "o": (Q_DIM, HIDDEN), "gate": (HIDDEN, FFN), "up": (HIDDEN, FFN),
    "down": (FFN, HIDDEN)
}
NORMS = [
    "input_norm", "post_attn_norm", "pre_ffn_norm", "post_ffn_norm", "q_norm",
    "k_norm"
]


def is_global_layer(i: int) -> bool:
    """config.layer_types: every 6th layer (5, 11, 17) is full_attention."""
    return (i + 1) % 6 == 0


# --- Quantization (mirrors gemma3_aux_kernels.cc and the dump script) ---------
def quantize_weight(w_hf: np.ndarray):
    """HF [N_out, K_in] float -> (int8 [K_in, N_out], fp32 scale [N_out]).

    Symmetric per-output-channel, RNE, clipped to [-127, 127].
    """
    w = w_hf.astype(np.float32)
    amax = np.max(np.abs(w), axis=1)
    scale = np.where(amax > 0, amax / 127.0, 1.0).astype(np.float32)
    q = np.clip(np.rint(w / scale[:, None]), -127, 127).astype(np.int8)
    return np.ascontiguousarray(q.T), scale


def quantize_act(x: np.ndarray):
    """fp32 [K] -> (int8 [K], scale). Same rule as gemma3_quantize_f32_to_i8."""
    x = x.astype(np.float32)
    amax = np.float32(np.max(np.abs(x)))
    scale = np.float32(amax / np.float32(127.0)) if amax > 0 else np.float32(1.0)
    inv = np.float32(1.0) / scale
    q = np.clip(np.rint(x * inv), -127, 127).astype(np.int8)
    return q, scale


def linear_int8(x: np.ndarray, w_i8: np.ndarray, w_scale: np.ndarray):
    q, s = quantize_act(x)
    acc = np.matmul(q.astype(np.int32), w_i8.astype(np.int32))
    return (acc.astype(np.float32) * s * w_scale).astype(np.float32)


# --- fp32 ops --------------------------------------------------------------------
def rms_norm(x: np.ndarray, w: np.ndarray, eps: float = RMS_EPS):
    """Gemma RMSNorm on the last axis: xn * (1 + w), computed as xn + xn*w."""
    x = x.astype(np.float32)
    ms = np.mean(x * x, axis=-1, keepdims=True, dtype=np.float32)
    inv = (np.float32(1.0) / np.sqrt(ms + np.float32(eps))).astype(np.float32)
    xn = x * inv
    return (xn + xn * w.astype(np.float32)).astype(np.float32)


def rope_tables(max_seq: int, base: float, head_dim: int = HEAD_DIM):
    """cos/sin [max_seq, head_dim/2] fp32, HF inv_freq convention."""
    half = head_dim // 2
    inv_freq = 1.0 / (base ** (np.arange(0, head_dim, 2, dtype=np.float64) / head_dim))
    ang = np.arange(max_seq, dtype=np.float64)[:, None] * inv_freq[None, :]
    assert ang.shape == (max_seq, half)
    return np.cos(ang).astype(np.float32), np.sin(ang).astype(np.float32)


def rope(x: np.ndarray, cos_row: np.ndarray, sin_row: np.ndarray):
    """HF rotate_half RoPE on [n_heads, head_dim]."""
    half = x.shape[-1] // 2
    x1, x2 = x[..., :half], x[..., half:]
    o1 = x1 * cos_row - x2 * sin_row
    o2 = x2 * cos_row + x1 * sin_row
    return np.concatenate([o1, o2], axis=-1).astype(np.float32)


# The two transcendental kernels are polynomial approximations. The reference
# replays them in fp32 rather than calling exact exp/tanh: the FFN intermediate
# is int8-quantised per tensor with Gemma's large outliers, so a 1e-3 difference
# in gelu flips int8 codes whose step is large, and the residual then diverges
# by percent-level amounts that are not RTL bugs. Exact variants are kept for
# measuring the approximation error itself.
F32 = np.float32


def kernel_exp(x: np.ndarray) -> np.ndarray:
    """rvv_exp_f32m8 from gemma_kernels/rvv_flashattention_kernel.cc."""
    x = np.maximum(x.astype(F32), F32(-88.0))
    y = x * F32(1.4426950408889634)
    i = np.rint(y).astype(np.int32)  # vfcvt.x.f.v, RNE
    f = (x - i.astype(F32) * F32(0.6931471805599453)).astype(F32)
    p = (f * F32(0.16666667) + F32(0.5)).astype(F32)
    p = (F32(1.0) + f * p).astype(F32)
    p = (F32(1.0) + f * p).astype(F32)
    scale = ((i + 127) << 23).astype(np.int32).view(F32)
    return (p * scale).astype(F32)


def kernel_tanh(z: np.ndarray) -> np.ndarray:
    """clamp(z, -3, 3) then y(y^2+27)/(9y^2+27), as in rvv_tanh_gelu_mul.cc."""
    y = np.clip(z.astype(F32), F32(-3.0), F32(3.0)).astype(F32)
    y2 = (y * y).astype(F32)
    num = (y * (y2 + F32(27.0))).astype(F32)
    den = (y2 * F32(9.0) + F32(27.0)).astype(F32)
    return (num / den).astype(F32)


def gelu_tanh_mul(gate: np.ndarray, up: np.ndarray, exact: bool = False):
    g = gate.astype(F32)
    u = up.astype(F32)
    if exact:
        inner = np.sqrt(2.0 / np.pi) * (g + 0.044715 * g ** 3)
        return (0.5 * g * (1.0 + np.tanh(inner)) * u).astype(F32)
    # z = x * (CA + CB * x^2); out = K + K * tanh(z), K = 0.5 * x * up
    x2 = (g * g).astype(F32)
    z = (g * (F32(0.79788456) + F32(0.035677408) * x2)).astype(F32)
    t = kernel_tanh(z)
    k = ((g * u) * F32(0.5)).astype(F32)
    return (k + k * t).astype(F32)


def attention_decode(q: np.ndarray, k_cache: np.ndarray, v_cache: np.ndarray,
                     pos: int, exact: bool = False):
    """q [HEADS, D]; caches [max_seq, D]; returns [HEADS, D]. Causal over 0..pos.

    Mirrors FlashAttentionRVV's decode path: q pre-scaled by 1/sqrt(D), scores
    in fp32, max-subtracted, kernel exp, normalised by 1/sum.
    """
    d = q.shape[-1]
    k = k_cache[:pos + 1]
    v = v_cache[:pos + 1]
    qs = (q.astype(F32) * F32(1.0 / np.sqrt(d))).astype(F32)
    scores = (qs @ k.T).astype(F32)
    scores = (scores - scores.max(axis=-1, keepdims=True)).astype(F32)
    p = np.exp(scores).astype(F32) if exact else kernel_exp(scores)
    inv = (F32(1.0) / p.sum(axis=-1, keepdims=True, dtype=F32)).astype(F32)
    p = (p * inv).astype(F32)
    return (p @ v).astype(F32)


# --- Model container ----------------------------------------------------------
class QuantizedGemma3:
    """Per-layer int8 weights + fp32 norms/scales in the DUT's layout.

    layers[i] is a dict with keys: w{q,k,v,o,gate,up,down} (int8 [K,N]),
    s{...} (fp32 [N]), the six norm vectors, and is_global.
    lm_head_i8 is int8 [HIDDEN, n_rows] with lm_head_s [n_rows] and
    lm_head_ids [n_rows] (vocab ids of those columns).
    """

    def __init__(self, layers, final_norm, lm_head_i8, lm_head_s, lm_head_ids,
                 config=MODELS["gemma3"]):
        self.config = config
        self.layers = layers
        self.final_norm = final_norm.astype(np.float32)
        self.lm_head_i8 = lm_head_i8
        self.lm_head_s = lm_head_s.astype(np.float32)
        self.lm_head_ids = lm_head_ids.astype(np.uint32)

    @classmethod
    def synthetic(cls, seed: int = 42, n_rows: int = 256):
        """Random model with Gemma 3 270M shapes. Used when no dump exists."""
        rng = np.random.default_rng(seed)
        layers = []
        for i in range(LAYERS):
            d = {"is_global": int(is_global_layer(i))}
            for p, (K, N) in PROJ_SHAPES.items():
                w_hf = rng.normal(scale=0.02, size=(N, K)).astype(np.float32)
                d["w" + p], d["s" + p] = quantize_weight(w_hf)
            for n in NORMS:
                dim = HEAD_DIM if n in ("q_norm", "k_norm") else HIDDEN
                d[n] = rng.normal(scale=0.1, size=dim).astype(np.float32)
            layers.append(d)
        final_norm = rng.normal(scale=0.1, size=HIDDEN).astype(np.float32)
        lm_hf = rng.normal(scale=0.02, size=(n_rows, HIDDEN)).astype(np.float32)
        lm_i8, lm_s = quantize_weight(lm_hf)
        ids = np.sort(rng.choice(VOCAB, size=n_rows, replace=False))
        return cls(layers, final_norm, lm_i8, lm_s, ids)

    @classmethod
    def from_npz(cls, weights_npz, lm_head_i8=None, lm_head_s=None,
                 lm_head_ids=None, config=MODELS["gemma3"]):
        """Load dump_gemma3_model.py output. lm_head_* default to the
        candidate columns stored in the npz; pass full arrays for the
        full-vocab test."""
        z = weights_npz
        layers = []
        for i in range(config.layers):
            d = {"is_global": int(config.is_global(i))}
            for p in config.proj_shapes:
                d["w" + p] = z[f"layer{i}.w{p}_i8"]
                d["s" + p] = z[f"layer{i}.s{p}"]
            for n in NORMS:
                d[n] = z[f"layer{i}.{n}"]
            layers.append(d)
        if lm_head_i8 is None:
            lm_head_i8 = z["cand_lm_head_i8"]
            lm_head_s = z["cand_lm_head_s"]
            lm_head_ids = z["cand_ids"]
        return cls(layers, z["final_norm"], lm_head_i8, lm_head_s, lm_head_ids, config)

    def select_rows(self, row_ids: np.ndarray, full_i8: np.ndarray,
                    full_s: np.ndarray):
        """Return a copy scoring only vocab rows row_ids (full_i8 is [HIDDEN, VOCAB])."""
        return QuantizedGemma3(self.layers, self.final_norm,
                               np.ascontiguousarray(full_i8[:, row_ids]),
                               full_s[row_ids], row_ids, self.config)


class Gemma3Reference:
    """Strict reference: replays the runner's dataflow with the same weights."""

    def __init__(self, model: QuantizedGemma3, max_seq: int):
        if not 1 <= max_seq <= MAX_SEQ:
            raise ValueError(f"max_seq must be in [1, {MAX_SEQ}]")
        self.m = model
        self.c = model.config
        self.max_seq = max_seq
        self.cos_l, self.sin_l = rope_tables(max_seq, ROPE_LOCAL_BASE, self.c.head_dim)
        self.cos_g, self.sin_g = rope_tables(max_seq, ROPE_GLOBAL_BASE, self.c.head_dim)
        # Keep the legacy Gemma shape for existing cocotb consumers.
        self.k_cache = np.zeros((self.c.layers, max_seq, self.c.kv_heads * self.c.head_dim), np.float32)
        self.v_cache = np.zeros_like(self.k_cache)

    def norm(self, x, w):
        if self.c.name != "qwen3":
            return rms_norm(x, w)
        inv = F32(1) / np.sqrt(np.mean(x * x, axis=-1, keepdims=True, dtype=F32) + F32(RMS_EPS))
        return ((x * inv) * w).astype(F32)

    def layer(self, x: np.ndarray, i: int, pos: int):
        """One decoder layer at position pos. Returns (x_new, taps)."""
        L = self.m.layers[i]
        if not 0 <= pos < self.max_seq:
            raise ValueError("token position outside KV cache")
        c = self.c
        x = x.astype(np.float32)
        h = self.norm(x, L["input_norm"])
        q = linear_int8(h, L["wq"], L["sq"]).reshape(c.heads, c.head_dim)
        k = linear_int8(h, L["wk"], L["sk"]).reshape(c.kv_heads, c.head_dim)
        v = linear_int8(h, L["wv"], L["sv"]).reshape(c.kv_heads, c.head_dim)
        q = self.norm(q, L["q_norm"])
        k = self.norm(k, L["k_norm"])
        cos, sin = (self.cos_g, self.sin_g) if L["is_global"] else (self.cos_l, self.sin_l)
        q = rope(q, cos[pos], sin[pos])
        k = rope(k, cos[pos], sin[pos])
        self.k_cache[i, pos] = k.ravel()
        self.v_cache[i, pos] = v.ravel()
        start = 0 if L["is_global"] else max(0, pos + 1 - SLIDING_WINDOW)
        kc = self.k_cache[i].reshape(self.max_seq, c.kv_heads, c.head_dim)
        vc = self.v_cache[i].reshape(self.max_seq, c.kv_heads, c.head_dim)
        group = c.heads // c.kv_heads
        a = np.concatenate([attention_decode(q[j * group:(j + 1) * group],
                           kc[start:, j], vc[start:, j], pos - start)
                            for j in range(c.kv_heads)])
        o = linear_int8(a.ravel(), L["wo"], L["so"])
        x = x + (o if c.name == "qwen3" else self.norm(o, L["post_attn_norm"]))
        h = self.norm(x, L["pre_ffn_norm"])
        g = linear_int8(h, L["wgate"], L["sgate"])
        u = linear_int8(h, L["wup"], L["sup"])
        if c.name == "qwen3":
            e = np.exp(-np.abs(g)).astype(F32)
            f = ((g * np.where(g >= 0, F32(1) / (F32(1) + e), e / (F32(1) + e))) * u).astype(F32)
        else:
            f = gelu_tanh_mul(g, u)
        d = linear_int8(f, L["wdown"], L["sdown"])
        x = x + (d if c.name == "qwen3" else self.norm(d, L["post_ffn_norm"]))
        taps = {"q": q.ravel(), "attn": a.ravel(), "ffn": f}
        return x.astype(np.float32), taps

    def layers(self, x: np.ndarray, lo: int, hi: int, pos: int):
        taps = {}
        for i in range(lo, hi):
            x, taps = self.layer(x, i, pos)
        return x, taps

    def lm_head(self, x: np.ndarray):
        h = self.norm(x, self.m.final_norm)
        logits = linear_int8(h, self.m.lm_head_i8, self.m.lm_head_s)
        return logits, int(np.argmax(logits))

    def forward(self, x: np.ndarray, pos: int):
        x, _ = self.layers(x, 0, self.c.layers, pos)
        logits, am = self.lm_head(x)
        return x, logits, am


# --- DDR image ----------------------------------------------------------------
class ModelImage:
    """Packs arrays into one contiguous byte image at a DDR base address and
    records the address of each. Written to the testbench memory model in one
    numpy slice assignment (no AXI traffic)."""

    ALIGN = 16

    def __init__(self, base: int):
        self.base = base
        self.chunks = []
        self.size = 0
        self.addr = {}

    def _pad(self):
        rem = (-self.size) % self.ALIGN
        if rem:
            self.chunks.append(np.zeros(rem, np.uint8))
            self.size += rem

    def add(self, name: str, arr: np.ndarray) -> int:
        self._pad()
        b = np.ascontiguousarray(arr, dtype=arr.dtype.newbyteorder("<")).view(np.uint8).reshape(-1)
        addr = self.base + self.size
        self.chunks.append(b)
        self.size += b.size
        self.addr[name] = addr
        return addr

    def reserve(self, name: str, nbytes: int) -> int:
        return self.add(name, np.zeros(nbytes, np.uint8))

    def to_bytes(self) -> np.ndarray:
        self._pad()
        return np.concatenate(self.chunks) if self.chunks else np.zeros(0, np.uint8)


def build_image(model: QuantizedGemma3, base: int, max_seq: int):
    """Lay the whole model out in DDR; return (image, descriptor words)."""
    if not 1 <= max_seq <= MAX_SEQ:
        raise ValueError(f"max_seq must be in [1, {MAX_SEQ}]")
    c = model.config
    if len(model.layers) != c.layers:
        raise ValueError("wrong number of layers")
    def vector(a, size, name, positive=False):
        if a.shape != (size,) or not np.isfinite(a).all() or (positive and np.any(a <= 0)):
            raise ValueError(f"invalid {name} shape/values")
    vector(model.final_norm, c.hidden, "final norm")
    if model.lm_head_i8.dtype != np.int8 or model.lm_head_i8.shape[0] != c.hidden:
        raise ValueError("invalid lm_head shape/dtype")
    vector(model.lm_head_s, model.lm_head_i8.shape[1], "lm_head scale", True)
    img = ModelImage(base)
    desc = {
        "magic": c.magic, "n_layers": c.layers, "hidden": c.hidden, "ffn": c.ffn,
        "n_heads": c.heads, "n_kv_heads": c.kv_heads, "head_dim": c.head_dim,
        "max_seq": max_seq, "vocab_rows": int(model.lm_head_i8.shape[1])
    }
    if not 1 <= desc["vocab_rows"] <= MAX_VOCAB_ROWS:
        raise ValueError("invalid lm_head chunk size")
    cos_l, sin_l = rope_tables(max_seq, ROPE_LOCAL_BASE, c.head_dim)
    cos_g, sin_g = rope_tables(max_seq, ROPE_GLOBAL_BASE, c.head_dim)
    desc["rope_cos_local"] = img.add("rope_cos_local", cos_l)
    desc["rope_sin_local"] = img.add("rope_sin_local", sin_l)
    desc["rope_cos_global"] = img.add("rope_cos_global", cos_g)
    desc["rope_sin_global"] = img.add("rope_sin_global", sin_g)
    desc["final_norm"] = img.add("final_norm", model.final_norm)
    desc["lm_head"] = img.add("lm_head", model.lm_head_i8)
    desc["lm_head_scale"] = img.add("lm_head_scale", model.lm_head_s)
    desc["logits"] = img.reserve("logits", 4 * MAX_VOCAB_ROWS)
    layer_words = []
    for i, L in enumerate(model.layers):
        d = {}
        for p, (K, N) in c.proj_shapes.items():
            if L["w" + p].shape != (K, N) or L["w" + p].dtype != np.int8 or np.any(L["w" + p] == -128):
                raise ValueError(f"invalid layer {i} projection {p} shape/dtype/range")
            vector(L["s" + p], N, f"layer {i} scale {p}", True)
            d["w" + p] = img.add(f"l{i}.w{p}", L["w" + p])
            d["s" + p] = img.add(f"l{i}.s{p}", L["s" + p].astype(np.float32))
        for n in NORMS:
            vector(L[n], c.head_dim if n in ("q_norm", "k_norm") else c.hidden, f"layer {i} {n}")
            d[n] = img.add(f"l{i}.{n}", L[n].astype(np.float32))
        d["k_cache"] = img.reserve(f"l{i}.k_cache", 4 * max_seq * c.kv_heads * c.head_dim)
        d["v_cache"] = img.reserve(f"l{i}.v_cache", 4 * max_seq * c.kv_heads * c.head_dim)
        d["is_global"] = int(L["is_global"])
        if d["is_global"] != int(c.is_global(i)):
            raise ValueError(f"invalid attention type for layer {i}")
        layer_words += [d[f] for f in LAYER_FIELDS]
    words = [desc[f] for f in MODEL_FIELDS] + layer_words
    if base < 0 or base % 16 or base + (img.size + 15) // 16 * 16 > 2**32:
        raise ValueError("model image exceeds the NPU's 32-bit address space")
    return img, np.array(words, dtype=np.uint32)


def pack_ctrl(cmd: int, pos: int, layer_lo: int = 0, layer_hi: int = 0):
    w = np.zeros(CTRL_WORDS, np.uint32)
    w[0:4] = [cmd, pos, layer_lo, layer_hi]
    return w


def unpack_ctrl(words: np.ndarray) -> dict:
    return {f: int(v) for f, v in zip(CTRL_FIELDS, words)}


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = a.astype(np.float64).ravel()
    b = b.astype(np.float64).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def rel_max_err(actual: np.ndarray, ref: np.ndarray) -> float:
    ref = ref.astype(np.float64)
    return float(np.max(np.abs(actual.astype(np.float64) - ref)) /
                 (np.max(np.abs(ref)) + 1e-12))


def _self_test():
    """Shape/packing sanity, runnable on the host: python3 gemma3_ref.py"""
    m = QuantizedGemma3.synthetic(n_rows=64)
    ref = Gemma3Reference(m, max_seq=8)
    x = np.random.default_rng(0).normal(size=HIDDEN).astype(np.float32)
    for pos in range(3):
        x, logits, am = ref.forward(x, pos)
    assert logits.shape == (64,) and 0 <= am < 64
    img, words = build_image(m, base=0x80000000, max_seq=8)
    assert words.size == MODEL_WORDS and words[0] == MAGIC
    b = img.to_bytes()
    assert b.size == img.size and img.addr["lm_head"] % 16 == 0
    print(f"ok: image {b.size / 2**20:.1f} MiB, {MODEL_WORDS} descriptor words, "
          f"{CTRL_WORDS} ctrl words, struct sizes {4*MODEL_WORDS}/{4*CTRL_WORDS} B")


if __name__ == "__main__":
    _self_test()
