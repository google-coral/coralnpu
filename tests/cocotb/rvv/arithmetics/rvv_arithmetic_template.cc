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


{DEFINES}

{SCALAR_TYPE} in_buf_1[{IN_DATA_SIZE}] __attribute__((section(".data")))
    __attribute__((aligned(16)));
{SCALAR_TYPE} in_buf_2[{IN_DATA_SIZE}] __attribute__((section(".data")))
    __attribute__((aligned(16)));
{SCALAR_TYPE} out_buf[{OUT_DATA_SIZE}] __attribute__((section(".data")))
    __attribute__((aligned(16)));

void {MATH_OP}_{OP_SUFFIX}(const {SCALAR_TYPE}* in_buf_1,
                            const {SCALAR_TYPE}* in_buf_2,
                            {SCALAR_TYPE}* out_buf) {
  {VEC_TYPE} input_v1 = __riscv_vle{SEW}_v_{OP_SUFFIX}(in_buf_1, {NUM_OPERANDS});
  {VEC_TYPE_V2} input_v2 = __riscv_vle{SEW}_v_{OP_SUFFIX_V2}(
      reinterpret_cast<const {SCALAR_TYPE_V2}*>(in_buf_2), {NUM_OPERANDS});
#if defined(TEST_TERNARY)
  {VEC_TYPE} vd_orig = __riscv_vle{SEW}_v_{OP_SUFFIX}(out_buf, {NUM_OPERANDS});
  {VEC_TYPE} {MATH_OP}_result =
      __riscv_v{MATH_OP}_vv_{OP_SUFFIX}(vd_orig, input_v1, input_v2, {NUM_OPERANDS});
#else
  {VEC_TYPE} {MATH_OP}_result = __riscv_v{MATH_OP}_vv_{OP_SUFFIX}(
      input_v1, input_v2 {EXTRA_ARGS}, {NUM_OPERANDS});
#endif
  __riscv_vse{SEW}_v_{OP_SUFFIX}(out_buf, {MATH_OP}_result, {NUM_OPERANDS});
}


int main(int argc, char **argv) {
  {MATH_OP}_{OP_SUFFIX}(in_buf_1, in_buf_2, out_buf);
  return 0;
}

