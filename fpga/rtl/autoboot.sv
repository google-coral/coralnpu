// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

module autoboot
  import tlul_pkg::*;
  import coralnpu_tlul_pkg_32::*;
#(
    parameter logic [31:0] CsrBaseAddr = 32'h00030000
) (
    input clk_i,
    input rst_ni,

    // TileLink-UL Interface (Host)
    output coralnpu_tlul_pkg_32::tl_h2d_t tl_o,
    input  coralnpu_tlul_pkg_32::tl_d2h_t tl_i
);

  // SECDED Functions for Integrity (copied from i2c_master_pkg to break dependencies)
  function automatic logic [6:0] secded_inv_39_32_enc(logic [31:0] data);
    logic [6:0] ecc;
    ecc[0] = ^(data & 32'h2606BD25);
    ecc[1] = ^(data & 32'hDEBA8050);
    ecc[2] = ^(data & 32'h413D89AA);
    ecc[3] = ^(data & 32'h31234ED1);
    ecc[4] = ^(data & 32'hC2C1323B);
    ecc[5] = ^(data & 32'h2DCC624C);
    ecc[6] = ^(data & 32'h98505586);
    return ecc ^ 7'h2A;
  endfunction

  function automatic logic [6:0] secded_inv_64_57_enc(logic [56:0] data);
    logic [6:0] ecc;
    ecc[0] = ^(data & 57'h0103FFF800007FFF);
    ecc[1] = ^(data & 57'h017C1FF801FF801F);
    ecc[2] = ^(data & 57'h01BDE1F87E0781E1);
    ecc[3] = ^(data & 57'h01DEEE3B8E388E22);
    ecc[4] = ^(data & 57'h01EF76CDB2C93244);
    ecc[5] = ^(data & 57'h01F7BB56D5525488);
    ecc[6] = ^(data & 57'h01FBDDA769A46910);
    return ecc ^ 7'h2a;
  endfunction

  typedef enum logic [2:0] {
    Idle,
    WriteClkGate,
    WaitClkGateAck,
    WriteReset,
    WaitResetAck,
    Done
  } state_e;

  state_e state_q, state_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle;
    end else begin
      state_q <= state_d;
    end
  end

  logic a_valid;
  tl_a_op_e a_opcode;
  logic [31:0] a_addr;
  logic [31:0] a_data;

  always_comb begin
    state_d  = state_q;
    a_valid  = 1'b0;
    a_opcode = PutFullData;
    a_addr   = CsrBaseAddr;
    a_data   = 32'h0;

    unique case (state_q)
      Idle: begin
        state_d = WriteClkGate;
      end

      WriteClkGate: begin
        a_valid  = 1'b1;
        a_opcode = PutFullData;
        a_addr   = CsrBaseAddr;
        a_data   = 32'h1;  // Release clock gate (bit 1=0, bit 0=1)
        if (tl_i.a_ready) begin
          state_d = WaitClkGateAck;
        end
      end

      WaitClkGateAck: begin
        if (tl_i.d_valid) begin
          state_d = WriteReset;
        end
      end

      WriteReset: begin
        a_valid  = 1'b1;
        a_opcode = PutFullData;
        a_addr   = CsrBaseAddr;
        a_data   = 32'h0;  // Release reset (bit 1=0, bit 0=0)
        if (tl_i.a_ready) begin
          state_d = WaitResetAck;
        end
      end

      WaitResetAck: begin
        if (tl_i.d_valid) begin
          state_d = Done;
        end
      end

      Done: begin
        state_d = Done;
      end

      default: state_d = Idle;
    endcase
  end

  // --- Integrity Generation (A Channel) ---
  logic [ 6:0] gen_cmd_intg;
  logic [ 6:0] gen_data_intg;

  // cmd_data = {rsvd, instr_type, address, opcode, mask}
  // rsvd (14 bits), instr_type (4 bits), address (32 bits), opcode (3 bits), mask (4 bits) = 57 bits total.
  logic [56:0] cmd_data_raw;
  assign cmd_data_raw = {14'h0, prim_mubi_pkg::MuBi4False, a_addr, a_opcode, 4'hF};

  assign gen_cmd_intg = secded_inv_64_57_enc(cmd_data_raw);
  assign gen_data_intg = secded_inv_39_32_enc(a_data);

  assign tl_o.a_valid = a_valid;
  assign tl_o.a_opcode = a_opcode;
  assign tl_o.a_param = 3'h0;
  assign tl_o.a_size = 2'h2;  // 4 bytes
  assign tl_o.a_source = 8'h0;
  assign tl_o.a_address = a_addr;
  assign tl_o.a_mask = 4'hF;
  assign tl_o.a_data = a_data;
  assign tl_o.a_user.rsvd = '0;
  assign tl_o.a_user.instr_type = prim_mubi_pkg::MuBi4False;
  assign tl_o.a_user.cmd_intg = gen_cmd_intg;
  assign tl_o.a_user.data_intg = gen_data_intg;
  assign tl_o.d_ready = 1'b1;

endmodule
