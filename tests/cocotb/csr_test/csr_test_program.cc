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

struct CsrTestResults {
  uint32_t test_1_write_value;
  uint32_t test_1_read_value;
  uint32_t test_2_write_value;
  uint32_t test_2_read_value;
  uint32_t test_3_write_value;
  uint32_t test_3_read_value;
  uint32_t test_4_write_value;
  uint32_t test_4_read_value;
  uint32_t test_status;
};

CsrTestResults csr_results __attribute__((section(".data"))) = {};

int main(int argc, char **argv) {
  uint32_t test1_write = 0x00000005;
  asm volatile("csrw fcsr, %0" : : "r"(test1_write));
  uint32_t test1_read = 0;
  asm volatile("csrr %0, fcsr" : "=r"(test1_read));
  csr_results.test_1_write_value = test1_write;
  csr_results.test_1_read_value  = test1_read;

  uint32_t test2_write = 0x00000003;
  asm volatile("csrw fflags, %0" : : "r"(test2_write));
  uint32_t test2_read = 0;
  asm volatile("csrr %0, fflags" : "=r"(test2_read));
  csr_results.test_2_write_value = test2_write;
  csr_results.test_2_read_value  = test2_read;

  uint32_t test3_write = 0x0000beef;
  asm volatile("csrw mscratch, %0" : : "r"(test3_write));
  uint32_t test3_read = 0;
  asm volatile("csrr %0, mscratch" : "=r"(test3_read));
  csr_results.test_3_write_value = test3_write;
  csr_results.test_3_read_value  = test3_read;

  uint32_t test4_write = 0x0000cafe;
  asm volatile("csrw mstatush, %0" : : "r"(test4_write));
  uint32_t test4_read = 0;
  asm volatile("csrr %0, mstatush" : "=r"(test4_read));
  csr_results.test_4_write_value = test4_write;
  csr_results.test_4_read_value  = test4_read;

  if ((test1_read & test1_write) == test1_write && (test2_read & test2_write) == test2_write &&
      (test3_read & test3_write) == test3_write && (test4_read == 0x00000000)) {
    csr_results.test_status = 0;
  } else {
    csr_results.test_status = 1;
  }

  return 0;
}
