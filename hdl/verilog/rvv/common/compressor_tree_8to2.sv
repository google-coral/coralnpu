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

(* keep_hierarchy = "yes" *)
module compressor_tree_8to2 #(
  parameter int WIDTH = 64
) (
  input  logic [7:0][WIDTH-1:0] src,
  output logic [WIDTH-1:0]      result_sum,
  output logic [WIDTH-1:0]      result_carry
);
  // Stage 1: Compress 8 operands to 4 operands (2x compressor_tree_4to2)
  logic [WIDTH-1:0] sum_stg1_0, carry_stg1_0;
  logic [WIDTH-1:0] sum_stg1_1, carry_stg1_1;

  compressor_tree_4to2 #(
    .WIDTH(WIDTH)
  ) u_tree42_stg1_0 (
    .src         (src[3:0]),
    .result_sum  (sum_stg1_0),
    .result_carry(carry_stg1_0)
  );

  compressor_tree_4to2 #(
    .WIDTH(WIDTH)
  ) u_tree42_stg1_1 (
    .src         (src[7:4]),
    .result_sum  (sum_stg1_1),
    .result_carry(carry_stg1_1)
  );

  // Stage 2: Compress 4 operands to 2 operands (1x compressor_tree_4to2)
  logic [3:0][WIDTH-1:0] src_stg2;

  assign src_stg2[0] = sum_stg1_0;
  assign src_stg2[1] = {carry_stg1_0[WIDTH-2:0], 1'b0};
  assign src_stg2[2] = sum_stg1_1;
  assign src_stg2[3] = {carry_stg1_1[WIDTH-2:0], 1'b0};

  compressor_tree_4to2 #(
    .WIDTH(WIDTH)
  ) u_tree42_stg2 (
    .src         (src_stg2),
    .result_sum  (result_sum),
    .result_carry(result_carry)
  );

endmodule
