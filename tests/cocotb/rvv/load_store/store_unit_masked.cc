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

size_t vl __attribute__((section(".data"))) = 16;
size_t vtype __attribute__((section(".data"))) = 0;
uint8_t mask_data[16] __attribute__((section(".data")));
uint8_t load_data[128] __attribute__((section(".data")));
uint8_t store_data[128] __attribute__((section(".data")));
// Allow store_addr to be overwritten to exercise AXI memory
uint8_t* store_addr __attribute__((section(".data"))) = store_data;

extern "C" {
__attribute__((used, retain)) void test_unit_store8() {
  asm("vsetvl zero, %[vl], %[vtype];"
      "vlm.v v0, %[mask_data];"
      "vle8.v v8, %[load_data];"
      "vse8.v v8, %[store_addr], v0.t;"
      : [store_addr] "=A"(*reinterpret_cast<uint8_t (*)[128]>(store_addr))
      : [vl] "r"(vl), [vtype] "r"(vtype), [mask_data] "A"(mask_data),
        [load_data] "A"(load_data)
      : "v0", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl",
        "vtype");
}

__attribute__((used, retain)) void test_unit_store16() {
  asm("vsetvl zero, %[vl], %[vtype];"
      "vlm.v v0, %[mask_data];"
      "vle16.v v8, %[load_data];"
      "vse16.v v8, %[store_addr], v0.t;"
      : [store_addr] "=A"(*reinterpret_cast<uint16_t (*)[64]>(store_addr))
      : [vl] "r"(vl), [vtype] "r"(vtype), [mask_data] "A"(mask_data),
        [load_data] "A"(load_data)
      : "v0", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl",
        "vtype");
}

__attribute__((used, retain)) void test_unit_store32() {
  asm("vsetvl zero, %[vl], %[vtype];"
      "vlm.v v0, %[mask_data];"
      "vle32.v v8, %[load_data];"
      "vse32.v v8, %[store_addr], v0.t;"
      : [store_addr] "=A"(*reinterpret_cast<uint32_t (*)[32]>(store_addr))
      : [vl] "r"(vl), [vtype] "r"(vtype), [mask_data] "A"(mask_data),
        [load_data] "A"(load_data)
      : "v0", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "vl",
        "vtype");
}
}

void (*impl)() __attribute__((section(".data"))) = &test_unit_store8;

int main(int argc, char** argv) {
  impl();

  return 0;
}
