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
module prefix_adder_han_carlson_64b #(
  parameter int WIDTH = 64
) (
  input  logic [WIDTH-1:0] a,
  input  logic [WIDTH-1:0] b,
  input  logic             cin,
  output logic [WIDTH-1:0] sum,
  output logic             cout
);
  localparam int PaddedWidth = (WIDTH <= 64) ? 64 : 128;

  logic [PaddedWidth-1:0] a_pad;
  logic [PaddedWidth-1:0] b_pad;
  logic [PaddedWidth-1:0] g0, p0;
  logic [PaddedWidth-1:0] g1, p1;
  logic [PaddedWidth-1:0] g2, p2;
  logic [PaddedWidth-1:0] g3, p3;
  logic [PaddedWidth-1:0] g4, p4;
  logic [PaddedWidth-1:0] g5, p5;
  logic [PaddedWidth-1:0] g6, p6;
  logic [PaddedWidth-1:0] g7, p7;
  logic [PaddedWidth-1:0] c;
  logic [PaddedWidth-1:0] sum_full;

  always_comb begin
    a_pad = '0;
    b_pad = '0;
    a_pad[WIDTH-1:0] = a;
    b_pad[WIDTH-1:0] = b;
  end

  // Level 0: Bit generate and propagate
  assign g0[0] = (a_pad[0] & b_pad[0]) | ((a_pad[0] ^ b_pad[0]) & cin);
  assign p0[0] = a_pad[0] ^ b_pad[0];

  genvar i;
  generate
    for (i = 1; i < PaddedWidth; i = i + 1) begin : gen_gp0
      assign g0[i] = a_pad[i] & b_pad[i];
      assign p0[i] = a_pad[i] ^ b_pad[i];
    end
  endgenerate

  // Stage 1: Span 1 on odd columns
  generate
    for (i = 0; i < PaddedWidth; i = i + 1) begin : gen_stg1
      if (i % 2 == 1) begin : gen_odd
        assign g1[i] = g0[i] | (p0[i] & g0[i-1]);
        assign p1[i] = p0[i] & p0[i-1];
      end else begin : gen_even
        assign g1[i] = g0[i];
        assign p1[i] = p0[i];
      end
    end
  endgenerate

  // Stage 2: Span 2 on odd columns
  generate
    for (i = 0; i < PaddedWidth; i = i + 1) begin : gen_stg2
      if ((i % 2 == 1) && (i >= 3)) begin : gen_odd_merge
        assign g2[i] = g1[i] | (p1[i] & g1[i-2]);
        assign p2[i] = p1[i] & p1[i-2];
      end else begin : gen_pass
        assign g2[i] = g1[i];
        assign p2[i] = p1[i];
      end
    end
  endgenerate

  // Stage 3: Span 4 on odd columns
  generate
    for (i = 0; i < PaddedWidth; i = i + 1) begin : gen_stg3
      if ((i % 2 == 1) && (i >= 5)) begin : gen_odd_merge
        assign g3[i] = g2[i] | (p2[i] & g2[i-4]);
        assign p3[i] = p2[i] & p2[i-4];
      end else begin : gen_pass
        assign g3[i] = g2[i];
        assign p3[i] = p2[i];
      end
    end
  endgenerate

  // Stage 4: Span 8 on odd columns
  generate
    for (i = 0; i < PaddedWidth; i = i + 1) begin : gen_stg4
      if ((i % 2 == 1) && (i >= 9)) begin : gen_odd_merge
        assign g4[i] = g3[i] | (p3[i] & g3[i-8]);
        assign p4[i] = p3[i] & p3[i-8];
      end else begin : gen_pass
        assign g4[i] = g3[i];
        assign p4[i] = p3[i];
      end
    end
  endgenerate

  // Stage 5: Span 16 on odd columns
  generate
    for (i = 0; i < PaddedWidth; i = i + 1) begin : gen_stg5
      if ((i % 2 == 1) && (i >= 17)) begin : gen_odd_merge
        assign g5[i] = g4[i] | (p4[i] & g4[i-16]);
        assign p5[i] = p4[i] & p4[i-16];
      end else begin : gen_pass
        assign g5[i] = g4[i];
        assign p5[i] = p4[i];
      end
    end
  endgenerate

  // Stage 6: Span 32 on odd columns
  generate
    for (i = 0; i < PaddedWidth; i = i + 1) begin : gen_stg6
      if ((i % 2 == 1) && (i >= 33)) begin : gen_odd_merge
        assign g6[i] = g5[i] | (p5[i] & g5[i-32]);
        assign p6[i] = p5[i] & p5[i-32];
      end else begin : gen_pass
        assign g6[i] = g5[i];
        assign p6[i] = p5[i];
      end
    end
  endgenerate

  // Stage 7: Span 64 on odd columns (for PaddedWidth > 64)
  generate
    for (i = 0; i < PaddedWidth; i = i + 1) begin : gen_stg7
      if ((PaddedWidth > 64) && (i % 2 == 1) && (i >= 65)) begin : gen_odd_merge
        assign g7[i] = g6[i] | (p6[i] & g6[i-64]);
        assign p7[i] = p6[i] & p6[i-64];
      end else begin : gen_pass
        assign g7[i] = g6[i];
        assign p7[i] = p6[i];
      end
    end
  endgenerate

  // Stage 8: Interpolation on even columns
  assign c[0] = g0[0];
  generate
    for (i = 1; i < PaddedWidth; i = i + 1) begin : gen_interp
      if (i % 2 == 0) begin : gen_even_interp
        assign c[i] = g0[i] | (p0[i] & g7[i-1]);
      end else begin : gen_odd_pass
        assign c[i] = g7[i];
      end
    end
  endgenerate

  // Final Sum Generation
  assign sum_full[0] = p0[0] ^ cin;
  generate
    for (i = 1; i < PaddedWidth; i = i + 1) begin : gen_final_sum
      assign sum_full[i] = p0[i] ^ c[i-1];
    end
  endgenerate

  assign sum  = sum_full[WIDTH-1:0];
  assign cout = c[WIDTH-1];

endmodule
