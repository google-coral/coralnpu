// Copyright 2025 Google LLC
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

module RvvCore #(parameter N = 4,
                 parameter CMD_BUFFER_MAX_CAPACITY = 16,
                 type RegDataT=logic [31:0],
                 type VRegDataT=logic [127:0],
                 type RegAddrT=logic [4:0],
                 type MaskT=logic [15:0]
                 )
(
  input clk,
  input rstn,

  input logic [`VSTART_WIDTH-1:0] vstart,
  input logic [1:0] vxrm,
  input logic vxsat,
  input logic [2:0] frm,

  // Instruction input.
  input logic [N-1:0] inst_valid,
  input RVVInstruction [N-1:0] inst_data,
  output logic [N-1:0] inst_ready,

  // Register file input
  input logic [(2*N)-1:0] reg_read_valid,
  input RegDataT [(2*N)-1:0] reg_read_data,

  // Floating point register file input
  input RegDataT [N-1:0] freg_read_data,

  // Scalar Regfile writeback for configuration functions.
  output logic [N-1:0] reg_write_valid,
  output RegAddrT [N-1:0] reg_write_addr,
  output RegDataT [N-1:0] reg_write_data,

  // Scalar Regfile writeback for non-configuration functions.
  output logic async_rd_valid,
  output RegAddrT async_rd_addr,
  output RegDataT async_rd_data,
  input logic async_rd_ready,

  // Floating Point Regfile writeback.
  output logic async_frd_valid,
  output RegAddrT async_frd_addr,
  output RegDataT async_frd_data,
  input logic async_frd_ready,

  // RVV to LSU
  output  logic     [`NUM_LSU-1:0] uop_lsu_valid_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_idx_valid_rvv2lsu,
  output  RegAddrT  [`NUM_LSU-1:0] uop_lsu_idx_addr_rvv2lsu,
  output  VRegDataT [`NUM_LSU-1:0] uop_lsu_idx_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_vregfile_valid_rvv2lsu,
  output  RegAddrT  [`NUM_LSU-1:0] uop_lsu_vregfile_addr_rvv2lsu,
  output  VRegDataT [`NUM_LSU-1:0] uop_lsu_vregfile_data_rvv2lsu,
  output  logic     [`NUM_LSU-1:0] uop_lsu_v0_valid_rvv2lsu,
  output  MaskT     [`NUM_LSU-1:0] uop_lsu_v0_data_rvv2lsu,
  input   logic     [`NUM_LSU-1:0] uop_lsu_ready_lsu2rvv,

  // LSU to RVV
  input  logic     [`NUM_LSU-1:0] uop_lsu_valid_lsu2rvv,
  input  RegAddrT  [`NUM_LSU-1:0] uop_lsu_addr_lsu2rvv,
  input  VRegDataT [`NUM_LSU-1:0] uop_lsu_wdata_lsu2rvv,
  input  logic     [`NUM_LSU-1:0] uop_lsu_last_lsu2rvv,
  output logic     [`NUM_LSU-1:0] uop_lsu_ready_rvv2lsu,

  // Vector CSR writeback
  output vcsr_valid,
  output RVVConfigState vector_csr,
  input vcsr_ready,

  // Config state
  output config_state_valid,
  output RVVConfigState config_state,

  // Idle
  output logic rvv_idle,
  output logic [$clog2(2*N + 1)-1:0] queue_capacity,

  // Writeback from reorder buffer
  output ROB2RT_t [`NUM_RT_UOP-1:0] rd_rob2rt_o,

  // Trap output
  output logic trap_valid_o,
  output RVVInstruction trap_data_o
);
  logic [N-1:0] frontend_cmd_valid;
  RVVCmd [N-1:0] frontend_cmd_data;
  logic [$clog2(2*N + 1)-1:0] queue_capacity_internal;
  RvvFrontEnd#(.N(N)) frontend(
      .clk(clk),
      .rstn(rstn),
      .vstart_i(vstart),
      .vxrm_i(vxrm),
      .vxsat_i(vxsat),
      .frm_i(frm),
      .inst_valid_i(inst_valid),
      .inst_data_i(inst_data),
      .inst_ready_o(inst_ready),
      .reg_read_valid_i(reg_read_valid),
      .reg_read_data_i(reg_read_data),
      .reg_write_valid_o(reg_write_valid),
      .reg_write_addr_o(reg_write_addr),
      .reg_write_data_o(reg_write_data),
      .cmd_valid_o(frontend_cmd_valid),
      .cmd_data_o(frontend_cmd_data),
      .queue_capacity_i(queue_capacity_internal),
      .queue_capacity_o(queue_capacity),
      .trap_valid_o(trap_valid_o),
      .trap_data_o(trap_data_o),
      .config_state_valid(config_state_valid),
      .config_state(config_state)
  );

  // Backpressure from backend fifo
  logic   [$clog2(`CQ_DEPTH):0] remaining_count_cq2rvs;
  // Back-pressure frontend
  always_comb begin
    if (remaining_count_cq2rvs > 2*N) begin
      queue_capacity_internal = 2*N;
    end else begin
      queue_capacity_internal = remaining_count_cq2rvs;
    end
  end

  // Back-end ============================================================

  // LSU Tie-offs
  // RVV send LSU uop to RVS
    UOP_RVV2LSU_t     [`NUM_LSU-1:0]          uop_lsu_rvv2lsu;
    always_comb begin
      for (int i = 0; i < `NUM_LSU; i++) begin
        uop_lsu_idx_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_valid;
        uop_lsu_idx_addr_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_addr;
        uop_lsu_idx_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vidx_data;
        uop_lsu_vregfile_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_valid;
        uop_lsu_vregfile_addr_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_addr;
        uop_lsu_vregfile_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].vregfile_read_data;
        uop_lsu_v0_valid_rvv2lsu[i] = uop_lsu_rvv2lsu[i].v0_valid;
        uop_lsu_v0_data_rvv2lsu[i] = uop_lsu_rvv2lsu[i].v0_data;
      end
    end

  // LSU feedback to RVV
    UOP_LSU2RVV_t     [`NUM_LSU-1:0]          uop_lsu_lsu2rvv;
    always_comb begin
      for (int i = 0; i < `NUM_LSU; i++) begin
        // TODO(derekjchow): Modify me
        uop_lsu_lsu2rvv[i].vregfile_write_valid = (
            uop_lsu_valid_lsu2rvv[i] && !uop_lsu_last_lsu2rvv[i]);
        uop_lsu_lsu2rvv[i].vregfile_write_addr = uop_lsu_addr_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].vregfile_write_data = uop_lsu_wdata_lsu2rvv[i];
        uop_lsu_lsu2rvv[i].lsu_vstore_last = (
            uop_lsu_valid_lsu2rvv[i] && uop_lsu_last_lsu2rvv[i]);
      `ifdef TB_SUPPORT
        uop_lsu_lsu2rvv[i].uop_pc = 0;
        uop_lsu_lsu2rvv[i].uop_index = 0;
      `endif
      end
    end

  // Scalar regfile write-back tie-offs
  // TODO(derekjchow): Properly arbitrate write-back tie-offs by extending
  // interface. For time being, only accept from slot 0.
  logic    [`NUM_RT_UOP-1:0] rt_xrf_valid_rvv2rvs;
  RT2XRF_t [`NUM_RT_UOP-1:0] rt_xrf_rvv2rvs;
  logic    [`NUM_RT_UOP-1:0] rt_xrf_ready_rvs2rvv;
  always_comb begin
    rt_xrf_ready_rvs2rvv[0] = async_rd_ready;
    async_rd_valid = rt_xrf_valid_rvv2rvs[0];
    async_rd_addr = rt_xrf_rvv2rvs[0].rt_index;
    async_rd_data = rt_xrf_rvv2rvs[0].rt_data;
    for (int i = 1; i < `NUM_RT_UOP; i++) begin
      rt_xrf_ready_rvs2rvv[i] = 0;
    end
  end

  // Backpressure
  logic wr_vxsat_ready;
  always_comb begin
    // TODO(derekjchow): Actually accept
    wr_vxsat_ready = 1;
  end

  // CSR Update, unused for now
  logic                            wr_vxsat_valid;
  logic    [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat;

  // Trap handling tie-off
  logic  trap_valid_rvs2rvv;
  logic  trap_ready_rvv2rvs;
  always_comb begin
    trap_valid_rvs2rvv = 0;
  end

  // Tie-off floating point writeback until implemented.
  assign async_frd_valid = 0;
  assign async_frd_addr = 0;
  assign async_frd_data = 0;

  ROB2RT_t [`NUM_RT_UOP-1:0] rd_rob2rt;
  assign rd_rob2rt_o = rd_rob2rt;

  logic   [`ISSUE_LANE-1:0] insts_ready_cq2rvs;
  logic rvv_backend_idle;
  assign rvv_idle = rvv_backend_idle && (frontend_cmd_valid == 0);
  rvv_backend backend(
      .clk(clk),
      .rst_n(rstn),
      .insts_valid_rvs2cq(frontend_cmd_valid),
      .insts_rvs2cq(frontend_cmd_data),
      .insts_ready_cq2rvs(insts_ready_cq2rvs),
      .remaining_count_cq2rvs(remaining_count_cq2rvs),

      .uop_lsu_valid_rvv2lsu(uop_lsu_valid_rvv2lsu),
      .uop_lsu_rvv2lsu(uop_lsu_rvv2lsu),
      .uop_lsu_ready_lsu2rvv(uop_lsu_ready_lsu2rvv),

      .uop_lsu_valid_lsu2rvv(uop_lsu_valid_lsu2rvv),
      .uop_lsu_lsu2rvv(uop_lsu_lsu2rvv),
      .uop_lsu_ready_rvv2lsu(uop_lsu_ready_rvv2lsu),

      .rt_xrf_rvv2rvs(rt_xrf_rvv2rvs),
      .rt_xrf_valid_rvv2rvs(rt_xrf_valid_rvv2rvs),
      .rt_xrf_ready_rvs2rvv(rt_xrf_ready_rvs2rvv),
      .wr_vxsat_valid(wr_vxsat_valid),
      .wr_vxsat(wr_vxsat),
      .wr_vxsat_ready(wr_vxsat_ready),
      .trap_valid_rvs2rvv(trap_valid_rvs2rvv),
      .trap_ready_rvv2rvs(trap_ready_rvv2rvs),
      .vcsr_valid(vcsr_valid),
      .vector_csr(vector_csr),
      .vcsr_ready(vcsr_ready),
`ifdef TB_SUPPORT
      .rd_valid_rob2rt_o(),
`endif
      .rvv_idle(rvv_backend_idle),
      .rd_rob2rt_o(rd_rob2rt)
  );

endmodule
