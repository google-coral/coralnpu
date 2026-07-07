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

// bf16 logistic sigmoid, sigmoid(x) = 1 / (1 + exp(-x)), computed in fp32
//
// Three variants share the identical exp path (RvvExpNegF32m8, which folds the 
// -x negation into the range reduction) and differ ONLU in the final divide:
//  - SigmoidBf16               1/(1+e) via vfrdiv (correctlu rounded)
//  - SigmoidBf16_Vfrec7        1/(1+e) via vfrec7 + one Newton step
//  - SigmoidBf16_Vfrec7Raw     1/(1+e) via vfrec7, NO Newton step
// vfrdiv uses the blocking FDIV unit; vfrec7* use the pipelined vfrec7;
// vfrdiv/vfrec7_NR are <= 1 ULP; vfrec7_raw drops the Newton step for speed and can
// reach ~3 ULP
//
// Data is raw bf16 (uint16). In-place (out == in) is safe: each VLMAX strip is 
// loaded before its store and elements never cross strips
#include <riscv_vector.h>

#include <stddef.h>
#include <stdint.h>

#include "tests/cocotb/rvv/ml_ops/bf16_activations/rvv_math.h"

namespace {
// e = exp(-x); denom = 1 + e; the caller supplies 1/denom
inline vfloat32m8_t SigmoidDenom(const uint16_t* in, size_t i, vfloat32m8_t d0v, size_t vl) {
    vfloat32m8_t x = RvvLoadBf16AsF32m8(in + i, vl);
    vfloat32m8_t e = RvvExpNegFMA(x, d0v, vl);
    return __riscv_vfadd_vf_f32m8(e, 1.0f, vl);
}
}  // namespace

extern "C" {
// baseline: 1/(1+exp(-x)) with a fp32 reciprocal (vfrdiv)
bool SigmoidBf16(const uint16_t* in, uint16_t* out, size_t n) {
    const vfloat32m8_t d0v = RvvExp2D0Splat(__riscv_vsetvlmax_e32m8());
    for (size_t i = 0; i < n;) {
        const size_t vl = __riscv_vsetvl_e32m8(n - i);
        vfloat32m8_t denom = SigmoidDenom(in, i, d0v,vl);
        vfloat32m8_t y = __riscv_vfrdiv_vf_f32m8(denom, 1.0f, vl);
        RvvStoreF32AsBf16m8(out + i, y, vl);
        i += vl;
    }
    return true;
}

// reciprocal via vfrev7 + one Newton-Raphson step. denom = 1 + exp(-x)
// is always >= 1 (positive-normal), so vfrec7 is well defined
bool SigmoidBf16_Vfrec7(const uint16_t* in, uint16_t* out, size_t n) {
    const vfloat32m8_t d0v = RvvExp2D0Splat(__riscv_vsetvlmax_e32m8());
    for (size_t i = 0; i < n;) {
        const size_t vl = __riscv_vsetvl_e32m8(n - i);
        vfloat32m8_t denom = SigmoidDenom(in, i, d0v, vl);
        vfloat32m8_t y = RvvRecip7F32m8(denom, vl);
        RvvStoreF32AsBf16m8(out + i, y, vl);
        i += vl;
    }
    return true;
}

// reciprocal via vfrev7 with no Newton refinement. Same positive-narmal precondition.
bool SigmoidBf16_Vfrec7Raw(const uint16_t* in, uint16_t* out, size_t n) {
    const vfloat32m8_t d0v = RvvExp2D0Splat(__riscv_vsetvlmax_e32m8());
    for (size_t i = 0; i < n;) {
        const size_t vl = __riscv_vsetvl_e32m8(n - i);
        vfloat32m8_t denom = SigmoidDenom(in, i, d0v, vl);
        vfloat32m8_t y = RvvRecip7RawF32m8(denom, vl);
        RvvStoreF32AsBf16m8(out + i, y, vl);
        i += vl;
    }
    return true;
}
}