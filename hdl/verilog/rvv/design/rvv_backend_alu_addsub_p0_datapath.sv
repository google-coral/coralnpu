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
`ifndef ALU_DEFINE_SVH
`include "rvv_backend_alu.svh"
`endif

(* keep_hierarchy = "yes" *)
module rvv_backend_alu_addsub_p0_datapath (
  input  logic        is_sub,
  input  logic [31:0] src2_data,
  input  logic [31:0] src1_data,
  input  logic [3:0]  cin,

  // P0 stage outputs
  output logic [31:0] product8_out,
  output logic [3:0]  cout8_out
);

`ifdef CORALNPU_STRUCTURAL_DATAPATH
  // ---------------------------------------------------------------------------
  // Structural OpenROAD Flow: SIMD Parallel-Prefix Adder (P0 Stage)
  // Logic Depth: 10-12 Gate Levels
  // ---------------------------------------------------------------------------
  logic [31:0] p0_sum;
  logic [3:0]  p0_cout;

  prefix_adder_han_carlson_simd32 u_p0_adder (
    .a      (src2_data),
    .b      (src1_data),
    .cin    (cin),
    .eew    (2'b00), // EEW8
    .is_sub (is_sub),
    .sum    (p0_sum),
    .cout   (p0_cout)
  );

  assign product8_out = p0_sum;
  assign cout8_out    = is_sub ? ~p0_cout : p0_cout;

`else
  // ---------------------------------------------------------------------------
  // Default Behavioral Reference Flow (Default Verilog Invariance)
  // Multi-target general flow: FPGA DSP mapping, Synopsys DesignWare, Fast Sim
  // ---------------------------------------------------------------------------

  // P0 byte slice additions/subtractions
  always_comb begin
    for (int i = 0; i < 4; i = i + 1) begin
      if (!is_sub) begin
        {cout8_out[i], product8_out[8*i +: 8]} =
            9'(src2_data[8*i +: 8]) + 9'(src1_data[8*i +: 8]) + 9'(cin[i]);
      end else begin
        {cout8_out[i], product8_out[8*i +: 8]} =
            9'(src2_data[8*i +: 8]) - 9'(src1_data[8*i +: 8]) - 9'(cin[i]);
      end
    end
  end

`endif

endmodule
