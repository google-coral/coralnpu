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
module brent_kung_prefix_sum_16 #(
  parameter int WIDTH = 7
) (
  input  logic [15:0]               mask_in,
  output logic [3:0][WIDTH-1:0]     block_prefix_sum,
  output logic [WIDTH-1:0]          total_sum,
  output logic [15:0][WIDTH-1:0]    prefix_sum
);

  // ---------------------------------------------------------------------------
  // Upward Reduction Tree (Brent-Kung parallel prefix)
  // Logic Depth: 4 levels of simple adders (depth <= 7 gates)
  // ---------------------------------------------------------------------------

  // Level 1: 8 2-bit Half Adders on adjacent 1-bit inputs
  logic [7:0][1:0] s1;
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : gen_stg1
      assign s1[i] = {1'b0, mask_in[2*i]} + {1'b0, mask_in[2*i+1]};
    end
  endgenerate

  // Level 2: 4 3-bit Adders combining pairs of 2-bit sums (sums of 4 bits)
  logic [3:0][2:0] s2;
  generate
    for (i = 0; i < 4; i = i + 1) begin : gen_stg2
      assign s2[i] = {1'b0, s1[2*i]} + {1'b0, s1[2*i+1]};
    end
  endgenerate

  // Level 3: 2 4-bit Adders combining pairs of 4-bit sums (sums of 8 bits)
  logic [1:0][3:0] s3;
  assign s3[0] = {1'b0, s2[0]} + {1'b0, s2[1]};
  assign s3[1] = {1'b0, s2[2]} + {1'b0, s2[3]};

  // Level 4: 1 5-bit Adder combining two 8-bit sums (total sum of 16 bits)
  logic [4:0] s4;
  assign s4 = {1'b0, s3[0]} + {1'b0, s3[1]};

  // Downward distribution step: sum of first 12 bits
  logic [3:0] p_12;
  assign p_12 = s3[0] + {1'b0, s2[2]};

  // ---------------------------------------------------------------------------
  // Block Prefix Sums (stride 4):
  //   block_prefix_sum[0] = 0
  //   block_prefix_sum[1] = sum(mask_in[0:3])
  //   block_prefix_sum[2] = sum(mask_in[0:7])
  //   block_prefix_sum[3] = sum(mask_in[0:11])
  // ---------------------------------------------------------------------------
  assign block_prefix_sum[0] = '0;
  assign block_prefix_sum[1] = {{(WIDTH-3){1'b0}}, s2[0]};
  assign block_prefix_sum[2] = {{(WIDTH-4){1'b0}}, s3[0]};
  assign block_prefix_sum[3] = {{(WIDTH-4){1'b0}}, p_12};
  assign total_sum           = {{(WIDTH-5){1'b0}}, s4};

  // ---------------------------------------------------------------------------
  // Full Element-wise Prefix Sums:
  //   prefix_sum[k] = sum_{j=0}^{k-1} mask_in[j] (with prefix_sum[0] = 0)
  // ---------------------------------------------------------------------------
  assign prefix_sum[0]  = '0;
  assign prefix_sum[1]  = {{(WIDTH-1){1'b0}}, mask_in[0]};
  assign prefix_sum[2]  = {{(WIDTH-2){1'b0}}, s1[0]};
  assign prefix_sum[3]  = {{(WIDTH-2){1'b0}}, s1[0]} + {{(WIDTH-1){1'b0}}, mask_in[2]};

  assign prefix_sum[4]  = block_prefix_sum[1];
  assign prefix_sum[5]  = block_prefix_sum[1] + {{(WIDTH-1){1'b0}}, mask_in[4]};
  assign prefix_sum[6]  = block_prefix_sum[1] + {{(WIDTH-2){1'b0}}, s1[2]};
  assign prefix_sum[7]  = block_prefix_sum[1] + {{(WIDTH-2){1'b0}}, s1[2]} +
                          {{(WIDTH-1){1'b0}}, mask_in[6]};

  assign prefix_sum[8]  = block_prefix_sum[2];
  assign prefix_sum[9]  = block_prefix_sum[2] + {{(WIDTH-1){1'b0}}, mask_in[8]};
  assign prefix_sum[10] = block_prefix_sum[2] + {{(WIDTH-2){1'b0}}, s1[4]};
  assign prefix_sum[11] = block_prefix_sum[2] + {{(WIDTH-2){1'b0}}, s1[4]} +
                          {{(WIDTH-1){1'b0}}, mask_in[10]};

  assign prefix_sum[12] = block_prefix_sum[3];
  assign prefix_sum[13] = block_prefix_sum[3] + {{(WIDTH-1){1'b0}}, mask_in[12]};
  assign prefix_sum[14] = block_prefix_sum[3] + {{(WIDTH-2){1'b0}}, s1[6]};
  assign prefix_sum[15] = block_prefix_sum[3] + {{(WIDTH-2){1'b0}}, s1[6]} +
                          {{(WIDTH-1){1'b0}}, mask_in[14]};

endmodule
