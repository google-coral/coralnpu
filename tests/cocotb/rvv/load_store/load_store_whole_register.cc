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

namespace {
constexpr size_t buf_size = 128;
}

size_t vl __attribute__((section(".data"))) = buf_size;
size_t vtype __attribute__((section(".data"))) = buf_size;
uint8_t load_data[buf_size] __attribute__((section(".data")));
uint8_t store_data[buf_size] __attribute__((section(".data")));

extern "C" {
#define CREATE_LOAD_FN(name, n_registers)                             \
  __attribute__((used, retain)) void name() {                         \
    size_t eight_vl = 8 * __riscv_vlenb();                            \
    asm("vsetvli zero, %[eight_vl], e8, m8, ta, ma;"                  \
        "vmv.v.i v8, 0;"                                              \
        "vsetvl zero, %[vl], %[vtype];"                               \
        "vl" #n_registers                                             \
        "r.v v8, %[load_data];"                                       \
        "vs8r.v v8, %[store_data];"                                   \
        : [store_data] "=A"(store_data)                               \
        : [eight_vl] "r"(eight_vl), [vl] "r"(vl), [vtype] "r"(vtype), \
          [load_data] "A"(load_data)                                  \
        : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", \
          "vtype");                                                   \
  }

#define CREATE_STORE_FN(name, n_registers)                             \
  __attribute__((used, retain)) void name() {                          \
    asm("vsetvl zero, %[vl], %[vtype];"                                \
        "vl8r.v v8, %[load_data];"                                     \
        "vs" #n_registers "r.v v8, %[store_data];"                     \
        : [store_data] "=A"(store_data)                                \
        : [vl] "r"(vl), [vtype] "r"(vtype), [load_data] "A"(load_data) \
        : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl",  \
          "vtype");                                                    \
  }

CREATE_LOAD_FN(test_vl1r, 1)
CREATE_LOAD_FN(test_vl2r, 2)
CREATE_LOAD_FN(test_vl4r, 4)
CREATE_LOAD_FN(test_vl8r, 8)
CREATE_STORE_FN(test_vs1r, 1)
CREATE_STORE_FN(test_vs2r, 2)
CREATE_STORE_FN(test_vs4r, 4)
CREATE_STORE_FN(test_vs8r, 8)
}

void (*impl)() __attribute__((section(".data"))) = &test_vl1r;

int main(int argc, char** argv) {
  impl();
  return 0;
}
