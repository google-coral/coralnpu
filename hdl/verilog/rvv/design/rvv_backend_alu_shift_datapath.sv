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

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_BACKEND_ALU_SHIFT_DATAPATH_SV
`define HDL_VERILOG_RVV_DESIGN_RVV_BACKEND_ALU_SHIFT_DATAPATH_SV

(* keep_hierarchy = "yes" *)
module rvv_backend_alu_shift_datapath (
  input  logic                   alu_uop_valid,
  input  ALU_RS_t                alu_uop,
  output logic                   result_valid,
  output PU2ROB_t                result
);
  localparam logic [1:0] ShiftSll = 2'b00;
  localparam logic [1:0] ShiftSrl = 2'b01;
  localparam logic [1:0] ShiftSra = 2'b10;

  // Unpack ALU_RS_t
  logic [`ROB_DEPTH_WIDTH-1:0]   rob_entry;
  FUNCT6_u                       uop_funct6;
  logic [`FUNCT3_WIDTH-1:0]      uop_funct3;
  RVVXRM                         vxrm;
  logic [`VLEN-1:0]              vs1_data;
  logic [`VLEN-1:0]              vs2_data;
  EEW_e                          vs2_eew;
  logic [`XLEN-1:0]              rs1_data;
  logic [$clog2(`EMUL_MAX)-1:0]  uop_index;

  assign rob_entry   = alu_uop.rob_entry;
  assign uop_funct6  = alu_uop.uop_funct6;
  assign uop_funct3  = alu_uop.uop_funct3;
  assign vxrm        = alu_uop.vxrm;
  assign vs1_data    = alu_uop.vs1_data;
  assign rs1_data    = alu_uop.vs1_data[`XLEN-1:0];
  assign vs2_data    = alu_uop.vs2_data;
  assign vs2_eew     = alu_uop.vs2_eew;
  assign uop_index   = alu_uop.uop_index;

  // ---------------------------------------------------------------------------
  // 1. Instruction Decoding
  // ---------------------------------------------------------------------------
  logic is_vsll, is_vsrl, is_vsra;
  logic is_vssrl, is_vssra;
  logic is_vnsrl, is_vnsra;
  logic is_vnclipu, is_vnclip;
  logic is_valid_shift_inst;

  always_comb begin
    is_vsll    = 1'b0;
    is_vsrl    = 1'b0;
    is_vsra    = 1'b0;
    is_vssrl   = 1'b0;
    is_vssra   = 1'b0;
    is_vnsrl   = 1'b0;
    is_vnsra   = 1'b0;
    is_vnclipu = 1'b0;
    is_vnclip  = 1'b0;

    if (uop_funct3 == OPIVV || uop_funct3 == OPIVX || uop_funct3 == OPIVI) begin
      case (uop_funct6.ari_funct6)
        VSLL:    is_vsll    = 1'b1;
        VSRL:    is_vsrl    = 1'b1;
        VSRA:    is_vsra    = 1'b1;
        VSSRL:   is_vssrl   = 1'b1;
        VSSRA:   is_vssra   = 1'b1;
        VNSRL:   is_vnsrl   = 1'b1;
        VNSRA:   is_vnsra   = 1'b1;
        VNCLIPU: is_vnclipu = 1'b1;
        VNCLIP:  is_vnclip  = 1'b1;
        default: ;
      endcase
    end
  end

  assign is_valid_shift_inst = is_vsll | is_vsrl | is_vsra | is_vssrl | is_vssra |
                               is_vnsrl | is_vnsra | is_vnclipu | is_vnclip;
  assign result_valid        = alu_uop_valid & is_valid_shift_inst;

  logic shift_is_left;
  logic shift_is_arith;
  logic needs_rounding;
  logic is_narrowing;
  logic [1:0] shift_mode;

  assign shift_is_left   = is_vsll;
  assign shift_is_arith  = is_vsra | is_vssra | is_vnsra | is_vnclip;
  assign needs_rounding  = is_vssrl | is_vssra | is_vnclipu | is_vnclip;
  assign is_narrowing    = is_vnsrl | is_vnsra | is_vnclipu | is_vnclip;
  assign shift_mode      = shift_is_left  ? ShiftSll :
                           shift_is_arith ? ShiftSra : ShiftSrl;

  // ---------------------------------------------------------------------------
  // 2. Source Operand Preparation
  // ---------------------------------------------------------------------------
  // EEW8: 16 elements (8-bit)
  logic [15:0][7:0] src2_data8;
  logic [15:0][2:0] shift_amount8;
  genvar k;
  generate
    for (k = 0; k < 16; k = k + 1) begin : gen_src8
      assign src2_data8[k] = vs2_data[k*8 +: 8];
      assign shift_amount8[k] = (uop_funct3 == OPIVV) ? vs1_data[k*8 +: 3] :
                                                        rs1_data[2:0];
    end
  endgenerate

  // EEW16: 8 elements (16-bit)
  logic [7:0][15:0] src2_data16;
  logic [7:0][3:0]  shift_amount16;
  generate
    for (k = 0; k < 8; k = k + 1) begin : gen_src16
      assign src2_data16[k] = vs2_data[k*16 +: 16];
      always_comb begin
        if (is_narrowing) begin
          if (uop_funct3 == OPIVV) begin
            if (uop_index[0] == 1'b0) begin
              shift_amount16[k] = vs1_data[k*8 +: 4];
            end else begin
              shift_amount16[k] = vs1_data[64 + k*8 +: 4];
            end
          end else begin
            shift_amount16[k] = rs1_data[3:0];
          end
        end else begin
          if (uop_funct3 == OPIVV) begin
            shift_amount16[k] = vs1_data[k*16 +: 4];
          end else begin
            shift_amount16[k] = rs1_data[3:0];
          end
        end
      end
    end
  endgenerate

  // EEW32: 4 elements (32-bit)
  logic [3:0][31:0] src2_data32;
  logic [3:0][4:0]  shift_amount32;
  generate
    for (k = 0; k < 4; k = k + 1) begin : gen_src32
      assign src2_data32[k] = vs2_data[k*32 +: 32];
      always_comb begin
        if (is_narrowing) begin
          if (uop_funct3 == OPIVV) begin
            if (uop_index[0] == 1'b0) begin
              shift_amount32[k] = vs1_data[k*16 +: 5];
            end else begin
              shift_amount32[k] = vs1_data[64 + k*16 +: 5];
            end
          end else begin
            shift_amount32[k] = rs1_data[4:0];
          end
        end else begin
          if (uop_funct3 == OPIVV) begin
            shift_amount32[k] = vs1_data[k*32 +: 5];
          end else begin
            shift_amount32[k] = rs1_data[4:0];
          end
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // 3. Execution: Tree Shifters, Parallel Sticky Trees & Round Increment
  // ---------------------------------------------------------------------------

  // --- EEW8 Datapath (16 slices) ---
  logic [15:0][7:0] product8_raw;
  logic [15:0][7:0] product8_rounded;
  logic [15:0]      round_inc8;

  generate
    for (k = 0; k < 16; k = k + 1) begin : gen_shifter8
      barrel_shifter_tree #(.DATA_WIDTH(8)) u_shf8 (
        .din          (src2_data8[k]),
        .shift_amount (shift_amount8[k]),
        .shift_mode   (shift_mode),
        .dout         (product8_raw[k])
      );

      // 3-level Kogge-Stone Prefix OR Tree for sticky bit
      logic [7:0] p_or8_l0, p_or8_l1, p_or8_l2, p_or8_l3;
      assign p_or8_l0 = src2_data8[k];
      assign p_or8_l1 = p_or8_l0 | {p_or8_l0[6:0], 1'b0};
      assign p_or8_l2 = p_or8_l1 | {p_or8_l1[5:0], 2'b0};
      assign p_or8_l3 = p_or8_l2 | {p_or8_l2[3:0], 4'b0};

      logic r_bit8, t_bit8, p0_8;
      assign r_bit8 = (shift_amount8[k] > 3'd0) ? src2_data8[k][shift_amount8[k] - 3'd1] : 1'b0;
      assign t_bit8 = (shift_amount8[k] > 3'd1) ? p_or8_l3[shift_amount8[k] - 3'd2]      : 1'b0;
      assign p0_8   = product8_raw[k][0];

      always_comb begin
        if (!needs_rounding || shift_is_left) begin
          round_inc8[k] = 1'b0;
        end else begin
          case (vxrm)
            RNU: round_inc8[k] = r_bit8;
            RNE: round_inc8[k] = r_bit8 & (t_bit8 | p0_8);
            RDN: round_inc8[k] = 1'b0;
            ROD: round_inc8[k] = (~p0_8) & (r_bit8 | t_bit8);
            default: round_inc8[k] = 1'b0;
          endcase
        end
      end
    end
  endgenerate

  // --- EEW16 Datapath (8 slices) ---
  logic [7:0][15:0] product16_raw;
  logic [7:0][15:0] product16_rounded;
  logic [7:0]       cout16;
  logic [7:0]       round_inc16;

  generate
    for (k = 0; k < 8; k = k + 1) begin : gen_shifter16
      barrel_shifter_tree #(.DATA_WIDTH(16)) u_shf16 (
        .din          (src2_data16[k]),
        .shift_amount (shift_amount16[k]),
        .shift_mode   (shift_mode),
        .dout         (product16_raw[k])
      );

      // 4-level Kogge-Stone Prefix OR Tree for sticky bit
      logic [15:0] p_or16_l0, p_or16_l1, p_or16_l2, p_or16_l3, p_or16_l4;
      assign p_or16_l0 = src2_data16[k];
      assign p_or16_l1 = p_or16_l0 | {p_or16_l0[14:0], 1'b0};
      assign p_or16_l2 = p_or16_l1 | {p_or16_l1[13:0], 2'b0};
      assign p_or16_l3 = p_or16_l2 | {p_or16_l2[11:0], 4'b0};
      assign p_or16_l4 = p_or16_l3 | {p_or16_l3[7:0],  8'b0};

      logic r_bit16, t_bit16, p0_16;
      assign r_bit16 = (shift_amount16[k] > 4'd0) ? src2_data16[k][shift_amount16[k] - 4'd1] : 1'b0;
      assign t_bit16 = (shift_amount16[k] > 4'd1) ? p_or16_l4[shift_amount16[k] - 4'd2]      : 1'b0;
      assign p0_16   = product16_raw[k][0];

      always_comb begin
        if (!needs_rounding || shift_is_left) begin
          round_inc16[k] = 1'b0;
        end else begin
          case (vxrm)
            RNU: round_inc16[k] = r_bit16;
            RNE: round_inc16[k] = r_bit16 & (t_bit16 | p0_16);
            RDN: round_inc16[k] = 1'b0;
            ROD: round_inc16[k] = (~p0_16) & (r_bit16 | t_bit16);
            default: round_inc16[k] = 1'b0;
          endcase
        end
      end
    end
  endgenerate

  // --- EEW32 Datapath (4 slices) ---
  logic [3:0][31:0] product32_raw;
  logic [3:0][31:0] product32_rounded;
  logic [3:0]       cout32;
  logic [3:0]       round_inc32;

  generate
    for (k = 0; k < 4; k = k + 1) begin : gen_shifter32
      barrel_shifter_tree #(.DATA_WIDTH(32)) u_shf32 (
        .din          (src2_data32[k]),
        .shift_amount (shift_amount32[k]),
        .shift_mode   (shift_mode),
        .dout         (product32_raw[k])
      );

      // 5-level Kogge-Stone Prefix OR Tree for sticky bit
      logic [31:0] p_or32_l0, p_or32_l1, p_or32_l2, p_or32_l3, p_or32_l4, p_or32_l5;
      assign p_or32_l0 = src2_data32[k];
      assign p_or32_l1 = p_or32_l0 | {p_or32_l0[30:0], 1'b0};
      assign p_or32_l2 = p_or32_l1 | {p_or32_l1[29:0], 2'b0};
      assign p_or32_l3 = p_or32_l2 | {p_or32_l2[27:0], 4'b0};
      assign p_or32_l4 = p_or32_l3 | {p_or32_l3[23:0], 8'b0};
      assign p_or32_l5 = p_or32_l4 | {p_or32_l4[15:0], 16'b0};

      logic r_bit32, t_bit32, p0_32;
      assign r_bit32 = (shift_amount32[k] > 5'd0) ? src2_data32[k][shift_amount32[k] - 5'd1] : 1'b0;
      assign t_bit32 = (shift_amount32[k] > 5'd1) ? p_or32_l5[shift_amount32[k] - 5'd2]      : 1'b0;
      assign p0_32   = product32_raw[k][0];

      always_comb begin
        if (!needs_rounding || shift_is_left) begin
          round_inc32[k] = 1'b0;
        end else begin
          case (vxrm)
            RNU: round_inc32[k] = r_bit32;
            RNE: round_inc32[k] = r_bit32 & (t_bit32 | p0_32);
            RDN: round_inc32[k] = 1'b0;
            ROD: round_inc32[k] = (~p0_32) & (r_bit32 | t_bit32);
            default: round_inc32[k] = 1'b0;
          endcase
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // 4. Fast Parallel-Prefix CLA Compound Incrementers (SIMD32 Lanes)
  // ---------------------------------------------------------------------------
  generate
    for (k = 0; k < 4; k = k + 1) begin : gen_compound_lanes
      logic [31:0] lane_op;
      logic [1:0]  lane_eew;
      logic [3:0]  lane_inc;
      logic [31:0] lane_sum;
      logic [3:0]  lane_cout;

      always_comb begin
        case (vs2_eew)
          EEW8: begin
            lane_op  = {product8_raw[4*k+3], product8_raw[4*k+2],
                        product8_raw[4*k+1], product8_raw[4*k]};
            lane_eew = 2'b00;
            lane_inc = round_inc8[4*k +: 4];
          end
          EEW16: begin
            lane_op  = {product16_raw[2*k+1], product16_raw[2*k]};
            lane_eew = 2'b01;
            lane_inc = {2'b0, round_inc16[2*k +: 2]};
          end
          default: begin // EEW32
            lane_op  = product32_raw[k];
            lane_eew = 2'b10;
            lane_inc = {3'b0, round_inc32[k]};
          end
        endcase
      end

      compound_incrementer_simd32 u_inc_lane (
        .a              (lane_op),
        .eew            (lane_eew),
        .inc            (lane_inc),
        .shift_is_arith (shift_is_arith),
        .sum0           (),
        .sum1           (),
        .sum            (lane_sum),
        .cout           (lane_cout)
      );

      assign product8_rounded[4*k]     = lane_sum[7:0];
      assign product8_rounded[4*k+1]   = lane_sum[15:8];
      assign product8_rounded[4*k+2]   = lane_sum[23:16];
      assign product8_rounded[4*k+3]   = lane_sum[31:24];

      assign product16_rounded[2*k]    = lane_sum[15:0];
      assign product16_rounded[2*k+1]  = lane_sum[31:16];
      assign cout16[2*k]               = lane_cout[0];
      assign cout16[2*k+1]             = lane_cout[1];

      assign product32_rounded[k]      = lane_sum;
      assign cout32[k]                 = lane_cout[0];
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // 5. Restructured Saturation Detection & Clamping (Balanced Tree Reductions)
  // ---------------------------------------------------------------------------
  // EEW16 Narrowing Clamps (16 -> 8 bit)
  logic [7:0] up_u16;
  logic [7:0] up_s16;
  logic [7:0] un_s16;

  generate
    for (k = 0; k < 8; k = k + 1) begin : gen_sat_flags16
      // Explicit 2-level 3-way balanced OR/AND reduction for bits [15:7] (9 bits)
      logic or3_0, or3_1, or3_2, or9;
      assign or3_0 = product16_rounded[k][7]  | product16_rounded[k][8]  | product16_rounded[k][9];
      assign or3_1 = product16_rounded[k][10] | product16_rounded[k][11] | product16_rounded[k][12];
      assign or3_2 = product16_rounded[k][13] | product16_rounded[k][14] | product16_rounded[k][15];
      assign or9   = or3_0 | or3_1 | or3_2;

      logic and3_0, and3_1, and3_2, and9;
      assign and3_0 = product16_rounded[k][7]  & product16_rounded[k][8]  &
                      product16_rounded[k][9];
      assign and3_1 = product16_rounded[k][10] & product16_rounded[k][11] &
                      product16_rounded[k][12];
      assign and3_2 = product16_rounded[k][13] & product16_rounded[k][14] &
                      product16_rounded[k][15];
      assign and9   = and3_0 & and3_1 & and3_2;

      logic or8;
      assign or8 = (|product16_rounded[k][15:8]);

      assign up_u16[k] = cout16[k] | or8;
      assign up_s16[k] = (~cout16[k]) & or9;
      assign un_s16[k] = cout16[k] & (~and9);
    end
  endgenerate

  // EEW32 Narrowing Clamps (32 -> 16 bit)
  logic [3:0] up_u32;
  logic [3:0] up_s32;
  logic [3:0] un_s32;

  generate
    for (k = 0; k < 4; k = k + 1) begin : gen_sat_flags32
      // Explicit 3-level balanced OR/AND reduction for bits [31:15] (17 bits)
      logic or_l1_0, or_l1_1, or_l1_2, or_l1_3, or_l1_4, or_l1_5;
      assign or_l1_0 = product32_rounded[k][15] | product32_rounded[k][16] |
                       product32_rounded[k][17];
      assign or_l1_1 = product32_rounded[k][18] | product32_rounded[k][19] |
                       product32_rounded[k][20];
      assign or_l1_2 = product32_rounded[k][21] | product32_rounded[k][22] |
                       product32_rounded[k][23];
      assign or_l1_3 = product32_rounded[k][24] | product32_rounded[k][25] |
                       product32_rounded[k][26];
      assign or_l1_4 = product32_rounded[k][27] | product32_rounded[k][28] |
                       product32_rounded[k][29];
      assign or_l1_5 = product32_rounded[k][30] | product32_rounded[k][31];

      logic or_l2_0, or_l2_1, or17;
      assign or_l2_0 = or_l1_0 | or_l1_1 | or_l1_2;
      assign or_l2_1 = or_l1_3 | or_l1_4 | or_l1_5;
      assign or17    = or_l2_0 | or_l2_1;

      logic and_l1_0, and_l1_1, and_l1_2, and_l1_3, and_l1_4, and_l1_5;
      assign and_l1_0 = product32_rounded[k][15] & product32_rounded[k][16] &
                        product32_rounded[k][17];
      assign and_l1_1 = product32_rounded[k][18] & product32_rounded[k][19] &
                        product32_rounded[k][20];
      assign and_l1_2 = product32_rounded[k][21] & product32_rounded[k][22] &
                        product32_rounded[k][23];
      assign and_l1_3 = product32_rounded[k][24] & product32_rounded[k][25] &
                        product32_rounded[k][26];
      assign and_l1_4 = product32_rounded[k][27] & product32_rounded[k][28] &
                        product32_rounded[k][29];
      assign and_l1_5 = product32_rounded[k][30] & product32_rounded[k][31];

      logic and_l2_0, and_l2_1, and17;
      assign and_l2_0 = and_l1_0 & and_l1_1 & and_l1_2;
      assign and_l2_1 = and_l1_3 & and_l1_4 & and_l1_5;
      assign and17    = and_l2_0 & and_l2_1;

      logic or16;
      assign or16 = (|product32_rounded[k][31:16]);

      assign up_u32[k] = cout32[k] | or16;
      assign up_s32[k] = (~cout32[k]) & or17;
      assign un_s32[k] = cout32[k] & (~and17);
    end
  endgenerate

  // Direct Clamped Vectors
  logic [15:0][7:0] clamped_byte16;
  generate
    for (k = 0; k < 16; k = k + 1) begin : gen_clamped_vec16
      localparam int ElemIdx = k % 8;
      logic k_active;
      assign k_active = uop_index[0] ? (k >= 8) : (k < 8);

      logic c_u, c_pos, c_neg;
      assign c_u   = is_vnclipu & k_active & up_u16[ElemIdx];
      assign c_pos = is_vnclip  & k_active & up_s16[ElemIdx];
      assign c_neg = is_vnclip  & k_active & un_s16[ElemIdx];

      assign clamped_byte16[k] = c_u   ? 8'hff :
                                 c_pos ? 8'h7f :
                                 c_neg ? 8'h80 : product16_rounded[ElemIdx][7:0];
    end
  endgenerate

  logic [7:0][15:0] clamped_hword32;
  generate
    for (k = 0; k < 8; k = k + 1) begin : gen_clamped_vec32
      localparam int ElemIdx = k % 4;
      logic h_active;
      assign h_active = uop_index[0] ? (k >= 4) : (k < 4);

      logic c_u, c_pos, c_neg;
      assign c_u   = is_vnclipu & h_active & up_u32[ElemIdx];
      assign c_pos = is_vnclip  & h_active & up_s32[ElemIdx];
      assign c_neg = is_vnclip  & h_active & un_s32[ElemIdx];

      assign clamped_hword32[k] = c_u   ? 16'hffff :
                                  c_pos ? 16'h7fff :
                                  c_neg ? 16'h8000 : product32_rounded[ElemIdx][15:0];
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // 6. Result Assembly & Saturation Flag Mapping (Parallel Factored Mux)
  // ---------------------------------------------------------------------------
  logic is_raw_shift;
  logic is_scaling_shift;
  logic is_narrow_raw;
  logic is_clip_inst;

  assign is_raw_shift     = is_vsll | is_vsrl | is_vsra;
  assign is_scaling_shift = is_vssrl | is_vssra;
  assign is_narrow_raw    = is_vnsrl | is_vnsra;
  assign is_clip_inst     = is_vnclipu | is_vnclip;

  logic [63:0] nar8_eew16;
  logic [63:0] nar16_eew32;

  assign nar8_eew16 = {product16_raw[7][7:0], product16_raw[6][7:0],
                       product16_raw[5][7:0], product16_raw[4][7:0],
                       product16_raw[3][7:0], product16_raw[2][7:0],
                       product16_raw[1][7:0], product16_raw[0][7:0]};

  assign nar16_eew32 = {product32_raw[3][15:0], product32_raw[2][15:0],
                        product32_raw[1][15:0], product32_raw[0][15:0]};

  logic [`VLEN-1:0]  raw_vec;
  logic [`VLEN-1:0]  scaling_vec;
  logic [`VLEN-1:0]  narrow_raw_vec;
  logic [`VLEN-1:0]  clamped_vec;
  logic [`VLEN-1:0]  result_data;
  logic [`VLENB-1:0] vsaturate_data;

  always_comb begin
    case (vs2_eew)
      EEW8:    raw_vec = product8_raw;
      EEW16:   raw_vec = product16_raw;
      default: raw_vec = product32_raw;
    endcase
  end

  always_comb begin
    case (vs2_eew)
      EEW8:    scaling_vec = product8_rounded;
      EEW16:   scaling_vec = product16_rounded;
      default: scaling_vec = product32_rounded;
    endcase
  end

  always_comb begin
    case (vs2_eew)
      EEW16:   narrow_raw_vec = uop_index[0] ? {nar8_eew16, 64'b0} : {64'b0, nar8_eew16};
      default: narrow_raw_vec = uop_index[0] ? {nar16_eew32, 64'b0} : {64'b0, nar16_eew32};
    endcase
  end

  assign clamped_vec = (vs2_eew == EEW16) ? clamped_byte16 : clamped_hword32;

  // Factored 3-Term One-Hot Output Multiplexer
  logic [`VLEN-1:0] round_or_clamp_vec;
  assign round_or_clamp_vec = is_clip_inst ? clamped_vec : scaling_vec;

  generate
    for (k = 0; k < `VLEN; k = k + 1) begin : gen_out_mux
      assign result_data[k] = (is_raw_shift  & raw_vec[k]) |
                              (is_narrow_raw & narrow_raw_vec[k]) |
                              ((is_scaling_shift | is_clip_inst) & round_or_clamp_vec[k]);
    end
  endgenerate

  // Saturation flags
  logic [7:0] sat_mask32_u, sat_mask32_s;
  logic [7:0] sat8_s;

  assign sat_mask32_u = {up_u32[3], 1'b0, up_u32[2], 1'b0,
                         up_u32[1], 1'b0, up_u32[0], 1'b0};
  assign sat8_s       = up_s16 | un_s16;
  assign sat_mask32_s = {(up_s32[3]|un_s32[3]), 1'b0, (up_s32[2]|un_s32[2]), 1'b0,
                         (up_s32[1]|un_s32[1]), 1'b0, (up_s32[0]|un_s32[0]), 1'b0};

  logic [`VLENB-1:0] sat_u_vec, sat_s_vec;
  always_comb begin
    case (vs2_eew)
      EEW16:   sat_u_vec = uop_index[0] ? {up_u16, 8'b0} : {8'b0, up_u16};
      default: sat_u_vec = uop_index[0] ? {sat_mask32_u, 8'b0} : {8'b0, sat_mask32_u};
    endcase
  end

  always_comb begin
    case (vs2_eew)
      EEW16:   sat_s_vec = uop_index[0] ? {sat8_s, 8'b0} : {8'b0, sat8_s};
      default: sat_s_vec = uop_index[0] ? {sat_mask32_s, 8'b0} : {8'b0, sat_mask32_s};
    endcase
  end

  assign vsaturate_data = is_vnclipu ? sat_u_vec :
                          is_vnclip  ? sat_s_vec : '0;

  // ---------------------------------------------------------------------------
  // 7. Output Struct Assignment
  // ---------------------------------------------------------------------------
`ifdef TB_SUPPORT
  assign result.uop_pc    = alu_uop.uop_pc;
`endif
  assign result.rob_entry = rob_entry;
  assign result.w_data    = result_data;
  assign result.w_valid   = result_valid;
  assign result.vsaturate = vsaturate_data;
`ifdef ZVE32F_ON
  assign result.fpexp     = '0;
`endif

endmodule

`endif // HDL_VERILOG_RVV_DESIGN_RVV_BACKEND_ALU_SHIFT_DATAPATH_SV
