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

#include <cstdint>

#include "vme_test_utils.h"

#define VME_MAX_ALTFMT_CASES 8

struct VmeAltfmtCase {
  uint32_t mtype_value;  // msetmtype rs1
  uint32_t vtype_value;  // msetmtype rs2
};

struct VmeAltfmtResult {
  uint32_t mtype_readback;
  uint32_t vtype_readback;
};

volatile uint32_t vme_altfmt_num_cases __attribute__((section(".data"))) = 0;
volatile VmeAltfmtCase vme_altfmt_inputs[VME_MAX_ALTFMT_CASES]
    __attribute__((section(".data")))                                                      = {};
VmeAltfmtResult vme_altfmt_results[VME_MAX_ALTFMT_CASES] __attribute__((section(".data"))) = {};

int main(int argc, char **argv) {
  for (uint32_t i = 0; i < vme_altfmt_num_cases; i++) {
    vme_msetmtype(vme_altfmt_inputs[i].mtype_value, vme_altfmt_inputs[i].vtype_value);
    vme_altfmt_results[i].mtype_readback = vme_read_mtype();
    uint32_t vt;
    asm volatile("csrr %0, vtype" : "=r"(vt));
    vme_altfmt_results[i].vtype_readback = vt;
  }
  return 0;
}
