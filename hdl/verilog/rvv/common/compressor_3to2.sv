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
module compressor_3_2 #( // verilog_lint: waive module-filename
  parameter int WIDTH = 8
) (
  input  logic [WIDTH-1:0] src1,
  input  logic [WIDTH-1:0] src2,
  input  logic [WIDTH-1:0] src3,
  output logic [WIDTH-1:0] result_sum,
  output logic [WIDTH-1:0] result_carry
);
  logic [WIDTH-1:0] xor_src1to2;

  assign xor_src1to2 = src1 ^ src2;
  assign result_sum  = xor_src1to2 ^ src3;

  genvar i;
  generate
    for (i = 0; i < WIDTH; i = i + 1) begin : gen_3to2_slice
      assign result_carry[i] = xor_src1to2[i] ? src3[i] : src1[i];
    end
  endgenerate

endmodule
