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

`ifndef HDL_VERILOG_RVV_COMMON_BARREL_SHIFTER_TREE_SV
`define HDL_VERILOG_RVV_COMMON_BARREL_SHIFTER_TREE_SV

(* keep_hierarchy = "yes" *)
module barrel_shifter_tree #(
  parameter int DATA_WIDTH = 32
) (
  input  logic [DATA_WIDTH-1:0]          din,
  input  logic [$clog2(DATA_WIDTH)-1:0]  shift_amount,
  input  logic [1:0]                     shift_mode,
  output logic [DATA_WIDTH-1:0]          dout
);
  localparam int ShiftWidth           = $clog2(DATA_WIDTH);
  localparam logic [1:0] ShiftSll     = 2'b00;
  localparam logic [1:0] ShiftSrl     = 2'b01;
  localparam logic [1:0] ShiftSra     = 2'b10;

  logic fill_bit;
  assign fill_bit = (shift_mode == ShiftSra) ? din[DATA_WIDTH-1] : 1'b0;

  generate
    if (DATA_WIDTH == 64) begin : gen_w64
      logic [63:0] r_stg0, r_stg1, r_stg2;
      logic [63:0] l_stg0, l_stg1, l_stg2;

      // Radix-4 Stage 0: Shift by 0, 1, 2, 3
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: r_stg0 = din;
          2'd1: r_stg0 = {{1{fill_bit}}, din[63:1]};
          2'd2: r_stg0 = {{2{fill_bit}}, din[63:2]};
          2'd3: r_stg0 = {{3{fill_bit}}, din[63:3]};
          default: r_stg0 = din;
        endcase
      end

      // Radix-4 Stage 1: Shift by 0, 4, 8, 12
      always_comb begin
        unique case (shift_amount[3:2])
          2'd0: r_stg1 = r_stg0;
          2'd1: r_stg1 = {{4{fill_bit}}, r_stg0[63:4]};
          2'd2: r_stg1 = {{8{fill_bit}}, r_stg0[63:8]};
          2'd3: r_stg1 = {{12{fill_bit}}, r_stg0[63:12]};
          default: r_stg1 = r_stg0;
        endcase
      end

      // Radix-4 Stage 2: Shift by 0, 16, 32, 48
      always_comb begin
        unique case (shift_amount[5:4])
          2'd0: r_stg2 = r_stg1;
          2'd1: r_stg2 = {{16{fill_bit}}, r_stg1[63:16]};
          2'd2: r_stg2 = {{32{fill_bit}}, r_stg1[63:32]};
          2'd3: r_stg2 = {{48{fill_bit}}, r_stg1[63:48]};
          default: r_stg2 = r_stg1;
        endcase
      end

      // Left shift: Stage 0 (0, 1, 2, 3)
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: l_stg0 = din;
          2'd1: l_stg0 = {din[62:0], 1'b0};
          2'd2: l_stg0 = {din[61:0], 2'b0};
          2'd3: l_stg0 = {din[60:0], 3'b0};
          default: l_stg0 = din;
        endcase
      end

      // Left shift: Stage 1 (0, 4, 8, 12)
      always_comb begin
        unique case (shift_amount[3:2])
          2'd0: l_stg1 = l_stg0;
          2'd1: l_stg1 = {l_stg0[59:0], 4'b0};
          2'd2: l_stg1 = {l_stg0[55:0], 8'b0};
          2'd3: l_stg1 = {l_stg0[51:0], 12'b0};
          default: l_stg1 = l_stg0;
        endcase
      end

      // Left shift: Stage 2 (0, 16, 32, 48)
      always_comb begin
        unique case (shift_amount[5:4])
          2'd0: l_stg2 = l_stg1;
          2'd1: l_stg2 = {l_stg1[47:0], 16'b0};
          2'd2: l_stg2 = {l_stg1[31:0], 32'b0};
          2'd3: l_stg2 = {l_stg1[15:0], 48'b0};
          default: l_stg2 = l_stg1;
        endcase
      end

      assign dout = (shift_mode == ShiftSll) ? l_stg2 : r_stg2;

    end else if (DATA_WIDTH == 32) begin : gen_w32
      logic [31:0] r_stg0, r_stg1, r_stg2;
      logic [31:0] l_stg0, l_stg1, l_stg2;

      // Radix-4 Stage 0: Shift by 0, 1, 2, 3
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: r_stg0 = din;
          2'd1: r_stg0 = {{1{fill_bit}}, din[31:1]};
          2'd2: r_stg0 = {{2{fill_bit}}, din[31:2]};
          2'd3: r_stg0 = {{3{fill_bit}}, din[31:3]};
          default: r_stg0 = din;
        endcase
      end

      // Radix-4 Stage 1: Shift by 0, 4, 8, 12
      always_comb begin
        unique case (shift_amount[3:2])
          2'd0: r_stg1 = r_stg0;
          2'd1: r_stg1 = {{4{fill_bit}}, r_stg0[31:4]};
          2'd2: r_stg1 = {{8{fill_bit}}, r_stg0[31:8]};
          2'd3: r_stg1 = {{12{fill_bit}}, r_stg0[31:12]};
          default: r_stg1 = r_stg0;
        endcase
      end

      // Radix-2 Stage 2: Shift by 0, 16
      always_comb begin
        if (shift_amount[4]) begin
          r_stg2 = {{16{fill_bit}}, r_stg1[31:16]};
        end else begin
          r_stg2 = r_stg1;
        end
      end

      // Left shift: Stage 0 (0, 1, 2, 3)
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: l_stg0 = din;
          2'd1: l_stg0 = {din[30:0], 1'b0};
          2'd2: l_stg0 = {din[29:0], 2'b0};
          2'd3: l_stg0 = {din[28:0], 3'b0};
          default: l_stg0 = din;
        endcase
      end

      // Left shift: Stage 1 (0, 4, 8, 12)
      always_comb begin
        unique case (shift_amount[3:2])
          2'd0: l_stg1 = l_stg0;
          2'd1: l_stg1 = {l_stg0[27:0], 4'b0};
          2'd2: l_stg1 = {l_stg0[23:0], 8'b0};
          2'd3: l_stg1 = {l_stg0[19:0], 12'b0};
          default: l_stg1 = l_stg0;
        endcase
      end

      // Left shift: Stage 2 (0, 16)
      always_comb begin
        if (shift_amount[4]) begin
          l_stg2 = {l_stg1[15:0], 16'b0};
        end else begin
          l_stg2 = l_stg1;
        end
      end

      assign dout = (shift_mode == ShiftSll) ? l_stg2 : r_stg2;

    end else if (DATA_WIDTH == 16) begin : gen_w16
      logic [15:0] r_stg0, r_stg1;
      logic [15:0] l_stg0, l_stg1;

      // Radix-4 Stage 0: Shift by 0, 1, 2, 3
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: r_stg0 = din;
          2'd1: r_stg0 = {{1{fill_bit}}, din[15:1]};
          2'd2: r_stg0 = {{2{fill_bit}}, din[15:2]};
          2'd3: r_stg0 = {{3{fill_bit}}, din[15:3]};
          default: r_stg0 = din;
        endcase
      end

      // Radix-4 Stage 1: Shift by 0, 4, 8, 12
      always_comb begin
        unique case (shift_amount[3:2])
          2'd0: r_stg1 = r_stg0;
          2'd1: r_stg1 = {{4{fill_bit}}, r_stg0[15:4]};
          2'd2: r_stg1 = {{8{fill_bit}}, r_stg0[15:8]};
          2'd3: r_stg1 = {{12{fill_bit}}, r_stg0[15:12]};
          default: r_stg1 = r_stg0;
        endcase
      end

      // Left shift: Stage 0 (0, 1, 2, 3)
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: l_stg0 = din;
          2'd1: l_stg0 = {din[14:0], 1'b0};
          2'd2: l_stg0 = {din[13:0], 2'b0};
          2'd3: l_stg0 = {din[12:0], 3'b0};
          default: l_stg0 = din;
        endcase
      end

      // Left shift: Stage 1 (0, 4, 8, 12)
      always_comb begin
        unique case (shift_amount[3:2])
          2'd0: l_stg1 = l_stg0;
          2'd1: l_stg1 = {l_stg0[11:0], 4'b0};
          2'd2: l_stg1 = {l_stg0[7:0], 8'b0};
          2'd3: l_stg1 = {l_stg0[3:0], 12'b0};
          default: l_stg1 = l_stg0;
        endcase
      end

      assign dout = (shift_mode == ShiftSll) ? l_stg1 : r_stg1;

    end else if (DATA_WIDTH == 8) begin : gen_w8
      logic [7:0] r_stg0, r_stg1;
      logic [7:0] l_stg0, l_stg1;

      // Radix-4 Stage 0: Shift by 0, 1, 2, 3
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: r_stg0 = din;
          2'd1: r_stg0 = {{1{fill_bit}}, din[7:1]};
          2'd2: r_stg0 = {{2{fill_bit}}, din[7:2]};
          2'd3: r_stg0 = {{3{fill_bit}}, din[7:3]};
          default: r_stg0 = din;
        endcase
      end

      // Radix-2 Stage 1: Shift by 0, 4
      always_comb begin
        if (shift_amount[2]) begin
          r_stg1 = {{4{fill_bit}}, r_stg0[7:4]};
        end else begin
          r_stg1 = r_stg0;
        end
      end

      // Left shift: Stage 0 (0, 1, 2, 3)
      always_comb begin
        unique case (shift_amount[1:0])
          2'd0: l_stg0 = din;
          2'd1: l_stg0 = {din[6:0], 1'b0};
          2'd2: l_stg0 = {din[5:0], 2'b0};
          2'd3: l_stg0 = {din[4:0], 3'b0};
          default: l_stg0 = din;
        endcase
      end

      // Left shift: Stage 1 (0, 4)
      always_comb begin
        if (shift_amount[2]) begin
          l_stg1 = {l_stg0[3:0], 4'b0};
        end else begin
          l_stg1 = l_stg0;
        end
      end

      assign dout = (shift_mode == ShiftSll) ? l_stg1 : r_stg1;

    end else begin : gen_default
      // Fallback for non-standard bitwidths
      logic [ShiftWidth:0][DATA_WIDTH-1:0] stage;
      assign stage[0] = din;
      assign dout     = stage[ShiftWidth];
      for (genvar j = 0; j < ShiftWidth; j = j + 1) begin : gen_shift_stages
        localparam int ShiftAmount = 1 << j;
        assign stage[j+1] = ~shift_amount[j] ? stage[j] :
                            (shift_mode == ShiftSll) ?
                                {stage[j][DATA_WIDTH-1-ShiftAmount:0], {ShiftAmount{1'b0}}} :
                            (shift_mode == ShiftSrl) ?
                                {{ShiftAmount{1'b0}}, stage[j][DATA_WIDTH-1:ShiftAmount]} :
                            (shift_mode == ShiftSra) ?
                                {{ShiftAmount{stage[j][DATA_WIDTH-1]}},
                                 stage[j][DATA_WIDTH-1:ShiftAmount]} :
                            stage[j];
      end
    end
  endgenerate

endmodule

`endif // HDL_VERILOG_RVV_COMMON_BARREL_SHIFTER_TREE_SV
