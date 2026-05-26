// Copyright 2024 Google LLC
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

// A module that assembles RVVInstructions into RVVCmd before storing into the
// RVVInstructionQueue. It's also responsible for handling architectural
// configuration state (ie. LMUL, SEW). Inputs to this module maybe unaligned
// (ie [invalid, valid, valid, invalid]) while outputs will always be aligned
// (ie [valid, valid, invalid, invalid]).
// Arguments from the scalar register file (for vx or configuration
// instructions) arrive one cycle after the Instruction is dispatched, so this
// module introduces one cycle of latency before putting the command into the
// queue.
module RvvFrontEnd#(parameter N = 4,
                    parameter CAPACITYBITS=$clog2(2*N + 1),
                    parameter REDUCE_LMUL = 1)
(
  input clk,
  input rstn,

  input logic [`VSTART_WIDTH-1:0]     vstart_i,
  input logic [`VCSR_VXRM_WIDTH-1:0]  vxrm_i,
  input logic [`VCSR_VXSAT_WIDTH-1:0] vxsat_i,
  input logic [2:0]                   frm_i,

  // Instruction input.
  input logic [N-1:0] inst_valid_i,
  input RVVInstruction [N-1:0] inst_data_i,
  output logic [N-1:0] inst_ready_o,

  // Register file input
  input logic [(2*N)-1:0] reg_read_valid_i,
  input logic [(2*N)-1:0][31:0] reg_read_data_i,

  // Floating point register file input (scalar rs1 for OPFVF instructions).
  input logic [N-1:0][31:0] freg_read_data_i,

  // Scalar Regfile writeback for configuration functions.
  output logic [N-1:0] reg_write_valid_o,
  output logic [N-1:0][4:0] reg_write_addr_o,
  output logic [N-1:0][31:0] reg_write_data_o,

  // Command output.
  output logic [N-1:0] cmd_valid_o,
  output RVVCmd [N-1:0] cmd_data_o,
  input logic [CAPACITYBITS-1:0] queue_capacity_i,  // Number of elements that can be enqueued
  output logic [CAPACITYBITS-1:0] queue_capacity_o,

  // Trap output.
  output logic trap_valid_o,
  output RVVInstruction trap_data_o,

  // Config state
  output config_state_valid,
  output RVVConfigState config_state
);
  localparam COUNTBITS = $clog2(N + 1);
  typedef logic [COUNTBITS-1:0] count_t;

  // vtype architectural state
  logic vill;
  RVVConfigState config_state_q;

  // Instructions to assemble into commands
  logic [N-1:0] valid_inst_q;     // If the instruction in this slot is valid
  count_t valid_inst_count_q;     // The sum of valid_inst_q
  RVVInstruction inst_q [N-1:0];  // The instruction in the slot

  // Backpressure
  count_t valid_in_psum [N:0];
  always_comb begin
    valid_in_psum[0] = 0;
    for (int i = 0; i < N; i++) begin
      valid_in_psum[i+1] = valid_in_psum[i] + inst_valid_i[i];
    end
  end

  // State, for time being lets do not state forwarding for timing
  logic config_state_reduction;
  always_comb begin
    config_state_reduction = 1;
    for (int i = 0; i < N; i++) begin
      config_state_reduction = config_state_reduction & (!valid_inst_q[i]);
    end
  end
  assign config_state_valid = config_state_reduction;
  assign config_state = config_state_q;

  logic [CAPACITYBITS-1:0] queue_capacity;
  assign queue_capacity_o = queue_capacity;
  always_comb begin
    queue_capacity = queue_capacity_i - valid_inst_count_q;
  end

  logic inst_accepted [N-1:0];
  count_t valid_inst_count_d;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      inst_accepted[i] = (valid_in_psum[i] < queue_capacity) && inst_valid_i[i];
      inst_ready_o[i] = inst_accepted[i];
    end
    valid_inst_count_d = (valid_in_psum[N] < queue_capacity) ?
        valid_in_psum[N] : queue_capacity;
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      for (int i = 0; i < N; i++) begin
        valid_inst_q[i] <= 0;
        valid_inst_count_q <= 0;
      end;
    end else begin
      for (int i = 0; i < N; i++) begin
        valid_inst_q[i] <= inst_accepted[i];
        valid_inst_count_q <= valid_inst_count_d;
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < N; i++) begin
      inst_q[i] <= inst_data_i[i];
    end
  end

  // Update configuration architectural state
  RVVConfigState inst_config_state [N:0];
  logic [31:0] avl [N-1:0];
  logic [31:0] vlmax [N-1:0];
  logic is_setvl [N-1:0];
  logic [`VL_WIDTH-1:0] vl_minus_one [N-1:0];
  always_comb begin
    inst_config_state[0] = config_state_q;
    inst_config_state[0].vstart = vstart_i;
    inst_config_state[0].xrm = RVVXRM'(vxrm_i);
    inst_config_state[0].xsat = vxsat_i;
`ifdef ZVE32F_ON
    inst_config_state[0].frm = RVFRM'(frm_i);
`endif  // ZVE32F_ON
    for (int i = 0; i < N; i++) begin
      inst_config_state[i+1] = inst_config_state[i];
      avl[i] = 0;
      vlmax[i] = 0;
      is_setvl[i] = 0;

      if (valid_inst_q[i] &&
          (inst_q[i].opcode == RVV) &&
          (inst_q[i].bits[7:5] == 3'b111)) begin
        if (inst_q[i].bits[24] == 0) begin  // vsetvli
          // Set AVL based on encoding (see Section 6.2 of RVV spec)
          unique case (inst_q[i].bits[12:8])
            0: unique case (inst_q[i].bits[4:0])
              0:  avl[i] = inst_config_state[i].vl;  // rd = x0, rs1 = x0
              default: avl[i] = 32'hFFFFFFFF;        // rd != x0, rs1 = x0
            endcase
            default: avl[i] = reg_read_data_i[2*i];  // rs1 != x0
          endcase

          inst_config_state[i+1].lmul_orig = RVVLMUL'(inst_q[i].bits[15:13]);
          inst_config_state[i+1].sew = RVVSEW'(inst_q[i].bits[18:16]);
          inst_config_state[i+1].ta = inst_q[i].bits[19];
          inst_config_state[i+1].ma = inst_q[i].bits[20];
          is_setvl[i] = 1;
        end else if (inst_q[i].bits[24:23] == 2'b11) begin  // vsetivli
          avl[i] =
              {{(`VL_WIDTH - 5){1'b0}}, inst_q[i].bits[12:8]};
          inst_config_state[i+1].lmul_orig = RVVLMUL'(inst_q[i].bits[15:13]);
          inst_config_state[i+1].sew = RVVSEW'(inst_q[i].bits[18:16]);
          inst_config_state[i+1].ta = inst_q[i].bits[19];
          inst_config_state[i+1].ma = inst_q[i].bits[20];
          is_setvl[i] = 1;
        end else if (inst_q[i].bits[24:23] == 2'b10) begin  // vsetvl
          // Set AVL based on encoding (see Section 6.2 of RVV spec)
          unique case (inst_q[i].bits[12:8])
            0: unique case (inst_q[i].bits[4:0])
              0:  avl[i] = inst_config_state[i].vl;  // rd = x0, rs1 = x0
              default: avl[i] = 32'hFFFFFFFF;        // rd != x0, rs1 = x0
            endcase
            default: avl[i] = reg_read_data_i[2*i];  // rs1 != x0
          endcase
          inst_config_state[i+1].lmul_orig =
              RVVLMUL'(reg_read_data_i[(2*i) + 1][2:0]);
          inst_config_state[i+1].sew =
              RVVSEW'(reg_read_data_i[(2*i) + 1][5:3]);
          inst_config_state[i+1].ta = reg_read_data_i[(2*i) + 1][6];
          inst_config_state[i+1].ma = reg_read_data_i[(2*i) + 1][7];
          is_setvl[i] = 1;
        end
      end

      if (is_setvl[i]) begin
        // Compute legality of vtype.
        unique case (inst_config_state[i+1].sew)
          SEW8:
            unique case(inst_config_state[i+1].lmul_orig)
              LMULRESERVED: inst_config_state[i+1].vill = 1;
              LMUL1_8: inst_config_state[i+1].vill = 1;
              default: inst_config_state[i+1].vill = 0;
            endcase
          SEW16:
            unique case(inst_config_state[i+1].lmul_orig)
              LMULRESERVED: inst_config_state[i+1].vill = 1;
              LMUL1_8: inst_config_state[i+1].vill = 1;
              LMUL1_4: inst_config_state[i+1].vill = 1;
              default: inst_config_state[i+1].vill = 0;
            endcase
          SEW32:
            unique case(inst_config_state[i+1].lmul_orig)
              LMULRESERVED: inst_config_state[i+1].vill = 1;
              LMUL1_8: inst_config_state[i+1].vill = 1;
              LMUL1_4: inst_config_state[i+1].vill = 1;
              LMUL1_2: inst_config_state[i+1].vill = 1;
              default: inst_config_state[i+1].vill = 0;
            endcase
          default: inst_config_state[i+1].vill = 1;
        endcase

        // Compute vl to set (saturating with necessary)
        unique case (inst_config_state[i+1].lmul_orig)
          LMUL1_8: vlmax[i] = ((`VLENB)/8) >> inst_config_state[i+1].sew;
          LMUL1_4: vlmax[i] = ((`VLENB)/4) >> inst_config_state[i+1].sew;
          LMUL1_2: vlmax[i] = ((`VLENB)/2) >> inst_config_state[i+1].sew;
          LMUL1: vlmax[i] = (`VLENB) >> inst_config_state[i+1].sew;
          LMUL2: vlmax[i] = (2*(`VLENB)) >> inst_config_state[i+1].sew;
          LMUL4: vlmax[i] = (4*(`VLENB)) >> inst_config_state[i+1].sew;
          LMUL8: vlmax[i] = (8*(`VLENB)) >> inst_config_state[i+1].sew;
          default: vlmax[i] = 0;
        endcase

        if (inst_config_state[i+1].vill) begin
          // If illegal, set to 0. See end of section 6.1 of RVV spec.
          inst_config_state[i+1].vl = 0;
        end else if (avl[i] > vlmax[i]) begin
          // One possible valid impl according to 6.3 of RVV spec.
          inst_config_state[i+1].vl = vlmax[i];
        end else begin
          inst_config_state[i+1].vl = avl[i];
        end

        inst_config_state[i+1].lmul = inst_config_state[i+1].lmul_orig;

        // TODO: filter out illegal lmul for widening ALU ops and non-indexed
        // LSU ops where eew>sew.
        if (REDUCE_LMUL) begin
          // We use vl here, it's guaranteed to be <= vlmax. This operation
          // should either reduce lmul or keep it untouched.
          // We don't need to worry about eew&emul here:
          // - the current sew&lmul is valid (does not lead to emul>8) and
          //   we don't increase it, so we cannot generate emul>8.
          // - we must keep lmul valid for the current sew, like lmul>=m1 for
          //   sew=e32. The resulting enul must also be valid.
          vl_minus_one[i] = (inst_config_state[i+1].vl == (`VL_WIDTH)'('b0)) ?
              (`VL_WIDTH)'('b0) :
              inst_config_state[i+1].vl - (`VL_WIDTH)'('b1);
          unique case (inst_config_state[i+1].sew)
            SEW8: begin
              if (vl_minus_one[i][`VL_WIDTH-2+:2] != 'b00) begin
                // vl from VLEN/2+1 to VLEN
                inst_config_state[i+1].lmul = LMUL8;
              end else if (vl_minus_one[i][`VL_WIDTH-3] == 'b1) begin
                // vl from VLEN/4+1 to VLEN/2
                inst_config_state[i+1].lmul = LMUL4;
              end else if (vl_minus_one[i][`VL_WIDTH-4] == 'b1) begin
                // vl from VLEN/8+1 to VLEN/4
                inst_config_state[i+1].lmul = LMUL2;
              end else if (vl_minus_one[i][`VL_WIDTH-5] == 'b1) begin
                // vl from VLEN/16+1 to VLEN/8
                inst_config_state[i+1].lmul = LMUL1;
              end else if (vl_minus_one[i][`VL_WIDTH-6] == 'b1) begin
                // vl from VLEN/32+1 to VLEN/16
                inst_config_state[i+1].lmul = LMUL1_2;
              end else begin
                // vl from 0 to VLEN/32
                inst_config_state[i+1].lmul = LMUL1_4;
              end
            end
            SEW16: begin
              if (vl_minus_one[i][`VL_WIDTH-3+:2] != 'b00) begin
                // vl from VLEN/4+1 to VLEN/2
                inst_config_state[i+1].lmul = LMUL8;
              end else if (vl_minus_one[i][`VL_WIDTH-4] == 'b1) begin
                // vl from VLEN/8+1 to VLEN/4
                inst_config_state[i+1].lmul = LMUL4;
              end else if (vl_minus_one[i][`VL_WIDTH-5] == 'b1) begin
                // vl from VLEN/16+1 to VLEN/8
                inst_config_state[i+1].lmul = LMUL2;
              end else if (vl_minus_one[i][`VL_WIDTH-6] == 'b1) begin
                // vl from VLEN/32+1 to VLEN/16
                inst_config_state[i+1].lmul = LMUL1;
              end else begin
                // vl from 0 to VLEN/32
                inst_config_state[i+1].lmul = LMUL1_2;
              end
            end
            SEW32: begin
              if (vl_minus_one[i][`VL_WIDTH-4+:2] != 'b00) begin
                // vl from VLEN/8+1 to VLEN/4
                inst_config_state[i+1].lmul = LMUL8;
              end else if (vl_minus_one[i][`VL_WIDTH-5] == 'b1) begin
                // vl from VLEN/16+1 to VLEN/8
                inst_config_state[i+1].lmul = LMUL4;
              end else if (vl_minus_one[i][`VL_WIDTH-6] == 'b1) begin
                // vl from VLEN/32+1 to VLEN/16
                inst_config_state[i+1].lmul = LMUL2;
              end else begin
                // vl from 0 to VLEN/32
                inst_config_state[i+1].lmul = LMUL1;
              end
            end
          endcase
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      // Per Section 3.11 of RVV spec, the recommended state on reset is
      // vill is set, with the remain vtype bits and vl being set to 0.
      config_state_q.vill <= 1;
      config_state_q.vl <= 0;
      config_state_q.vstart <= 0;
      config_state_q.ma <= 0;
      config_state_q.ta <= 0;
      config_state_q.xrm <= RNU;
      config_state_q.xsat <= 0;
`ifdef ZVE32F_ON
      config_state_q.frm <= RVFRM'('0);
`endif
  // ZVE32F_ON
      config_state_q.sew <= SEW8;
      config_state_q.lmul <= LMUL1;
    end else begin
      // Update config state next cycle
      config_state_q <= inst_config_state[N];
    end
  end

  // Propagate outputs
  logic [N-1:0] unaligned_cmd_valid;
  RVVCmd [N-1:0] unaligned_cmd_data;
  logic [N-1:0] unaligned_trap_valid;  // Should this instruction trap
  RVVInstruction [N-1:0] unaligned_trap_data;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      unaligned_trap_valid[i] = valid_inst_q[i] && !is_setvl[i] &&
          inst_config_state[i+1].vill;
      unaligned_trap_data[i] = inst_q[i];
      unaligned_cmd_valid[i] = valid_inst_q[i] && !is_setvl[i] &&
          !inst_config_state[i+1].vill;

      // Combine instruction + arch state into command
`ifdef TB_SUPPORT
      unaligned_cmd_data[i].inst_pc = inst_q[i].pc;
`endif
      unaligned_cmd_data[i].opcode = inst_q[i].opcode;
      unaligned_cmd_data[i].bits = inst_q[i].bits;
      unaligned_cmd_data[i].arch_state = inst_config_state[i+1];
      // TODO: Handle rs propagation for loads/stores
      // funct3 == inst[14:12] == bits[7:5]; bits[7] == funct3[2] indicates
      // scalar rs1 is used (OPIVX, OPFVF, OPMVX, OPCFG). For OPFVF the scalar
      // comes from the floating-point regfile.
      unaligned_cmd_data[i].rs1 =
          inst_q[i].bits[7] ?
              ((inst_q[i].bits[7:5] == 3'b101) ? freg_read_data_i[i]  // OPFVF
                                               : reg_read_data_i[2*i])
            : 0;

      // Write new value of vl into rd for configuration function.
      reg_write_valid_o[i] = is_setvl[i];
      reg_write_addr_o[i] = inst_q[i].bits[4:0];
      reg_write_data_o[i] =
          {{(`XLEN-`VL_WIDTH){1'b0}}, inst_config_state[i+1].vl};
    end
  end

  // Align outputs
  Aligner#(.T(RVVCmd), .N(N)) cmd_aligner(
      .valid_in(unaligned_cmd_valid),
      .data_in(unaligned_cmd_data),
      .valid_out(cmd_valid_o),
      .data_out(cmd_data_o)
  );

  // Trap
  logic trap_occurred;
  RVVInstruction trap_data;
  assign trap_valid_o = trap_occurred;
  assign trap_data_o = trap_data;
  always_comb begin
    trap_occurred = (unaligned_trap_valid != 0);
    // Initialize all trap_data fields to some zero value
    trap_data.pc = '0;
    trap_data.bits = '0;
    trap_data.opcode = RVV;

    for (int i = 0; i < N; i++) begin
      if (unaligned_trap_valid[i]) begin
        trap_occurred = 1'b1;
        trap_data = unaligned_trap_data[i];
        break;
      end
    end
  end

  // Assertions
`ifndef SYNTHESIS
  logic [N-1:0] lsu_requires_rs1_read;
  logic [N-1:0] non_lsu_requires_rs1_read;
  logic [N-1:0] requires_rs1_read;
  logic [N-1:0] lsu_requires_rs2_read;
  logic [N-1:0] non_lsu_requires_rs2_read;
  logic [N-1:0] requires_rs2_read;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      // All LSU instructions read from rs1
      lsu_requires_rs1_read[i] = (inst_q[i].opcode != RVV);
      // Non LSU rs1 check
      non_lsu_requires_rs1_read[i] = (inst_q[i].opcode == RVV) && (
        (inst_q[i].bits[7:5] == 'b100) ||  // OPIVX
        (inst_q[i].bits[7:5] == 'b110) ||  // OPMVX
        ((inst_q[i].bits[7:5] == 'b111) && (inst_q[i].bits[24:23] != 2'b11))  // vsetvl and vsetvli
      );
      requires_rs1_read[i] =
          lsu_requires_rs1_read[i] || non_lsu_requires_rs1_read[i];

      // Only strided loads/stores (mop=0b10) read rs2
      lsu_requires_rs2_read[i] = (inst_q[i].opcode != RVV) &&
          (inst_q[i].bits[20:19] == 2'b10);
      // vsetvl is only non LSU instruction that reads rs2
      non_lsu_requires_rs2_read[i] = (inst_q[i].opcode == RVV) &&
          (inst_q[i].bits[7:5] == 3'b111) &&
          (inst_q[i].bits[24:18] == 7'b1000000);
      requires_rs2_read[i] =
          lsu_requires_rs2_read[i] || non_lsu_requires_rs2_read[i];
    end
  end

  always @(posedge clk) begin
    for (int i = 0; i < N; i++) begin
      assert(!valid_inst_q[i] || !requires_rs1_read[i] ||
              reg_read_valid_i[2*i]);
      assert(!valid_inst_q[i] || !requires_rs2_read[i] ||
              reg_read_valid_i[(2*i) + 1]);
    end
  end
`endif  // not def SYNTHESIS
endmodule
