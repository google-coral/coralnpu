# Gemma 3 270M inference tests (cocotb, Verilator)

End-to-end inference of `google/gemma-3-270m` on `RvvCoreMiniHighmemAxi`,
built from the per-kernel tests in `../gemma_kernels/`. The per-kernel suite
proves each op in isolation; this suite proves the composition: real weights,
real prompt, KV cache across tokens, next-token agreement with the HF bf16
model. It is the RTL-level numerics gate that `CLAUDE.md` asks for ("any change
that could alter output codes must be validated against the bf16 HF
reference"), and the per-op cycle table it prints is the baseline the GR-288
work is measured against.

Status (2026-09-05): T1, T2 and T3 pass on the EC2 dev host with real
Gemma 3 270M weights (section 7 has the numbers); T4 is running. T5 and T6
are manual. The suite runs on the `RvvCoreMiniHighmemAxiSimMem` model, which
keeps external memory inside the RTL (section 8); on the stock model with the
Python AXI memory a token costs about 90 minutes of simulation.

## 1. What is being tested

| Property | Value (config.json, verified) |
|---|---|
| Layers / hidden / FFN | 18 / 640 / 2048 |
| Attention | 4 query heads, 1 KV head, head_dim 256, `query_pre_attn_scalar` 256 |
| Norms | RMSNorm `(1 + w)`, eps 1e-6: input, post-attn, pre-FFN, post-FFN, q_norm, k_norm, final |
| RoPE | rotate_half, base 10 000 on sliding layers, 1 000 000 on global layers 5, 11, 17 |
| Sliding window | 512; the tests keep every position below 512, so sliding == full attention |
| Activation | `gelu_pytorch_tanh(gate) * up` |
| Vocab / lm_head | 262 144, tied to the embedding table |
| Softcapping | none (attn and final both `null`) |

Numerics under test (fixed by `gemma3_model.h` and `gemma3_ref.py`):

* every projection is int8 x int8 -> int32 on `rvv_gemv_int8`, weights
  quantized per output channel (symmetric, RNE, clipped to +/-127), activations
  quantized per token at runtime (same rule, `gemma3_quantize_f32_to_i8`);
* everything else is fp32: norms, RoPE, attention (FlashAttentionRVV, Taylor
  exp), GELU (rational tanh), residual stream, K/V cache, logits;
* the DUT never sees the embedding table. The test supplies the scaled
  embedding vector for each token (HF's `embed_tokens` output as fp32), and
  the lm_head is scored on a chosen set of vocab columns (<= 4096 per run).

Two references, two kinds of assertion:

| Reference | What it is | Assertion |
|---|---|---|
| strict | `gemma3_ref.py` replays the runner's dataflow in NumPy with the same int8 weights and quantizer, exact exp/tanh | cos > 0.9999 and max err / max ref < 2e-2 on every tap (q, attention out, gelu*up, residual, logits); argmax equal |
| HF bf16 | `dump_gemma3_model.py` runs the HF model in bfloat16 and stores hidden states after every layer, last-position logits, top-k ids, and the greedy continuation | cos > 0.99 per layer residual, cos > 0.98 on logits, top-1 equal, greedy ids equal |

The strict reference makes a failure attributable: an int8 GEMV mismatch is
exact and shows up as a hard error, an fp32 op mismatch shows up as a tolerance
miss on one tap. The HF reference measures the quantization scheme itself.
Both tolerances are provisional and should be tightened from measured margins
after the first run.

## 2. Test tiers

| Test | Runs | Checks | Est. cycles | Purpose |
|---|---|---|---|---|
| T1 `gemma3_layer0_decode_step` | layer 0, pos 0 | 4 taps strict, residual vs HF | ~1 layer | ABI, every kernel once, fastest smoke |
| T2 `gemma3_layer_sweep_teacher_forced` | each layer alone at pos 0, input = HF residual entering that layer | residual strict + HF per layer | 18 layers | isolates a failing layer; covers both RoPE bases |
| T3 `gemma3_layer0_prefill` | layer 0 at pos 0..7, one token per run | attention tap + residual per position | 8 layers | KV-cache growth, RoPE at pos > 0, softmax over N keys |
| T4 `gemma3_next_token_candidates` | all 18 layers, prompt positions 0..N-1, lm_head on ~300 candidate columns | final residual strict + HF each position; last-position logits vs HF; DUT top-1 == HF top-1 | 18 x N layers | the headline "does it predict the right token" test |
| T5 `gemma3_greedy_generate` (slow) | T4 then M greedy steps feeding HF's embedding of the DUT's own output | each generated id == HF greedy id | 18 x (N+M) | multi-token generation, cache beyond the prompt |
| T6 `gemma3_full_vocab_logits` (slow) | T4 then 64 lm_head runs of 4096 columns | full 262 144 logits: cos vs HF, top-1, top-5 overlap | 18 x N + 168M MACs | quantized lm_head over the whole vocabulary |

"Est. cycles" is in units of one decoder layer, about 5.57M int8 MACs plus the
fp32 ops. The int8 GEMV rate on this core has not been measured here; at 2 to
8 MACs per cycle one layer is 0.7M to 3M cycles, one full forward 13M to 50M
cycles. Verilator throughput for `RvvCoreMiniHighmemAxi` is also unmeasured;
the existing FlashAttention test budgets 40M cycles inside Bazel's
"enormous" timeout, so one T4 token should fit and T5/T6 are correctly tagged
as manual, multi-hour runs. Timeouts are computed from
`GEMMA3_CYCLES_PER_LAYER` (default 4M) and can be overridden wholesale with
`COCOTB_TIMEOUT_CYCLES`. Prompt length is `GEMMA3_PROMPT_TOKENS` (default 4),
generation length `GEMMA3_GEN_TOKENS` (default 4), prefill length
`GEMMA3_PREFILL_TOKENS` (default 8).

Without a dump in `test_data/` every test still runs on a synthetic model of
the right shapes with the strict reference only, and logs a warning; T5 and T6
return early because they are meaningless without HF data. This follows the
convention of `rvv_flashattention_cocotb_test.py`.

## 3. How the test talks to the DUT

```
 cocotb test (Python)                              RvvCoreMiniHighmemAxi
 --------------------                              ---------------------
 QuantizedGemma3 ---> build_image() ---> bytes --> core.memory[...]   (DDR, 0x8000_0000, backdoor numpy write)
                    \-> descriptor (431 words) --> `model` symbol     (DTCM .data, AXI write)
 per command:  x_in, ctrl{cmd,pos,layer_lo,layer_hi} --> AXI write
               run_to_halt()
               ctrl{status,argmax,total_cycles,op_cycles[12]}, x_out, dbg_q, dbg_attn, dbg_ffn <-- AXI read
               logits <-- core.memory (backdoor)
```

* **Weights never cross the AXI bus.** ~97 MiB for 18 layers is written
  straight into the testbench-side memory model (`CoreMiniAxiInterface.memory`),
  the same array `load_elf_backdoor` uses for DDR segments. At 16 B per beat
  the bus path would take longer than the inference. The DUT reads weights
  through its AXI master as it would from real DDR.
* **The ELF is model-size independent.** `Gemma3Model` holds DDR addresses
  for every tensor; the test owns the layout (`ModelImage`). Changing the
  candidate vocab, the sequence length, or swapping to the full lm_head does
  not rebuild the ELF.
* **One run per (token, command).** `CMD_LAYERS` runs `[layer_lo, layer_hi)`
  on `x_in`; `CMD_LM_HEAD` runs final norm + lm_head; `CMD_FORWARD` does both.
  The K/V caches live in DDR and persist across runs because the memory model
  is testbench-side, so prefill is simply decode repeated at pos = 0, 1, 2...
  This is exactly causal with `Q_len = 1`, which is why the unmasked
  `FlashAttentionRVV` is sufficient.
* **Debug taps.** The runner exports the last layer's post-RoPE q, attention
  output and `gelu*up`; the strict reference produces the same taps, so a
  failure is attributed to a stage, not just a layer.
* **Per-op cycle table.** `mcycle` is read around every kernel call and summed
  into 12 buckets (`Gemma3Op`). `log_matmul_metrics` prints MACs/cycle per run
  and the test logs the bucket table. This is the baseline for the GR-288
  cadence work: it says where the RVV core spends time per token today.

## 4. Files

| File | Role |
|---|---|
| `gemma3_model.h` | ABI: constants, `Gemma3Model` / `Gemma3LayerWeights` / `Gemma3Control` structs (all `uint32_t`), command and status codes, op buckets |
| `gemma3_runner.cc` | DUT program. Decoder layer and lm_head in HF op order, calling the existing kernels |
| `gemma3_aux_kernels.cc` | The four kernels `gemma_kernels/` lacks: activation quantize, int32 dequant, RoPE, argmax (RVV intrinsics) |
| `gemma3_ref.py` | Strict reference, synthetic model, `ModelImage` DDR packer, descriptor/ctrl packing, metrics helpers. `python3 gemma3_ref.py` self-tests the packing |
| `dump_gemma3_model.py` | HF bf16 -> `test_data/gemma3_weights.npz`, `gemma3_prompt.npz`, optional full `gemma3_lm_head_i8.npy` |
| `cocotb_tests/gemma3_inference_cocotb_test.py` | The six tests and the `Gemma3Harness` |
| `BUILD` | `gemma3_runner` ELF, `gemma3_ref` library + self-test, `dump_gemma3_model`, two `cocotb_test_suite`s |
| `../gemma_kernels/BUILD` | gained `cc_library(name = "gemma_kernels")` wrapping the five kernel sources so this package links the same code the per-kernel tests exercise |

## 5. Running

All commands go through `tools/dev/bazel-docker.sh` on the Mac (see
`docs/gr288-port-map.md` section 1) or run natively on the EC2 dev host.

```bash
# 0. Host-side sanity, no Bazel needed
python3 tests/cocotb/rvv/ml_ops/gemma_inference/gemma3_ref.py

# 1. Reference data (once; needs HF access to the gated model or a mirror)
bazel run //tests/cocotb/rvv/ml_ops/gemma_inference:dump_gemma3_model -- \
    --out_dir $PWD/tests/cocotb/rvv/ml_ops/gemma_inference/test_data \
    --prompt "The capital of France is" --gen_tokens 8            # add --full_lm_head for T6

# 2. Fast tier, one test at a time (targets are <suite>_<testcase>)
bazel test //tests/cocotb/rvv/ml_ops/gemma_inference:gemma3_inference_cocotb_test_gemma3_layer0_decode_step
bazel test //tests/cocotb/rvv/ml_ops/gemma_inference:gemma3_inference_cocotb_test

# 3. Slow tier
bazel test //tests/cocotb/rvv/ml_ops/gemma_inference:gemma3_inference_slow_cocotb_test_gemma3_greedy_generate \
    --test_env=GEMMA3_GEN_TOKENS=8 --test_timeout=36000
```

`test_data/` is git-ignored by intent: the weights npz is ~100 MB and the
full lm_head 168 MB.

## 6. Known limits and decisions

* **Embedding lookup is off-DUT.** The 262 144 x 640 table is 168 MB int8;
  keeping it host-side keeps the image at 97 MiB and the ELF small. If GR-288
  makes the table model-resident, add a `CMD_EMBED` that gathers a row and
  scales by sqrt(640); the descriptor already has room for a pointer.
* **Sliding window is not exercised.** With positions < 512 the sliding
  layers are identical to full attention, and the runner has no window logic.
  A position >= 512 test would need both a masked kernel and ~512 x 18 runs;
  out of scope until the simulator is faster or the FPGA flow is used.
* **Prefill is sequential.** The 2D prefill kernel paths (`rvv_matmul_int8`,
  FlashAttention `Q_len > 1`) are unused; the unmasked FlashAttention kernel
  cannot do causal prefill in one call. Sequential decode is slower but
  exact. A prefill-mode runner is a natural follow-up once a masked or
  causal-tiled attention kernel exists.
* **Activation quantization is per-token, per-tensor.** This is the simplest
  scheme consistent with `rvv_gemv_int8`'s "-128 on at most one side" rule. If
  HF agreement at the logits is too loose (cos < 0.98), the first thing to try
  is per-group scales on the down_proj input (2048 wide, heavy tailed after
  GELU); the strict reference and dump script both go through
  `quantize_weight` / `quantize_act`, so a scheme change is one function each.
* **Three exp implementations coexist** in the kernel set (port map section
  3). The strict reference uses exact `np.exp`; the 2e-2 relative tolerance
  is there to absorb the Taylor/rational approximations. If a tap exceeds it,
  compare against a reference that uses the kernel's polynomial before
  blaming the RTL.
* **`stack_size_bytes = 4096`.** The kernels' own runners use the 128-byte
  default; the composed program has deeper call chains. All large buffers are
  static in DTCM (~40 KB) so 1 MB DTCM is far from full.
* **Not yet run.** See status at the top. First-run checklist: link the ELF,
  confirm `readelf -S` shows no DDR-resident sections, run T1 on the
  synthetic model, then generate the dump and run T1 to T4 with real weights,
  then set the tolerances from the printed margins.

## 7. Measured results (EC2 c7i.2xlarge, Verilator 5.050)

T1, layer 0, position 0, prompt "The capital of France is", weights from
`unsloth/gemma-3-270m-it`:

| Tap | cos (strict) | rel. max err | cos (HF bf16) |
|---|---|---|---|
| q after norm + RoPE | 1.000000 | 1.1e-7 | |
| attention out | 1.000000 | 6.0e-8 | |
| gelu(gate) * up | 0.999995 | 4.8e-4 | |
| residual | 1.000000 | 2.6e-9 | 0.999995 |

Cycle accounting for one decoder layer (RTL external memory, 1-cycle DDR):

| Op | Cycles |
|---|---|
| gate/up GEMV | 934K (Python-memory run; RTL-memory run total 1.78M) |
| down GEMV | 466K |
| q/k/v GEMV | 350K |
| o GEMV | 233K |
| norms, quant, dequant, gelu, residual, RoPE, attention | 99K |
| total | 2,132,836 with the Python memory model, 1,780,644 with `axi_sim_mem` |

int8 GEMV runs at 2.8 MAC/cycle; the layer averages 2.6 to 3.1 MAC/cycle
depending on memory latency. A token is 18 x 1.78M = 32M cycles plus the
lm_head (640 MACs per scored vocab row).

Simulator throughput, T1 (`ns/s` from the cocotb summary, clock 1.25 ns):

| Configuration | cycles/s | wall per token (32M cycles) |
|---|---|---|
| stock model, Python AXI memory, polling agents | 7.2k | ~90 min |
| `*SimMem` model, DDR in RTL, event-driven cocotb | 16.5k | ~32 min |
| same, Verilator `--threads 2` (the configured default) | 24.8k | ~22 min |
| same, Verilator `--threads 4` | 25.9k | ~21 min |
| `--threads 2` + `-O3 --x-initial fast` (configured default) | +9% over the row above in a back-to-back A/B | ~20 min |

`-CFLAGS -march=native` was part of the +9% measurement but is not in the
BUILD so the cached model stays portable; add it locally if the build host is
the run host.

T2 (each of the 18 layers fed HF's residual at its input, position 0): every
layer matches the strict reference with cos 1.000000 and relative max error
between 8e-8 and 1.2e-3, and HF bf16 with cos 0.99999 or better, on both the
local (1e4) and global (1e6) RoPE bases. T4, first forward (BOS, all 18
layers): final residual 1.2e-7 and candidate logits 6.6e-7 relative to the
strict reference, i.e. the DUT executes the int8 model exactly; the int8
model itself drifts from bf16 HF to cos 0.9875 after the final norm, which
is why the full-stack HF bar is 0.98 and the top-1 check is the gate. The
first predicted token (position 0, after BOS) agrees with the strict
reference; the whole forward including the 530-column lm_head is
32,011,264 cycles (3.14 MAC/cycle), about 21 minutes of wall time on the
SimMem model with two Verilator threads.

### Two lessons from the first real-weight runs

* **The strict reference must replay the kernels' approximations.** The
  FlashAttention exp is a range-reduced cubic Taylor polynomial (8e-4
  relative) and the GELU tanh is `y(y^2+27)/(9y^2+27)` on `clamp(z, -3, 3)`
  (2.4e-2 absolute). The FFN intermediate is int8-quantised per tensor with
  Gemma's outliers, so a 1e-3 difference between exact tanh and the kernel
  flips int8 codes with a large step and the residual diverges by percent
  amounts. With `kernel_exp` / `kernel_tanh` in `gemma3_ref.py` the DUT
  matches the reference to ~1e-7 on every tap at every prefill position;
  before, position 2 failed at 3.6e-2. `exact=True` keeps the exact forms for
  measuring the approximation itself.
* **HF's last hidden state is post-norm.** `output_hidden_states[-1]` is
  taken after the final RMSNorm, so the DUT's last-layer residual is passed
  through the final norm before that comparison (`check_hf_residual`). The
  raw comparison reads as cosine 0.15 and looks like a broken layer 17.

## 8. The `*SimMem` model

`tests/cocotb/BUILD` builds `rvv_core_mini_highmem_axi_simmem_model` from a
generated wrapper (`hdl/verilog/gen_axi_sim_mem_wrapper.py`) that instantiates
the emitted core and connects its AXI master to `hdl/verilog/axi_sim_mem.sv`,
whose storage is C++ (`ddr_sim_mem.cc`) behind DPI. The testbench loads and
reads that memory through `ddr_backdoor_*_c` (ctypes, like the SRAM backdoor),
so the 97 MiB image and every weight beat stay out of Python.
`CoreMiniAxiInterface` detects the wrapper (no `io_axi_master_*` ports),
switches `memory` to `DdrBackdoorMemory`, skips the master agents, lets the
bus monitor sleep unless a testbench transaction is in flight, and waits for
`io_halted` on an edge instead of polling. The plain models are unaffected
(`rvv_int8_matmul_test_gemv` still passes with the patched interface).

Pitfall found on the way: the Verilator config marks every `io_*` variable of
the top module public, so the wrapper's internal nets must not be named
`io_axi_master_*`, or cocotb sees them and drives them alongside the memory.

What remains is Verilator's own evaluation cost for this core (about 60 us per
cycle single-threaded). Verilator's scheduler warns (UNOPTTHREADS) that it cannot
partition this design for 4 threads; forced anyway, 2 threads give 1.5x and 4
threads only 4% more, so the model is built with 2 and four tiers run in
parallel on the 8-vCPU host; `TB_SUPPORT` only threads a uop PC through the
vector pipeline and is not worth removing. Multi-token generation belongs on
the FPGA (50 MHz: about 0.65 s per token) rather than in RTL simulation.

Arcilator was probed as an alternative kernel (CIRCT `circt-verilog --ir-hw`
on the emitted core plus the SimMem wrapper, `-DXSIM` to skip the SVA
blocks and keep the behavioral SRAM). Parsing and elaboration of the 13 MB
design take 80 s, but the Moore-to-core lowering did not finish in 3 h of
single-threaded CPU (2.4 GB), so no arcilator model could be built. That
path needs work on the CIRCT side (or per-module lowering) before it can
be evaluated; see docs/gemma3-sim-report.
