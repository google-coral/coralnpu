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

// Tests loads after setting vtype. Loads/stores should be agnostic to vtype.

size_t vl __attribute__((section(".data"))) = 16;
size_t vtype __attribute__((section(".data"))) = 0;
uint8_t load_data[256] __attribute__((section(".data")));
uint8_t store_data[256] __attribute__((section(".data")));

extern "C" {

#define CREATE_LOAD_FN(name, data_bits)                               \
  __attribute__((used, retain)) void name() {                         \
    size_t store_vl = 8 * __riscv_vlenb();                            \
    asm("vsetvl zero, %[vl], %[vtype];"                               \
        "vle" #data_bits                                              \
        ".v v8, %[load_data];"                                        \
        "vsetvli zero, %[store_vl], e8, m8, ta, ma;"                  \
        "vse8.v v8, %[store_data];"                                   \
        : [store_data] "=A"(store_data)                               \
        : [vl] "r"(vl), [store_vl] "r"(store_vl), [vtype] "r"(vtype), \
          [load_data] "A"(load_data)                                  \
        : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", \
          "vtype");                                                   \
  }

#define CREATE_SEGMENT_LOAD_FN(name, data_bits, segment)              \
  __attribute__((used, retain)) void name() {                         \
    size_t store_vl = 8 * __riscv_vlenb();                            \
    asm("vsetvl zero, %[vl], %[vtype];"                               \
        "vlseg" #segment "e" #data_bits                               \
        ".v v8, %[load_data];"                                        \
        "vsetvli zero, %[store_vl], e8, m8, ta, ma;"                  \
        "vse8.v v8, %[store_data];"                                   \
        : [store_data] "=A"(store_data)                               \
        : [vl] "r"(vl), [store_vl] "r"(store_vl), [vtype] "r"(vtype), \
          [load_data] "A"(load_data)                                  \
        : "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl", \
          "vtype");                                                   \
  }

CREATE_LOAD_FN(test_vle8, 8)
CREATE_SEGMENT_LOAD_FN(test_vlseg2e8, 8, 2)
CREATE_SEGMENT_LOAD_FN(test_vlseg3e8, 8, 3)
CREATE_SEGMENT_LOAD_FN(test_vlseg4e8, 8, 4)
CREATE_SEGMENT_LOAD_FN(test_vlseg5e8, 8, 5)
CREATE_SEGMENT_LOAD_FN(test_vlseg6e8, 8, 6)
CREATE_SEGMENT_LOAD_FN(test_vlseg7e8, 8, 7)
CREATE_SEGMENT_LOAD_FN(test_vlseg8e8, 8, 8)

CREATE_LOAD_FN(test_vle16, 16)
CREATE_SEGMENT_LOAD_FN(test_vlseg2e16, 16, 2)
CREATE_SEGMENT_LOAD_FN(test_vlseg3e16, 16, 3)
CREATE_SEGMENT_LOAD_FN(test_vlseg4e16, 16, 4)
CREATE_SEGMENT_LOAD_FN(test_vlseg5e16, 16, 5)
CREATE_SEGMENT_LOAD_FN(test_vlseg6e16, 16, 6)
CREATE_SEGMENT_LOAD_FN(test_vlseg7e16, 16, 7)
CREATE_SEGMENT_LOAD_FN(test_vlseg8e16, 16, 8)

CREATE_LOAD_FN(test_vle32, 32)
CREATE_SEGMENT_LOAD_FN(test_vlseg2e32, 32, 2)
CREATE_SEGMENT_LOAD_FN(test_vlseg3e32, 32, 3)
CREATE_SEGMENT_LOAD_FN(test_vlseg4e32, 32, 4)
CREATE_SEGMENT_LOAD_FN(test_vlseg5e32, 32, 5)
CREATE_SEGMENT_LOAD_FN(test_vlseg6e32, 32, 6)
CREATE_SEGMENT_LOAD_FN(test_vlseg7e32, 32, 7)
CREATE_SEGMENT_LOAD_FN(test_vlseg8e32, 32, 8)

}

void (*impl)() __attribute__((section(".data"))) = &test_vle8;

int main(int argc, char** argv) {
  impl();
  return 0;
}
