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

#include <stdint.h>

uint32_t op_type __attribute__((section(".data")))  = 0;
uint32_t use_mask __attribute__((section(".data"))) = 0;
uint32_t vma __attribute__((section(".data")))      = 0;
uint32_t vta __attribute__((section(".data")))      = 0;
uint32_t sew __attribute__((section(".data")))      = 1;  // e16
uint32_t lmul __attribute__((section(".data")))     = 0;  // m1
uint32_t vl __attribute__((section(".data")))       = 4;
uint32_t offset __attribute__((section(".data")))   = 2;
uint32_t scalar __attribute__((section(".data")))   = 0;

uint8_t mask_data[16] __attribute__((section(".data")));
uint8_t vs2_data[8 * 16] __attribute__((section(".data")));
uint8_t vd_orig_data[8 * 16] __attribute__((section(".data")));
uint8_t result_data[8 * 16] __attribute__((section(".data")));

int main(int argc, char **argv) {
  // Load mask data into v0
  asm volatile("vsetivli x0, 16, e8, m1, ta, ma");
  asm volatile("vle8.v v0, (%0)" : : "r"(mask_data));

  // Pre-fill destination register group v16 (m8) with vd_orig_data
  asm volatile("li a0, 128\n vsetvli x0, a0, e8, m8, ta, ma\n vle8.v v16, (%0)"
               :
               : "r"(vd_orig_data)
               : "a0");

  // Pre-fill source register group v8 (m8) with vs2_data
  asm volatile("li a0, 128\n vsetvli x0, a0, e8, m8, ta, ma\n vle8.v v8, (%0)"
               :
               : "r"(vs2_data)
               : "a0");

  // Set target vector configuration
  uint32_t vtype_to_write = (vma << 7) | (vta << 6) | (sew << 3) | lmul;
  asm volatile("vsetvl x0, %0, %1" : : "r"(vl), "r"(vtype_to_write));

  // Execute slide operation
  if (use_mask) {
    switch (op_type) {
      case 0:  // vslidedown.vx with mask
        asm volatile("vslidedown.vx v16, v8, %0, v0.t" : : "r"(offset));
        break;
      case 1:  // vslidedown.vi 2 with mask (specialized for immediate offset 2)
        asm volatile("vslidedown.vi v16, v8, 2, v0.t");
        break;
      case 2:  // vslideup.vx with mask
        asm volatile("vslideup.vx v16, v8, %0, v0.t" : : "r"(offset));
        break;
      case 3:  // vslide1down.vx with mask
        asm volatile("vslide1down.vx v16, v8, %0, v0.t" : : "r"(scalar));
        break;
      case 4:  // vslide1up.vx with mask
        asm volatile("vslide1up.vx v16, v8, %0, v0.t" : : "r"(scalar));
        break;
      default:
        break;
    }
  } else {
    switch (op_type) {
      case 0:  // vslidedown.vx unmasked
        asm volatile("vslidedown.vx v16, v8, %0" : : "r"(offset));
        break;
      case 1:  // vslidedown.vi 2 unmasked
        asm volatile("vslidedown.vi v16, v8, 2");
        break;
      case 2:  // vslideup.vx unmasked
        asm volatile("vslideup.vx v16, v8, %0" : : "r"(offset));
        break;
      case 3:  // vslide1down.vx unmasked
        asm volatile("vslide1down.vx v16, v8, %0" : : "r"(scalar));
        break;
      case 4:  // vslide1up.vx unmasked
        asm volatile("vslide1up.vx v16, v8, %0" : : "r"(scalar));
        break;
      default:
        break;
    }
  }

  // Store full result register group v16 (m8 = 128 bytes)
  asm volatile("li a0, 128\n vsetvli x0, a0, e8, m8, ta, ma\n vse8.v v16, (%0)"
               :
               : "r"(result_data)
               : "a0");

  return 0;
}
