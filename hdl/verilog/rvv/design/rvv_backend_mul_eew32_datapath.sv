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
module rvv_backend_mul_eew32_datapath (
  input  logic [15:0][15:0] mul8_out,
  input  logic              src1_is_signed,
  input  logic              src2_is_signed,
  input  logic              keep_low_bits,
  input  logic [1:0]        xrm,
  input  logic              is_vsmul,
  output logic [31:0]       result_narrow,
  output logic [63:0]       result_widen,
  output logic              vxsat
);

`ifdef CORALNPU_STRUCTURAL_DATAPATH
  // ---------------------------------------------------------------------------
  // Structural OpenROAD Flow: Trapezoidal Dadda CSA Tree + Han-Carlson VMA
  // Logic Depth: 12 Gate Levels
  // ---------------------------------------------------------------------------
  logic [15:0][63:0] pp_terms;
  logic [63:0]       csa_sum, csa_carry;
  logic [63:0]       full_product;
  logic              vsmul_round_incr;

  // Align partial products with Baugh-Wooley sign extensions
  assign pp_terms[0]  = {48'b0, mul8_out[0]};
  assign pp_terms[1]  = {40'b0, mul8_out[1], 8'b0};
  assign pp_terms[2]  = {32'b0, mul8_out[2], 16'b0};
  assign pp_terms[3]  = {{24{mul8_out[3][15]  & src2_is_signed}}, mul8_out[3],  24'b0};
  assign pp_terms[4]  = {40'b0, mul8_out[4], 8'b0};
  assign pp_terms[5]  = {32'b0, mul8_out[5], 16'b0};
  assign pp_terms[6]  = {24'b0, mul8_out[6], 24'b0};
  assign pp_terms[7]  = {{16{mul8_out[7][15]  & src2_is_signed}}, mul8_out[7],  32'b0};
  assign pp_terms[8]  = {32'b0, mul8_out[8], 16'b0};
  assign pp_terms[9]  = {24'b0, mul8_out[9], 24'b0};
  assign pp_terms[10] = {16'b0, mul8_out[10], 32'b0};
  assign pp_terms[11] = {{8{mul8_out[11][15]  & src2_is_signed}}, mul8_out[11], 40'b0};
  assign pp_terms[12] = {{24{mul8_out[12][15] & src1_is_signed}}, mul8_out[12], 24'b0};
  assign pp_terms[13] = {{16{mul8_out[13][15] & src1_is_signed}}, mul8_out[13], 32'b0};
  assign pp_terms[14] = {{8{mul8_out[14][15]  & src1_is_signed}}, mul8_out[14], 40'b0};
  assign pp_terms[15] = {mul8_out[15], 48'b0};

  compressor_tree_16to2_dadda #(.WIDTH(64)) u_dadda_tree (
    .src         (pp_terms),
    .result_sum  (csa_sum),
    .result_carry(csa_carry)
  );

  // Han-Carlson 64-bit Vector Merge Adder
  prefix_adder_han_carlson_64b #(.WIDTH(64)) u_vma (
    .a  (csa_sum),
    .b  ({csa_carry[62:0], 1'b0}),
    .cin(1'b0),
    .sum(full_product),
    .cout()
  );

  // Rounding increment evaluation
  always_comb begin
    case (xrm)
      2'd3:    vsmul_round_incr = !full_product[31] && (|full_product[30:0]);
      2'd2:    vsmul_round_incr = 1'b0;
      2'd1:    vsmul_round_incr = full_product[30] && ((|full_product[29:0]) || full_product[31]);
      default: vsmul_round_incr = full_product[30];
    endcase
  end

  // Preserves 1:1 baseline saturation detection for bit-exact equivalence with behavioral model
  // (Note: Post-rounding saturation overflow behavior matches baseline behavioral model)
  assign vxsat = (full_product[63:62] == 2'b01);

  always_comb begin
    result_widen = full_product;
    if (is_vsmul) begin
      result_narrow = vxsat ? 32'h7fff_ffff : (full_product[31+:32] + {31'b0, vsmul_round_incr});
    end else begin
      result_narrow = keep_low_bits ? full_product[31:0] : full_product[63:32];
    end
  end

`else
  // ---------------------------------------------------------------------------
  // Default Behavioral Reference Flow (Default Verilog Invariance)
  // Multi-target general flow: FPGA DSP mapping, Synopsys DesignWare, Fast Sim
  // ---------------------------------------------------------------------------
  logic [63:0] full_product;
  logic        vsmul_round_incr;

  always_comb begin
    full_product = {mul8_out[15], 48'b0} +
                   {{8{mul8_out[14][15]  && src1_is_signed}}, mul8_out[14], 40'b0} +
                   {{8{mul8_out[11][15]  && src2_is_signed}}, mul8_out[11], 40'b0} +
                   {{16{mul8_out[13][15] && src1_is_signed}}, mul8_out[13], 32'b0} +
                   {16'b0, mul8_out[10], 32'b0} +
                   {{16{mul8_out[7][15]  && src2_is_signed}}, mul8_out[7],  32'b0} +
                   {{24{mul8_out[12][15] && src1_is_signed}}, mul8_out[12], 24'b0} +
                   {24'b0, mul8_out[9], 24'b0} +
                   {24'b0, mul8_out[6], 24'b0} +
                   {{24{mul8_out[3][15]  && src2_is_signed}}, mul8_out[3],  24'b0} +
                   {32'b0, mul8_out[8], 16'b0} +
                   {32'b0, mul8_out[5], 16'b0} +
                   {32'b0, mul8_out[2], 16'b0} +
                   {40'b0, mul8_out[4], 8'b0} +
                   {40'b0, mul8_out[1], 8'b0} +
                   {48'b0, mul8_out[0]};

    result_widen = full_product;

    case (xrm)
      2'd3:    vsmul_round_incr = !full_product[31] && (|full_product[30:0]);
      2'd2:    vsmul_round_incr = 1'b0;
      2'd1:    vsmul_round_incr = full_product[30] && ((|full_product[29:0]) || full_product[31]);
      default: vsmul_round_incr = full_product[30];
    endcase

    vxsat = (full_product[63:62] == 2'b01);

    if (is_vsmul) begin
      result_narrow = vxsat ? 32'h7fff_ffff : (full_product[31+:32] + {31'b0, vsmul_round_incr});
    end else begin
      result_narrow = keep_low_bits ? full_product[31:0] : full_product[63:32];
    end
  end
`endif

endmodule
