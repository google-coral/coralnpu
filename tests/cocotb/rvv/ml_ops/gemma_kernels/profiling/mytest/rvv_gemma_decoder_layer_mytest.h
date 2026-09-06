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

#ifndef TESTS_COCOTB_RVV_ML_OPS_GEMMA_KERNELS_PROFILING_MYTEST_RVV_GEMMA_DECODER_LAYER_H_
#define TESTS_COCOTB_RVV_ML_OPS_GEMMA_KERNELS_PROFILING_MYTEST_RVV_GEMMA_DECODER_LAYER_H_

#include <cstddef>
#include <cstdint>

namespace gemma_270m {

constexpr size_t kHiddenSize       = 640;
constexpr size_t kIntermediateSize = 2048;
constexpr size_t kNumQueryHeads    = 4;
constexpr size_t kNumKvHeads       = 1;
constexpr size_t kHeadDim          = 256;
constexpr size_t kQuerySize        = kNumQueryHeads * kHeadDim;
constexpr size_t kKvSize           = kNumKvHeads * kHeadDim;
constexpr size_t kMaxCacheLength   = 64;

// 两种模式编译进同一个 ELF，并使用完全相同的输入、权重、缓存和输出地址。
// Cocotb 会在两次运行之间复位整个 DUT，从而让整层路径和逐算子路径都从
// 冷启动状态开始，避免拿不同 ELF 或不同 DDR 布局下的数据直接相减。
enum DecoderLayerRunMode : uint32_t {
  kRunWholeLayer = 0,
  kRunProfiledStages = 1,
};

// 分阶段计时顺序与 Decoder Layer 的真实执行顺序完全一致。整层总 cycle
// 仍由 runner 外层的 cycle_count 记录；此数组用于解释各算子的占比。
enum DecoderLayerStage : size_t {
  kStageInputRmsNorm = 0,
  kStageQProjection,
  kStageKProjection,
  kStageVProjection,
  kStageQRmsNorm,
  kStageKRmsNorm,
  kStageRope,
  kStageCacheAppend,
  kStageFlashAttention,
  kStageOutputProjection,
  kStagePostAttentionRmsNorm,
  kStagePostAttentionResidualAdd,
  kStagePreFeedforwardRmsNorm,
  kStageGateProjection,
  kStageUpProjection,
  kStageTanhGeluMul,
  kStageDownProjection,
  kStagePostFeedforwardRmsNorm,
  kStagePostFeedforwardResidualAdd,
  kDecoderLayerStageCount,
};

struct DecoderLayerWeightsBf16 {
  const __bf16 *input_layernorm;
  const __bf16 *q_norm;
  const __bf16 *k_norm;
  const __bf16 *post_attention_layernorm;
  const __bf16 *pre_feedforward_layernorm;
  const __bf16 *post_feedforward_layernorm;

  // Matrices are row-major [K, N], matching the RVV matmul kernels.
  const __bf16 *q_proj;
  const __bf16 *k_proj;
  const __bf16 *v_proj;
  const __bf16 *o_proj;
  const __bf16 *gate_proj;
  const __bf16 *up_proj;
  const __bf16 *down_proj;
};

struct DecoderLayerBuffersBf16 {
  __bf16 *input_norm;
  __bf16 *q_projection;
  __bf16 *k_projection;
  __bf16 *v_projection;
  __bf16 *q_rope;
  __bf16 *k_rope;
  __bf16 *k_cache;
  __bf16 *v_cache;
  __bf16 *attention_output;
  __bf16 *attention_projection;
  __bf16 *post_attention_norm;
  __bf16 *post_attention_residual;
  __bf16 *pre_feedforward_norm;
  __bf16 *gate_projection;
  __bf16 *up_projection;
  __bf16 *gelu_output;
  __bf16 *down_projection;
  __bf16 *post_feedforward_norm;
  __bf16 *layer_output;
};

struct DecoderLayerConfig {
  uint32_t position;
  uint32_t cache_length;
  float epsilon;
  float rope_theta;
};

}  // namespace gemma_270m

extern "C" uint32_t gemma_stage_cycles[gemma_270m::kDecoderLayerStageCount];

extern "C" int Gemma270mDecoderLayerBf16(
    const __bf16 *hidden_input, const gemma_270m::DecoderLayerWeightsBf16 *weights,
    gemma_270m::DecoderLayerBuffersBf16 *buffers,
    const gemma_270m::DecoderLayerConfig *config);

// 无内部 mcycle_read() 的完整层路径。它用于测量“完整算子”本身，避免
// 19 组阶段计时改变完整层的 cycle。
extern "C" int Gemma270mDecoderLayerBf16Whole(
    const __bf16 *hidden_input, const gemma_270m::DecoderLayerWeightsBf16 *weights,
    gemma_270m::DecoderLayerBuffersBf16 *buffers,
    const gemma_270m::DecoderLayerConfig *config);

#endif  // TESTS_COCOTB_RVV_ML_OPS_GEMMA_KERNELS_PROFILING_MYTEST_RVV_GEMMA_DECODER_LAYER_H_
