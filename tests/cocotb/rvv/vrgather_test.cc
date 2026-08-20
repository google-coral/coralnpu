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
#include <stdint.h>

#define MAX_BUFFER_SIZE 128

uint8_t vs2_buf[MAX_BUFFER_SIZE] __attribute__((section(".data"))) __attribute__((aligned(16)));
uint8_t vs1_buf[MAX_BUFFER_SIZE] __attribute__((section(".data"))) __attribute__((aligned(16)));
uint16_t vs1_ei16_buf[MAX_BUFFER_SIZE / 2] __attribute__((section(".data")))
__attribute__((aligned(16)));
uint8_t vd_buf[MAX_BUFFER_SIZE] __attribute__((section(".data"))) __attribute__((aligned(16)));
uint8_t v0_mask_buf[16] __attribute__((section(".data"))) __attribute__((aligned(16)));

uint32_t scalar_idx __attribute__((section(".data"))) = 0;
uint32_t req_vl __attribute__((section(".data")))     = 16;

extern "C" {

// vrgather.vv with SEW=8, LMUL=2, masked with v0.t (mask-undisturbed mu)
__attribute__((used, retain)) void run_vrgather_vv_masked() {
  asm volatile("vsetvli x0, %0, e8, m2, tu, mu" : : "r"(req_vl));
  asm volatile("vlm.v v0, (%0)" : : "r"(v0_mask_buf));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v10, (%0)" : : "r"(vs2_buf + 32));
  asm volatile("vle8.v v12, (%0)" : : "r"(vs2_buf + 64));
  asm volatile("vle8.v v2, (%0)" : : "r"(vs1_buf));
  asm volatile("vle8.v v14, (%0)" : : "r"(vd_buf));
  asm volatile("vrgather.vv v14, v8, v2, v0.t");
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgather.vv with SEW=8, LMUL=2, unmasked
__attribute__((used, retain)) void run_vrgather_vv_unmasked() {
  asm volatile("vsetvli x0, %0, e8, m2, tu, ma" : : "r"(req_vl));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v10, (%0)" : : "r"(vs2_buf + 32));
  asm volatile("vle8.v v12, (%0)" : : "r"(vs2_buf + 64));
  asm volatile("vle8.v v2, (%0)" : : "r"(vs1_buf));
  asm volatile("vrgather.vv v14, v8, v2");
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgather.vv with SEW=8, LMUL=2, tail-undisturbed tu (reading index >= vl and < VLMAX)
__attribute__((used, retain)) void run_vrgather_vv_partial_vl() {
  asm volatile("vsetvli t0, x0, e8, m2, tu, ma");
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v2, (%0)" : : "r"(vs1_buf));
  asm volatile("vle8.v v14, (%0)" : : "r"(vd_buf));
  asm volatile("vsetvli x0, %0, e8, m2, tu, ma" : : "r"(req_vl));
  asm volatile("vrgather.vv v14, v8, v2");
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgatherei16.vv with SEW=8, LMUL=2 (index EEW=16, EMUL=4), masked (mu)
__attribute__((used, retain)) void run_vrgatherei16_vv_masked() {
  asm volatile("vsetvli x0, %0, e8, m2, tu, mu" : : "r"(req_vl));
  asm volatile("vlm.v v0, (%0)" : : "r"(v0_mask_buf));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v10, (%0)" : : "r"(vs2_buf + 32));
  asm volatile("vle8.v v12, (%0)" : : "r"(vs2_buf + 64));
  asm volatile("vsetvli x0, %0, e16, m4, tu, mu" : : "r"(req_vl));
  asm volatile("vle16.v v4, (%0)" : : "r"(vs1_ei16_buf));
  asm volatile("vsetvli x0, %0, e8, m2, tu, mu" : : "r"(req_vl));
  asm volatile("vle8.v v14, (%0)" : : "r"(vd_buf));
  asm volatile("vrgatherei16.vv v14, v8, v4, v0.t");
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgatherei16.vv with SEW=8, LMUL=2 (index EEW=16, EMUL=4), unmasked
__attribute__((used, retain)) void run_vrgatherei16_vv_unmasked() {
  asm volatile("vsetvli x0, %0, e8, m2, tu, ma" : : "r"(req_vl));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v10, (%0)" : : "r"(vs2_buf + 32));
  asm volatile("vle8.v v12, (%0)" : : "r"(vs2_buf + 64));
  asm volatile("vsetvli x0, %0, e16, m4, tu, ma" : : "r"(req_vl));
  asm volatile("vle16.v v4, (%0)" : : "r"(vs1_ei16_buf));
  asm volatile("vsetvli x0, %0, e8, m2, tu, ma" : : "r"(req_vl));
  asm volatile("vrgatherei16.vv v14, v8, v4");
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgather.vx with SEW=8, LMUL=2
__attribute__((used, retain)) void run_vrgather_vx() {
  asm volatile("vsetvli x0, %0, e8, m2, tu, ma" : : "r"(req_vl));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v10, (%0)" : : "r"(vs2_buf + 32));
  asm volatile("vle8.v v12, (%0)" : : "r"(vs2_buf + 64));
  asm volatile("vrgather.vx v14, v8, %0" : : "r"(scalar_idx));
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgather.vi with SEW=8, LMUL=1, uimm = 5
__attribute__((used, retain)) void run_vrgather_vi_5() {
  asm volatile("vsetvli x0, %0, e8, m1, tu, ma" : : "r"(req_vl));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v9, (%0)" : : "r"(vs2_buf + 16));
  asm volatile("vrgather.vi v14, v8, 5");
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgather.vi with SEW=8, LMUL=1, uimm = 20
__attribute__((used, retain)) void run_vrgather_vi_20() {
  asm volatile("vsetvli x0, %0, e8, m1, tu, ma" : : "r"(req_vl));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v9, (%0)" : : "r"(vs2_buf + 16));
  asm volatile("vrgather.vi v14, v8, 20");
  asm volatile("vse8.v v14, (%0)" : : "r"(vd_buf));
}

// vrgather.vv with SEW=8, LMUL=4, vs2 = v8 (tests LMUL=4 overgather beyond VLMAX=64)
__attribute__((used, retain)) void run_vrgather_vv_lmul4() {
  asm volatile("vsetvli x0, %0, e8, m4, tu, ma" : : "r"(req_vl));
  asm volatile("vle8.v v8, (%0)" : : "r"(vs2_buf));
  asm volatile("vle8.v v12, (%0)" : : "r"(vs2_buf + 64));
  asm volatile("vle8.v v4, (%0)" : : "r"(vs1_buf));
  asm volatile("vrgather.vv v16, v8, v4");
  asm volatile("vse8.v v16, (%0)" : : "r"(vd_buf));
}

}  // extern "C"

void (*test_fn)() __attribute__((section(".data"))) = &run_vrgather_vv_unmasked;

int main(int argc, char **argv) {
  test_fn();
  return 0;
}
