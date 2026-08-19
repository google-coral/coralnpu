// Copyright 2025 Google LLC
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
#include <stdint.h>

int8_t buf_dest8[128] __attribute__((section(".data")));
int16_t buf_dest16[64] __attribute__((section(".data")));
int32_t buf_dest32[32] __attribute__((section(".data")));

int8_t buf_src8[128] __attribute__((section(".data")));
int16_t buf_src16[64] __attribute__((section(".data")));
int32_t buf_src32[32] __attribute__((section(".data")));

int8_t scalar8 __attribute__((section(".data")));
int16_t scalar16 __attribute__((section(".data")));
int32_t scalar32 __attribute__((section(".data")));

size_t offset = 1;
size_t vl     = 16;

#define CREATE_VSLIDEUP_FN(bits, lmul)                                         \
  __attribute__((used, retain)) void vslideup_i##bits##lmul() {                \
    const auto src = __riscv_vle##bits##_v_i##bits##lmul(buf_src##bits, vl);   \
    auto dest      = __riscv_vle##bits##_v_i##bits##lmul(buf_dest##bits, vl);  \
    dest           = __riscv_vslideup_vx_i##bits##lmul(dest, src, offset, vl); \
    __riscv_vse##bits##_v_i##bits##lmul(buf_dest##bits, dest, vl);             \
  }

#define CREATE_VSLIDEDOWN_FN(bits, lmul)                                      \
  __attribute__((used, retain)) void vslidedown_i##bits##lmul() {             \
    const auto src  = __riscv_vle##bits##_v_i##bits##lmul(buf_src##bits, vl); \
    const auto dest = __riscv_vslidedown_vx_i##bits##lmul(src, offset, vl);   \
    __riscv_vse##bits##_v_i##bits##lmul(buf_dest##bits, dest, vl);            \
  }

#define CREATE_VSLIDE1UP_FN(bits, lmul)                                          \
  __attribute__((used, retain)) void vslide1up_i##bits##lmul() {                 \
    const auto src  = __riscv_vle##bits##_v_i##bits##lmul(buf_src##bits, vl);    \
    const auto dest = __riscv_vslide1up_vx_i##bits##lmul(src, scalar##bits, vl); \
    __riscv_vse##bits##_v_i##bits##lmul(buf_dest##bits, dest, vl);               \
  }

#define CREATE_VSLIDE1DOWN_FN(bits, lmul)                                          \
  __attribute__((used, retain)) void vslide1down_i##bits##lmul() {                 \
    const auto src  = __riscv_vle##bits##_v_i##bits##lmul(buf_src##bits, vl);      \
    const auto dest = __riscv_vslide1down_vx_i##bits##lmul(src, scalar##bits, vl); \
    __riscv_vse##bits##_v_i##bits##lmul(buf_dest##bits, dest, vl);                 \
  }

extern "C" {
// vslideup
CREATE_VSLIDEUP_FN(8, mf4)
CREATE_VSLIDEUP_FN(8, mf2)
CREATE_VSLIDEUP_FN(8, m1)
CREATE_VSLIDEUP_FN(8, m2)
CREATE_VSLIDEUP_FN(8, m4)
CREATE_VSLIDEUP_FN(8, m8)
CREATE_VSLIDEUP_FN(16, mf2)
CREATE_VSLIDEUP_FN(16, m1)
CREATE_VSLIDEUP_FN(16, m2)
CREATE_VSLIDEUP_FN(16, m4)
CREATE_VSLIDEUP_FN(16, m8)
CREATE_VSLIDEUP_FN(32, m1)
CREATE_VSLIDEUP_FN(32, m2)
CREATE_VSLIDEUP_FN(32, m4)
CREATE_VSLIDEUP_FN(32, m8)

// vslidedown
CREATE_VSLIDEDOWN_FN(8, mf4)
CREATE_VSLIDEDOWN_FN(8, mf2)
CREATE_VSLIDEDOWN_FN(8, m1)
CREATE_VSLIDEDOWN_FN(8, m2)
CREATE_VSLIDEDOWN_FN(8, m4)
CREATE_VSLIDEDOWN_FN(8, m8)
CREATE_VSLIDEDOWN_FN(16, mf2)
CREATE_VSLIDEDOWN_FN(16, m1)
CREATE_VSLIDEDOWN_FN(16, m2)
CREATE_VSLIDEDOWN_FN(16, m4)
CREATE_VSLIDEDOWN_FN(16, m8)
CREATE_VSLIDEDOWN_FN(32, m1)
CREATE_VSLIDEDOWN_FN(32, m2)
CREATE_VSLIDEDOWN_FN(32, m4)
CREATE_VSLIDEDOWN_FN(32, m8)

// vslide1up
CREATE_VSLIDE1UP_FN(8, mf4)
CREATE_VSLIDE1UP_FN(8, mf2)
CREATE_VSLIDE1UP_FN(8, m1)
CREATE_VSLIDE1UP_FN(8, m2)
CREATE_VSLIDE1UP_FN(8, m4)
CREATE_VSLIDE1UP_FN(8, m8)
CREATE_VSLIDE1UP_FN(16, mf2)
CREATE_VSLIDE1UP_FN(16, m1)
CREATE_VSLIDE1UP_FN(16, m2)
CREATE_VSLIDE1UP_FN(16, m4)
CREATE_VSLIDE1UP_FN(16, m8)
CREATE_VSLIDE1UP_FN(32, m1)
CREATE_VSLIDE1UP_FN(32, m2)
CREATE_VSLIDE1UP_FN(32, m4)
CREATE_VSLIDE1UP_FN(32, m8)

// vslide1down
CREATE_VSLIDE1DOWN_FN(8, mf4)
CREATE_VSLIDE1DOWN_FN(8, mf2)
CREATE_VSLIDE1DOWN_FN(8, m1)
CREATE_VSLIDE1DOWN_FN(8, m2)
CREATE_VSLIDE1DOWN_FN(8, m4)
CREATE_VSLIDE1DOWN_FN(8, m8)
CREATE_VSLIDE1DOWN_FN(16, mf2)
CREATE_VSLIDE1DOWN_FN(16, m1)
CREATE_VSLIDE1DOWN_FN(16, m2)
CREATE_VSLIDE1DOWN_FN(16, m4)
CREATE_VSLIDE1DOWN_FN(16, m8)
CREATE_VSLIDE1DOWN_FN(32, m1)
CREATE_VSLIDE1DOWN_FN(32, m2)
CREATE_VSLIDE1DOWN_FN(32, m4)
CREATE_VSLIDE1DOWN_FN(32, m8)
}

void (*impl)() __attribute__((section(".data"))) = &vslideup_i8m1;

int main(int argc, char **argv) {
  impl();
  return 0;
}
