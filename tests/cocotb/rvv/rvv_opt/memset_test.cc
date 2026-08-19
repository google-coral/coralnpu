/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <riscv_vector.h>
#include <stdint.h>

#include "sw/opt/rvv_opt.h"

int val_in __attribute__((section(".data")));
uint8_t out_buf[512] __attribute__((section(".data"))) __attribute__((aligned(16)));
size_t size_n __attribute__((section(".data")));

int main(int argc, char **argv) {
  coralnpu_v2::opt::Memset(out_buf, val_in, size_n);
  return 0;
}
