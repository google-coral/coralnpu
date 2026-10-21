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
module rvv_backend_mac_eew32_datapath (
  input  logic [15:0][15:0] mac8_out,
  input  logic              src1_is_signed,
  input  logic              src2_is_signed,
  input  logic              keep_low_bits,
  input  logic [1:0]        xrm,
  input  logic              is_vsmul,
  input  logic              is_vmac,
  input  logic              mul_reverse,
  input  logic [31:0]       addsrc_no_widen,
  input  logic [63:0]       addsrc_widen,
  output logic [31:0]       result_narrow,
  output logic [63:0]       result_widen,
  output logic              vxsat
);

`ifdef CORALNPU_STRUCTURAL_DATAPATH
  // ---------------------------------------------------------------------------
  // Structural OpenROAD Flow: Trapezoidal Dadda CSA Tree + Han-Carlson VMA
  // Logic Depth: 12-14 Gate Levels
  // ---------------------------------------------------------------------------
  logic [15:0][63:0] pp_terms;
  logic [63:0]       csa_sum, csa_carry;
  logic [63:0]       full_product;
  logic              vsmul_round_incr;

  // Align partial products with Baugh-Wooley sign extensions
  assign pp_terms[0]  = {48'b0, mac8_out[0]};
  assign pp_terms[1]  = {40'b0, mac8_out[1], 8'b0};
  assign pp_terms[2]  = {32'b0, mac8_out[2], 16'b0};
  assign pp_terms[3]  = {{24{mac8_out[3][15]  & src2_is_signed}}, mac8_out[3],  24'b0};
  assign pp_terms[4]  = {40'b0, mac8_out[4], 8'b0};
  assign pp_terms[5]  = {32'b0, mac8_out[5], 16'b0};
  assign pp_terms[6]  = {24'b0, mac8_out[6], 24'b0};
  assign pp_terms[7]  = {{16{mac8_out[7][15]  & src2_is_signed}}, mac8_out[7],  32'b0};
  assign pp_terms[8]  = {32'b0, mac8_out[8], 16'b0};
  assign pp_terms[9]  = {24'b0, mac8_out[9], 24'b0};
  assign pp_terms[10] = {16'b0, mac8_out[10], 32'b0};
  assign pp_terms[11] = {{8{mac8_out[11][15]  & src2_is_signed}}, mac8_out[11], 40'b0};
  assign pp_terms[12] = {{24{mac8_out[12][15] & src1_is_signed}}, mac8_out[12], 24'b0};
  assign pp_terms[13] = {{16{mac8_out[13][15] & src1_is_signed}}, mac8_out[13], 32'b0};
  assign pp_terms[14] = {{8{mac8_out[14][15]  & src1_is_signed}}, mac8_out[14], 40'b0};
  assign pp_terms[15] = {mac8_out[15], 48'b0};

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
  assign vxsat = (full_product[63:62] == 2'b01);

  logic [31:0] mac_rslt_no_widen;
  logic [63:0] mac_rslt_widen;
  logic [31:0] vsmul_rslt;
  logic [32:0] vmac_mul_add_no_widen;
  logic [32:0] vmac_mul_sub_no_widen;
  logic [31:0] vmac_rslt_no_widen;
  logic [64:0] vmac_mul_add_widen;
  logic [64:0] vmac_mul_sub_widen;
  logic [63:0] vmac_rslt_widen;

  always_comb begin
    mac_rslt_widen    = full_product;
    mac_rslt_no_widen = keep_low_bits ? full_product[31:0] : full_product[63:32];
    vsmul_rslt        = vxsat ? 32'h7fff_ffff : (full_product[31+:32] + {31'b0, vsmul_round_incr});

    vmac_mul_add_no_widen = {1'b0, addsrc_no_widen} + {1'b0, mac_rslt_no_widen};
    vmac_mul_sub_no_widen = {1'b0, addsrc_no_widen} - {1'b0, mac_rslt_no_widen};
    vmac_rslt_no_widen    = mul_reverse ? vmac_mul_sub_no_widen[31:0] : vmac_mul_add_no_widen[31:0];

    vmac_mul_add_widen = {1'b0, addsrc_widen} + {1'b0, mac_rslt_widen};
    vmac_mul_sub_widen = {1'b0, addsrc_widen} - {1'b0, mac_rslt_widen};
    vmac_rslt_widen    = mul_reverse ? vmac_mul_sub_widen[63:0] : vmac_mul_add_widen[63:0];

    result_widen  = is_vmac ? vmac_rslt_widen : mac_rslt_widen;
    result_narrow = is_vmac ? vmac_rslt_no_widen : (is_vsmul ? vsmul_rslt : mac_rslt_no_widen);
  end

`else
  // ---------------------------------------------------------------------------
  // Default Behavioral Reference Flow (Default Verilog Invariance)
  // Multi-target general flow: FPGA DSP mapping, Synopsys DesignWare, Fast Sim
  // ---------------------------------------------------------------------------
  logic [17:0] mac_rslt_part16;
  logic [33:0] mac_rslt_part32;
  logic [49:0] mac_rslt_part48;
  logic [63:0] mac_rslt_full;
  logic [31:0] mac_rslt_no_widen;
  logic [63:0] mac_rslt_widen;
  logic        vsmul_round_incr;
  logic [31:0] vsmul_rslt;
  logic [32:0] vmac_mul_add_no_widen;
  logic [32:0] vmac_mul_sub_no_widen;
  logic [31:0] vmac_rslt_no_widen;
  logic [64:0] vmac_mul_add_widen;
  logic [64:0] vmac_mul_sub_widen;
  logic [63:0] vmac_rslt_widen;

  always_comb begin
    mac_rslt_part16 = {{2{mac8_out[12][15] && src1_is_signed}}, mac8_out[12]} +
                      {{2{mac8_out[3 ][15] && src2_is_signed}}, mac8_out[3 ]};
    mac_rslt_part32 = {{2{mac8_out[13][15] && src1_is_signed}}, mac8_out[13], mac8_out[5]} +
                      {{2{mac8_out[7 ][15] && src2_is_signed}}, mac8_out[7 ], mac8_out[8]};
    mac_rslt_part48 =
        {{2{mac8_out[14][15] && src1_is_signed}}, mac8_out[14], mac8_out[6], mac8_out[4]} +
        {{2{mac8_out[11][15] && src2_is_signed}}, mac8_out[11], mac8_out[9], mac8_out[1]};

    mac_rslt_full = {mac8_out[15], mac8_out[10], mac8_out[2], mac8_out[0]} +
                    {{22{mac_rslt_part16[17]}}, mac_rslt_part16, 24'b0} +
                    {{14{mac_rslt_part32[33]}}, mac_rslt_part32, 16'b0} +
                    {{6{mac_rslt_part48[49]}},  mac_rslt_part48, 8'b0};

    mac_rslt_widen    = mac_rslt_full;
    mac_rslt_no_widen = keep_low_bits ? mac_rslt_full[31:0] : mac_rslt_full[63:32];

    case (xrm)
      2'd3:    vsmul_round_incr = !mac_rslt_full[31] && (|mac_rslt_full[30:0]);
      2'd2:    vsmul_round_incr = 1'b0;
      2'd1:    vsmul_round_incr = mac_rslt_full[30] &&
                                  ((|mac_rslt_full[29:0]) || mac_rslt_full[31]);
      default: vsmul_round_incr = mac_rslt_full[30];
    endcase

    vxsat = (mac_rslt_full[63:62] == 2'b01);
    vsmul_rslt = vxsat ? 32'h7fff_ffff : (mac_rslt_full[31+:32] + {31'b0, vsmul_round_incr});

    vmac_mul_add_no_widen = {1'b0, addsrc_no_widen} + {1'b0, mac_rslt_no_widen};
    vmac_mul_sub_no_widen = {1'b0, addsrc_no_widen} - {1'b0, mac_rslt_no_widen};
    vmac_rslt_no_widen    = mul_reverse ? vmac_mul_sub_no_widen[31:0] : vmac_mul_add_no_widen[31:0];

    vmac_mul_add_widen = {1'b0, addsrc_widen} + {1'b0, mac_rslt_widen};
    vmac_mul_sub_widen = {1'b0, addsrc_widen} - {1'b0, mac_rslt_widen};
    vmac_rslt_widen    = mul_reverse ? vmac_mul_sub_widen[63:0] : vmac_mul_add_widen[63:0];

    result_widen  = is_vmac ? vmac_rslt_widen : mac_rslt_widen;
    result_narrow = is_vmac ? vmac_rslt_no_widen : (is_vsmul ? vsmul_rslt : mac_rslt_no_widen);
  end
`endif

endmodule
