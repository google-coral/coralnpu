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
uint32_t active_run_mode __attribute__((section(".data"), used, retain)) =
    kRunProfiledStages;
uint32_t cycle_count __attribute__((section(".data"), used, retain))         = 0;
uint32_t cycle_count_corrected __attribute__((section(".data"), used, retain)) = 0;
uint32_t mcycle_read_overhead_cycles
    __attribute__((section(".data"), used, retain)) = 0;
uint32_t stage_cycle_sum_raw __attribute__((section(".data"), used, retain)) = 0;
uint32_t stage_cycle_sum_corrected
    __attribute__((section(".data"), used, retain)) = 0;
int32_t layer_status __attribute__((section(".data"), used, retain))         = 0;
uint32_t gemma_stage_cycles[kDecoderLayerStageCount]
    __attribute__((section(".data"), used, retain)) = {};
}

namespace {

// 连续读取两次 mcycle，并取 32 次测量中的最小值。这个差值代表“空测量区间”
// 本身的最低开销：第一次读取返回之后的收尾指令，加上第二次读取到采样点
// 之前的指令。用最小值可以避开偶发的 cache/流水线停顿。
uint32_t MeasureMcycleReadOverhead() {
  uint64_t minimum = ~uint64_t{0};
  for (int i = 0; i < 32; ++i) {
    const uint64_t start = mcycle_read();
    const uint64_t end = mcycle_read();
    const uint64_t delta = end - start;
    if (delta < minimum) {
      minimum = delta;
    }
  }
  return static_cast<uint32_t>(minimum);
}

}  // namespace

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

  // 每次启动 ELF 都清空结果，保证 DUT reset 后完整层和逐算子模式不会读取到
  // 上一次运行留下的统计值。
  cycle_count = 0;
  cycle_count_corrected = 0;
  stage_cycle_sum_raw = 0;
  stage_cycle_sum_corrected = 0;
  for (size_t i = 0; i < kDecoderLayerStageCount; ++i) {
    gemma_stage_cycles[i] = 0;
  }

  mcycle_read_overhead_cycles = MeasureMcycleReadOverhead();
  const uint64_t start_cycles = mcycle_read();
  if (active_run_mode == kRunWholeLayer) {
    layer_status = Gemma270mDecoderLayerBf16Whole(
        gemma_hidden_input, &weights, &buffers, &config);
  } else if (active_run_mode == kRunProfiledStages) {
    layer_status = Gemma270mDecoderLayerBf16(
        gemma_hidden_input, &weights, &buffers, &config);
  } else {
    layer_status = -2;
  }
  const uint64_t end_cycles = mcycle_read();
  cycle_count = static_cast<uint32_t>(end_cycles - start_cycles);
  cycle_count_corrected =
      cycle_count > mcycle_read_overhead_cycles
          ? cycle_count - mcycle_read_overhead_cycles
          : 0;

  if (active_run_mode == kRunProfiledStages) {
    for (size_t i = 0; i < kDecoderLayerStageCount; ++i) {
      const uint32_t raw = gemma_stage_cycles[i];
      stage_cycle_sum_raw += raw;
      stage_cycle_sum_corrected +=
          raw > mcycle_read_overhead_cycles
              ? raw - mcycle_read_overhead_cycles
              : 0;
    }
  }
  return layer_status;
}

#undef DDR_BSS
