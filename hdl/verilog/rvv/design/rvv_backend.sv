`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend
(
    clk,
    rst_n,

    insts_valid_rvs2cq,
    insts_rvs2cq,
    insts_ready_cq2rvs,
    remaining_count_cq2rvs,

    uop_lsu_valid_rvv2lsu,
    uop_lsu_rvv2lsu,
    uop_lsu_ready_lsu2rvv,

    uop_lsu_valid_lsu2rvv,
    uop_lsu_lsu2rvv,
    uop_lsu_ready_rvv2lsu,

`ifdef ZVT_ON
    uop_vme2lsu_vld,
    uop_vme2lsu,
    uop_vme2lsu_rdy,

    uop_lsu2vme_vld,
    uop_lsu2vme,
    uop_lsu2vme_rdy,
    vme_lsuflush_vld,
    vme_lsuflush_rdy,

    vmeRtVld,
    vmeRt,
    vmeRtRdy,
`endif

    rt_xrf_valid_rvv2rvs,
    rt_rvs_rvv2rvs,
    rt_rvs_ready_rvs2rvv,

`ifdef ZVE32F_ON
    async_frd_valid,
  `ifdef TB_SUPPORT
    async_frd_pc,
  `endif
    async_frd_addr,
    async_frd_data,
    async_frd_ready,
`endif

    wr_vxsat_valid,
    wr_vxsat,
    wr_vxsat_ready,

`ifdef ZVE32F_ON
    rt2fcsr_write_valid,
    rt2fcsr_write_data,
    fcsr2rt_write_ready,
`endif

    trap_valid_rvs2rvv,
    trap_ready_rvv2rvs,    

    vcsr_valid,
    vector_csr,
    vcsr_ready,

    rd_valid_rob2rt_o,
    rd_rob2rt_o,

    rvv_idle
);
// global signal
    input   logic                                 clk;
    input   logic                                 rst_n;

// vector instruction and scalar operand input. 
    input   logic         [`ISSUE_LANE-1:0]       insts_valid_rvs2cq;
    input   RVVCmd        [`ISSUE_LANE-1:0]       insts_rvs2cq;
    output  logic         [`ISSUE_LANE-1:0]       insts_ready_cq2rvs;  
    output  logic         [$clog2(`CQ_DEPTH):0]   remaining_count_cq2rvs; 

// load/store unit interface
  // RVV send LSU uop to RVS
    output  logic         [`NUM_LSU-1:0]          uop_lsu_valid_rvv2lsu;
    output  UOP_RVV2LSU_t [`NUM_LSU-1:0]          uop_lsu_rvv2lsu;
    input   logic         [`NUM_LSU-1:0]          uop_lsu_ready_lsu2rvv;
  // LSU feedback to RVV
    input   logic         [`NUM_LSU-1:0]          uop_lsu_valid_lsu2rvv;
    input   UOP_LSU2RVV_t [`NUM_LSU-1:0]          uop_lsu_lsu2rvv;
    output  logic         [`NUM_LSU-1:0]          uop_lsu_ready_rvv2lsu;
`ifdef ZVT_ON
  // VME2LSU
    output  logic                                 uop_vme2lsu_vld;
    output  UOP_VME2LSU_t                         uop_vme2lsu;
    input   logic                                 uop_vme2lsu_rdy;
  // LSU2VME
    input   logic                                 uop_lsu2vme_vld;
    input   UOP_LSU2VME_t                         uop_lsu2vme;
    output  logic                                 uop_lsu2vme_rdy;
    input   logic                                 vme_lsuflush_vld;
    output  logic                                 vme_lsuflush_rdy;
  // ZVT retire
    output logic                                  vmeRtVld;
    output VMERT_t                                vmeRt;
    input  logic                                  vmeRtRdy;
`endif
// RT to XRF. 
    output  logic         [`NUM_RT_UOP-1:0]       rt_xrf_valid_rvv2rvs;
    output  RT2RVS_t      [`NUM_RT_UOP-1:0]       rt_rvs_rvv2rvs;
    input   logic         [`NUM_RT_UOP-1:0]       rt_rvs_ready_rvs2rvv;

// RT to FRF. 
`ifdef ZVE32F_ON
    output  logic [`NUM_RT_UOP-1:0]                     async_frd_valid;
  `ifdef TB_SUPPORT
    output  logic [`NUM_RT_UOP-1:0][`PC_WIDTH-1:0]      async_frd_pc;
  `endif
    output  logic [`NUM_RT_UOP-1:0][`REGIDX_WIDTH-1:0]  async_frd_addr;
    output  logic [`NUM_RT_UOP-1:0][`XLEN-1:0]          async_frd_data;
    input   logic [`NUM_RT_UOP-1:0]                     async_frd_ready;
`endif

// RT to VCSR.vxsat
    output  logic                                 wr_vxsat_valid;
    output  logic         [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat;
    input   logic                                 wr_vxsat_ready;

`ifdef ZVE32F_ON
// RT to FCSR
    output  logic                                 rt2fcsr_write_valid;
    output  RVFEXP_t                              rt2fcsr_write_data;
    input   logic                                 fcsr2rt_write_ready;
`endif

// exception handler
  // trap signal handshake
    input   logic                                 trap_valid_rvs2rvv;
    output  logic                                 trap_ready_rvv2rvs;    
  // the vcsr of last retired uop in last cycle
    output  logic                                 vcsr_valid;
    output  RVVConfigState                        vector_csr;
    input   logic                                 vcsr_ready;

// Retire information:
// In verification testbenches, the port is widened to include both execution
// retirement (NUM_RT_UOP) and decode bypass retirement for reserved instructions
// (NUM_DE_INST).
// For synthesis, fallback to the base NUM_RT_UOP lanes required by the scalar
// RetirementBuffer.
  `ifdef TB_SUPPORT
    output  logic     [`NUM_RT_UOP+`NUM_DE_INST-1:0]  rd_valid_rob2rt_o;
    output  ROB2RT_t  [`NUM_RT_UOP+`NUM_DE_INST-1:0]  rd_rob2rt_o;
  `else
    output  logic     [`NUM_RT_UOP-1:0]               rd_valid_rob2rt_o;
    output  ROB2RT_t  [`NUM_RT_UOP-1:0]               rd_rob2rt_o;
  `endif
    
// rvv_backend is not active.(IDLE)
    output  logic                                 rvv_idle;

// ---internal signals definition-------------------------------------
  // RVV frontend to command queue
    logic         [`ISSUE_LANE-1:0]       insts_ready;  
    logic         [$clog2(`CQ_DEPTH):0]   used_count_cq; 
  // Command queue to Decode in DE1 stage
    logic         [`NUM_DE_INST-1:0]      inst_valid_cq2de;
    RVVCmd        [`NUM_DE_INST-1:0]      inst_cq2de;
    logic                                 fifo_empty_cq2de;
    logic         [`NUM_DE_INST-1:0]      fifo_almost_empty_cq2de;
    logic         [`NUM_DE_INST-1:0]      pop_de2cq;

    logic         [`NUM_DE_INST-1:0]      lcmd_valid_de2lcq;
    LCMD_t        [`NUM_DE_INST-1:0]      lcmd_de2lcq;
  `ifdef TB_SUPPORT
    logic         [`NUM_DE_INST-1:0]      de2rvvi_valid;
    ROB2RT_t      [`NUM_DE_INST-1:0]      de2rvvi_data;
  `endif
  // Legal command queue to Decode in DE2 stage
    logic         [`NUM_DE_INST-1:0]      lcmd_valid_lcq2de;
    LCMD_t        [`NUM_DE_INST-1:0]      lcmd_lcq2de;
    logic                                 fifo_empty_lcq2de;
    logic         [`NUM_DE_INST-1:0]      fifo_almost_empty_lcq2de;
    logic         [`NUM_DE_INST-1:0]      fifo_almost_full_lcq2de;
    logic         [`NUM_DE_INST-1:0]      pop_de2lcq;
  // Decode to uop queue
    logic         [`NUM_DE_UOP-1:0]       push_de2uq;
    UOP_QUEUE_t   [`NUM_DE_UOP-1:0]       uop_de2uq;
    logic         [`NUM_DE_UOP-1:0]       uq_ready;
  // Uop queue to dispatch
    logic                                 uq_empty;
    logic         [`NUM_DP_UOP-1:0]       uq_almost_empty;
    logic         [`NUM_DP_UOP-1:0]       uop_valid_uop2dp;
    UOP_QUEUE_t   [`NUM_DP_UOP-1:0]       uop_uop2dp;
    logic         [`NUM_DP_UOP-1:0]       uop_ready_dp2uop;

  // Dispatch to RS
    // ALU_RS
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2alu;
    ALU_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2alu;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_alu2dp;
    // PMTRDT_RS  
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2pmtrdt;
    PMT_RDT_RS_t  [`NUM_DP_UOP-1:0]       rs_dp2pmtrdt;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_pmtrdt2dp;
    // MUL_RS
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2mul;
    MUL_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2mul;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_mul2dp;
    // DIV_RS
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2div;
    DIV_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2div;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_div2dp;
`ifdef ZVE32F_ON
    // FMA_RS
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2falu;
    FALU_RS_t     [`NUM_DP_UOP-1:0]       rs_dp2falu;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_falu2dp;
`endif
`ifdef ZVT_ON
    // ZVT_RS
    logic         [`NUM_DP_UOP-1:0]       zvt_rs_almost_full;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2zvt;
    ZVT_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2zvt;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_zvt2dp;
`endif
    // LSU_RS
    logic                                 lsu_rs_empty;
    logic         [`NUM_LSU-1:0]          lsu_rs_almost_empty;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_dp2lsu;
    UOP_RVV2LSU_t [`NUM_DP_UOP-1:0]       rs_dp2lsu;
    logic         [`NUM_DP_UOP-1:0]       rs_ready_lsu2dp;
    // LSU MAP INFO
    logic         [`NUM_DP_UOP-1:0]       mapinfo_valid_dp2lsu;
    LSU_MAP_INFO_t  [`NUM_DP_UOP-1:0]     mapinfo_dp2lsu;
    logic         [`NUM_DP_UOP-1:0]       mapinfo_ready_lsu2dp;
  // Dispatch to ROB
    logic         [`NUM_DP_UOP-1:0]       uop_valid_dp2rob;
    DP2ROB_t      [`NUM_DP_UOP-1:0]       uop_dp2rob;
    logic         [`NUM_DP_UOP-1:0]       uop_ready_rob2dp;
    logic         [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2dp;
  
  // RS to excution unit
  // ALU_RS to ALU
    logic         [`NUM_ALU-1:0]          pop_alu2rs;
    logic         [`NUM_ALU-1:0]          uop_valid_rs2alu;
    ALU_RS_t      [`NUM_ALU-1:0]          uop_rs2alu;
    logic         [`NUM_ALU-1:0]          fifo_almost_empty_rs2alu;
  // PMTRDT_RS to PMTRDT
    logic         [`NUM_PMTRDT-1:0]       pop_pmtrdt2rs;
    PMT_RDT_RS_t  [`NUM_PMTRDT-1:0]       uop_rs2pmtrdt;
    logic         [`NUM_PMTRDT-1:0]       fifo_almost_empty_rs2pmtrdt;
  // MUL_RS to MUL
    logic         [`NUM_MUL-1:0]          pop_mul2rs;
    MUL_RS_t      [`NUM_MUL-1:0]          uop_rs2mul;
    logic                                 fifo_empty_rs2mul;
    logic         [`NUM_MUL-1:0]          fifo_almost_empty_rs2mul;
  // DIV_RS to DIV
    logic         [`NUM_DIV-1:0]          pop_div2rs;
    logic         [`NUM_DIV-1:0]          uop_valid_rs2div;
    DIV_RS_t      [`NUM_DIV-1:0]          uop_rs2div;
    logic         [`NUM_DIV-1:0]          fifo_almost_empty_rs2div;
`ifdef ZVE32F_ON
  // FALU_RS to FALU
    logic         [`NUM_FALU-1:0]         pop_falu2rs;
    logic         [`NUM_FALU-1:0]         uop_valid_rs2falu;
    FALU_RS_t     [`NUM_FALU-1:0]         uop_rs2falu;
    logic         [`NUM_FALU-1:0]         fifo_almost_empty_rs2falu;
`endif
`ifdef ZVT_ON
  // ZVT_RS to ZVT
    logic         [`ZVT_LMUL-1:0]         pop_zvt2rs;
    logic         [`ZVT_LMUL-1:0]         uop_valid_rs2zvt;
    ZVT_RS_t      [`ZVT_LMUL-1:0]         uop_rs2zvt;
    logic         [`ZVT_LMUL-1:0]         fifo_almost_empty_rs2zvt;
`endif
  // LSU mapinfo
    logic         [`NUM_LSU-1:0]          mapinfo_valid;
    LSU_MAP_INFO_t  [`NUM_LSU-1:0]        mapinfo;
    logic         [`NUM_LSU-1:0]          pop_mapinfo;
    logic                                 mapinfo_empty;
    logic         [`NUM_LSU-1:0]          mapinfo_almost_empty;
  // LSU result
    logic         [`NUM_LSU-1:0]          lsu_res_valid;
    UOP_LSU_t     [`NUM_LSU-1:0]          lsu_res;
    logic         [`NUM_LSU-1:0]          pop_lsu_res;
    logic                                 lsu_res_empty;
    logic         [`NUM_LSU-1:0]          lsu_res_almost_full;
    logic         [`NUM_LSU-1:0]          lsu_res_almost_empty;
    logic         [`NUM_LSU-1:0]          uop_lsu_valid;
    UOP_LSU_t     [`NUM_LSU-1:0]          uop_lsu;
    logic         [`NUM_LSU-1:0]          uop_lsu_ready;
    logic                                 trap_valid_rmp2rob;
    logic         [`ROB_DEPTH_WIDTH-1:0]  trap_rob_entry_rmp2rob;

  // execution unit submit result to ROB
  // PU to ARB
    logic         [`NUM_PU-1:0]           res_valid_pu2arb;
    PU2ROB_t      [`NUM_PU-1:0]           res_pu2arb;
    logic         [`NUM_PU-1:0]           res_ready_arb2pu;
  // ARB
  `ifdef ARBITER_ON
    logic     [`NUM_PU-1:`NUM_PU_NOPINGPONG]  req_ari;
    logic     [`NUM_PU-1:0]                   req_arb;
    logic     [`NUM_PU-1:0]                   grant_arb;
    PU2ROB_t  [`NUM_PU-1:`NUM_PU_NOPINGPONG]  item_ari; 
    PU2ROB_t  [`NUM_PU-1:0]                   item_arb; 
    logic     [`NUM_PU-1:`NUM_PU_NOPINGPONG]  res_ff_empty;
  `endif
  // ARB to ROB
    logic         [`NUM_SMPORT-1:0]                   res_valid_arb2rob;
    PU2ROB_t      [`NUM_SMPORT-1:0]                   res_arb2rob;
    logic         [`NUM_SMPORT-1:0][$clog2(`VLENB):0] res_ff_tail_index;
  // ALU result
    logic         [`NUM_ALU-1:0]          res_valid_alu;
    PU2ROB_t      [`NUM_ALU-1:0]          res_alu;
    logic         [`NUM_ALU-1:0]          res_ready_alu;
  // PMTRDT result
    logic         [`NUM_PMTRDT-1:0]       res_valid_pmtrdt;
    PU2ROB_t      [`NUM_PMTRDT-1:0]       res_pmtrdt;
    logic         [`NUM_PMTRDT-1:0]       res_ready_pmtrdt;
  // MUL result
    logic         [`NUM_MUL-1:0]          res_valid_mul;
    PU2ROB_t      [`NUM_MUL-1:0]          res_mul;
    logic         [`NUM_MUL-1:0]          res_ready_mul;
  // DIV result
    logic         [`NUM_DIV-1:0]          res_valid_div;
    PU2ROB_t      [`NUM_DIV-1:0]          res_div;
    logic         [`NUM_DIV-1:0]          res_ready_div;
`ifdef ZVE32F_ON
  // FALU result
    logic         [`NUM_FALU-1:0]         res_valid_falu;
    PU2ROB_t      [`NUM_FALU-1:0]         res_falu;
    logic         [`NUM_FALU-1:0]         res_ready_falu;
`endif
  // LSU result
    logic         [`NUM_LSU-1:0]          	    res_valid_lsu;
    PU2ROB_t      [`NUM_LSU-1:0]          	    res_lsu;
    logic         [`NUM_LSU-1:0][$clog2(`VLENB):0]  ff_tail_index;
    logic         [`NUM_LSU-1:0]          	    res_ready_lsu;
`ifdef ZVT_ON
  // VME2RVV
    logic                                 res_vme2rvv_vld;
    PU2ROB_t                              res_vme2rvv;
    logic                                 res_vme2rvv_rdy;
  // ZVT to Retire
    logic                                 zvtFpexpVld;
    RVFEXP_t                              zvtFpexp;
    logic                                 zvtFpexpRdy;
`endif
  // DP to VRF
    logic [`NUM_DP_VRF-1:0][`REGIDX_WIDTH-1:0]  rd_index_dp2vrf;          
    logic [`NUM_DP_VRF-1:0][`VLEN-1:0]          rd_data_vrf2dp;
    logic [`VLEN-1:0]                           v0_mask_vrf2dp;
  // PMT to VRF
    logic [`REGIDX_WIDTH-1:0]             rd_index_pmt2vrf;          
    logic [`VLEN-1:0]                     rd_data_vrf2pmt;
  // ROB to dispatch
    ROB2DP_t      [`ROB_DEPTH-1:0]        uop_rob2dp;
    logic                                 rob_empty;
  // ROB to RT
    logic         [`NUM_RT_UOP-1:0]       rd_valid_rob2rt;
    ROB2RT_t      [`NUM_RT_UOP-1:0]       rd_rob2rt;
    logic         [`NUM_RT_UOP-1:0]       rd_ready_rt2rob;
    logic         [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2rt;
  `ifdef TB_SUPPORT
    logic         [`NUM_RT_UOP-1:0]       rt2rvvi_valid;
    ROB2RT_t      [`NUM_RT_UOP-1:0]       rt2rvvi_data;
  `endif
  // RT to VRF
    logic         [`NUM_RT_UOP-1:0]       wr_valid_rt2vrf;
    RT2VRF_t      [`NUM_RT_UOP-1:0]       wr_data_rt2vrf;
  
  // trap handler
    logic                                 trap_en;
    logic                                 is_trapping;
    logic                                 trap_ready_rob2rmp;   
    logic                                 trap_flush_rvv;

`ifdef ZVT_ON
  // ZVT busy
    logic                                 zvtBusy;
`endif

  `ifdef TB_SUPPORT
    // 32 VRF value.
    logic    [`NUM_VRF-1:0][`VLEN-1:0]    vrf_data;
  `endif

    genvar                                i;

// ---code start------------------------------------------------------
  // Command queue
    multi_fifo #(
        .T            (RVVCmd),
        .M            (`ISSUE_LANE),
        .N            (`NUM_DE_INST),
        .ASYNC_RSTN   (1'b1),
        .DEPTH        (`CQ_DEPTH),
        .CHAOS_PUSH   (1'b1)
    ) u_command_queue (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (insts_valid_rvs2cq & insts_ready_cq2rvs),
        .pushRdy      (insts_ready),
        .datain       (insts_rvs2cq),
      // read
        .pop          (pop_de2cq),
        .dataout      (inst_cq2de),
      // fifo status
        .empty        (fifo_empty_cq2de),
        .full         (),
        .almost_full  (),
        .almost_empty (fifo_almost_empty_cq2de),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  (used_count_cq)
    );

    assign insts_ready_cq2rvs = is_trapping ? 'b0 : insts_ready;
    
    // output the remaining count in CQ
    assign remaining_count_cq2rvs = is_trapping ? 'b0 : `CQ_DEPTH - used_count_cq;

  // Decode unit in DE1 stage
    assign inst_valid_cq2de = ~(fifo_almost_empty_cq2de | fifo_almost_full_lcq2de);
    assign pop_de2cq = inst_valid_cq2de; 
    
    rvv_backend_decode #(
    ) u_decode_de1 (
      .inst_valid         (inst_valid_cq2de),
      .inst               (inst_cq2de),
      .lcmd_valid         (lcmd_valid_de2lcq),
      .lcmd               (lcmd_de2lcq)
     `ifdef TB_SUPPORT
      ,.de2rvvi_valid     (de2rvvi_valid),
      .de2rvvi_data       (de2rvvi_data)
     `endif
    );
  
  // Legal Command Queue
    multi_fifo #(
        .T                (LCMD_t),
        .M                (`NUM_DE_INST),
        .N                (`NUM_DE_INST),
        .ASYNC_RSTN       (1'b1),
        .DEPTH            (`LCQ_DEPTH),
        .CHAOS_PUSH       (1'b1)
    ) u_legal_command_queue (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (lcmd_valid_de2lcq),
        .pushRdy          (),
        .datain           (lcmd_de2lcq),
      // read
        .pop              (pop_de2lcq),
        .dataout          (lcmd_lcq2de),
      // fifo status
        .full             (),
        .almost_full      (fifo_almost_full_lcq2de),
        .empty            (fifo_empty_lcq2de),
        .almost_empty     (fifo_almost_empty_lcq2de),
        .clear            (trap_flush_rvv),
        .fifo_data        (),
        .wptr             (),
        .rptr             (),
        .entry_count      ()
    );

  // Decode unit in DE2 stage
    assign lcmd_valid_lcq2de = ~fifo_almost_empty_lcq2de;

    rvv_backend_decode_de2 #(
    ) u_decode_de2 (
      .clk                (clk),
      .rst_n              (rst_n),
      .lcmd_valid         (lcmd_valid_lcq2de),
      .lcmd               (lcmd_lcq2de),
      .pop                (pop_de2lcq),
      .push               (push_de2uq),
      .uop                (uop_de2uq),
      .uq_ready           (uq_ready),
      .trap_flush_rvv     (trap_flush_rvv)
    );

  // Uop queue
    multi_fifo #(
        .T                (UOP_QUEUE_t),
        .M                (`NUM_DE_UOP),
        .N                (`NUM_DP_UOP),
        .ASYNC_RSTN       (1'b1),
        .DEPTH            (`UQ_DEPTH)
    ) u_uop_queue (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (push_de2uq),
        .pushRdy          (uq_ready),
        .datain           (uop_de2uq),
      // read
        .pop              (uop_valid_uop2dp & uop_ready_dp2uop),
        .dataout          (uop_uop2dp),
      // fifo status
        .full             (),
        .almost_full      (),
        .empty            (uq_empty),
        .almost_empty     (uq_almost_empty),
        .clear            (trap_flush_rvv),
        .fifo_data        (),
        .wptr             (),
        .rptr             (),
        .entry_count      ()
    );
   
    assign uop_valid_uop2dp = ~uq_almost_empty;

  `ifdef ASSERT_ON
    `ifdef  DISPATCH3
      PushToUopQueue: `rvv_expect(push_de2uq inside {6'b111111, 6'b011111, 6'b001111, 6'b000111, 6'b000011, 6'b000001, 6'b000000})
        else $error("Push to uops queue out-of-order:      0", $sampled(push_de2uq));

      PopFromUopQueue: `rvv_expect((uop_valid_uop2dp & uop_ready_dp2uop) inside {3'b111, 3'b011, 3'b001,3'b000})
        else $error("Pop from uops queue out-of-order:   0", $sampled(uop_valid_uop2dp & uop_ready_dp2uop));
    `else // DISPATCH2
      PushToUopQueue: `rvv_expect(push_de2uq inside {4'b1111, 4'b0111, 4'b0011, 4'b0001, 4'b0000})
        else $error("Push to uops queue out-of-order:    0", $sampled(push_de2uq));

      PopFromUopQueue: `rvv_expect((uop_valid_uop2dp & uop_ready_dp2uop) inside {2'b11, 2'b01, 2'b00})
        else $error("Pop from uops queue out-of-order:  0", $sampled(uop_valid_uop2dp & uop_ready_dp2uop));
    `endif
  `endif // ASSERT_ON

  // Dispatch unit
    rvv_backend_dispatch #(
    ) u_dispatch (
      // global
        .clk                  (clk),
        .rst_n                (rst_n),
      // Uop queue to dispatch
        .uop_valid_uop2dp     (uop_valid_uop2dp),
        .uop_uop2dp           (uop_uop2dp),
        .uop_ready_dp2uop     (uop_ready_dp2uop),
      // Dispatch to RS
        // ALU_RS
        .rs_valid_dp2alu      (rs_valid_dp2alu),
        .rs_dp2alu            (rs_dp2alu),
        .rs_ready_alu2dp      (rs_ready_alu2dp),
        // PMTRDT_RS 
        .rs_valid_dp2pmtrdt   (rs_valid_dp2pmtrdt),
        .rs_dp2pmtrdt         (rs_dp2pmtrdt),
        .rs_ready_pmtrdt2dp   (rs_ready_pmtrdt2dp),
        // MUL_RS
        .rs_valid_dp2mul      (rs_valid_dp2mul),
        .rs_dp2mul            (rs_dp2mul),
        .rs_ready_mul2dp      (rs_ready_mul2dp),
        // DIV_RS
        .rs_valid_dp2div      (rs_valid_dp2div),
        .rs_dp2div            (rs_dp2div),
        .rs_ready_div2dp      (rs_ready_div2dp),
        `ifdef ZVE32F_ON
        // FALU_RS
        .rs_valid_dp2falu      (rs_valid_dp2falu),
        .rs_dp2falu            (rs_dp2falu),
        .rs_ready_falu2dp      (rs_ready_falu2dp),
        `endif
        `ifdef ZVT_ON
        // ZVT_RS
        .rs_valid_dp2zvt       (rs_valid_dp2zvt),
        .rs_dp2zvt             (rs_dp2zvt),
        .rs_ready_zvt2dp       (rs_ready_zvt2dp),
        `endif
        // LSU_RS
        .rs_valid_dp2lsu      (rs_valid_dp2lsu),
        .rs_dp2lsu            (rs_dp2lsu),
        .rs_ready_lsu2dp      (rs_ready_lsu2dp),
        // LSU MAP INFO
        .mapinfo_valid_dp2lsu (mapinfo_valid_dp2lsu),
        .mapinfo_dp2lsu       (mapinfo_dp2lsu),
        .mapinfo_ready_lsu2dp (mapinfo_ready_lsu2dp),
      // Dispatch to ROB
        .uop_valid_dp2rob     (uop_valid_dp2rob),
        .uop_dp2rob           (uop_dp2rob),
        .uop_ready_rob2dp     (uop_ready_rob2dp),
        .rob_entry_rob2dp     (rob_entry_rob2dp),
      // VRF to dispatch
        .rd_index_dp2vrf      (rd_index_dp2vrf),
        .rd_data_vrf2dp       (rd_data_vrf2dp),
        .v0_mask_vrf2dp       (v0_mask_vrf2dp),
      // ROB to dispatch
        .rob_entry            (uop_rob2dp)
    );

  // RS, Reserve station
    // ALU RS
    multi_fifo #(
        .T            (ALU_RS_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_ALU),
        .DEPTH        (`ALU_RS_DEPTH),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1)
    ) u_alu_rs (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (rs_valid_dp2alu),
        .pushRdy      (rs_ready_alu2dp),
        .datain       (rs_dp2alu),
      // read
        .pop          (pop_alu2rs),
        .dataout      (uop_rs2alu),
      // fifo status
        .full         (),
        .almost_full  (),
        .empty        (),
        .almost_empty (fifo_almost_empty_rs2alu),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

  `ifdef ASSERT_ON
    PopFromAluRSQueue: `rvv_expect((pop_alu2rs) inside {2'b11, 2'b01, 2'b00})
      else $error("Pop from ALU Reservation Station out-of-order:  0", $sampled(pop_alu2rs));
  `endif // ASSERT_ON

    // PMTRDT RS, Permutation + Reduction
    multi_fifo #(
        .T                (PMT_RDT_RS_t),
        .M                (`NUM_DP_UOP),
        .N                (`NUM_PMTRDT),
        .ASYNC_RSTN       (1'b1),
        .DEPTH            (`PMTRDT_RS_DEPTH),
        .CHAOS_PUSH       (1'b1)
    ) u_pmtrdt_rs (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (rs_valid_dp2pmtrdt),
        .pushRdy          (rs_ready_pmtrdt2dp),
        .datain           (rs_dp2pmtrdt),
      // read
        .pop              (pop_pmtrdt2rs),
        .dataout          (uop_rs2pmtrdt),
      // fifo status
        .full             (),
        .almost_full      (),
        .empty            (),
        .almost_empty     (fifo_almost_empty_rs2pmtrdt),
        .clear            (trap_flush_rvv),
        .fifo_data        (),
        .wptr             (),
        .rptr             (),
        .entry_count      ()
    );

  `ifdef ASSERT_ON
     PopFromPmtrdtRSQueue: `rvv_expect((pop_pmtrdt2rs) inside {1'b1, 1'b0})
       else $error("Pop from PMTRDT Reservation Station out-of-order: 0", $sampled(pop_pmtrdt2rs));
  `endif // ASSERT_ON

    // MUL RS, Multiply + Multiply-accumulate
    multi_fifo #(
        .T              (MUL_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_MUL),
        .DEPTH          (`MUL_RS_DEPTH),
        .ASYNC_RSTN     (1'b1),
        .CHAOS_PUSH     (1'b1)
    ) u_mul_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2mul),
        .pushRdy        (rs_ready_mul2dp),
        .datain         (rs_dp2mul),
      // read
        .pop            (pop_mul2rs),
        .dataout        (uop_rs2mul),
      // fifo status
        .full           (),
        .almost_full    (),
        .empty          (fifo_empty_rs2mul),
        .almost_empty   (fifo_almost_empty_rs2mul),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

  `ifdef ASSERT_ON
     PopFromMulRSQueue: `rvv_expect((pop_mul2rs) inside {2'b11, 2'b01, 2'b00})
       else $error("Pop from MUL Reservation Station out-of-order: %2b", $sampled(pop_mul2rs));
  `endif // ASSERT_ON

    // DIV RS
    multi_fifo #(
        .T              (DIV_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_DIV),
        .DEPTH          (`DIV_RS_DEPTH),
        .ASYNC_RSTN     (1'b1),
        .CHAOS_PUSH     (1'b1)
    ) u_div_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2div),
        .pushRdy        (rs_ready_div2dp),
        .datain         (rs_dp2div),
      // read
        .pop            (pop_div2rs),
        .dataout        (uop_rs2div),
      // fifo status
        .full           (),
        .almost_full    (),
        .empty          (),
        .almost_empty   (fifo_almost_empty_rs2div),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

  `ifdef ASSERT_ON
     PopFromDivRSQueue: `rvv_expect((pop_div2rs) inside {1'b1, 1'b0})
       else $error("Pop from DIV Reservation Station out-of-order: 0", $sampled(pop_div2rs));
  `endif // ASSERT_ON

  `ifdef ZVE32F_ON
    // FALU RS
    multi_fifo #(
        .T              (FALU_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_FALU),
        .ASYNC_RSTN     (1'b1),
        .DEPTH          (`FALU_RS_DEPTH),
        .CHAOS_PUSH     (1'b1)
    ) u_falu_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2falu),
        .pushRdy        (rs_ready_falu2dp),
        .datain         (rs_dp2falu),
      // read
        .pop            (pop_falu2rs),       
        .dataout        (uop_rs2falu),       
      // fifo status
        .full           (),
        .almost_full    (),
        .empty          (),
        .almost_empty   (fifo_almost_empty_rs2falu),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );
  `endif

  `ifdef ZVT_ON
    // ZVT RS
    multi_fifo #(
        .T              (ZVT_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`ZVT_LMUL),
        .ASYNC_RSTN     (1'b1),
        .DEPTH          (`ZVT_RS_DEPTH),
        .CHAOS_PUSH     (1'b1)
    ) u_zvt_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2zvt),
        .datain         (rs_dp2zvt),
        .pushRdy        (),
      // read
        .pop            (pop_zvt2rs),       
        .dataout        (uop_rs2zvt),       
      // fifo status
        .full           (),
        .almost_full    (zvt_rs_almost_full),
        .empty          (),
        .almost_empty   (fifo_almost_empty_rs2zvt),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

    assign rs_ready_zvt2dp  = ~zvt_rs_almost_full;
  `endif

    // LSU RS pop logic
    logic [`NUM_LSU-1:0] lsu_rs_pop;
    generate
        for (i=0; i<`NUM_LSU; i++) begin: gen_lsu_rs_pop
            if (i==0) begin: gen_first
                assign lsu_rs_pop[i] = uop_lsu_valid_rvv2lsu[i] & uop_lsu_ready_lsu2rvv[i];
            end else begin: gen_i
                assign lsu_rs_pop[i] = lsu_rs_pop[i-1] & uop_lsu_valid_rvv2lsu[i] & uop_lsu_ready_lsu2rvv[i];
            end
        end
    endgenerate

    // LSU RS
    multi_fifo #(
        .T            (UOP_RVV2LSU_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_LSU),
        .DEPTH        (`LSU_RS_DEPTH),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_rs (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (rs_valid_dp2lsu),
        .pushRdy      (rs_ready_lsu2dp),
        .datain       (rs_dp2lsu),
      // read
        .pop          (lsu_rs_pop),
        .dataout      (uop_lsu_rvv2lsu),
      // fifo status
        .full         (),
        .almost_full  (),
        .empty        (lsu_rs_empty),
        .almost_empty (lsu_rs_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );
    // output valid and data to LSU
    logic [`NUM_LSU-1:0] lsu_rs_valid_pre;
    assign lsu_rs_valid_pre = ~lsu_rs_almost_empty;
    generate
        for (i=0; i<`NUM_LSU; i++) begin: gen_lsu_valid
            if (i==0) begin: gen_first
                assign uop_lsu_valid_rvv2lsu[i] = lsu_rs_valid_pre[i];
            end else begin: gen_i
                assign uop_lsu_valid_rvv2lsu[i] = lsu_rs_valid_pre[i] & (uop_lsu_valid_rvv2lsu[i-1] & uop_lsu_ready_lsu2rvv[i-1]);
            end
        end
    endgenerate

    // LSU MAP INFO
    multi_fifo #(
        .T            (LSU_MAP_INFO_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_LSU),
        .DEPTH        (`LSUMAP_DEPTH),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_map_info (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (mapinfo_valid_dp2lsu),
        .pushRdy      (mapinfo_ready_lsu2dp),
        .datain       (mapinfo_dp2lsu),
      // read
        .pop          (pop_mapinfo),
        .dataout      (mapinfo),
      // fifo status
        .full         (),
        .almost_full  (),
        .empty        (mapinfo_empty),
        .almost_empty (mapinfo_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

  // trap handler
    // make sure all lsu uops before the trapping uop have been pushed into LSU_RES_FIFO 
    assign trap_en = trap_valid_rvs2rvv & (uop_lsu_valid_lsu2rvv=='b0) & (!lsu_res_almost_full[0]) & (!is_trapping);

    cdffr
    trap_valid
    (
      .clk            (clk),
      .rst_n          (rst_n),
      .e              (trap_en),
      .c              (trap_ready_rvv2rvs),
      .d              (1'b1),
      .q              (is_trapping)
    );

  // LSU feedback result
    assign uop_lsu_valid = trap_en ? 'b1 : uop_lsu_valid_lsu2rvv;
    
    generate
      assign uop_lsu[0].trap_valid = trap_en;
      assign uop_lsu[0].uop_lsu2rvv = trap_en ? 'b0 : uop_lsu_lsu2rvv[0];
      
      for (i=1;i<`NUM_LSU;i++) begin: get_uop_lsu
        assign uop_lsu[i].trap_valid = 'b0;
        assign uop_lsu[i].uop_lsu2rvv = uop_lsu_lsu2rvv[i];
      end
    endgenerate

    multi_fifo #(
        .T            (UOP_LSU_t),
        .M            (`NUM_LSU),
        .N            (`NUM_LSU),
        .DEPTH        (`NUM_LSU*2),
        .ASYNC_RSTN   (1'b1)
    ) u_lsu_res (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (uop_lsu_valid&uop_lsu_ready_rvv2lsu),
        .pushRdy      (uop_lsu_ready),
        .datain       (uop_lsu),
      // read
        .pop          (pop_lsu_res),
        .dataout      (lsu_res),
      // fifo status
        .full         (),
        .almost_full  (lsu_res_almost_full),
        .empty        (lsu_res_empty),
        .almost_empty (lsu_res_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );
    // ready signal for LSU
    assign uop_lsu_ready_rvv2lsu = is_trapping ? 'b0 : uop_lsu_ready;

  // PU, Process unit
    // ALU
    assign uop_valid_rs2alu = ~fifo_almost_empty_rs2alu;
    rvv_backend_alu #(
    ) u_alu (
      // ALU_RS to ALU
        .clk                        (clk),
        .rst_n                      (rst_n),
        .pop                        (pop_alu2rs),
        .uop_valid                  (uop_valid_rs2alu),
        .uop                        (uop_rs2alu),
      // ALU to ROB  
        .result_valid               (res_valid_alu),
        .result                     (res_alu),
        .result_ready               (res_ready_alu),
      // trap-flush
        .trap_flush_rvv             (trap_flush_rvv)
    );

    // PMTRDT
    rvv_backend_pmtrdt #(
    ) u_pmtrdt (
        .clk                        (clk),
        .rst_n                      (rst_n),
      // PMTRDT_RS to PMTRDT
        .pop_ex2rs                  (pop_pmtrdt2rs),
        .pmtrdt_uop_rs2ex           (uop_rs2pmtrdt),
        .fifo_almost_empty_rs2ex    (fifo_almost_empty_rs2pmtrdt),
      // PMT to VRF
        .rd_index_pmt2vrf           (rd_index_pmt2vrf),
        .rd_data_vrf2pmt            (rd_data_vrf2pmt),
      // PMTRDT to ROB
        .result_valid_ex2rob        (res_valid_pmtrdt),
        .result_ex2rob              (res_pmtrdt),
        .result_ready_rob2ex        (res_ready_pmtrdt),
      // MISC
        .rob_entry_rob2rt           (rob_entry_rob2rt),
      // trap-flush
        .trap_flush_rvv             (trap_flush_rvv)
    );
    
    // MULMAC
    rvv_backend_mulmac #(
    ) u_mulmac (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .trap_flush_rvv             (trap_flush_rvv),
        .uop_valid_rs2ex            (~fifo_almost_empty_rs2mul),
        .mac_uop_rs2ex              (uop_rs2mul),
        .pop                        (pop_mul2rs),
        .res_valid_ex2rob           (res_valid_mul),
        .res_ex2rob                 (res_mul),
        .res_ready_rob2ex           (res_ready_mul)
    );
    
    // DIV
    assign uop_valid_rs2div = ~fifo_almost_empty_rs2div;
    rvv_backend_div u_div
    (  
      .clk                          (clk),
      .rst_n                        (rst_n),
      // DIV_RS to DIV
      .pop                          (pop_div2rs),
      .uop_valid                    (uop_valid_rs2div),
      .uop                          (uop_rs2div),
      // DIV to ROB
      .result_valid                 (res_valid_div),
      .result                       (res_div),
      .result_ready                 (res_ready_div),
      // trap-flush
      .trap_flush_rvv               (trap_flush_rvv)
    );

  `ifdef ZVE32F_ON
    // FALU
    assign uop_valid_rs2falu = ~fifo_almost_empty_rs2falu;
    rvv_backend_falu u_falu
    (  
      .clk                          (clk),
      .rst_n                        (rst_n),
      // FALU_RS to FALU
      .pop                          (pop_falu2rs),
      .uop_valid                    (uop_valid_rs2falu),
      .uop                          (uop_rs2falu),
      // FALU to ROB
      .result_valid                 (res_valid_falu),
      .result                       (res_falu),
      .result_ready                 (res_ready_falu),
      // trap-flush
      .trap_flush_rvv               (trap_flush_rvv)
    );
   `endif

  `ifdef ZVT_ON
    // ZVT
    assign uop_valid_rs2zvt = ~fifo_almost_empty_rs2zvt;
    zvt vme
    (  
      .clk                          (clk),
      .rst_n                        (rst_n),
      .uopVld                       (uop_valid_rs2zvt),
      .uop                          (uop_rs2zvt),
      .uopRdy                       (pop_zvt2rs),
      .res_vme2rvv_vld              (res_vme2rvv_vld),
      .res_vme2rvv                  (res_vme2rvv),
      .res_vme2rvv_rdy              (res_vme2rvv_rdy),
      .uop_vme2lsu_vld              (uop_vme2lsu_vld),
      .uop_vme2lsu                  (uop_vme2lsu),
      .uop_vme2lsu_rdy              (uop_vme2lsu_rdy),
      .uop_lsu2vme_vld              (uop_lsu2vme_vld),
      .uop_lsu2vme                  (uop_lsu2vme),
      .uop_lsu2vme_rdy              (uop_lsu2vme_rdy),
      .vmeRtVld                     (vmeRtVld),
      .vmeRt                        (vmeRt),
      .vmeRtRdy                     (vmeRtRdy),
      .fpexpVld                     (zvtFpexpVld),
      .fpexp                        (zvtFpexp),
      .fpexpRdy                     (zvtFpexpRdy),
      .flush                        (trap_flush_rvv),
      .zvtBusy                      (zvtBusy)
    );
   `endif

    // LSU remap
    assign mapinfo_valid = ~mapinfo_almost_empty;
    assign lsu_res_valid = ~lsu_res_almost_empty;
    rvv_backend_lsu_remap
    u_lsu_remap
    (
      .mapinfo_valid                (mapinfo_valid),
      .mapinfo                      (mapinfo),
      .pop_mapinfo                  (pop_mapinfo),
      .lsu_res_valid                (lsu_res_valid),
      .lsu_res                      (lsu_res),
      .pop_lsu_res                  (pop_lsu_res),
      .result_valid                 (res_valid_lsu),
      .result                       (res_lsu),      
      .ff_tail_index                (ff_tail_index),
      .result_ready                 (res_ready_lsu),
      .trap_valid_rmp2rob           (trap_valid_rmp2rob),
      .trap_rob_entry_rmp2rob       (trap_rob_entry_rmp2rob),
      .trap_ready_rob2rmp           (trap_ready_rob2rmp)  
    );

    assign res_valid_pu2arb = {
                              `ifdef ZVE32F_ON
                               res_valid_falu,
                              `endif
                               res_valid_div,
                               res_valid_pmtrdt,  
                               res_valid_mul,
                               res_valid_alu,
                              `ifdef ZVT_ON
                               res_vme2rvv_vld,
                              `endif
                               res_valid_lsu
                              };
                             
    assign res_pu2arb = {
                        `ifdef ZVE32F_ON
                         res_falu,
                        `endif
                         res_div,
                         res_pmtrdt,
                         res_mul,
                         res_alu,
                        `ifdef ZVT_ON
                         res_vme2rvv,
                        `endif
                         res_lsu
                        };

    assign {
           `ifdef ZVE32F_ON
            res_ready_falu,
           `endif
            res_ready_div,
            res_ready_pmtrdt,
            res_ready_mul,
            res_ready_alu,
           `ifdef ZVT_ON
            res_vme2rvv_rdy,
           `endif
            res_ready_lsu 
           } = res_ready_arb2pu;

`ifdef ARBITER_ON
    generate
      for(i=`NUM_PU_NOPINGPONG;i<`NUM_PU;i++) begin : gen_res_ff
        multi_fifo #(
            .T            (PU2ROB_t),
            .M            (1),
            .N            (1),
            .ASYNC_RSTN   (1'b1),
            .DEPTH        (2)
        ) u_res_ff (
          // global
            .clk          (clk),
            .rst_n        (rst_n),
          // write
            .push         (res_valid_pu2arb[i] & res_ready_arb2pu[i]),
            .pushRdy      (res_ready_arb2pu[i]),
            .datain       (res_pu2arb[i]),
          // read
            .pop          (grant_arb[i]),
            .dataout      (item_ari[i]),
          // fifo status
            .full         (),
            .almost_full  (),
            .empty        (res_ff_empty[i]),
            .almost_empty (),
            .clear        (trap_flush_rvv),
            .fifo_data    (),
            .wptr         (),
            .rptr         (),
            .entry_count  ()
        );

        assign req_ari[i] = !res_ff_empty[i];
      end
    endgenerate

    assign res_ready_arb2pu[`NUM_PU_NOPINGPONG-1:0] = grant_arb[`NUM_PU_NOPINGPONG-1:0] |
                                                      ~{
                                                      `ifdef ZVT_ON
                                                        res_vme2rvv,
                                                      `endif
                                                        res_valid_lsu};

    assign req_arb  = {req_ari, res_valid_pu2arb[`NUM_PU_NOPINGPONG-1:0]};

    assign item_arb = {item_ari, res_pu2arb[`NUM_PU_NOPINGPONG-1:0]};

    rvv_backend_arb u_arb(
      .clk                (clk),
      .rst_n              (rst_n),
      .req                (req_arb),
      .item               (item_arb),
      .ff_tail_index      (ff_tail_index),
      .grant              (grant_arb),
      .result_valid       (res_valid_arb2rob),
      .result             (res_arb2rob),
      .res_ff_tail_index  (res_ff_tail_index)
    );

`else
    assign res_valid_arb2rob = res_valid_pu2arb;
    assign res_arb2rob       = res_pu2arb;
    assign res_ff_tail_index = {'0, ff_tail_index};
    assign res_ready_arb2pu  = '1;
`endif

  // ROB, Re-Order Buffer
    rvv_backend_rob #(
    ) u_rob (
      // global signal
        .clk                    (clk),
        .rst_n                  (rst_n),
      // Dispatch to ROB
        .uop_valid_dp2rob       (uop_valid_dp2rob),
        .uop_dp2rob             (uop_dp2rob),
        .uop_ready_rob2dp       (uop_ready_rob2dp),
        .rob_empty              (rob_empty),
        .rob_entry_rob2dp       (rob_entry_rob2dp),
      // PU to ROB
        .wr_valid_pu2rob        (res_valid_arb2rob),
        .wr_pu2rob              (res_arb2rob),
        .ff_tail_index          (res_ff_tail_index),
      // ROB to RT
        .rd_valid_rob2rt        (rd_valid_rob2rt),
        .rd_rob2rt              (rd_rob2rt),
        .rd_ready_rt2rob        (rd_ready_rt2rob),
        .rob_entry_rob2rt       (rob_entry_rob2rt),
      // ROB to DP
        .uop_rob2dp             (uop_rob2dp),
      // Trap
      `ifdef ZVT_ON
        .vme_lsuflush_vld       (vme_lsuflush_vld),
        .vme_lsuflush_rdy       (vme_lsuflush_rdy),
      `endif
        .trap_valid_rmp2rob     (trap_valid_rmp2rob),
        .trap_rob_entry_rmp2rob (trap_rob_entry_rmp2rob),
        .trap_ready_rob2rmp     (trap_ready_rob2rmp),
        .trap_ready_rvv2rvs     (trap_ready_rvv2rvs),
        .trap_flush_rvv         (trap_flush_rvv)
    );

  // RT, Retire
    rvv_backend_retire #(
    ) u_retire (
      // ROB to RT
        .rob2rt_write_valid     (rd_valid_rob2rt),
        .rob2rt_write_data      (rd_rob2rt),
        .rt2rob_write_ready     (rd_ready_rt2rob),
      // RT to RVS.XRF/FRF
        .rt2xrf_write_valid     (rt_xrf_valid_rvv2rvs),
        .rt2rvs_write_data      (rt_rvs_rvv2rvs),
        .rvs2rt_write_ready     (rt_rvs_ready_rvs2rvv),
      `ifdef ZVE32F_ON
        .rt2frf_write_valid     (async_frd_valid),
        .frf2rt_write_ready     (async_frd_ready),
      `endif
      // RT to VRF
        .rt2vrf_write_valid     (wr_valid_rt2vrf),
        .rt2vrf_write_data      (wr_data_rt2vrf),
      // update vxsat
        .rt2vxsat_write_valid   (wr_vxsat_valid),
        .rt2vxsat_write_data    (wr_vxsat),
        .vxsat2rt_write_ready   (wr_vxsat_ready),
      `ifdef ZVT_ON
        .zvtFpexpVld            (zvtFpexpVld),
        .zvtFpexp               (zvtFpexp),
        .zvtFpexpRdy            (zvtFpexpRdy),
      `endif
      `ifdef ZVE32F_ON
      // update FCSR
        .rt2fcsr_write_valid    (rt2fcsr_write_valid),
        .rt2fcsr_write_data     (rt2fcsr_write_data),
        .fcsr2rt_write_ready    (fcsr2rt_write_ready),
      `endif
      // write to update vcsr   
        .rt2vcsr_write_valid    (vcsr_valid),
        .rt2vcsr_write_data     (vector_csr),
        .vcsr2rt_write_ready    (vcsr_ready)
      // Retire information for RVVI.
      `ifdef TB_SUPPORT
        ,.vrf_data              (vrf_data),
        .rt2rvvi_valid          (rt2rvvi_valid),
        .rt2rvvi_data           (rt2rvvi_data)
      `endif
    );
    
  `ifdef ZVE32F_ON
    // write back FRF.
    generate
      for(i=0; i<`NUM_RT_UOP; i++) begin: gen_rt_frf
      `ifdef TB_SUPPORT
        assign async_frd_pc[i]   = rt_rvs_rvv2rvs[i].uop_pc;
      `endif
        assign async_frd_addr[i] = rt_rvs_rvv2rvs[i].rt_index;
        assign async_frd_data[i] = rt_rvs_rvv2rvs[i].rt_data;
      end
    endgenerate
  `endif

  // VRF, Vector Register File
    rvv_backend_vrf #(
    ) u_vrf (
      // global signal
        .clk              (clk),
        .rst_n            (rst_n),
      // DP to VRF
        .dp2vrf_rd_index  (rd_index_dp2vrf),
      // VRF to DP
        .vrf2dp_rd_data   (rd_data_vrf2dp),
        .vrf2dp_v0_data   (v0_mask_vrf2dp),
      // PMT to VRF
        .pmt2vrf_rd_index (rd_index_pmt2vrf),
      // VRF to PMT
        .vrf2pmt_rd_data  (rd_data_vrf2pmt),
      // RT to VRF
      `ifdef TB_SUPPORT
        .vrf_data         (vrf_data),
      `endif
        .rt2vrf_wr_valid  (wr_valid_rt2vrf),
        .rt2vrf_wr_data   (wr_data_rt2vrf)
    );
  
  // Retire information:
  // In testbenches, concatenate decode bypass packets ({de2rvvi}) with
  // execution retirement ({rt2rvvi}) for RVVI tracers.
  // For synthesis, directly wire base ROB retirement signals to maintain
  // hardware compatibility with the scalar RetirementBuffer.
  `ifdef TB_SUPPORT
    assign rd_valid_rob2rt_o = {de2rvvi_valid, rt2rvvi_valid};
    assign rd_rob2rt_o       = {de2rvvi_data, rt2rvvi_data};
  `else
    assign rd_valid_rob2rt_o = rd_valid_rob2rt;
    assign rd_rob2rt_o       = rd_rob2rt;
  `endif
  
  // rvv_backend IDLE 
  assign rvv_idle = fifo_empty_cq2de&fifo_empty_lcq2de&uq_empty&rob_empty
                  `ifdef ZVT_ON
                    &fifo_almost_empty_rs2zvt[0]&(!zvtBusy) 
                  `endif
                    ;

endmodule
