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
module compressor_tree_4to2 #(
  parameter int WIDTH = 64
) (
  input  logic [3:0][WIDTH-1:0] src,
  output logic [WIDTH-1:0]      result_sum,
  output logic [WIDTH-1:0]      result_carry
);
  logic [WIDTH-1:0] comp_cout;
  logic [WIDTH-1:0] comp_cin;

  // Horizontal carry link: cin[0] = 0, cin[i] = cout[i-1]
  assign comp_cin = {comp_cout[WIDTH-2:0], 1'b0};

  compressor_4_2 #(
    .WIDTH(WIDTH)
  ) u_comp42 (
    .src1        (src[0]),
    .src2        (src[1]),
    .src3        (src[2]),
    .src4        (src[3]),
    .cin         (comp_cin),
    .result_sum  (result_sum),
    .result_carry(result_carry),
    .result_cout (comp_cout)
  );

endmodule
