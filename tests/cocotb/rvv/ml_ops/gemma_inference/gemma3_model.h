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

// ABI shared between the Gemma 3 270M inference runner (gemma3_runner.cc) and
// the cocotb testbench (cocotb_tests/gemma3_inference_cocotb_test.py).
//
// The testbench owns the DDR layout. It packs every weight tensor into one
// image (gemma3_ref.py: ModelImage), writes the image straight into the
// testbench-side AXI memory model (no bus traffic), then fills the
// Gemma3Model descriptor below with DDR addresses. The runner never allocates
// weights itself, so the ELF is independent of model size and of which vocab
// rows the test chose to score.
//
// Layout conventions (all row-major, 16-byte aligned):
//   * Projection weights are stored TRANSPOSED relative to HF, i.e. as
//     [K_in x N_out] int8, because rvv_gemv_int8(A[1xK], B[KxN]) expects B in
//     K x N order. Per-output-channel fp32 scales are [N_out].
//   * Norm weights are the raw HF parameters w; the kernels apply (1 + w).
//   * RoPE tables are [max_seq x head_dim/2] fp32 cos and sin, one pair per
//     rope base (local 10 000, global 1 000 000).
//   * K/V caches are [max_seq x head_dim] fp32, one KV head (Gemma 3 270M has
//     num_key_value_heads = 1), rows 0..pos valid after position pos.
//
// Every field is a 32-bit word so the Python side can pack the struct with a
// flat '<I' array; see gemma3_ref.py: pack_descriptor().

#ifndef TESTS_COCOTB_RVV_ML_OPS_GEMMA_INFERENCE_GEMMA3_MODEL_H_
#define TESTS_COCOTB_RVV_ML_OPS_GEMMA_INFERENCE_GEMMA3_MODEL_H_

#include <stdint.h>

// Gemma 3 270M hyperparameters (google/gemma-3-270m config.json, verified
// 2026-09-05). Changing any of these means a different model; the descriptor
// carries them so the runner can assert the test and the ELF agree.
#define GEMMA3_MAGIC 0x47334D30u  // "G3M0"
#define GEMMA3_HIDDEN 640
#define GEMMA3_FFN 2048
#define GEMMA3_HEADS 4
#define GEMMA3_KV_HEADS 1
#define GEMMA3_HEAD_DIM 256
#define GEMMA3_LAYERS 18
#define GEMMA3_Q_DIM (GEMMA3_HEADS * GEMMA3_HEAD_DIM)      // 1024
#define GEMMA3_KV_DIM (GEMMA3_KV_HEADS * GEMMA3_HEAD_DIM)  // 256
#define GEMMA3_RMS_EPS 1e-6f
#define GEMMA3_VOCAB 262144

// Largest lm_head slice the runner will score in one command. Full-vocab
// logits (262 144 rows) are scored in chunks of this size by the testbench.
#define GEMMA3_MAX_VOCAB_ROWS 4096

// Commands (Gemma3Control.cmd).
#define GEMMA3_CMD_LAYERS 0   // run layers [layer_lo, layer_hi) on x_in -> x_out
#define GEMMA3_CMD_LM_HEAD 1  // final norm + lm_head on x_in -> logits, argmax
#define GEMMA3_CMD_FORWARD 2  // CMD_LAYERS over all layers, then CMD_LM_HEAD

// Status codes (Gemma3Control.status).
#define GEMMA3_STATUS_IDLE 0
#define GEMMA3_STATUS_OK 1
#define GEMMA3_STATUS_BAD_MAGIC 2
#define GEMMA3_STATUS_BAD_SHAPE 3
#define GEMMA3_STATUS_BAD_CMD 4
#define GEMMA3_STATUS_POS_OVERFLOW 5

// Per-op cycle accumulators (Gemma3Control.op_cycles index).
enum Gemma3Op {
  GEMMA3_OP_NORM = 0,       // all RMSNorms (input/post/pre/post, q/k norm, final)
  GEMMA3_OP_QUANT,          // fp32 -> int8 activation quantization
  GEMMA3_OP_QKV_GEMV,       // q, k, v projections (int8 gemv)
  GEMMA3_OP_ROPE,           // rotary embedding
  GEMMA3_OP_ATTENTION,      // FlashAttentionRVV decode step
  GEMMA3_OP_O_GEMV,         // o_proj
  GEMMA3_OP_GATE_UP_GEMV,   // gate_proj and up_proj
  GEMMA3_OP_GELU_MUL,       // gelu_tanh(gate) * up
  GEMMA3_OP_DOWN_GEMV,      // down_proj
  GEMMA3_OP_DEQUANT,        // int32 -> fp32 with scales
  GEMMA3_OP_RESIDUAL,       // residual adds
  GEMMA3_OP_LM_HEAD,        // lm_head gemv + dequant + argmax
  GEMMA3_NUM_OPS
};

typedef struct {
  // int8 [K x N] weights and fp32 [N] per-column scales. DDR addresses.
  uint32_t wq, sq;        // [640 x 1024], [1024]
  uint32_t wk, sk;        // [640 x 256],  [256]
  uint32_t wv, sv;        // [640 x 256],  [256]
  uint32_t wo, so;        // [1024 x 640], [640]
  uint32_t wgate, sgate;  // [640 x 2048], [2048]
  uint32_t wup, sup;      // [640 x 2048], [2048]
  uint32_t wdown, sdown;  // [2048 x 640], [640]
  // fp32 norm weights (HF parameter w; kernel applies 1 + w).
  uint32_t input_norm;      // [640]
  uint32_t post_attn_norm;  // [640]
  uint32_t pre_ffn_norm;    // [640]
  uint32_t post_ffn_norm;   // [640]
  uint32_t q_norm;          // [256]
  uint32_t k_norm;          // [256]
  // fp32 [max_seq x 256] caches, written by the runner.
  uint32_t k_cache;
  uint32_t v_cache;
  // 1 for full_attention layers (rope base 1e6), 0 for sliding_attention (1e4).
  uint32_t is_global;
} Gemma3LayerWeights;

typedef struct {
  uint32_t magic;
  uint32_t n_layers;
  uint32_t hidden;
  uint32_t ffn;
  uint32_t n_heads;
  uint32_t n_kv_heads;
  uint32_t head_dim;
  uint32_t max_seq;     // rows in the KV caches and RoPE tables
  uint32_t vocab_rows;  // columns of lm_head present in DDR (<= MAX_VOCAB_ROWS)
  uint32_t rope_cos_local, rope_sin_local;    // [max_seq x 128] fp32
  uint32_t rope_cos_global, rope_sin_global;  // [max_seq x 128] fp32
  uint32_t final_norm;                        // [640] fp32
  uint32_t lm_head, lm_head_scale;            // int8 [640 x vocab_rows], fp32 [vocab_rows]
  uint32_t logits;                            // fp32 [vocab_rows] output, DDR
  Gemma3LayerWeights layers[GEMMA3_LAYERS];
} Gemma3Model;

// Control block. Lives in DTCM .data so the testbench can poke it by symbol.
typedef struct {
  uint32_t cmd;
  uint32_t pos;       // position of the token being processed (0-based)
  uint32_t layer_lo;  // CMD_LAYERS: first layer (inclusive)
  uint32_t layer_hi;  // CMD_LAYERS: last layer (exclusive)
  uint32_t status;
  uint32_t argmax;    // CMD_LM_HEAD / CMD_FORWARD: index into lm_head columns
  uint32_t total_cycles;
  uint32_t op_cycles[GEMMA3_NUM_OPS];
  uint32_t max_logit;  // CMD_LM_HEAD / CMD_FORWARD: fp32 bits of logits[argmax]
} Gemma3Control;

#endif  // TESTS_COCOTB_RVV_ML_OPS_GEMMA_INFERENCE_GEMMA3_MODEL_H_
