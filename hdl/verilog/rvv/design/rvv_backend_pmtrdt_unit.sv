// description
// 1. the pmtrdt_unit module is responsible for one PMTRDT instruction.
//
// feature list:
// 1. Compare/Reduction/Compress instruction is optional based on parameters.
// 2. the latency of Compare instructions is 2-cycles.
//    the latency of Reduction instructions is N-cycle based on VLENB.
//      |VLENB|latency|
//      |16B  |3-cycle|
//      |32B  |4-cycle|
//      |64B  |5-cycle|
//      |128B |6-cycle|
//    the latency of Permutation instructions is N-cycle based on offset value.

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`ifndef PMTRDT_DEFINE_SVH
`include "rvv_backend_pmtrdt.svh"
`endif

module rvv_backend_pmtrdt_unit
(
  clk,
  rst_n,

  pmtrdt_uop_valid,
  pmtrdt_uop,
  pmtrdt_uop_ready,

  pmtrdt_res_valid,
  pmtrdt_res,
  pmtrdt_res_ready,

  rd_index_pmt2vrf,
  rd_data_vrf2pmt,

  rob_rptr,
  trap_flush_rvv
);
// ---parameter definition--------------------------------------------
  parameter GEN_RDT = 1'b0; // by default, NO Reduction unit
  parameter GEN_PMT = 1'b0; // by default, NO PERMUTATION unit
  parameter GEN_FRDT= 1'b0;

// ---port definition-------------------------------------------------
// global signal
  input logic       clk;
  input logic       rst_n;

// the uop from PMTRDT RS
  input               pmtrdt_uop_valid;
  input PMT_RDT_RS_t  pmtrdt_uop;
  output logic        pmtrdt_uop_ready;

// the result to PMTRDT PU
  output logic        pmtrdt_res_valid;
  output PU2ROB_t     pmtrdt_res;
  input               pmtrdt_res_ready;

// read vrf for permutation
  output logic [`REGIDX_WIDTH-1:0]    rd_index_pmt2vrf;
  input  logic [`VLEN-1:0]            rd_data_vrf2pmt;

// MISC
  input  logic [`ROB_DEPTH_WIDTH-1:0] rob_rptr;
// trap-flush
  input               trap_flush_rvv;

// ---internal signal definition--------------------------------------
  // reduction signals
  logic               rdt_uop_valid;
  PMT_RDT_RS_t        rdt_uop;
  logic               rdt_uop_ready;

  logic               rdt_res_valid;
  PU2ROB_t            rdt_res;
  logic               rdt_res_ready;

  // permutation signals
  logic               pmt_uop_valid;
  PMT_RDT_RS_t        pmt_uop;
  logic               pmt_uop_ready;

  logic               pmt_res_valid;
  PU2ROB_t            pmt_res;
  logic               pmt_res_ready;

`ifdef ZVE32F_ON
  logic               frdt_uop_valid;
  PMT_RDT_RS_t        frdt_uop;
  logic               frdt_uop_ready;

  logic               frdt_res_valid;
  PU2ROB_t            frdt_res;
  logic               frdt_res_ready;

  // arbiter
  logic    [2:0]      pmtrdt_req; // 'b01 for rdt, 'b10 for pmt, 'b100 for frdt
  PU2ROB_t [2:0]      pmtrdt_reqData; // 'b01 for rdt, 'b10 for pmt, 'b100 for frdt
  logic    [2:0]      pmtrdt_grant; // 'b01 for rdt, 'b10 for pmt 'b100 for frdt
`else
  // arbiter
  logic    [1:0]      pmtrdt_req; // 'b01 for rdt, 'b10 for pmt
  PU2ROB_t [1:0]      pmtrdt_reqData; // 'b01 for rdt, 'b10 for pmt
  logic    [1:0]      pmtrdt_grant; // 'b01 for rdt, 'b10 for pmt
`endif

  genvar i;

// ---code start------------------------------------------------------
// control signals based on uop
  assign rdt_uop = pmtrdt_uop;
  assign pmt_uop = pmtrdt_uop;
  assign pmt_uop_valid = pmtrdt_uop_valid &&  pmtrdt_uop.uop_exe_unit == VEU_PMT;
`ifdef ZVE32F_ON
  assign frdt_uop= pmtrdt_uop;
  assign rdt_uop_valid  = pmtrdt_uop_valid && pmtrdt_uop.uop_exe_unit != VEU_PMT && pmtrdt_uop.uop_funct3 != OPFVV;
  assign frdt_uop_valid = pmtrdt_uop_valid && pmtrdt_uop.uop_exe_unit != VEU_PMT && pmtrdt_uop.uop_funct3 == OPFVV;
  assign pmtrdt_uop_ready = pmtrdt_uop.uop_exe_unit == VEU_PMT ? pmt_uop_ready :
                           (pmtrdt_uop.uop_funct3 == OPFVV)? frdt_uop_ready: rdt_uop_ready;
`else
  assign rdt_uop_valid = pmtrdt_uop_valid && pmtrdt_uop.uop_exe_unit != VEU_PMT;
  assign pmtrdt_uop_ready = pmtrdt_uop.uop_exe_unit == VEU_PMT ? pmt_uop_ready : rdt_uop_ready;
`endif

// Reduction unit
  generate
    if (GEN_RDT == 1'b1) begin
      rvv_backend_pmtrdt_unit_reduction u_rdt (
        .clk      (clk),
        .rst_n    (rst_n),
        .rdt_uop_valid  (rdt_uop_valid),
        .rdt_uop        (rdt_uop),
        .rdt_uop_ready  (rdt_uop_ready),
        .rdt_res_valid  (rdt_res_valid),
        .rdt_res        (rdt_res),
        .rdt_res_ready  (rdt_res_ready),
        .trap_flush_rvv (trap_flush_rvv)
      );
    end else begin
      assign rdt_uop_ready = 1'b0;
      assign rdt_res_valid = 1'b0;
      assign rdt_res = '0;
    end
  endgenerate

`ifdef ZVE32F_ON
// Float Reduction unit
  generate
    if (GEN_FRDT == 1'b1) begin
      rvv_backend_freduction u_frdt (
        .clk      (clk),
        .rst_n    (rst_n),
        .uop_valid      (frdt_uop_valid),
        .uop            (frdt_uop),
        .uop_ready      (frdt_uop_ready),
        .result_valid   (frdt_res_valid),
        .result         (frdt_res),
        .result_ready   (frdt_res_ready),
        .trap_flush_rvv (trap_flush_rvv)
      );
      //to be done
    end else begin
      assign frdt_uop_ready = 1'b0;
      assign frdt_res_valid = 1'b0;
      assign frdt_res = '0;
    end
  endgenerate
`endif

// Permutation unit 
  generate
    if (GEN_PMT == 1'b1) begin
      rvv_backend_pmtrdt_unit_permutation u_pmt (
        .clk      (clk),
        .rst_n    (rst_n),
        .pmt_uop_valid  (pmt_uop_valid),
        .pmt_uop        (pmt_uop),
        .pmt_uop_ready  (pmt_uop_ready),
        .pmt_res_valid  (pmt_res_valid),
        .pmt_res        (pmt_res),
        .pmt_res_ready  (pmt_res_ready),
        .rd_index_pmt2vrf (rd_index_pmt2vrf),
        .rd_data_vrf2pmt  (rd_data_vrf2pmt),
        .rob_rptr         (rob_rptr),
        .trap_flush_rvv   (trap_flush_rvv)
      );
    end else begin
      assign pmt_uop_ready = 1'b0;
      assign pmt_res_valid = 1'b0;
      assign pmt_res = '0;
      assign rd_index_pmt2vrf = '0;
    end
  endgenerate

`ifdef ZVE32F_ON
  assign pmtrdt_req     = {frdt_res_valid, pmt_res_valid, rdt_res_valid};
  assign pmtrdt_reqData = {frdt_res, pmt_res, rdt_res};
`else
  assign pmtrdt_req     = {pmt_res_valid, rdt_res_valid};
  assign pmtrdt_reqData = {pmt_res, rdt_res};
`endif
  arb_round_robin #(
  `ifdef ZVE32F_ON
    .REQ_NUM  (3),
  `else
    .REQ_NUM  (2),
  `endif
    .T        (PU2ROB_t)
  ) arb_pmtrdt (
    .clk      (clk),
    .rst_n    (rst_n),
    .req      (pmtrdt_req),
    .reqData  (pmtrdt_reqData),
    .grant    (pmtrdt_grant),
    .grantData(pmtrdt_res)
  );
  
  assign pmtrdt_res_valid = |pmtrdt_req;

  always_comb begin
    rdt_res_ready = 1'b0;
    pmt_res_ready = 1'b0;
  `ifdef ZVE32F_ON
    frdt_res_ready= 1'b0;
  `endif
    case (1'b1)
      pmtrdt_grant[1]: pmt_res_ready  = pmtrdt_res_ready;
    `ifdef ZVE32F_ON
      pmtrdt_grant[2]: frdt_res_ready = pmtrdt_res_ready;
    `endif
      default:         rdt_res_ready  = pmtrdt_res_ready;
    endcase
  end

endmodule
