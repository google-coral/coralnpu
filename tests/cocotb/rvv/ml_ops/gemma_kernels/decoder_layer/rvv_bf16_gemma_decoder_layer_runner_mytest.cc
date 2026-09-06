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

#include <cstdint>

#include "rvv_gemma_decoder_layer_mytest.h"
#include "sw/utils/utils.h"

using namespace gemma_270m;

#define DDR_BSS __attribute__((section(".ddr_bss"), used, retain, aligned(16)))

extern "C" {
__bf16 gemma_hidden_input[kHiddenSize] DDR_BSS;

__bf16 gemma_input_layernorm_weight[kHiddenSize] DDR_BSS;
__bf16 gemma_q_norm_weight[kHeadDim] DDR_BSS;
__bf16 gemma_k_norm_weight[kHeadDim] DDR_BSS;
__bf16 gemma_post_attention_layernorm_weight[kHiddenSize] DDR_BSS;
__bf16 gemma_pre_feedforward_layernorm_weight[kHiddenSize] DDR_BSS;
__bf16 gemma_post_feedforward_layernorm_weight[kHiddenSize] DDR_BSS;

__bf16 gemma_q_proj_weight[kHiddenSize * kQuerySize] DDR_BSS;
__bf16 gemma_k_proj_weight[kHiddenSize * kKvSize] DDR_BSS;
__bf16 gemma_v_proj_weight[kHiddenSize * kKvSize] DDR_BSS;
__bf16 gemma_o_proj_weight[kQuerySize * kHiddenSize] DDR_BSS;
__bf16 gemma_gate_proj_weight[kHiddenSize * kIntermediateSize] DDR_BSS;
__bf16 gemma_up_proj_weight[kHiddenSize * kIntermediateSize] DDR_BSS;
__bf16 gemma_down_proj_weight[kIntermediateSize * kHiddenSize] DDR_BSS;

__bf16 gemma_k_cache[kMaxCacheLength * kHeadDim] DDR_BSS;
__bf16 gemma_v_cache[kMaxCacheLength * kHeadDim] DDR_BSS;

__bf16 gemma_input_norm[kHiddenSize] DDR_BSS;
__bf16 gemma_q_projection[kQuerySize] DDR_BSS;
__bf16 gemma_k_projection[kKvSize] DDR_BSS;
__bf16 gemma_v_projection[kKvSize] DDR_BSS;
__bf16 gemma_q_rope[kQuerySize] DDR_BSS;
__bf16 gemma_k_rope[kKvSize] DDR_BSS;
__bf16 gemma_attention_output[kQuerySize] DDR_BSS;
__bf16 gemma_attention_projection[kHiddenSize] DDR_BSS;
__bf16 gemma_post_attention_norm[kHiddenSize] DDR_BSS;
__bf16 gemma_post_attention_residual[kHiddenSize] DDR_BSS;
__bf16 gemma_pre_feedforward_norm[kHiddenSize] DDR_BSS;
__bf16 gemma_gate_projection[kIntermediateSize] DDR_BSS;
__bf16 gemma_up_projection[kIntermediateSize] DDR_BSS;
__bf16 gemma_gelu_output[kIntermediateSize] DDR_BSS;
__bf16 gemma_down_projection[kHiddenSize] DDR_BSS;
__bf16 gemma_post_feedforward_norm[kHiddenSize] DDR_BSS;
__bf16 gemma_layer_output[kHiddenSize] DDR_BSS;

uint32_t active_position __attribute__((section(".data"), used, retain))     = 0;
uint32_t active_cache_length __attribute__((section(".data"), used, retain)) = 0;
float active_epsilon __attribute__((section(".data"), used, retain))         = 1e-6f;
float active_rope_theta __attribute__((section(".data"), used, retain))      = 10000.0f;
uint32_t cycle_count __attribute__((section(".data"), used, retain))         = 0;
int32_t layer_status __attribute__((section(".data"), used, retain))         = 0;
}

int main() {
  DecoderLayerWeightsBf16 weights = {
      gemma_input_layernorm_weight,
      gemma_q_norm_weight,
      gemma_k_norm_weight,
      gemma_post_attention_layernorm_weight,
      gemma_pre_feedforward_layernorm_weight,
      gemma_post_feedforward_layernorm_weight,
      gemma_q_proj_weight,
      gemma_k_proj_weight,
      gemma_v_proj_weight,
      gemma_o_proj_weight,
      gemma_gate_proj_weight,
      gemma_up_proj_weight,
      gemma_down_proj_weight,
  };
  DecoderLayerBuffersBf16 buffers = {
      gemma_input_norm,
      gemma_q_projection,
      gemma_k_projection,
      gemma_v_projection,
      gemma_q_rope,
      gemma_k_rope,
      gemma_k_cache,
      gemma_v_cache,
      gemma_attention_output,
      gemma_attention_projection,
      gemma_post_attention_norm,
      gemma_post_attention_residual,
      gemma_pre_feedforward_norm,
      gemma_gate_projection,
      gemma_up_projection,
      gemma_gelu_output,
      gemma_down_projection,
      gemma_post_feedforward_norm,
      gemma_layer_output,
  };
  DecoderLayerConfig config = {
      active_position,
      active_cache_length,
      active_epsilon,
      active_rope_theta,
  };

  uint32_t start_cycles = mcycle_read();
  layer_status = Gemma270mDecoderLayerBf16(gemma_hidden_input, &weights, &buffers, &config);
  uint32_t end_cycles = mcycle_read();
  cycle_count = end_cycles - start_cycles;
  return layer_status;
}

#undef DDR_BSS
