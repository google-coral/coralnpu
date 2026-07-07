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

#include <riscv_vector.h>
#include <stddef.h>
#include <stdint.h>

#include "tests/cocotb/rvv/ml_ops/bf16_activations/rvv_math.h"

#define MAX_N 4096
#define EXTMEM __attribute__((section(".extmem"))) __attribute__((aligned(16)))

extern "C" {
uint16_t cvt_in[MAX_N] EXTMEM;      // round-trip: bf16 -> widen -> narrow -> bf16
uint16_t cvt_out[MAX_N] EXTMEM;
float narrow_in[MAX_N] EXTMEM;      // RNE narrow: arbitrary fp32 -> bf16
uint16_t narrow_out[MAX_N] EXTMEM;
float exp_in[MAX_N] EXTMEM;         // exp(x) general + folded exp(-x) on the same input
float exp_out[MAX_N] EXTMEM;
float exp_neg_out[MAX_N] EXTMEM;
float expnp_in[MAX_N] EXTMEM;       // x <= 0: nonpos vector exp + scalar mirror
float expnp_out[MAX_N] EXTMEM;
float scalar_exp_out[MAX_N] EXTMEM;
float recip_in[MAX_N] EXTMEM;       // positive-normal reciprocal
float recip_out[MAX_N] EXTMEM;      // vfrec7 + Newton (~14-bit)
float recip_raw_out[MAX_N] EXTMEM;  // vfrec7 raw, no refinement (~7-bit)
uint16_t widen_in[MAX_N] EXTMEM;    // bf16 -> fp32, bit-exact (pattern << 16)
float widen_out[MAX_N] EXTMEM;
float exp_neg_fma_out[MAX_N] EXTMEM;  // FMA-core exp(-x): must match exp_neg_out at bf16
uint16_t maxkey_in[MAX_N] EXTMEM;     // integer sign-magnitude-key max over the array
float maxkey_out[MAX_N] EXTMEM;       // [0] = max value (helpers used by small-row/online)
float treesum_in[MAX_N] EXTMEM;       // tree-fold sum over the array (positive-conditioned)
float treesum_out[MAX_N] EXTMEM;      // [0] = sum
uint32_t active_n EXTMEM = 256;
uint32_t cycle_count EXTMEM = 0;
}

int main() {
    if (active_n > MAX_N) return -1;
    const int n = static_cast<int>(active_n);
    uint32_t start;
    asm volatile("csrr %0, mcycle" : "=r"(start) : : "memory");

    for (int i = 0; i < n;) {  // round-trip + narrow (both strip-mined the same way)
        size_t vl = __riscv_vsetvl_e32m8(n - i);
        RvvStoreF32AsBf16m8(cvt_out + i, RvvLoadBf16AsF32m8(cvt_in + i, vl), vl);
        RvvStoreF32AsBf16m8(narrow_out + i, __riscv_vle32_v_f32m8(narrow_in + i, vl), vl);
        i += vl;
    }
    for (int i = 0; i < n;) {  // exp: general + folded exp(-x)
        size_t vl = __riscv_vsetvl_e32m8(n - i);
        vfloat32m8_t x = __riscv_vle32_v_f32m8(exp_in + i, vl);
        __riscv_vse32_v_f32m8(exp_out + i, RvvExpF32m8(x, vl), vl);
        __riscv_vse32_v_f32m8(exp_neg_out + i, RvvExpNegF32m8(x, vl), vl);
        i += vl;
    }
    for (int i = 0; i < n;) {  // nonpos exp (vector), plus scalar mirror per element
        size_t vl = __riscv_vsetvl_e32m8(n - i);
        vfloat32m8_t x = __riscv_vle32_v_f32m8(expnp_in + i, vl);
        __riscv_vse32_v_f32m8(expnp_out + i, RvvExpNonPosF32m8(x, vl), vl);
        i += vl;
    }
    for (int i = 0; i < n; ++i)  // scalar nonpos exp mirrors the online-softmax rescale
        scalar_exp_out[i] = ScalarExpNonPosF32(expnp_in[i]);
    for (int i = 0; i < n;) {  // reciprocal: refined (Newton) and raw (estimate only)
        size_t vl = __riscv_vsetvl_e32m8(n - i);
        vfloat32m8_t d = __riscv_vle32_v_f32m8(recip_in + i, vl);
        __riscv_vse32_v_f32m8(recip_out + i, RvvRecip7F32m8(d, vl), vl);
        __riscv_vse32_v_f32m8(recip_raw_out + i, RvvRecip7RawF32m8(d, vl), vl);
        i += vl;
    }
    for (int i = 0; i < n;) {  // widen bf16 -> fp32
        size_t vl = __riscv_vsetvl_e32m8(n - i);
        __riscv_vse32_v_f32m8(widen_out + i, RvvLoadBf16AsF32m8(widen_in + i, vl), vl);
        i += vl;
    }
    {   // FMA-core exp(-x): hoist d0v once (mirrors the sigmoid kernels' path)
        const size_t vlmax = __riscv_vsetvlmax_e32m8();
        vfloat32m8_t d0v = RvvExp2D0Splat(vlmax);
        for (int i = 0; i < n;) {
            size_t vl = __riscv_vsetvl_e32m8(n - i);
            vfloat32m8_t x = __riscv_vle32_v_f32m8(exp_in + i, vl);
            __riscv_vse32_v_f32m8(exp_neg_fma_out + i, RvvExpNegFMA(x, d0v, vl), vl);
            i += vl;
        }
    }
    {   // integer sign-magnitude-key max over the whole array
        uint16_t kmax = 0;  // key(-inf) = 0x007F, so 0 sits below every finite key
        for (int i = 0; i < n;) {
            size_t vl = __riscv_vsetvl_e16m4(n - i);
            vuint16m4_t raw = __riscv_vle16_v_u16m4(maxkey_in + i, vl);
            uint16_t kc = RvvBf16MaxKeyReduceM4(RvvBf16MaxKeyM4(raw, vl), vl);
            if (kc > kmax) kmax = kc;
            i += vl;
        }
        maxkey_out[0] = Bf16BitsToF32(RvvBf16UnKey(kmax));
    }
    {   // tree-fold sum: strided accumulate into a full-width m8, fold once
        const size_t vlmax = __riscv_vsetvlmax_e32m8();
        vfloat32m8_t acc = __riscv_vfmv_v_f_f32m8(0.0f, vlmax);
        for (int i = 0; i < n;) {
            size_t vl = __riscv_vsetvl_e32m8(n - i);
            vfloat32m8_t v = __riscv_vle32_v_f32m8(treesum_in + i, vl);
            acc = __riscv_vfadd_vv_f32m8_tu(acc, acc, v, vl);
            i += vl;
        }
        treesum_out[0] = RvvTreeSumF32m8(acc);
    }

    uint32_t end;
    asm volatile("csrr %0, mcycle" : "=r"(end) : : "memory");
    cycle_count = end - start;
    return 0;
}
