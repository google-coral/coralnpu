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

#ifndef SW_OPT_LITERT_MICRO_MEMORY_UTIL_H_
#define SW_OPT_LITERT_MICRO_MEMORY_UTIL_H_

#include <cstring>
#include <memory>

#include "tensorflow/lite/kernels/internal/compatibility.h"
#include "tensorflow/lite/micro/kernels/conv.h"

namespace coralnpu_v2::opt::litert_micro {

struct OpDataConvCustom : public tflite::OpDataConv {
  int accs_buffer_index;
  int16_t *repacked_weights;
  int32_t *weight_sums;
  int tiled_input_buffer_index;
  int generic_tiled_buffer_index;
  int8_t *repacked_weights_generic;
};

struct AlignedFree {
  void operator()(void *ptr) const { std::free(ptr); }
};

template <typename T>
using aligned_array = std::unique_ptr<T[], AlignedFree>;

template <typename T>
aligned_array<T> make_aligned_array(size_t alignment, size_t nmemb) {
  void *ptr = aligned_alloc(alignment, sizeof(T) * nmemb);
  // TODO(davidgao): Handle allocation failure gracefully if possible,
  // typically callers check for nullptr.
  return aligned_array<T>(reinterpret_cast<T *>(ptr));
}

template <typename T>
aligned_array<T> make_aligned_array(size_t alignment, size_t nmemb, const T *src) {
  auto arr = make_aligned_array<T>(alignment, nmemb);
  if (arr) {
    std::memcpy(arr.get(), src, sizeof(T) * nmemb);
  }
  return arr;
}

}  // namespace coralnpu_v2::opt::litert_micro

#endif  // SW_OPT_LITERT_MICRO_MEMORY_UTIL_H_
