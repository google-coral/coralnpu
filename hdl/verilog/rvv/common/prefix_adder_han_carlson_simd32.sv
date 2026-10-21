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
module prefix_adder_han_carlson_simd32 (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [3:0]  cin,       // Carry-in per byte
  input  logic [1:0]  eew,       // 2'b00: EEW8, 2'b01: EEW16, 2'b10: EEW32
  input  logic        is_sub,
  output logic [31:0] sum,
  output logic [3:0]  cout
);
  logic [31:0] b_eff;
  logic [31:0] g_0, p_0;
  logic [3:0]  lane_cin;

  // Invert B for subtraction
  assign b_eff = is_sub ? ~b : b;

  always_comb begin
    case (eew)
      2'b00:   lane_cin = cin ^ {4{is_sub}};
      2'b01:   lane_cin = {1'b0, cin[2] ^ is_sub, 1'b0, cin[0] ^ is_sub};
      default: lane_cin = {3'b0, cin[0] ^ is_sub};
    endcase
  end

  // Step 1: Bit-level Generate & Propagate with Lane Cin Injection
  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : gen_gp0
      if (i == 0) begin : gen_g0
        assign g_0[0] = (a[0] & b_eff[0]) | ((a[0] ^ b_eff[0]) & lane_cin[0]);
      end else if (i == 8) begin : gen_g8
        assign g_0[8] = (eew == 2'b00) ?
                        ((a[8] & b_eff[8]) | ((a[8] ^ b_eff[8]) & lane_cin[1])) :
                        (a[8] & b_eff[8]);
      end else if (i == 16) begin : gen_g16
        assign g_0[16] = (eew == 2'b00 || eew == 2'b01) ?
                         ((a[16] & b_eff[16]) | ((a[16] ^ b_eff[16]) & lane_cin[2])) :
                         (a[16] & b_eff[16]);
      end else if (i == 24) begin : gen_g24
        assign g_0[24] = (eew == 2'b00) ?
                         ((a[24] & b_eff[24]) | ((a[24] ^ b_eff[24]) & lane_cin[3])) :
                         (a[24] & b_eff[24]);
      end else begin : gen_g_other
        assign g_0[i] = a[i] & b_eff[i];
      end

      assign p_0[i] = a[i] ^ b_eff[i];
    end
  endgenerate

  // Step 2: Han-Carlson Parallel-Prefix Tree with Dynamic SIMD Partitioning
  // Stage 1: Span 1 on odd columns (never crosses 8-bit boundaries)
  logic [31:0] g1, p1;
  generate
    for (i = 0; i < 32; i = i + 1) begin : gen_stg1
      if (i % 2 == 1) begin : gen_odd
        assign g1[i] = g_0[i] | (p_0[i] & g_0[i-1]);
        assign p1[i] = p_0[i] & p_0[i-1];
      end else begin : gen_even
        assign g1[i] = g_0[i];
        assign p1[i] = p_0[i];
      end
    end
  endgenerate

  // Stage 2: Span 2 on odd columns (step = 2)
  logic [31:0] g2, p2;
  generate
    for (i = 0; i < 32; i = i + 1) begin : gen_stg2
      if ((i % 2 == 1) && (i >= 3)) begin : gen_odd_merge
        localparam bit SameByte = (i / 8 == (i - 2) / 8);
        localparam bit SameHword = (i / 16 == (i - 2) / 16);
        logic en_stg2;
        assign en_stg2 = (eew == 2'b00) ? SameByte :
                         (eew == 2'b01) ? SameHword : 1'b1;
        assign g2[i] = en_stg2 ? (g1[i] | (p1[i] & g1[i-2])) : g1[i];
        assign p2[i] = en_stg2 ? (p1[i] & p1[i-2]) : p1[i];
      end else begin : gen_pass
        assign g2[i] = g1[i];
        assign p2[i] = p1[i];
      end
    end
  endgenerate

  // Stage 3: Span 4 on odd columns (step = 4)
  logic [31:0] g3, p3;
  generate
    for (i = 0; i < 32; i = i + 1) begin : gen_stg3
      if ((i % 2 == 1) && (i >= 5)) begin : gen_odd_merge
        localparam bit SameByte = (i / 8 == (i - 4) / 8);
        localparam bit SameHword = (i / 16 == (i - 4) / 16);
        logic en_stg3;
        assign en_stg3 = (eew == 2'b00) ? SameByte :
                         (eew == 2'b01) ? SameHword : 1'b1;
        assign g3[i] = en_stg3 ? (g2[i] | (p2[i] & g2[i-4])) : g2[i];
        assign p3[i] = en_stg3 ? (p2[i] & p2[i-4]) : p2[i];
      end else begin : gen_pass
        assign g3[i] = g2[i];
        assign p3[i] = p2[i];
      end
    end
  endgenerate

  // Stage 4: Span 8 on odd columns (step = 8)
  logic [31:0] g4, p4;
  generate
    for (i = 0; i < 32; i = i + 1) begin : gen_stg4
      if ((i % 2 == 1) && (i >= 9)) begin : gen_odd_merge
        localparam bit SameHword = (i / 16 == (i - 8) / 16);
        logic en_stg4;
        assign en_stg4 = (eew == 2'b00) ? 1'b0 :
                         (eew == 2'b01) ? SameHword : 1'b1;
        assign g4[i] = en_stg4 ? (g3[i] | (p3[i] & g3[i-8])) : g3[i];
        assign p4[i] = en_stg4 ? (p3[i] & p3[i-8]) : p3[i];
      end else begin : gen_pass
        assign g4[i] = g3[i];
        assign p4[i] = p3[i];
      end
    end
  endgenerate

  // Stage 5: Span 16 on odd columns (step = 16)
  logic [31:0] g5, p5;
  generate
    for (i = 0; i < 32; i = i + 1) begin : gen_stg5
      if ((i % 2 == 1) && (i >= 17)) begin : gen_odd_merge
        logic en_stg5;
        assign en_stg5 = (eew == 2'b00 || eew == 2'b01) ? 1'b0 : 1'b1;
        assign g5[i] = en_stg5 ? (g4[i] | (p4[i] & g4[i-16])) : g4[i];
        assign p5[i] = en_stg5 ? (p4[i] & p4[i-16]) : p4[i];
      end else begin : gen_pass
        assign g5[i] = g4[i];
        assign p5[i] = p4[i];
      end
    end
  endgenerate

  // Stage 6: Interpolation on even columns
  logic [31:0] c;
  assign c[0] = g_0[0];
  generate
    for (i = 1; i < 32; i = i + 1) begin : gen_interp
      if (i % 2 == 0) begin : gen_even_interp
        localparam bit SameByte = (i / 8 == (i - 1) / 8);
        localparam bit SameHword = (i / 16 == (i - 1) / 16);
        logic en_interp;
        assign en_interp = (eew == 2'b00) ? SameByte :
                           (eew == 2'b01) ? SameHword : 1'b1;
        assign c[i] = en_interp ? (g_0[i] | (p_0[i] & g5[i-1])) : g_0[i];
      end else begin : gen_odd_pass
        assign c[i] = g5[i];
      end
    end
  endgenerate

  // Step 3: Final Sum Generation
  assign sum[0] = (a[0] ^ b_eff[0]) ^ lane_cin[0];
  generate
    for (i = 1; i < 32; i = i + 1) begin : gen_sum
      if (i == 8) begin : gen_sum_8
        assign sum[8] = (a[8] ^ b_eff[8]) ^ ((eew == 2'b00) ? lane_cin[1] : c[7]);
      end else if (i == 16) begin : gen_sum_16
        assign sum[16] = (a[16] ^ b_eff[16]) ^
                         ((eew == 2'b00 || eew == 2'b01) ? lane_cin[2] : c[15]);
      end else if (i == 24) begin : gen_sum_24
        assign sum[24] = (a[24] ^ b_eff[24]) ^ ((eew == 2'b00) ? lane_cin[3] : c[23]);
      end else begin : gen_sum_other
        assign sum[i] = (a[i] ^ b_eff[i]) ^ c[i-1];
      end
    end
  endgenerate

  assign cout = {c[31], c[23], c[15], c[7]};

endmodule
