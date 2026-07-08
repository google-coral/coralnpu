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
      inst_q[i] <= inst_accepted[i] ? inst_data_i[i] : inst_q[i];
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

        // Encoding validation (above) now filters illegal EMUL for
        // widening ALU ops and non-indexed LSU ops where eew>sew.
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
              end else if (vl_minus_one[i][`VL_WIDTH-7] == 'b1) begin
                // vl from VLEN/64+1 to VLEN/32
                inst_config_state[i+1].lmul = LMUL1_2;
              end else begin
                // vl from 0 to VLEN/64
                inst_config_state[i+1].lmul = LMUL1_4;
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
              end else if (vl_minus_one[i][`VL_WIDTH-7] == 'b1) begin
                // vl from VLEN/64+1 to VLEN/32
                inst_config_state[i+1].lmul = LMUL1;
              end else if (vl_minus_one[i][`VL_WIDTH-8] == 'b1) begin
                // vl from VLEN/128+1 to VLEN/64
                inst_config_state[i+1].lmul = LMUL1_2;
              end else begin
                // vl from 0 to VLEN/128
                inst_config_state[i+1].lmul = LMUL1_4;
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
`endif  // ZVE32F_ON
      config_state_q.sew <= SEW8;
      config_state_q.lmul <= LMUL1;
      config_state_q.lmul_orig <= LMUL1;
    end else begin
      // Update config state next cycle
      config_state_q <= inst_config_state[N];
    end
  end

  // ====================================================================
  // Encoding validation: reject illegal instructions before they reach
  // the backend (which would silently discard them, causing a hang).
  // This replicates the backend's inst_encoding_correct check using only
  // instruction bits + vtype state, both available here.
  // ====================================================================

  // LSU width-field encoding (funct3 for load/store EEW)
  localparam logic [2:0] LSU_EEW_8  = 3'b000;
  localparam logic [2:0] LSU_EEW_16 = 3'b101;
  localparam logic [2:0] LSU_EEW_32 = 3'b110;

  // Compute EMUL from LMUL and a signed ratio (log2(EEW/SEW)).
  // ratio: 0=1x, +1=2x, +2=4x, -1=half, -2=quarter.
  // Returns EMUL_NONE on overflow (EMUL > 8).
  function automatic EMUL_e compute_emul(RVVLMUL lmul, logic signed [2:0] ratio);
    logic signed [3:0] lmul_log2;
    logic signed [3:0] emul_log2;
    case (lmul)
      LMUL1:   lmul_log2 = 0;
      LMUL2:   lmul_log2 = 1;
      LMUL4:   lmul_log2 = 2;
      LMUL8:   lmul_log2 = 3;
      LMUL1_2: lmul_log2 = -1;
      LMUL1_4: lmul_log2 = -2;
      LMUL1_8: lmul_log2 = -3;
      default: return EMUL_NONE;
    endcase
    emul_log2 = lmul_log2 + {{1{ratio[2]}}, ratio};
    if (emul_log2 > 3) return EMUL_NONE;
    if (emul_log2 <= 0) return EMUL1;
    case (emul_log2[1:0])
      2'd1: return EMUL2;
      2'd2: return EMUL4;
      2'd3: return EMUL8;
      default: return EMUL1;
    endcase
  endfunction

  // Check register alignment to EMUL group
  function automatic logic check_align(logic [4:0] reg_idx, EMUL_e emul);
    case (emul)
      EMUL_NONE, EMUL1: return 1'b1;
      EMUL2: return (reg_idx[0] == 1'b0);
      EMUL4: return (reg_idx[1:0] == 2'b0);
      EMUL8: return (reg_idx[2:0] == 3'b0);
      default: return 1'b0;
    endcase
  endfunction

  // Check vd does not overlap v0 when masked (vm=0)
  function automatic logic check_vd_v0(logic vm, logic [4:0] vd);
    return vm | (vd != 5'b0);
  endfunction

  // Check vd does NOT partially overlap a source group (src EMUL > vd EMUL).
  // vd sits inside the src group at a non-zero offset → illegal.
  function automatic logic check_no_partial_overlap(
      logic [4:0] vd, logic [4:0] src, EMUL_e src_emul);
    case (src_emul)
      EMUL1: return 1'b1;
      EMUL2: return !((vd[0] != 1'b0) && (vd[4:1] == src[4:1]));
      EMUL4: return !((vd[1:0] != 2'b0) && (vd[4:2] == src[4:2]));
      EMUL8: return !((vd[2:0] != 3'b0) && (vd[4:3] == src[4:3]));
      default: return 1'b1;
    endcase
  endfunction

  // Check full group non-overlap (vd group != src group)
  function automatic logic check_no_full_overlap(
      logic [4:0] vd, EMUL_e emul_vd,
      logic [4:0] src, EMUL_e emul_src);
    if ((emul_vd == EMUL8) || (emul_src == EMUL8))
      return (vd[4:3] != src[4:3]);
    else if ((emul_vd == EMUL4) || (emul_src == EMUL4))
      return (vd[4:2] != src[4:2]);
    else if ((emul_vd == EMUL2) || (emul_src == EMUL2))
      return (vd[4:1] != src[4:1]);
    else if ((emul_vd == EMUL1) || (emul_src == EMUL1))
      return (vd != src);
    else
      return 1'b0;
  endfunction

  // Check src does NOT partially overlap vd for widening (vd EMUL > src EMUL).
  // For 2:1 ratio: src must be at upper half of vd group.
  function automatic logic check_src_no_partial_vd_2_1(
      logic [4:0] vd, logic [4:0] src, EMUL_e emul_vd);
    case (emul_vd)
      EMUL1: return 1'b1;
      EMUL2: return !((vd[4:1] == src[4:1]) && (src[0] != 1'b1));
      EMUL4: return !((vd[4:2] == src[4:2]) && (src[1:0] != 2'b10));
      EMUL8: return !((vd[4:3] == src[4:3]) && (src[2:0] != 3'b100));
      default: return 1'b1;
    endcase
  endfunction

  // For 4:1 ratio: src must be at 3/4 position of vd group.
  function automatic logic check_src_no_partial_vd_4_1(
      logic [4:0] vd, logic [4:0] src, EMUL_e emul_vd);
    case (emul_vd)
      EMUL1: return 1'b1;
      EMUL2: return !((vd[4:1] == src[4:1]) && (src[0] != 1'b1));
      EMUL4: return !((vd[4:2] == src[4:2]) && (src[1:0] != 2'b11));
      EMUL8: return !((vd[4:3] == src[4:3]) && (src[2:0] != 3'b110));
      default: return 1'b1;
    endcase
  endfunction

  // Get EEW/SEW ratio as signed value for LSU width field
  function automatic logic signed [2:0] lsu_eew_ratio(
      logic [2:0] funct3, RVVSEW sew);
    logic [1:0] eew_log2;
    logic [1:0] sew_log2;
    case (funct3)
      LSU_EEW_8:  eew_log2 = 2'd0;
      LSU_EEW_16: eew_log2 = 2'd1;
      LSU_EEW_32: eew_log2 = 2'd2;
      default: return 3'sd0; // invalid width, will fail check_sew
    endcase
    sew_log2 = sew[1:0];
    return 3'(signed'({1'b0, eew_log2}) - signed'({1'b0, sew_log2}));
  endfunction

  // Per-lane encoding validity check
  logic [N-1:0] encoding_valid;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      // Extract instruction fields from bits[24:0] = inst[31:7]
      automatic logic [5:0]  funct6  = inst_q[i].bits[24:19];
      automatic logic        vm      = inst_q[i].bits[18];
      automatic logic [4:0]  vs2     = inst_q[i].bits[17:13];
      automatic logic [4:0]  vs1     = inst_q[i].bits[12:8];
      automatic logic [2:0]  funct3  = inst_q[i].bits[7:5];
      automatic logic [4:0]  vd      = inst_q[i].bits[4:0];
      automatic logic [2:0]  nf      = funct6[5:3];  // LSU segment fields
      automatic logic [2:0]  mop     = funct6[2:0];  // LSU memory op type
      automatic logic [4:0]  umop    = vs2;           // LSU unit-stride sub-op
      automatic logic [2:0]  nr      = vs1[2:0];     // vmv<nr>r register count
      automatic RVVOpCode    opcode  = inst_q[i].opcode;
      automatic RVVLMUL      lmul    = inst_config_state[i+1].lmul;
      automatic RVVSEW       sew     = inst_config_state[i+1].sew;
      automatic logic [`VL_WIDTH-1:0]     vl     = inst_config_state[i+1].vl;
      automatic logic [`VSTART_WIDTH-1:0] vstart = inst_config_state[i+1].vstart;

      // Computed values
      automatic EMUL_e emul_vd  = EMUL_NONE;
      automatic EMUL_e emul_vs2 = EMUL_NONE;
      automatic EMUL_e emul_vs1 = EMUL_NONE;
      automatic logic  valid_eew = 1'b1;   // EEW is representable
      automatic logic  chk_special = 1'b0;
      automatic logic  chk_common  = 1'b0;
      automatic logic  is_whole_reg = 1'b0;
      automatic logic  is_mask_ld   = 1'b0;
      automatic logic  skip_evl     = 1'b0; // skip evl/vstart checks
      automatic logic [`VL_WIDTH-1:0] evl = vl;

      if (opcode == RVV) begin
        // ============================================================
        // Arithmetic instructions
        // ============================================================
        case (funct3)
          OPIVV, OPIVX, OPIVI: begin
            case (funct6)
              // --- Standard 1x/1x/1x ---
              VADD, VSUB, VRSUB, VMINU, VMIN, VMAXU, VMAX,
              VAND, VOR, VXOR, VSLL, VSRL, VSRA,
              VSADDU, VSADD, VSSUBU, VSSUB, VSSRL, VSSRA,
              VSLIDEDOWN: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = emul_vd;
                if (funct3 == OPIVV) emul_vs1 = emul_vd;
                chk_special = check_vd_v0(vm, vd);
              end

              // --- ADC/SBC (carry-in, vm must be 0, vd != v0) ---
              VADC, VSBC: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = emul_vd;
                if (funct3 == OPIVV) emul_vs1 = emul_vd;
                chk_special = (vm == 1'b0) && (vd != 5'b0);
              end

              // --- MADC/MSBC (mask-producing) ---
              VMADC, VMSBC: begin
                emul_vd  = EMUL1;
                emul_vs2 = compute_emul(lmul, 3'sd0);
                if (funct3 == OPIVV) emul_vs1 = emul_vs2;
                chk_special = check_no_partial_overlap(vd, vs2, emul_vs2);
                if (funct3 == OPIVV)
                  chk_special = chk_special &&
                      check_no_partial_overlap(vd, vs1, emul_vs1);
              end

              // --- Compare (mask-producing) ---
              VMSEQ, VMSNE, VMSLTU, VMSLT, VMSLEU, VMSLE,
              VMSGTU, VMSGT: begin
                emul_vd  = EMUL1;
                emul_vs2 = compute_emul(lmul, 3'sd0);
                if (funct3 == OPIVV) emul_vs1 = emul_vs2;
                chk_special = check_no_partial_overlap(vd, vs2, emul_vs2);
                if (funct3 == OPIVV)
                  chk_special = chk_special &&
                      check_no_partial_overlap(vd, vs1, emul_vs1);
              end

              // --- Narrowing (vd=1x, vs2=2x) ---
              VNSRL, VNSRA, VNCLIPU, VNCLIP: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = compute_emul(lmul, 3'sd1);
                if (funct3 == OPIVV) emul_vs1 = emul_vd;
                chk_special = check_vd_v0(vm, vd) &&
                    check_no_partial_overlap(vd, vs2, emul_vs2);
              end

              // --- Merge/Move ---
              VMERGE_VMV: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = (vm == 1'b0) ? emul_vd : EMUL_NONE;
                if (funct3 == OPIVV) emul_vs1 = emul_vd;
                chk_special = ((vm == 1'b0) && (vd != 5'b0)) ||
                              ((vm == 1'b1) && (vs2 == 5'b0));
              end

              // --- SMUL / vmv<nr>r ---
              VSMUL_VMVNRR: begin
                if (funct3 == OPIVI && vm == 1'b1) begin
                  // vmv<nr>r.v: whole-register move
                  case (nr)
                    NREG1: emul_vd = EMUL1;
                    NREG2: emul_vd = EMUL2;
                    NREG4: emul_vd = EMUL4;
                    NREG8: emul_vd = EMUL8;
                    default: emul_vd = EMUL_NONE;
                  endcase
                  emul_vs2 = emul_vd;
                  is_whole_reg = 1'b1;
                  chk_special = (vs1[4:3] == 2'b0) &&
                      ((nr == NREG1) || (nr == NREG2) ||
                       (nr == NREG4) || (nr == NREG8));
                end else begin
                  // vsmul
                  emul_vd  = compute_emul(lmul, 3'sd0);
                  emul_vs2 = emul_vd;
                  if (funct3 == OPIVV) emul_vs1 = emul_vd;
                  chk_special = check_vd_v0(vm, vd);
                end
              end

              // --- Widening reductions ---
              VWREDSUMU, VWREDSUM: begin
                emul_vd  = EMUL1;
                emul_vs2 = compute_emul(lmul, 3'sd0);
                emul_vs1 = EMUL1;
                chk_special = (vstart == '0);
              end

              // --- Gather (full non-overlap) ---
              VRGATHER: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = emul_vd;
                if (funct3 == OPIVV) emul_vs1 = emul_vd;
                chk_special = check_vd_v0(vm, vd) &&
                    check_no_full_overlap(vd, emul_vd, vs2, emul_vs2);
                if (funct3 == OPIVV)
                  chk_special = chk_special &&
                      check_no_full_overlap(vd, emul_vd, vs1, emul_vs1);
              end

              // --- SlideUp / RgatherEI16 ---
              VSLIDEUP_RGATHEREI16: begin
                if (funct3 == OPIVV) begin
                  // vrgatherei16: vs1 EMUL based on 16/SEW ratio
                  emul_vd  = compute_emul(lmul, 3'sd0);
                  emul_vs2 = emul_vd;
                  case (sew)
                    SEW8:  emul_vs1 = compute_emul(lmul, 3'sd1); // 16/8=2x
                    SEW16: emul_vs1 = emul_vd;                    // 16/16=1x
                    SEW32: emul_vs1 = compute_emul(lmul, -3'sd1); // 16/32=0.5x
                    default: emul_vs1 = EMUL_NONE;
                  endcase
                  chk_special = check_vd_v0(vm, vd) &&
                      check_no_full_overlap(vd, emul_vd, vs2, emul_vs2) &&
                      check_no_full_overlap(vd, emul_vd, vs1, emul_vs1);
                end else begin
                  // vslideup
                  emul_vd  = compute_emul(lmul, 3'sd0);
                  emul_vs2 = emul_vd;
                  chk_special = check_vd_v0(vm, vd) &&
                      check_no_full_overlap(vd, emul_vd, vs2, emul_vs2);
                end
              end

              default: begin
                // Unrecognized funct6 for OPI* — let backend handle
                emul_vd = compute_emul(lmul, 3'sd0);
                chk_special = 1'b1;
              end
            endcase
          end

          OPMVV: begin
            case (funct6)
              // --- Widening (2x, 1x, 1x) ---
              VWADDU, VWADD, VWSUBU, VWSUB,
              VWMULU, VWMULSU, VWMUL,
              VWMACCU, VWMACC, VWMACCSU: begin
                emul_vd  = compute_emul(lmul, 3'sd1);
                emul_vs2 = compute_emul(lmul, 3'sd0);
                emul_vs1 = emul_vs2;
                chk_special = check_vd_v0(vm, vd) &&
                    check_src_no_partial_vd_2_1(vd, vs2, emul_vd) &&
                    check_src_no_partial_vd_2_1(vd, vs1, emul_vd);
              end

              // --- Widening WW (2x, 2x, 1x) ---
              VWADDU_W, VWADD_W, VWSUBU_W, VWSUB_W: begin
                emul_vd  = compute_emul(lmul, 3'sd1);
                emul_vs2 = emul_vd;
                emul_vs1 = compute_emul(lmul, 3'sd0);
                chk_special = check_vd_v0(vm, vd) &&
                    check_src_no_partial_vd_2_1(vd, vs1, emul_vd);
              end

              // --- Extension ---
              VXUNARY0: begin
                case (vs1)
                  VZEXT_VF2, VSEXT_VF2: begin
                    emul_vd  = compute_emul(lmul, 3'sd1);
                    emul_vs2 = compute_emul(lmul, 3'sd0);
                    chk_special = check_vd_v0(vm, vd) &&
                        check_src_no_partial_vd_2_1(vd, vs2, emul_vd);
                  end
                  VZEXT_VF4, VSEXT_VF4: begin
                    emul_vd  = compute_emul(lmul, 3'sd2);
                    emul_vs2 = compute_emul(lmul, 3'sd0);
                    chk_special = check_vd_v0(vm, vd) &&
                        check_src_no_partial_vd_4_1(vd, vs2, emul_vd);
                  end
                  default: chk_special = 1'b0;
                endcase
              end

              // --- Standard OPMVV (1x, 1x, 1x) ---
              VMUL, VMULH, VMULHU, VMULHSU,
              VDIVU, VDIV, VREMU, VREM,
              VMACC, VNMSAC, VMADD, VNMSUB,
              VAADDU, VAADD, VASUBU, VASUB: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = emul_vd;
                emul_vs1 = emul_vd;
                chk_special = check_vd_v0(vm, vd);
              end

              // --- Reduction ---
              VREDSUM, VREDAND, VREDOR, VREDXOR,
              VREDMINU, VREDMIN, VREDMAXU, VREDMAX: begin
                emul_vd  = EMUL1;
                emul_vs2 = compute_emul(lmul, 3'sd0);
                emul_vs1 = EMUL1;
                chk_special = (vstart == '0);
              end

              // --- Mask logical (EMUL1, EMUL1, EMUL1) ---
              VMAND, VMNAND, VMANDN,
              VMXOR, VMOR, VMNOR, VMORN, VMXNOR: begin
                emul_vd  = EMUL1;
                emul_vs2 = EMUL1;
                emul_vs1 = EMUL1;
                chk_special = vm; // must be unmasked
              end

              // --- Scalar read / population count ---
              VWRXUNARY0: begin
                case (vs1)
                  VCPOP, VFIRST: begin
                    emul_vd  = EMUL_NONE;
                    emul_vs2 = EMUL1;
                    skip_evl = 1'b1;
                    chk_special = (vstart == '0);
                  end
                  VMV_X_S: begin
                    emul_vd  = EMUL_NONE;
                    emul_vs2 = EMUL1;
                    skip_evl = 1'b1;
                    chk_special = (vm == 1'b1);
                  end
                  default: chk_special = 1'b0;
                endcase
              end

              // --- Mask utility ---
              VMUNARY0: begin
                case (vs1)
                  VMSBF, VMSIF, VMSOF: begin
                    emul_vd  = EMUL1;
                    emul_vs2 = EMUL1;
                    chk_special = (vstart == '0) &&
                        check_vd_v0(vm, vd) &&
                        check_no_full_overlap(vd, EMUL1, vs2, EMUL1);
                  end
                  VIOTA: begin
                    emul_vd  = compute_emul(lmul, 3'sd0);
                    emul_vs2 = EMUL1;
                    chk_special = (vstart == '0) &&
                        check_vd_v0(vm, vd) &&
                        check_no_full_overlap(vd, emul_vd, vs2, EMUL1);
                  end
                  VID: begin
                    emul_vd = compute_emul(lmul, 3'sd0);
                    chk_special = (vs2 == 5'b0) && check_vd_v0(vm, vd);
                  end
                  default: chk_special = 1'b0;
                endcase
              end

              // --- Compress ---
              VCOMPRESS: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = emul_vd;
                emul_vs1 = EMUL1;
                chk_special = (vstart == '0) && vm &&
                    check_no_full_overlap(vd, emul_vd, vs2, emul_vs2) &&
                    check_no_full_overlap(vd, emul_vd, vs1, EMUL1);
              end

              default: begin
                emul_vd = compute_emul(lmul, 3'sd0);
                chk_special = 1'b1;
              end
            endcase
          end

          OPMVX: begin
            case (funct6)
              // --- Widening (2x, 1x, scalar) ---
              VWADDU, VWADD, VWSUBU, VWSUB,
              VWMULU, VWMULSU, VWMUL,
              VWMACCU, VWMACC, VWMACCSU: begin
                emul_vd  = compute_emul(lmul, 3'sd1);
                emul_vs2 = compute_emul(lmul, 3'sd0);
                chk_special = check_vd_v0(vm, vd) &&
                    check_src_no_partial_vd_2_1(vd, vs2, emul_vd);
              end

              VWMACCUS: begin
                emul_vd  = compute_emul(lmul, 3'sd1);
                emul_vs2 = compute_emul(lmul, 3'sd0);
                chk_special = check_vd_v0(vm, vd) &&
                    check_src_no_partial_vd_2_1(vd, vs2, emul_vd);
              end

              // --- Widening WW (2x, 2x, scalar) ---
              VWADDU_W, VWADD_W, VWSUBU_W, VWSUB_W: begin
                emul_vd  = compute_emul(lmul, 3'sd1);
                emul_vs2 = emul_vd;
                chk_special = check_vd_v0(vm, vd);
              end

              // --- Standard (1x, 1x, scalar) ---
              VMUL, VMULH, VMULHU, VMULHSU,
              VDIVU, VDIV, VREMU, VREM,
              VMACC, VNMSAC, VMADD, VNMSUB,
              VAADDU, VAADD, VASUBU, VASUB,
              VSLIDE1DOWN: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = emul_vd;
                chk_special = check_vd_v0(vm, vd);
              end

              // --- Slide1up (full non-overlap vd/vs2) ---
              VSLIDE1UP: begin
                emul_vd  = compute_emul(lmul, 3'sd0);
                emul_vs2 = emul_vd;
                chk_special = check_vd_v0(vm, vd) &&
                    check_no_full_overlap(vd, emul_vd, vs2, emul_vs2);
              end

              // --- VMV.S.X ---
              VWRXUNARY0: begin
                emul_vd = EMUL1;
                chk_special = (vs2 == 5'b0) && (vm == 1'b1);
                evl = vl;
                skip_evl = (vl == '0);
              end

              default: begin
                emul_vd = compute_emul(lmul, 3'sd0);
                chk_special = 1'b1;
              end
            endcase
          end

          default: begin
            // OPCFG (vsetvl*) is handled by is_setvl; skip here
            chk_special = 1'b1;
            emul_vd = EMUL1;
          end
        endcase

      end else begin
        // ============================================================
        // LSU instructions (opcode == LOAD or STORE)
        // ============================================================
        automatic logic signed [2:0] ratio;
        automatic logic is_load = (opcode == LOAD);

        case (mop)
          UNIT_STRIDE: begin
            case (umop)
              US_REGULAR, US_FAULT_FIRST: begin
                ratio = lsu_eew_ratio(funct3, sew);
                emul_vd = compute_emul(lmul, ratio);
                valid_eew = (funct3 == LSU_EEW_8) ||
                            (funct3 == LSU_EEW_16) ||
                            (funct3 == LSU_EEW_32);
                if (umop == US_FAULT_FIRST)
                  chk_special = is_load && check_vd_v0(vm, vd);
                else
                  chk_special = is_load ? check_vd_v0(vm, vd) : 1'b1;
              end
              US_WHOLE_REGISTER: begin
                case (nf)
                  3'b000: emul_vd = EMUL1;
                  3'b001: emul_vd = EMUL2;
                  3'b011: emul_vd = EMUL4;
                  3'b111: emul_vd = EMUL8;
                  default: emul_vd = EMUL_NONE;
                endcase
                is_whole_reg = 1'b1;
                valid_eew = (funct3 == LSU_EEW_8) ||
                            (funct3 == LSU_EEW_16) ||
                            (funct3 == LSU_EEW_32);
                chk_special = vm && (is_load ||
                    ((!is_load) && (funct3 == LSU_EEW_8)));
              end
              US_MASK: begin
                emul_vd = EMUL1;
                is_mask_ld = 1'b1;
                valid_eew = (funct3 == LSU_EEW_8);
                chk_special = vm && (funct3 == LSU_EEW_8) &&
                              (nf == 3'b0);
              end
              default: chk_special = 1'b0;
            endcase
          end

          CONSTANT_STRIDE: begin
            ratio = lsu_eew_ratio(funct3, sew);
            emul_vd = compute_emul(lmul, ratio);
            valid_eew = (funct3 == LSU_EEW_8) ||
                        (funct3 == LSU_EEW_16) ||
                        (funct3 == LSU_EEW_32);
            chk_special = is_load ? check_vd_v0(vm, vd) : 1'b1;
          end

          UNORDERED_INDEX, ORDERED_INDEX: begin
            // Data EMUL uses SEW, index EMUL uses funct3
            emul_vd  = compute_emul(lmul, 3'sd0);  // data at SEW
            ratio = lsu_eew_ratio(funct3, sew);
            emul_vs2 = compute_emul(lmul, ratio);   // index at EEW
            valid_eew = (funct3 == LSU_EEW_8) ||
                        (funct3 == LSU_EEW_16) ||
                        (funct3 == LSU_EEW_32);

            if (nf == NF1) begin
              // Non-segment indexed
              if (ratio > 0) begin
                // EEW_index > SEW: check vd not partial in vs2
                chk_special = is_load ?
                    (check_vd_v0(vm, vd) &&
                     check_no_partial_overlap(vd, vs2, emul_vs2)) : 1'b1;
              end else if (ratio < 0) begin
                // SEW > EEW_index: check vs2 not partial in vd
                if (ratio == -3'sd1)
                  chk_special = is_load ?
                      (check_vd_v0(vm, vd) &&
                       check_src_no_partial_vd_2_1(vd, vs2, emul_vd)) : 1'b1;
                else
                  chk_special = is_load ?
                      (check_vd_v0(vm, vd) &&
                       check_src_no_partial_vd_4_1(vd, vs2, emul_vd)) : 1'b1;
              end else begin
                // EEW_index == SEW: same EMUL
                chk_special = is_load ? check_vd_v0(vm, vd) : 1'b1;
              end
            end else begin
              // Segment indexed: full non-overlap vd/vs2
              chk_special = is_load ?
                  (check_vd_v0(vm, vd) &&
                   check_no_full_overlap(vd, emul_vd, vs2, emul_vs2)) : 1'b1;
            end
          end

          default: chk_special = 1'b0;
        endcase

        // For ALL LSU segments (any mop), scale emul_vd by NF for
        // alignment/range check. This catches vd + NF*EMUL > 31.
        if (nf != NF1) begin
          case (emul_vd)
            EMUL1: case (nf)
              NF2: emul_vd = EMUL2;
              NF3: emul_vd = EMUL4; // approximate: EMUL3->EMUL4
              NF4: emul_vd = EMUL4;
              NF5, NF6, NF7, NF8: emul_vd = EMUL8;
              default: ;
            endcase
            EMUL2: case (nf)
              NF2: emul_vd = EMUL4;
              NF3, NF4: emul_vd = EMUL8;
              default: emul_vd = EMUL_NONE;
            endcase
            EMUL4: case (nf)
              NF2: emul_vd = EMUL8;
              default: emul_vd = EMUL_NONE;
            endcase
            EMUL8: emul_vd = EMUL_NONE; // any NF>1 overflows
            default: ;
          endcase
        end
      end

      // ============================================================
      // check_common: alignment + valid EMUL + EVL/vstart
      // ============================================================
      begin
        automatic logic align_vd  = check_align(vd, emul_vd);
        automatic logic align_vs2 = check_align(vs2, emul_vs2);
        automatic logic align_vs1 = check_align(vs1, emul_vs1);
        automatic logic valid_emul = (emul_vd != EMUL_NONE) ||
                                     (emul_vs2 != EMUL_NONE) ||
                                     (emul_vs1 != EMUL_NONE);
        automatic logic evl_ok;
        automatic logic vstart_ok;

        if (is_whole_reg || skip_evl) begin
          evl_ok = 1'b1;
          vstart_ok = 1'b1;
        end else if (is_mask_ld) begin
          evl_ok = vl != '0;
          vstart_ok = {1'b0, vstart} < vl;
        end else begin
          evl_ok = evl != '0;
          vstart_ok = {1'b0, vstart} < evl;
        end

        chk_common = align_vd && align_vs2 && align_vs1 &&
                     valid_eew && valid_emul && evl_ok && vstart_ok;
      end

      encoding_valid[i] = chk_special && chk_common;
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
          (inst_config_state[i+1].vill || !encoding_valid[i]);
      unaligned_trap_data[i] = inst_q[i];
      unaligned_cmd_valid[i] = valid_inst_q[i] && !is_setvl[i] &&
          !inst_config_state[i+1].vill && encoding_valid[i];

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
