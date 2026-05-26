/*
 * Copyright 2025 Google LLC
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

#define __ATTRIBUTE_IN_DTCM__ \
    __attribute__((section(".data"))) __attribute__((aligned(16)))

{SCALAR_TYPE} in_buf_1[{IN_DATA_SIZE}] __ATTRIBUTE_IN_DTCM__;
{SCALAR_TYPE} scalar_input __ATTRIBUTE_IN_DTCM__;
{SCALAR_TYPE} out_buf __ATTRIBUTE_IN_DTCM__;
uint32_t vstart __ATTRIBUTE_IN_DTCM__ = 0;
uint32_t vl __ATTRIBUTE_IN_DTCM__ = {NUM_OPERANDS};
uint32_t faulted __ATTRIBUTE_IN_DTCM__ = 0;
uint32_t mcause __ATTRIBUTE_IN_DTCM__ = 0;

// Fault handler to log fault
extern "C" {
void coralnpu_exception_handler() {
  faulted = 1;
  uint32_t local_mcause;
  asm volatile("csrr %0, mcause" : "=r"(local_mcause));
  mcause = local_mcause;

  asm volatile("ebreak");
  while (1) {}
}
}

void {REDUCTION_OP}_{OP_SUFFIX}(const {SCALAR_TYPE}* in_buf_1, const {SCALAR_TYPE} scalar_input, {SCALAR_TYPE}* out_buf){

    {VEC_TYPE} input_v1 = __riscv_vle{SEW}_v_{OP_SUFFIX}(in_buf_1, vl);
    {VEC_TYPE} input_s1 = {S_MV_V_FN}(scalar_input, vl);
    asm("csrw vstart, %0" : : "r"(vstart));
    {VEC_TYPE} {REDUCTION_OP}_result = __riscv_v{REDUCTION_OP}_vs_{OP_SUFFIX}_{OP_SUFFIX}(input_v1, input_s1, vl);
    *out_buf = {V_MV_S_FN}({REDUCTION_OP}_result);
}


int main(int argc, char **argv) {
  {REDUCTION_OP}_{OP_SUFFIX}(in_buf_1, scalar_input, &out_buf);
  return 0;
}