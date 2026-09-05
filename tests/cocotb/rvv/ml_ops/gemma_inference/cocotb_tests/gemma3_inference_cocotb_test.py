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
"""Gemma 3 270M inference tests on RvvCoreMiniHighmemAxi (Verilator, cocotb).

Tiers (see README.md):
  T1 gemma3_layer0_decode_step        one layer, one token           minutes
  T2 gemma3_layer_sweep_teacher_forced each layer from HF's input     ~18x T1
  T3 gemma3_layer0_prefill            layer 0 over N positions        ~N x T1
  T4 gemma3_next_token_candidates     full forward, candidate vocab   ~1 h/token
  T5 gemma3_greedy_generate           T4 + greedy continuation        manual
  T6 gemma3_full_vocab_logits         T4 + all 262 144 logits         manual

Without test_data/gemma3_*.npz the tests run on a synthetic model and check
only against the strict NumPy reference; HF comparisons are skipped with a
warning (same convention as gemma_kernels/rvv_flashattention_cocotb_test.py).
"""

import os

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture
from sw.utils.metrics import log_matmul_metrics
from tests.cocotb.rvv.ml_ops.gemma_inference import gemma3_ref as ref

DDR_BASE = 0x80000000
RUNFILES_DIR = "coralnpu_hw/tests/cocotb/rvv/ml_ops/gemma_inference"
ELF = f"{RUNFILES_DIR}/gemma3_runner.elf"
WEIGHTS_NPZ = f"{RUNFILES_DIR}/test_data/gemma3_weights.npz"
PROMPT_NPZ = f"{RUNFILES_DIR}/test_data/gemma3_prompt.npz"
LM_HEAD_I8 = f"{RUNFILES_DIR}/test_data/gemma3_lm_head_i8.npy"
LM_HEAD_S = f"{RUNFILES_DIR}/test_data/gemma3_lm_head_s.npy"

# Provisional tolerances; tighten once the first Verilator run reports margins.
STRICT_COS = 0.9999   # DUT vs NumPy replay of the same int8 arithmetic
STRICT_REL_MAX = 2e-2  # max |err| / max |ref|, absorbs the Taylor exp / rational tanh
HF_COS = 0.99          # DUT residual vs HF bf16 hidden state, one layer
HF_FULL_COS = 0.98     # same after all 18 layers (accumulated int8 drift; the
                       # top-1 check at the last position is the real gate)
HF_LOGIT_COS = 0.98    # DUT logits vs HF bf16 logits (int8 lm_head)

# Cycle budgets used only to size wait_for_halted timeouts. Override with
# GEMMA3_CYCLES_PER_LAYER or COCOTB_TIMEOUT_CYCLES.
CYCLES_PER_LAYER = int(os.environ.get("GEMMA3_CYCLES_PER_LAYER", 4_000_000))
CYCLES_PER_LM_HEAD_ROW = 1_000
MACS_PER_LAYER = (ref.HIDDEN * (ref.Q_DIM + 2 * ref.KV_DIM) + ref.Q_DIM * ref.HIDDEN
                  + 2 * ref.HIDDEN * ref.FFN + ref.FFN * ref.HIDDEN)


def _rloc(r, path):
    p = r.Rlocation(path)
    return p if p and os.path.exists(p) else None


def load_test_data(dut, r):
    """Returns (QuantizedGemma3, prompt dict or None)."""
    w = _rloc(r, WEIGHTS_NPZ)
    p = _rloc(r, PROMPT_NPZ)
    if w and p:
        dut._log.info("Real Gemma 3 270M dump found; HF bf16 checks enabled.")
        prompt = dict(np.load(p))
        return ref.QuantizedGemma3.from_npz(np.load(w)), prompt
    dut._log.warning(
        f"{WEIGHTS_NPZ} / {PROMPT_NPZ} not found: using a synthetic model. "
        "Run :dump_gemma3_model to enable HF comparisons.")
    return ref.QuantizedGemma3.synthetic(), None


class Gemma3Harness:
    """Owns the DUT, the DDR image and the strict reference for one test."""

    def __init__(self, dut, r, model, max_seq, extra_bytes=0):
        self.dut, self.r, self.model, self.max_seq = dut, r, model, max_seq
        self.ref = ref.Gemma3Reference(model, max_seq)
        self.image, self.desc = ref.build_image(model, DDR_BASE, max_seq)
        # Room the test may reserve later (T6 grows the lm_head region).
        self.extra_bytes = extra_bytes

    async def start(self):
        ext_mem_size = (self.image.size + self.extra_bytes + (1 << 20) + 0xFFFFF) & ~0xFFFFF
        self.fixture = await Fixture.Create(
            self.dut, highmem=True, ext_mem_base_addr=DDR_BASE,
            ext_mem_size=ext_mem_size)
        await self.fixture.load_elf_and_lookup_symbols(
            _rloc(self.r, ELF) or ELF,
            ["model", "ctrl", "x_in", "x_out", "dbg_q", "dbg_attn", "dbg_ffn"])
        # Backdoor: the weights go straight into the testbench-side memory
        # model. ~100 MB over AXI would take hours of simulated time.
        blob = self.image.to_bytes()
        self.mem = self.fixture.core_mini_axi.memory
        self.mem[0:blob.size] = blob
        await self.fixture.write("model", self.desc)
        mode = "RTL axi_sim_mem" if self.fixture.core_mini_axi.ext_mem_in_rtl else "Python AXI model"
        self.dut._log.info(
            f"external memory: {mode}; DDR image {blob.size / 2**20:.1f} MiB at 0x{DDR_BASE:08x}, "
            f"ext_mem_size {ext_mem_size / 2**20:.0f} MiB, max_seq {self.max_seq}")

    # -- DDR helpers (backdoor, zero simulated time) --
    def ddr_read(self, addr, nbytes):
        off = addr - DDR_BASE
        return np.array(self.mem[off:off + nbytes])

    def ddr_write(self, addr, arr):
        b = np.ascontiguousarray(arr).view(np.uint8).reshape(-1)
        off = addr - DDR_BASE
        self.mem[off:off + b.size] = b

    def logits(self, n):
        return self.ddr_read(self.image.addr["logits"], 4 * n).view(np.float32)

    def timeout(self, n_layers, vocab_rows=0):
        return (n_layers * CYCLES_PER_LAYER + vocab_rows * CYCLES_PER_LM_HEAD_ROW
                + 2_000_000)

    async def run(self, cmd, pos, x, layer_lo=0, layer_hi=0):
        f = self.fixture
        await f.write("x_in", np.asarray(x, np.float32))
        await f.write("ctrl", ref.pack_ctrl(cmd, pos, layer_lo, layer_hi))
        n_layers = {ref.CMD_LAYERS: layer_hi - layer_lo, ref.CMD_LM_HEAD: 0,
                    ref.CMD_FORWARD: ref.LAYERS}[cmd]
        rows = 0 if cmd == ref.CMD_LAYERS else self.model.lm_head_i8.shape[1]
        await f.run_to_halt(timeout_cycles=self.timeout(n_layers, rows))
        ctrl = ref.unpack_ctrl((await f.read("ctrl", 4 * ref.CTRL_WORDS)).view(np.uint32))
        assert ctrl["status"] == 1, (
            f"runner status {ref.STATUS_NAMES.get(ctrl['status'], ctrl['status'])}, "
            f"io_fault={int(self.dut.io_fault.value)} io_halted={int(self.dut.io_halted.value)} "
            f"after {ctrl['total_cycles']} cycles")
        out = {
            "ctrl": ctrl,
            "x": (await f.read("x_out", 4 * ref.HIDDEN)).view(np.float32).copy(),
            "q": (await f.read("dbg_q", 4 * ref.Q_DIM)).view(np.float32).copy(),
            "attn": (await f.read("dbg_attn", 4 * ref.Q_DIM)).view(np.float32).copy(),
            "ffn": (await f.read("dbg_ffn", 4 * ref.FFN)).view(np.float32).copy(),
        }
        if cmd != ref.CMD_LAYERS:
            out["logits"] = self.logits(rows).copy()
            out["argmax"] = ctrl["argmax"]
        return out

    def log_perf(self, label, ctrl, n_layers, vocab_rows=0):
        macs = n_layers * MACS_PER_LAYER + vocab_rows * ref.HIDDEN
        log_matmul_metrics(self.dut, label, ctrl["total_cycles"], macs=macs)
        rows = "\n".join(f"  {n:>14}: {ctrl['op_' + n]:>12,}" for n in ref.OP_NAMES)
        self.dut._log.info(f"per-op cycles for {label}:\n{rows}")


def check_strict(dut, name, actual, expected):
    cos = ref.cosine(actual, expected)
    rel = ref.rel_max_err(actual, expected)
    dut._log.info(f"{name}: strict cos={cos:.6f} rel_max_err={rel:.2e}")
    assert cos > STRICT_COS and rel < STRICT_REL_MAX, \
        f"{name}: DUT diverged from strict reference (cos={cos:.6f}, rel={rel:.2e})"


def check_hf(dut, name, actual, hf, thresh=HF_COS):
    if hf is None:
        return
    cos = ref.cosine(actual, hf)
    dut._log.info(f"{name}: HF bf16 cos={cos:.6f}")
    assert cos > thresh, f"{name}: DUT vs HF bf16 cos={cos:.6f} < {thresh}"


def prompt_embed(prompt, pos, rng):
    if prompt is not None:
        return prompt["embeds"][pos]
    return rng.normal(scale=1.0, size=ref.HIDDEN).astype(np.float32)


def hf_hidden(prompt, layer_after, pos):
    return None if prompt is None else prompt["hidden_states"][layer_after][pos]


def check_hf_residual(dut, name, x, prompt, layer_after, pos, model, thresh=HF_COS):
    """Compare a residual with HF's hidden state after `layer_after` layers.

    HF's output_hidden_states[-1] is taken *after* the final RMSNorm, not the
    raw output of the last decoder layer, so for layer_after == LAYERS the
    DUT residual is passed through the final norm first (which also checks
    the final-norm weights and the reference norm against HF).
    """
    hf = hf_hidden(prompt, layer_after, pos)
    if hf is None:
        return
    if layer_after == ref.LAYERS:
        check_hf(dut, name + " (after final norm)", ref.rms_norm(x, model.final_norm), hf, thresh)
    else:
        check_hf(dut, name, x, hf, thresh)


# ---------------------------------------------------------------------------
@cocotb.test()
async def gemma3_layer0_decode_step(dut):
    """T1: layer 0 at position 0. Fastest end-to-end check of the ABI, the
    int8 GEMV path, RMSNorm, q/k norm, RoPE, attention over one key, GELU."""
    r = runfiles.Create()
    model, prompt = load_test_data(dut, r)
    h = Gemma3Harness(dut, r, model, max_seq=8)
    await h.start()
    rng = np.random.default_rng(42)
    x = prompt_embed(prompt, 0, rng)

    out = await h.run(ref.CMD_LAYERS, pos=0, x=x, layer_lo=0, layer_hi=1)
    exp, taps = h.ref.layers(x, 0, 1, pos=0)
    check_strict(dut, "layer0 q (post norm+rope)", out["q"], taps["q"])
    check_strict(dut, "layer0 attention out", out["attn"], taps["attn"])
    check_strict(dut, "layer0 gelu*up", out["ffn"], taps["ffn"])
    check_strict(dut, "layer0 residual", out["x"], exp)
    check_hf(dut, "layer0 residual", out["x"], hf_hidden(prompt, 1, 0))
    h.log_perf("gemma3 layer0 decode step", out["ctrl"], n_layers=1)


@cocotb.test()
async def gemma3_layer_sweep_teacher_forced(dut):
    """T2: every layer in isolation, fed HF's residual stream at its input
    (position 0). Localizes a failure to one layer and covers the global
    (rope base 1e6) layers 5, 11, 17."""
    r = runfiles.Create()
    model, prompt = load_test_data(dut, r)
    h = Gemma3Harness(dut, r, model, max_seq=8)
    await h.start()
    rng = np.random.default_rng(42)
    x = prompt_embed(prompt, 0, rng)
    for i in range(ref.LAYERS):
        x_in = hf_hidden(prompt, i, 0) if prompt is not None else x
        out = await h.run(ref.CMD_LAYERS, pos=0, x=x_in, layer_lo=i, layer_hi=i + 1)
        exp, _ = h.ref.layers(x_in, i, i + 1, pos=0)
        kind = "global" if ref.is_global_layer(i) else "local"
        check_strict(dut, f"layer{i} ({kind}) residual", out["x"], exp)
        check_hf_residual(dut, f"layer{i} ({kind}) residual", out["x"], prompt, i + 1, 0, h.model)
        h.log_perf(f"gemma3 layer{i} ({kind})", out["ctrl"], n_layers=1)
        x = exp


@cocotb.test()
async def gemma3_layer0_prefill(dut):
    """T3: layer 0 over the first N prompt positions, one token per run.
    Exercises KV-cache growth, RoPE at pos > 0 and softmax over N keys."""
    r = runfiles.Create()
    model, prompt = load_test_data(dut, r)
    n = int(os.environ.get("GEMMA3_PREFILL_TOKENS", 8))
    if prompt is not None:
        n = min(n, prompt["embeds"].shape[0])
    h = Gemma3Harness(dut, r, model, max_seq=max(n, 8))
    await h.start()
    rng = np.random.default_rng(42)
    for pos in range(n):
        x = prompt_embed(prompt, pos, rng)
        out = await h.run(ref.CMD_LAYERS, pos=pos, x=x, layer_lo=0, layer_hi=1)
        exp, taps = h.ref.layers(x, 0, 1, pos=pos)
        check_strict(dut, f"layer0 pos{pos} attention out", out["attn"], taps["attn"])
        check_strict(dut, f"layer0 pos{pos} gelu*up", out["ffn"], taps["ffn"])
        check_strict(dut, f"layer0 pos{pos} residual", out["x"], exp)
        check_hf(dut, f"layer0 pos{pos} residual", out["x"], hf_hidden(prompt, 1, pos))
        dut._log.info(f"pos {pos}: attention cycles {out['ctrl']['op_attention']:,}")


async def _forward_prompt(dut, h, prompt, rng, n_tokens):
    """Runs CMD_FORWARD over positions 0..n_tokens-1; returns the last output."""
    out = None
    for pos in range(n_tokens):
        x = prompt_embed(prompt, pos, rng)
        out = await h.run(ref.CMD_FORWARD, pos=pos, x=x)
        exp_x, exp_logits, exp_am = h.ref.forward(x, pos)
        check_strict(dut, f"pos{pos} final residual", out["x"], exp_x)
        check_strict(dut, f"pos{pos} candidate logits", out["logits"], exp_logits)
        check_hf_residual(dut, f"pos{pos} final residual", out["x"], prompt, ref.LAYERS, pos, h.model,
                          HF_FULL_COS)
        dut._log.info(f"pos {pos}: argmax col {out['argmax']} (strict ref {exp_am}) "
                      f"-> vocab id {int(h.model.lm_head_ids[out['argmax']])}")
        assert out["argmax"] == exp_am, f"pos{pos}: argmax {out['argmax']} != strict {exp_am}"
        h.log_perf(f"gemma3 forward pos{pos}", out["ctrl"], ref.LAYERS,
                   h.model.lm_head_i8.shape[1])
    return out


@cocotb.test()
async def gemma3_next_token_candidates(dut):
    """T4: full 18-layer forward over the prompt; logits restricted to the
    candidate vocab rows (HF top-k per position + greedy ids + random rows).
    Asserts the DUT's next token equals HF bf16's."""
    r = runfiles.Create()
    model, prompt = load_test_data(dut, r)
    n_tokens = int(os.environ.get("GEMMA3_PROMPT_TOKENS", 4))
    if prompt is not None:
        n_tokens = min(n_tokens, prompt["embeds"].shape[0])
    h = Gemma3Harness(dut, r, model, max_seq=max(n_tokens, 8))
    await h.start()
    rng = np.random.default_rng(42)
    out = await _forward_prompt(dut, h, prompt, rng, n_tokens)
    if prompt is None:
        return
    cand = h.model.lm_head_ids
    # HF's logits at the last position, restricted to the same columns.
    if n_tokens == prompt["embeds"].shape[0]:
        hf_logits = prompt["logits_last"][cand]
        check_hf(dut, "last-position candidate logits", out["logits"], hf_logits,
                 HF_LOGIT_COS)
    hf_top1 = int(prompt["topk_ids"][n_tokens - 1][0])
    dut_top1 = int(cand[out["argmax"]])
    dut._log.info(f"next token: DUT {dut_top1}, HF bf16 {hf_top1}")
    assert dut_top1 == hf_top1, f"top-1 mismatch: DUT {dut_top1} vs HF {hf_top1}"


@cocotb.test()
async def gemma3_greedy_generate(dut):
    """T5 (slow, manual): greedy decode of GEMMA3_GEN_TOKENS tokens after the
    prompt; every generated id must equal HF's greedy continuation."""
    r = runfiles.Create()
    model, prompt = load_test_data(dut, r)
    if prompt is None:
        dut._log.warning("Skipping greedy generation: needs the HF dump.")
        return
    n_prompt = prompt["embeds"].shape[0]
    n_gen = min(int(os.environ.get("GEMMA3_GEN_TOKENS", 4)), prompt["gen_ids"].size)
    h = Gemma3Harness(dut, r, model, max_seq=n_prompt + n_gen + 1)
    await h.start()
    rng = np.random.default_rng(42)
    out = await _forward_prompt(dut, h, prompt, rng, n_prompt)
    cand = h.model.lm_head_ids
    generated = []
    for s in range(n_gen):
        tok = int(cand[out["argmax"]])
        generated.append(tok)
        want = int(prompt["gen_ids"][s])
        dut._log.info(f"gen step {s}: DUT {tok}, HF {want}, "
                      f"{out['ctrl']['total_cycles']:,} cycles")
        assert tok == want, f"greedy divergence at step {s}: DUT {tok} vs HF {want}"
        if s + 1 < n_gen:
            out = await h.run(ref.CMD_FORWARD, pos=n_prompt + s, x=prompt["gen_embeds"][s])
    dut._log.info(f"generated {generated} == HF {prompt['gen_ids'][:n_gen].tolist()}")


@cocotb.test()
async def gemma3_full_vocab_logits(dut):
    """T6 (slow, manual): full 262 144-row lm_head at the last prompt
    position, scored in 4096-column chunks. Needs gemma3_lm_head_i8.npy."""
    r = runfiles.Create()
    model, prompt = load_test_data(dut, r)
    full_i8, full_s = _rloc(r, LM_HEAD_I8), _rloc(r, LM_HEAD_S)
    if prompt is None or not (full_i8 and full_s):
        dut._log.warning("Skipping full-vocab logits: needs the HF dump with --full_lm_head.")
        return
    full_i8 = np.load(full_i8, mmap_mode="r")
    full_s = np.load(full_s)
    n_prompt = prompt["embeds"].shape[0]
    chunk = ref.MAX_VOCAB_ROWS
    h = Gemma3Harness(dut, r, model, max_seq=max(n_prompt, 8),
                      extra_bytes=(ref.HIDDEN + 4) * chunk)
    await h.start()
    rng = np.random.default_rng(42)
    out = await _forward_prompt(dut, h, prompt, rng, n_prompt)
    x_final = out["x"]

    lm_addr, s_addr = h.image.addr["lm_head"], h.image.addr["lm_head_scale"]
    assert model.lm_head_i8.shape[1] <= chunk
    logits = np.zeros(ref.VOCAB, np.float32)
    for c0 in range(0, ref.VOCAB, chunk):
        rows = np.arange(c0, min(c0 + chunk, ref.VOCAB))
        sub = h.model.select_rows(rows, full_i8, full_s)
        # The reserved lm_head region only holds the candidate columns; grow
        # the image once so a full 4096-column chunk fits.
        if c0 == 0 and h.model.lm_head_i8.shape[1] < chunk:
            lm_addr = h.image.reserve("lm_head_full", ref.HIDDEN * chunk)
            s_addr = h.image.reserve("lm_head_full_scale", 4 * chunk)
            h.desc[ref.MODEL_FIELDS.index("lm_head")] = lm_addr
            h.desc[ref.MODEL_FIELDS.index("lm_head_scale")] = s_addr
        h.desc[ref.MODEL_FIELDS.index("vocab_rows")] = rows.size
        h.ddr_write(lm_addr, sub.lm_head_i8)
        h.ddr_write(s_addr, sub.lm_head_s)
        await h.fixture.write("model", h.desc)
        h.model = sub
        h.ref.m = sub
        o = await h.run(ref.CMD_LM_HEAD, pos=n_prompt - 1, x=x_final)
        exp_logits, _ = h.ref.lm_head(x_final)
        check_strict(dut, f"logits rows {c0}..{c0 + rows.size - 1}", o["logits"], exp_logits)
        logits[rows] = o["logits"]
    hf = prompt["logits_last"]
    cos = ref.cosine(logits, hf)
    dut_top5 = set(np.argsort(-logits)[:5].tolist())
    hf_top5 = set(np.argsort(-hf)[:5].tolist())
    dut._log.info(f"full-vocab logits: cos={cos:.5f} top1 DUT {np.argmax(logits)} "
                  f"HF {np.argmax(hf)} top5 overlap {len(dut_top5 & hf_top5)}/5")
    assert cos > HF_LOGIT_COS
    assert int(np.argmax(logits)) == int(np.argmax(hf))
