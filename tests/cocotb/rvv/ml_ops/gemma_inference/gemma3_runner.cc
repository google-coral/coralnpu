// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Gemma 3 270M single-token inference runner for the RvvCoreMiniHighmemAxi
// cocotb testbench. One run of main() executes one Gemma3Control.cmd for one
// token position; the testbench re-runs the ELF per token (KV caches persist
// in DDR across runs because the AXI memory model is testbench-side).
//
// Dataflow per decoder layer (HF Gemma3DecoderLayer order):
//   h  = RMSNorm(x, input_norm)
//   q  = h Wq ; k = h Wk ; v = h Wv                (int8 gemv, per-token act scale)
//   q  = RMSNorm_head(q, q_norm) ; k = RMSNorm_head(k, k_norm)
//   q, k = RoPE(q, k, pos, base = is_global ? 1e6 : 1e4)
//   Kc[pos] = k ; Vc[pos] = v
//   a  = FlashAttention(q, Kc[0..pos], Vc[0..pos])   scale 1/sqrt(256) == query_pre_attn_scalar^-0.5
//   x += RMSNorm(a Wo, post_attn_norm)
//   h  = RMSNorm(x, pre_ffn_norm)
//   f  = gelu_tanh(h Wgate) * (h Wup)
//   x += RMSNorm(f Wdown, post_ffn_norm)
// Final: logits = RMSNorm(x, final_norm) lm_head[:, vocab_rows]; argmax.
//
// Every matmul is int8 x int8 -> int32 with a dynamic per-token activation
// scale and per-output-channel weight scales. Everything else is fp32.
// gemma3_ref.py replays the same arithmetic in NumPy.

#include <stddef.h>
#include <stdint.h>
#include <math.h>

#ifdef CORALNPU_HOST_TEST
extern uint64_t mcycle_read();
extern void *host_ddr_pointer(uint32_t addr);
#else
#include "sw/utils/utils.h"
#endif
#include "tests/cocotb/rvv/ml_ops/gemma_inference/gemma3_model.h"

extern "C" {
// Existing kernels from //tests/cocotb/rvv/ml_ops/gemma_kernels.
void rvv_gemv_int8(const int8_t *__restrict__ A, const int8_t *__restrict__ B,
                   int32_t *__restrict__ C, size_t K, size_t N);
void RmsNormF(size_t seq_len, size_t hidden_size, float epsilon, const float *__restrict__ input,
              const float *__restrict__ weight, float *__restrict__ output);
void rvv_tanh_gelu_mul_f32(const float *__restrict__ gate, const float *__restrict__ up,
                           float *__restrict__ output, size_t total_elements);
void rvv_residual_add_f32(const float *__restrict__ A, const float *__restrict__ B,
                          float *__restrict__ Y, size_t total_elements);
void FlashAttentionRVV(size_t Q_heads, size_t KV_heads, size_t Q_len, size_t KV_len, size_t Dim,
                       const float *Q, const float *K, const float *V, float *Output);
// Glue kernels from gemma3_aux_kernels.cc.
float gemma3_quantize_f32_to_i8(const float *__restrict__ x, int8_t *__restrict__ q, size_t n);
void gemma3_dequant_i32_to_f32(const int32_t *__restrict__ acc, float a_scale,
                               const float *__restrict__ w_scale, float *__restrict__ out,
                               size_t n);
void gemma3_rope_inplace(float *__restrict__ x, size_t n_heads, size_t head_dim,
                         const float *__restrict__ cos_row, const float *__restrict__ sin_row);
uint32_t gemma3_argmax_f32(const float *x, size_t n);

// ---- Testbench-visible symbols (DTCM .data) --------------------------------
#ifdef CORALNPU_HOST_TEST
#define NPU_DATA __attribute__((aligned(16)))
#else
#define NPU_DATA __attribute__((section(".data"), used, retain, aligned(16)))
#endif
Gemma3Model model NPU_DATA;
// Read by the blob builder to bind the firmware to its model architecture.
extern const uint32_t model_magic __attribute__((used, retain)) = GEMMA3_MAGIC;
Gemma3Control ctrl NPU_DATA;
float x_in[GEMMA3_HIDDEN] NPU_DATA;
float x_out[GEMMA3_HIDDEN] NPU_DATA;
// Debug taps: last layer's intermediate tensors, for localizing a mismatch.
float dbg_q[GEMMA3_Q_DIM] NPU_DATA;
float dbg_attn[GEMMA3_Q_DIM] NPU_DATA;
float dbg_ffn[GEMMA3_FFN] NPU_DATA;
}

// ---- Scratch (DTCM .bss) ----------------------------------------------------
#ifdef QWEN3_MODEL
// Qwen norm weights multiply directly; Gemma's RmsNormF applies (1 + w).
static void qwen_rms_norm(size_t rows, size_t dim, float eps, const float *in,
                          const float *weight, float *out) {
  for (size_t r = 0; r < rows; ++r) {
    float sum = 0;
    for (size_t i = 0; i < dim; ++i) sum += in[r * dim + i] * in[r * dim + i];
    float inv = 1.0f / sqrtf(sum / dim + eps);
    for (size_t i = 0; i < dim; ++i) out[r * dim + i] = (in[r * dim + i] * inv) * weight[i];
  }
}
#define RmsNormF qwen_rms_norm
#endif

static float x[GEMMA3_HIDDEN] __attribute__((aligned(16)));
static float h[GEMMA3_HIDDEN] __attribute__((aligned(16)));
static float q[GEMMA3_Q_DIM] __attribute__((aligned(16)));
static float k[GEMMA3_KV_DIM] __attribute__((aligned(16)));
static float v[GEMMA3_KV_DIM] __attribute__((aligned(16)));
static float attn[GEMMA3_Q_DIM] __attribute__((aligned(16)));
static float gate[GEMMA3_FFN] __attribute__((aligned(16)));
static float up[GEMMA3_FFN] __attribute__((aligned(16)));
static float tmp[GEMMA3_FFN] __attribute__((aligned(16)));
static int8_t a_q[GEMMA3_FFN] __attribute__((aligned(16)));
static int32_t acc[GEMMA3_MAX_VOCAB_ROWS] __attribute__((aligned(16)));

template <typename T>
static inline T *P(uint32_t addr) {
#ifdef CORALNPU_HOST_TEST
  return static_cast<T *>(host_ddr_pointer(addr));
#else
  return reinterpret_cast<T *>(addr);
#endif
}

#define TIMED(op, stmt)                                  \
  do {                                                   \
    uint32_t _t0 = (uint32_t)mcycle_read();              \
    stmt;                                                \
    ctrl.op_cycles[op] += (uint32_t)mcycle_read() - _t0; \
  } while (0)

// In-place wrappers for kernels whose pointer parameters are __restrict__
// qualified: the caller aliased input and output, which gcc rejects with
// -Werror=restrict. Go through a scratch buffer instead.
static float inplace_scratch[GEMMA3_Q_DIM > GEMMA3_HIDDEN ? GEMMA3_Q_DIM : GEMMA3_HIDDEN];
static void rms_norm_inplace(size_t rows, size_t dim, float *xio, const float *w) {
  RmsNormF(rows, dim, GEMMA3_RMS_EPS, xio, w, inplace_scratch);
  for (size_t i = 0; i < rows * dim; ++i) xio[i] = inplace_scratch[i];
}
static void residual_add_inplace(float *xio, const float *y, size_t n) {
  rvv_residual_add_f32(xio, y, inplace_scratch, n);
  for (size_t i = 0; i < n; ++i) xio[i] = inplace_scratch[i];
}

// out[N] = dequant(quant(in[K]) . W[KxN])
static void linear_int8(const float *in, size_t K, uint32_t w, uint32_t s, size_t N, float *out,
                        Gemma3Op gemv_op) {
  float a_scale;
  TIMED(GEMMA3_OP_QUANT, a_scale = gemma3_quantize_f32_to_i8(in, a_q, K));
  TIMED(gemv_op, rvv_gemv_int8(a_q, P<const int8_t>(w), acc, K, N));
  TIMED(GEMMA3_OP_DEQUANT, gemma3_dequant_i32_to_f32(acc, a_scale, P<const float>(s), out, N));
}

static void decoder_layer(const Gemma3LayerWeights &L, uint32_t pos) {
  const size_t H  = GEMMA3_HIDDEN;
  const size_t D  = GEMMA3_HEAD_DIM;
  const size_t QD = GEMMA3_Q_DIM;
  const size_t KD = GEMMA3_KV_DIM;
  const size_t F  = GEMMA3_FFN;

  // --- attention block ---
  TIMED(GEMMA3_OP_NORM, RmsNormF(1, H, GEMMA3_RMS_EPS, x, P<const float>(L.input_norm), h));
  linear_int8(h, H, L.wq, L.sq, QD, q, GEMMA3_OP_QKV_GEMV);
  linear_int8(h, H, L.wk, L.sk, KD, k, GEMMA3_OP_QKV_GEMV);
  linear_int8(h, H, L.wv, L.sv, KD, v, GEMMA3_OP_QKV_GEMV);
  // q_norm / k_norm: RMSNorm over head_dim, one "row" per head.
  TIMED(GEMMA3_OP_NORM, rms_norm_inplace(GEMMA3_HEADS, D, q, P<const float>(L.q_norm)));
  TIMED(GEMMA3_OP_NORM, rms_norm_inplace(GEMMA3_KV_HEADS, D, k, P<const float>(L.k_norm)));

  const size_t half   = D / 2;
  const float *cosrow = P<const float>(L.is_global ? model.rope_cos_global : model.rope_cos_local) + pos * half;
  const float *sinrow = P<const float>(L.is_global ? model.rope_sin_global : model.rope_sin_local) + pos * half;
  TIMED(GEMMA3_OP_ROPE, gemma3_rope_inplace(q, GEMMA3_HEADS, D, cosrow, sinrow));
  TIMED(GEMMA3_OP_ROPE, gemma3_rope_inplace(k, GEMMA3_KV_HEADS, D, cosrow, sinrow));
  for (size_t i = 0; i < QD; ++i) dbg_q[i] = q[i];

  float *kc = P<float>(L.k_cache);
  float *vc = P<float>(L.v_cache);
  // Head-major caches with a fixed max_seq stride. Invoke attention once per
  // KV group: its packed KV_len stride and modulo head mapping cannot express
  // a partially filled multi-head cache or HF repeat_kv grouping.
  const size_t group = GEMMA3_HEADS / GEMMA3_KV_HEADS;
  const size_t start = (!L.is_global && pos >= GEMMA3_SLIDING_WINDOW)
                           ? pos + 1 - GEMMA3_SLIDING_WINDOW : 0;
  for (size_t kh = 0; kh < GEMMA3_KV_HEADS; ++kh) {
    const size_t off = kh * model.max_seq * D;
    for (size_t i = 0; i < D; ++i) {
      kc[off + pos * D + i] = k[kh * D + i];
      vc[off + pos * D + i] = v[kh * D + i];
    }
    TIMED(GEMMA3_OP_ATTENTION,
          FlashAttentionRVV(group, 1, 1, pos + 1 - start, D, q + kh * group * D,
                            kc + off + start * D, vc + off + start * D,
                            attn + kh * group * D));
  }
  for (size_t i = 0; i < QD; ++i) dbg_attn[i] = attn[i];

  linear_int8(attn, QD, L.wo, L.so, H, h, GEMMA3_OP_O_GEMV);
#ifndef QWEN3_MODEL
  TIMED(GEMMA3_OP_NORM, rms_norm_inplace(1, H, h, P<const float>(L.post_attn_norm)));
#endif
  TIMED(GEMMA3_OP_RESIDUAL, residual_add_inplace(x, h, H));

  // --- MLP block ---
  TIMED(GEMMA3_OP_NORM, RmsNormF(1, H, GEMMA3_RMS_EPS, x, P<const float>(L.pre_ffn_norm), h));
  linear_int8(h, H, L.wgate, L.sgate, F, gate, GEMMA3_OP_GATE_UP_GEMV);
  linear_int8(h, H, L.wup, L.sup, F, up, GEMMA3_OP_GATE_UP_GEMV);
#ifdef QWEN3_MODEL
  TIMED(GEMMA3_OP_GELU_MUL, {
    for (size_t i = 0; i < F; ++i) {
      // Stable SiLU, including large negative inputs (no exp overflow).
      float e = expf(-fabsf(gate[i]));
      float sigmoid = gate[i] >= 0 ? 1.0f / (1.0f + e) : e / (1.0f + e);
      tmp[i] = (gate[i] * sigmoid) * up[i];
    }
  });
#else
  TIMED(GEMMA3_OP_GELU_MUL, rvv_tanh_gelu_mul_f32(gate, up, tmp, F));
#endif
  for (size_t i = 0; i < F; ++i) dbg_ffn[i] = tmp[i];
  linear_int8(tmp, F, L.wdown, L.sdown, H, h, GEMMA3_OP_DOWN_GEMV);
#ifndef QWEN3_MODEL
  TIMED(GEMMA3_OP_NORM, rms_norm_inplace(1, H, h, P<const float>(L.post_ffn_norm)));
#endif
  TIMED(GEMMA3_OP_RESIDUAL, residual_add_inplace(x, h, H));
}

static void lm_head() {
  const size_t H = GEMMA3_HIDDEN;
  const size_t V = model.vocab_rows;
  float *logits  = P<float>(model.logits);
  TIMED(GEMMA3_OP_NORM, RmsNormF(1, H, GEMMA3_RMS_EPS, x, P<const float>(model.final_norm), h));
  float a_scale;
  TIMED(GEMMA3_OP_QUANT, a_scale = gemma3_quantize_f32_to_i8(h, a_q, H));
  TIMED(GEMMA3_OP_LM_HEAD, {
    rvv_gemv_int8(a_q, P<const int8_t>(model.lm_head), acc, H, V);
    gemma3_dequant_i32_to_f32(acc, a_scale, P<const float>(model.lm_head_scale), logits, V);
    ctrl.argmax = gemma3_argmax_f32(logits, V);
    // Exposed in DTCM so a host never has to read NPU-written DDR (which a
    // caching host CPU may hold stale).
    uint32_t bits;
    __builtin_memcpy(&bits, &logits[ctrl.argmax], sizeof(bits));
    ctrl.max_logit = bits;
  });
}

static uint32_t validate() {
  if (model.magic != GEMMA3_MAGIC) return GEMMA3_STATUS_BAD_MAGIC;
  if (model.n_layers != GEMMA3_LAYERS || model.hidden != GEMMA3_HIDDEN || model.ffn != GEMMA3_FFN ||
      model.n_heads != GEMMA3_HEADS || model.n_kv_heads != GEMMA3_KV_HEADS ||
      model.head_dim != GEMMA3_HEAD_DIM || !model.vocab_rows ||
      model.vocab_rows > GEMMA3_MAX_VOCAB_ROWS || !model.max_seq ||
      model.max_seq > GEMMA3_MAX_SEQ)
    return GEMMA3_STATUS_BAD_SHAPE;
  if (ctrl.pos >= model.max_seq) return GEMMA3_STATUS_POS_OVERFLOW;
  if (ctrl.cmd > GEMMA3_CMD_FORWARD) return GEMMA3_STATUS_BAD_CMD;
  if (ctrl.cmd == GEMMA3_CMD_LAYERS && (ctrl.layer_lo > ctrl.layer_hi || ctrl.layer_hi > GEMMA3_LAYERS))
    return GEMMA3_STATUS_BAD_SHAPE;
  return GEMMA3_STATUS_OK;
}

int main() {
  ctrl.status = GEMMA3_STATUS_IDLE;
  for (int i = 0; i < GEMMA3_NUM_OPS; ++i) ctrl.op_cycles[i] = 0;
  uint32_t st = validate();
  if (st != GEMMA3_STATUS_OK) {
    ctrl.status = st;
    return 0;
  }
  uint32_t t0 = (uint32_t)mcycle_read();
  for (size_t i = 0; i < GEMMA3_HIDDEN; ++i) x[i] = x_in[i];

  uint32_t lo = 0, hi = GEMMA3_LAYERS;
  if (ctrl.cmd == GEMMA3_CMD_LAYERS) {
    lo = ctrl.layer_lo;
    hi = ctrl.layer_hi;
  }
  if (ctrl.cmd != GEMMA3_CMD_LM_HEAD) {
    for (uint32_t l = lo; l < hi; ++l) decoder_layer(model.layers[l], ctrl.pos);
  }
  if (ctrl.cmd != GEMMA3_CMD_LAYERS) lm_head();

  for (size_t i = 0; i < GEMMA3_HIDDEN; ++i) x_out[i] = x[i];
  ctrl.total_cycles = (uint32_t)mcycle_read() - t0;
  ctrl.status       = GEMMA3_STATUS_OK;
  return 0;
}
