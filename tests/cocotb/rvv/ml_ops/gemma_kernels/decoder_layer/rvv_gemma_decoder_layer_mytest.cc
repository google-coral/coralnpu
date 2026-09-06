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

#include "rvv_gemma_decoder_layer_mytest.h"

#include <cmath>

extern "C" {
void RmsNormBf16(size_t seq_len, size_t hidden_size, float epsilon,
                 const __bf16 *__restrict__ input, const __bf16 *__restrict__ weight,
                 __bf16 *__restrict__ output);
void rvv_gemv_1d_bf16(const __bf16 *__restrict__ lhs, const __bf16 *__restrict__ rhs,
                      __bf16 *__restrict__ output, int k, int n);
void rvv_tanh_gelu_mul_bf16(const __bf16 *__restrict__ gate, const __bf16 *__restrict__ up,
                            __bf16 *__restrict__ output, size_t total_elements);
void rvv_residual_add_bf16(const __bf16 *__restrict__ lhs, const __bf16 *__restrict__ rhs,
                           __bf16 *__restrict__ output, size_t total_elements);
void FlashAttentionRVV_Bf16(size_t q_heads, size_t kv_heads, size_t q_len, size_t kv_len,
                            size_t dim, const __bf16 *q, const __bf16 *k, const __bf16 *v,
                            __bf16 *output);
}

namespace {

using namespace gemma_270m;

void ApplyRoPE(__bf16 *q, __bf16 *k, uint32_t position, float theta) {
  constexpr size_t kHalfDim = kHeadDim / 2;

  for (size_t i = 0; i < kHalfDim; ++i) {
    float exponent = static_cast<float>(2 * i) / static_cast<float>(kHeadDim);
    float angle    = static_cast<float>(position) * std::pow(theta, -exponent);
    float cos_val  = std::cos(angle);
    float sin_val  = std::sin(angle);

    for (size_t head = 0; head < kNumQueryHeads; ++head) {
      __bf16 *q_head = q + head * kHeadDim;
      float first    = static_cast<float>(q_head[i]);
      float second   = static_cast<float>(q_head[i + kHalfDim]);
      q_head[i]            = static_cast<__bf16>(first * cos_val - second * sin_val);
      q_head[i + kHalfDim] = static_cast<__bf16>(second * cos_val + first * sin_val);
    }

    float first  = static_cast<float>(k[i]);
    float second = static_cast<float>(k[i + kHalfDim]);
    k[i]            = static_cast<__bf16>(first * cos_val - second * sin_val);
    k[i + kHalfDim] = static_cast<__bf16>(second * cos_val + first * sin_val);
  }
}

void AppendToCache(const __bf16 *current, __bf16 *cache, size_t cache_length) {
  __bf16 *destination = cache + cache_length * kHeadDim;
  for (size_t i = 0; i < kHeadDim; ++i) {
    destination[i] = current[i];
  }
}

}  // namespace

extern "C" int Gemma270mDecoderLayerBf16(const __bf16 *hidden_input,
                                          const DecoderLayerWeightsBf16 *weights,
                                          DecoderLayerBuffersBf16 *buffers,
                                          const DecoderLayerConfig *config) {
  if (config->cache_length >= kMaxCacheLength || config->rope_theta <= 0.0f) {
    return -1;
  }

  RmsNormBf16(1, kHiddenSize, config->epsilon, hidden_input, weights->input_layernorm,
              buffers->input_norm);

  rvv_gemv_1d_bf16(buffers->input_norm, weights->q_proj, buffers->q_projection, kHiddenSize,
                    kQuerySize);
  rvv_gemv_1d_bf16(buffers->input_norm, weights->k_proj, buffers->k_projection, kHiddenSize,
                    kKvSize);
  rvv_gemv_1d_bf16(buffers->input_norm, weights->v_proj, buffers->v_projection, kHiddenSize,
                    kKvSize);

  RmsNormBf16(kNumQueryHeads, kHeadDim, config->epsilon, buffers->q_projection, weights->q_norm,
              buffers->q_rope);
  RmsNormBf16(kNumKvHeads, kHeadDim, config->epsilon, buffers->k_projection, weights->k_norm,
              buffers->k_rope);
  ApplyRoPE(buffers->q_rope, buffers->k_rope, config->position, config->rope_theta);

  AppendToCache(buffers->k_rope, buffers->k_cache, config->cache_length);
  AppendToCache(buffers->v_projection, buffers->v_cache, config->cache_length);
  size_t attention_length = config->cache_length + 1;
  FlashAttentionRVV_Bf16(kNumQueryHeads, kNumKvHeads, 1, attention_length, kHeadDim,
                         buffers->q_rope, buffers->k_cache, buffers->v_cache,
                         buffers->attention_output);

  rvv_gemv_1d_bf16(buffers->attention_output, weights->o_proj,
                    buffers->attention_projection, kQuerySize, kHiddenSize);
  RmsNormBf16(1, kHiddenSize, config->epsilon, buffers->attention_projection,
              weights->post_attention_layernorm, buffers->post_attention_norm);
  rvv_residual_add_bf16(hidden_input, buffers->post_attention_norm,
                        buffers->post_attention_residual, kHiddenSize);

  RmsNormBf16(1, kHiddenSize, config->epsilon, buffers->post_attention_residual,
              weights->pre_feedforward_layernorm, buffers->pre_feedforward_norm);
  rvv_gemv_1d_bf16(buffers->pre_feedforward_norm, weights->gate_proj,
                    buffers->gate_projection, kHiddenSize, kIntermediateSize);
  rvv_gemv_1d_bf16(buffers->pre_feedforward_norm, weights->up_proj,
                    buffers->up_projection, kHiddenSize, kIntermediateSize);
  rvv_tanh_gelu_mul_bf16(buffers->gate_projection, buffers->up_projection,
                         buffers->gelu_output, kIntermediateSize);
  rvv_gemv_1d_bf16(buffers->gelu_output, weights->down_proj, buffers->down_projection,
                    kIntermediateSize, kHiddenSize);
  RmsNormBf16(1, kHiddenSize, config->epsilon, buffers->down_projection,
              weights->post_feedforward_layernorm, buffers->post_feedforward_norm);
  rvv_residual_add_bf16(buffers->post_attention_residual, buffers->post_feedforward_norm,
                        buffers->layer_output, kHiddenSize);

  return 0;
}
