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

    rt_xrf_rvv2rvs,
    rt_xrf_valid_rvv2rvs,
    rt_xrf_ready_rvs2rvv,

    wr_vxsat_valid,
    wr_vxsat,
    wr_vxsat_ready,

    trap_valid_rvs2rvv,
    trap_ready_rvv2rvs,    

    vcsr_valid,
    vector_csr,
    vcsr_ready,
    
  `ifdef TB_SUPPORT
    rd_valid_rob2rt_o,
  `endif

    rvv_idle,

    rd_rob2rt_o
);
// global signal
    input   logic                                     clk;
    input   logic                                     rst_n;

// vector instruction and scalar operand input. 
    input   logic             [`ISSUE_LANE-1:0]       insts_valid_rvs2cq;
    input   RVVCmd            [`ISSUE_LANE-1:0]       insts_rvs2cq;
    output  logic             [`ISSUE_LANE-1:0]       insts_ready_cq2rvs;  
    output  logic             [$clog2(`CQ_DEPTH):0]   remaining_count_cq2rvs;

// load/store unit interface
  // RVV send LSU uop to RVS
    output  logic             [`NUM_LSU-1:0]          uop_lsu_valid_rvv2lsu;
    output  UOP_RVV2LSU_t     [`NUM_LSU-1:0]          uop_lsu_rvv2lsu;
    input   logic             [`NUM_LSU-1:0]          uop_lsu_ready_lsu2rvv;
  // LSU feedback to RVV
    input   logic             [`NUM_LSU-1:0]          uop_lsu_valid_lsu2rvv;
    input   UOP_LSU2RVV_t     [`NUM_LSU-1:0]          uop_lsu_lsu2rvv;
    output  logic             [`NUM_LSU-1:0]          uop_lsu_ready_rvv2lsu;

// RT to XRF. RVS arbitrates write ports of XRF by itself.
    output  logic             [`NUM_RT_UOP-1:0]       rt_xrf_valid_rvv2rvs;
    output  RT2XRF_t          [`NUM_RT_UOP-1:0]       rt_xrf_rvv2rvs;
    input   logic             [`NUM_RT_UOP-1:0]       rt_xrf_ready_rvs2rvv;

// RT to VCSR.vxsat
    output  logic                                     wr_vxsat_valid;
    output  logic             [`VCSR_VXSAT_WIDTH-1:0] wr_vxsat;
    input   logic                                     wr_vxsat_ready;

// exception handler
  // trap signal handshake
    input   logic                                     trap_valid_rvs2rvv;
    output  logic                                     trap_ready_rvv2rvs;    
  // the vcsr of last retired uop in last cycle
    output  logic                                     vcsr_valid;
    output  RVVConfigState                            vector_csr;
    input   logic                                     vcsr_ready;

// retire information
  `ifdef TB_SUPPORT
    output  logic     [`NUM_RT_UOP-1:0]               rd_valid_rob2rt_o;
  `endif

// rvv_backend is not active.(IDLE)
    output  logic                                     rvv_idle;
    output ROB2RT_t [`NUM_RT_UOP-1:0]                 rd_rob2rt_o;

`ifdef TB_BRINGUP
  // inst queue
  logic [5:0] src1_idx [3:0]; 
  logic [5:0] src2_idx [3:0]; 
  logic [5:0] dest_idx [3:0];
  logic inst_valid [3:0];
  logic [31:0] inst_queue [3:0];
  always_ff @(posedge clk) begin
    if(!rst_n) begin 
      insts_ready_cq2rvs[0] <= 1'b0;
      insts_ready_cq2rvs[1] <= 1'b0;
      insts_ready_cq2rvs[2] <= 1'b0;
      insts_ready_cq2rvs[3] <= 1'b0;
      rt_xrf_valid_wb2rvs[0] <= 1'b0;
      rt_xrf_valid_wb2rvs[1] <= 1'b0;
      rt_xrf_valid_wb2rvs[2] <= 1'b0;
      rt_xrf_valid_wb2rvs[3] <= 1'b0;
    end else begin
      insts_ready_cq2rvs[0] <= 1'b1;
      insts_ready_cq2rvs[1] <= 1'b1;
      insts_ready_cq2rvs[2] <= 1'b0;
      insts_ready_cq2rvs[3] <= 1'b0;
      rt_xrf_valid_wb2rvs[0] <= 1'b0;
      rt_xrf_valid_wb2rvs[1] <= 1'b0;
      rt_xrf_valid_wb2rvs[2] <= 1'b0;
      rt_xrf_valid_wb2rvs[3] <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if(!rst_n) begin 
      inst_valid[0] <= 1'b0;
      inst_valid[1] <= 1'b0;
      inst_valid[2] <= 1'b0;
      inst_valid[3] <= 1'b0;
    end else begin
      inst_valid[0] <= insts_ready_cq2rvs[0] & insts_valid_rvs2cq[0];
      inst_valid[1] <= insts_ready_cq2rvs[1] & insts_valid_rvs2cq[1];
      inst_valid[2] <= insts_ready_cq2rvs[2] & insts_valid_rvs2cq[2];
      inst_valid[3] <= insts_ready_cq2rvs[3] & insts_valid_rvs2cq[3];
      inst_queue[0] <= (insts_ready_cq2rvs[0] & insts_valid_rvs2cq[0]) ? {insts_rvs2cq[0].bits,insts_rvs2cq[0].opcode,5'b0} : inst_queue[0];
      inst_queue[1] <= (insts_ready_cq2rvs[1] & insts_valid_rvs2cq[1]) ? {insts_rvs2cq[1].bits,insts_rvs2cq[1].opcode,5'b0} : inst_queue[1];
      inst_queue[2] <= (insts_ready_cq2rvs[2] & insts_valid_rvs2cq[2]) ? {insts_rvs2cq[2].bits,insts_rvs2cq[2].opcode,5'b0} : inst_queue[2];
      inst_queue[3] <= (insts_ready_cq2rvs[3] & insts_valid_rvs2cq[3]) ? {insts_rvs2cq[3].bits,insts_rvs2cq[3].opcode,5'b0} : inst_queue[3];
    end
  end

  always_comb begin
    for(int i=0;i<4;i++) begin
      src1_idx[i] = inst_queue[i][19:15];
      src2_idx[i] = inst_queue[i][24:20];
      dest_idx[i] = inst_queue[i][11:7];
    end
  end

  // vrf
  logic [127:0] vreg [31:0];
  logic [127:0] vreg_init_data [31:0];
  logic [3:0] rt_last_uop;
  always_ff @(posedge clk) begin
    if(!rst_n) begin 
      for(int i=0; i<32; i++) begin
        vreg[i] <= vreg_init_data[i];
      end
      for(int i=0; i<4; i++) begin
        rt_last_uop[i] <= 1'b0;
      end
    end else begin
      for(int i=0; i<4; i++) begin
        if(inst_valid[i]) begin
            for(int elm_idx=0; elm_idx<16; elm_idx++) begin
              // sew 8b, lmul 1, vl=16
              vreg[dest_idx[i]][elm_idx*8+:8] <= vreg[src1_idx[i]][elm_idx*8+:8] + vreg[src2_idx[i]][elm_idx*8+:8];
            end
          rt_last_uop[i] <= 1'b1;
        end else begin
          rt_last_uop[i] <= 1'b0;
        end
      end
    end
  end

  initial begin
    forever begin
      @(posedge clk);
      for(int i=0; i<3; i++) begin
        if(insts_valid_rvs2cq[i] && insts_ready_cq2rvs[i]) begin
          $display("[RTL INFO] @ %0t Got a instruction packet in insts_rvs2cq[%0d]", $time, i);
          $display("insts_rvs2cq[i].pc    = 0x%8x", insts_rvs2cq[i].inst_pc);
          $display("insts_rvs2cq[i].insts = 0x%8x", {insts_rvs2cq[i].bits,insts_rvs2cq[i].opcode,5'b0});
        end
      end
    end
  end
`else
// ---internal signals definition-------------------------------------
  // RVV frontend to command queue
    logic                                 cq_full;
    logic        [`ISSUE_LANE-1:0]        cq_almost_full;
    logic        [`ISSUE_LANE-1:0]        insts_ready;
    logic        [$clog2(`CQ_DEPTH):0]    used_count_cq;
  // Command queue to Decode
    RVVCmd       [`NUM_DE_INST-1:0]       inst_pkg_cq2de;
    logic                                 fifo_empty_cq2de;
    logic        [`NUM_DE_INST-1:0]       fifo_almost_empty_cq2de;
    logic        [`NUM_DE_INST-1:0]       pop_de2cq;
  // Decode to uop queue
    logic        [`NUM_DE_UOP-1:0]        push_de2uq;
    UOP_QUEUE_t  [`NUM_DE_UOP-1:0]        data_de2uq;
    logic                                 fifo_full_uq2de; 
    logic        [`NUM_DE_UOP-1:0]        fifo_almost_full_uq2de;
  // Uop queue to dispatch
    logic                                 uq_empty;
    logic        [`NUM_DP_UOP-1:0]        uq_almost_empty;
    logic        [`NUM_DP_UOP-1:0]        uop_valid_uop2dp;
    UOP_QUEUE_t  [`NUM_DP_UOP-1:0]        uop_uop2dp;
    logic        [`NUM_DP_UOP-1:0]        uop_ready_dp2uop;

  // Dispatch to RS
    // ALU_RS
    logic                                 alu_rs_full;
    logic        [`NUM_DP_UOP-1:0]        alu_rs_almost_full;
    logic        [`NUM_DP_UOP-1:0]        rs_valid_dp2alu;
    ALU_RS_t     [`NUM_DP_UOP-1:0]        rs_dp2alu;
    logic        [`NUM_DP_UOP-1:0]        rs_ready_alu2dp;
    // PMTRDT_RS 
    logic                                 pmtrdt_rs_full;
    logic        [`NUM_DP_UOP-1:0]        pmtrdt_rs_almost_full;
    logic        [`NUM_DP_UOP-1:0]        rs_valid_dp2pmtrdt;
    PMT_RDT_RS_t [`NUM_DP_UOP-1:0]        rs_dp2pmtrdt;
    logic        [`NUM_DP_UOP-1:0]        rs_ready_pmtrdt2dp;
    // MUL_RS
    logic                                 mul_rs_full;
    logic        [`NUM_DP_UOP-1:0]        mul_rs_almost_full;
    logic        [`NUM_DP_UOP-1:0]        rs_valid_dp2mul;
    MUL_RS_t     [`NUM_DP_UOP-1:0]        rs_dp2mul;
    logic        [`NUM_DP_UOP-1:0]        rs_ready_mul2dp;
    // DIV_RS
    logic                                 div_rs_full;
    logic        [`NUM_DP_UOP-1:0]        div_rs_almost_full;
    logic        [`NUM_DP_UOP-1:0]        rs_valid_dp2div;
    DIV_RS_t     [`NUM_DP_UOP-1:0]        rs_dp2div;
    logic        [`NUM_DP_UOP-1:0]        rs_ready_div2dp;
    // LSU_RS
    logic                                 lsu_rs_full;
    logic        [`NUM_DP_UOP-1:0]        lsu_rs_almost_full;
    logic                                 lsu_rs_empty;
    logic        [`NUM_LSU-1:0]           lsu_rs_almost_empty;
    logic        [`NUM_DP_UOP-1:0]        rs_valid_dp2lsu;
    UOP_RVV2LSU_t [`NUM_DP_UOP-1:0]       rs_dp2lsu;
    logic        [`NUM_DP_UOP-1:0]        rs_ready_lsu2dp;
    // LSU MAP INFO
    logic                                 mapinfo_full;
    logic        [`NUM_DP_UOP-1:0]        mapinfo_almost_full;
    logic        [`NUM_DP_UOP-1:0]        mapinfo_valid_dp2lsu;
    LSU_MAP_INFO_t  [`NUM_DP_UOP-1:0]     mapinfo_dp2lsu;
    logic        [`NUM_DP_UOP-1:0]        mapinfo_ready_lsu2dp;
  // Dispatch to ROB
    logic        [`NUM_DP_UOP-1:0]        uop_valid_dp2rob;
    DP2ROB_t     [`NUM_DP_UOP-1:0]        uop_dp2rob;
    logic        [`NUM_DP_UOP-1:0]        uop_ready_rob2dp;
    logic        [`ROB_DEPTH_WIDTH-1:0]   uop_index_rob2dp;
  
  // RS to excution unit
  // ALU_RS to ALU
    logic        [`NUM_ALU-1:0]           pop_alu2rs;
    ALU_RS_t     [`NUM_ALU-1:0]           uop_rs2alu;
    logic                                 fifo_empty_rs2alu;
    logic        [`NUM_ALU-1:0]           fifo_almost_empty_rs2alu;
  // PMTRDT_RS to PMTRDT
    logic        [`NUM_PMTRDT-1:0]        pop_pmtrdt2rs;
    PMT_RDT_RS_t [`NUM_PMTRDT-1:0]        uop_rs2pmtrdt;
    logic                                 fifo_empty_rs2pmtrdt;
    logic        [`NUM_PMTRDT-1:0]        fifo_almost_empty_rs2pmtrdt;
    PMT_RDT_RS_t [`PMTRDT_RS_DEPTH-1:0]   all_uop_rs2pmtrdt;
    logic        [$clog2(`PMTRDT_RS_DEPTH):0] valid_cnt_rs2pmtrdt;
  // MUL_RS to MUL
    logic        [`NUM_MUL-1:0]           pop_mul2rs;
    MUL_RS_t     [`NUM_MUL-1:0]           uop_rs2mul;
    logic                                 fifo_empty_rs2mul;
    logic        [`NUM_MUL-1:0]           fifo_almost_empty_rs2mul;
  // DIV_RS to DIV
    logic        [`NUM_DIV-1:0]           pop_div2rs;
    DIV_RS_t     [`NUM_DIV-1:0]           uop_rs2div;
    logic                                 fifo_empty_rs2div;
    logic        [`NUM_DIV-1:0]           fifo_almost_empty_rs2div;
  // LSU mapinfo
    logic        [`NUM_LSU-1:0]           pop_mapinfo;
    LSU_MAP_INFO_t  [`NUM_LSU-1:0]        mapinfo;
    logic                                 mapinfo_empty;
    logic        [`NUM_LSU-1:0]           mapinfo_almost_empty;
  // LSU result
    logic        [`NUM_LSU-1:0]           pop_lsu_res;
    UOP_LSU_t    [`NUM_LSU-1:0]           lsu_res;
    logic                                 lsu_res_full;
    logic        [`NUM_LSU-1:0]           lsu_res_almost_full;
    logic                                 lsu_res_empty;
    logic        [`NUM_LSU-1:0]           lsu_res_almost_empty;
    logic        [`NUM_LSU-1:0]           uop_lsu_valid;
    UOP_LSU_t    [`NUM_LSU-1:0]           uop_lsu;
    logic        [`NUM_LSU-1:0]           uop_lsu_ready;
    logic                                 trap_valid_rmp2rob;
    logic        [`ROB_DEPTH_WIDTH-1:0]   trap_rob_entry_rmp2rob;

  // execution unit submit result to ROB
  // ALU to ROB
    logic        [`NUM_ALU-1:0]           wr_valid_alu2rob;
    PU2ROB_t     [`NUM_ALU-1:0]           wr_alu2rob;
    logic        [`NUM_ALU-1:0]           wr_ready_rob2alu;
  // PMTRDT to ROB
    logic        [`NUM_PMTRDT-1:0]        wr_valid_pmtrdt2rob;
    PU2ROB_t     [`NUM_PMTRDT-1:0]        wr_pmtrdt2rob;
    logic        [`NUM_PMTRDT-1:0]        wr_ready_rob2pmtrdt;
  // MUL to ROB
    logic        [`NUM_MUL-1:0]           wr_valid_mul2rob;
    PU2ROB_t     [`NUM_MUL-1:0]           wr_mul2rob;
    logic        [`NUM_MUL-1:0]           wr_ready_rob2mul;
  // DIV to ROB
    logic        [`NUM_DIV-1:0]           wr_valid_div2rob;
    PU2ROB_t     [`NUM_DIV-1:0]           wr_div2rob;
    logic        [`NUM_DIV-1:0]           wr_ready_rob2div;
  // LSU to ROB
    logic        [`NUM_LSU-1:0]           wr_valid_lsu2rob;
    PU2ROB_t     [`NUM_LSU-1:0]           wr_lsu2rob;
    logic        [`NUM_LSU-1:0]           wr_ready_rob2lsu;
  // DP to VRF
    logic [`NUM_DP_VRF-1:0][`REGFILE_INDEX_WIDTH-1:0] rd_index_dp2vrf;          
    logic [`NUM_DP_VRF-1:0][`VLEN-1:0]                rd_data_vrf2dp;
    logic [`VLEN-1:0]                                 v0_mask_vrf2dp;
  // ROB to dispatch
    ROB2DP_t     [`ROB_DEPTH-1:0]         uop_rob2dp;
    logic                                 rob_empty;
  // ROB to RT
    logic        [`NUM_RT_UOP-1:0]        rd_valid_rob2rt;
    ROB2RT_t     [`NUM_RT_UOP-1:0]        rd_rob2rt;
    logic        [`NUM_RT_UOP-1:0]        rd_ready_rt2rob;
  // RT to VRF
    logic        [`NUM_RT_UOP-1:0]        wr_valid_rt2vrf;
    RT2VRF_t     [`NUM_RT_UOP-1:0]        wr_data_rt2vrf;

  // trap handler
    logic                                 trap_en;
    logic                                 is_trapping;
    logic                                 trap_ready_rob2rmp;   
    logic                                 trap_flush_rvv;

    genvar i;

// ---code start------------------------------------------------------
  // Command queue
    multi_fifo #(
        .T            (RVVCmd),
        .M            (`ISSUE_LANE),
        .N            (`NUM_DE_INST),
        .DATAOUT_REG  (1'b1),
        .DEPTH        (`CQ_DEPTH)
    ) u_command_queue (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (insts_valid_rvs2cq & insts_ready_cq2rvs),
        .datain       (insts_rvs2cq),
      // read
        .pop          (pop_de2cq),
        .dataout      (inst_pkg_cq2de),
      // fifo status
        .full         (cq_full),
        .almost_full  (cq_almost_full),
        .empty        (fifo_empty_cq2de),
        .almost_empty (fifo_almost_empty_cq2de),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  (used_count_cq)
    );

    assign insts_ready[0] = ~cq_full;
    generate
      for (i=1;i<`ISSUE_LANE;i++) begin: cmq_ready
        assign insts_ready[i] = !cq_almost_full[i];
      end
    endgenerate

    assign insts_ready_cq2rvs = is_trapping ? 'b0 : insts_ready;

    // output the remaining count in CQ
    assign remaining_count_cq2rvs = `CQ_DEPTH - used_count_cq;

  `ifdef ASSERT_ON
    PushToCMDQueue: `rvv_expect((insts_valid_rvs2cq & insts_ready_cq2rvs) inside {4'b1111, 4'b0111, 4'b0011, 4'b0001, 4'b0000})
      else $error("Push to command queue out-of-order: %4b.", $sampled(insts_valid_rvs2cq & insts_ready_cq2rvs));

    PopFromCMDQueue: `rvv_expect(pop_de2cq inside {2'b11, 2'b01, 2'b00})
      else $error("Pop from command queue out-of-order: %2b.", $sampled(pop_de2cq));
  `endif // ASSERT_ON

  // Decode unit
    rvv_backend_decode #(
    ) u_decode (
      // global
        .clk                      (clk),
        .rst_n                    (rst_n),
      // cq2de
        .inst_pkg_cq2de           (inst_pkg_cq2de),
        .fifo_empty_cq2de         (fifo_empty_cq2de),
        .fifo_almost_empty_cq2de  (fifo_almost_empty_cq2de),
        .pop_de2cq                (pop_de2cq),
      // de2uq
        .push_de2uq               (push_de2uq),
        .data_de2uq               (data_de2uq),
        .fifo_full_uq2de          (fifo_full_uq2de),
        .fifo_almost_full_uq2de   (fifo_almost_full_uq2de),
      // trap-flush
        .trap_flush_rvv           (trap_flush_rvv)
    );

  // Uop queue
    multi_fifo #(
        .T                (UOP_QUEUE_t),
        .M                (`NUM_DE_UOP),
        .N                (`NUM_DP_UOP),
        .DEPTH            (`UQ_DEPTH)
    ) u_uop_queue (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (push_de2uq),
        .datain           (data_de2uq),
      // read
        .pop              (uop_valid_uop2dp & uop_ready_dp2uop),
        .dataout          (uop_uop2dp),
      // fifo status
        .full             (fifo_full_uq2de),
        .almost_full      (fifo_almost_full_uq2de),
        .empty            (uq_empty),
        .almost_empty     (uq_almost_empty),
        .clear            (trap_flush_rvv),
        .fifo_data        (),
        .wptr             (),
        .rptr             (),
        .entry_count      ()
    );
   
    assign uop_valid_uop2dp[0] = ~uq_empty;
    generate
      for (i=1;i<`NUM_DP_UOP;i++) begin: uop_queue_valid
        assign uop_valid_uop2dp[i] = !uq_almost_empty[i];
      end
    endgenerate

  `ifdef ASSERT_ON
    `ifdef ISSUE_3_READ_PORT_6 
      PushToUopQueue: `rvv_expect(push_de2uq inside {6'b111111, 6'b011111, 6'b001111, 6'b000111, 6'b000011, 6'b000001, 6'b000000})
        else $error("Push to uops queue out-of-order: %6b", $sampled(push_de2uq));

      PopFromUopQueue: `rvv_expect((uop_valid_uop2dp & uop_ready_dp2uop) inside {3'b111, 3'b011, 3'b001,3'b000})
        else $error("Pop from uops queue out-of-order: %3b", $sampled(uop_valid_uop2dp & uop_ready_dp2uop));
    `else //ISSUE_2
      PushToUopQueue: `rvv_expect(push_de2uq inside {4'b1111, 4'b0111, 4'b0011, 4'b0001, 4'b0000})
        else $error("Push to uops queue out-of-order: %4b", $sampled(push_de2uq));

      PopFromUopQueue: `rvv_expect((uop_valid_uop2dp & uop_ready_dp2uop) inside {2'b11, 2'b01, 2'b00})
        else $error("Pop from uops queue out-of-order: %2b", $sampled(uop_valid_uop2dp & uop_ready_dp2uop));
    `endif
  `endif // ASSERT_ON

  // Dispatch unit
    rvv_backend_dispatch #(
    ) u_dispatch (
      // global
        .clk                (clk),
        .rst_n              (rst_n),
      // Uop queue to dispatch
        .uop_valid_uop2dp   (uop_valid_uop2dp),
        .uop_uop2dp         (uop_uop2dp),
        .uop_ready_dp2uop   (uop_ready_dp2uop),
      // Dispatch to RS
        // ALU_RS
        .rs_valid_dp2alu    (rs_valid_dp2alu),
        .rs_dp2alu          (rs_dp2alu),
        .rs_ready_alu2dp    (rs_ready_alu2dp),
        // PMTRDT_RS 
        .rs_valid_dp2pmtrdt (rs_valid_dp2pmtrdt),
        .rs_dp2pmtrdt       (rs_dp2pmtrdt),
        .rs_ready_pmtrdt2dp (rs_ready_pmtrdt2dp),
        // MUL_RS
        .rs_valid_dp2mul    (rs_valid_dp2mul),
        .rs_dp2mul          (rs_dp2mul),
        .rs_ready_mul2dp    (rs_ready_mul2dp),
        // DIV_RS
        .rs_valid_dp2div    (rs_valid_dp2div),
        .rs_dp2div          (rs_dp2div),
        .rs_ready_div2dp    (rs_ready_div2dp),
        // LSU_RS
        .rs_valid_dp2lsu      (rs_valid_dp2lsu),
        .rs_dp2lsu            (rs_dp2lsu),
        .rs_ready_lsu2dp      (rs_ready_lsu2dp),
        // LSU MAP INFO
        .mapinfo_valid_dp2lsu (mapinfo_valid_dp2lsu),
        .mapinfo_dp2lsu       (mapinfo_dp2lsu),
        .mapinfo_ready_lsu2dp (mapinfo_ready_lsu2dp),
      // Dispatch to ROB
        .uop_valid_dp2rob   (uop_valid_dp2rob),
        .uop_dp2rob         (uop_dp2rob),
        .uop_ready_rob2dp   (uop_ready_rob2dp),
        .uop_index_rob2dp   (uop_index_rob2dp),
      // VRF to dispatch
        .rd_index_dp2vrf    (rd_index_dp2vrf),
        .rd_data_vrf2dp     (rd_data_vrf2dp),
        .v0_mask_vrf2dp     (v0_mask_vrf2dp),
      // ROB to dispatch
        .rob_entry          (uop_rob2dp)
    );

  // RS, Reserve station
    // ALU RS
    multi_fifo #(
        .T            (ALU_RS_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_ALU),
        .DEPTH        (`ALU_RS_DEPTH),
        .CHAOS_PUSH   (1'b1),
        .DATAOUT_REG  (1'b1)
    ) u_alu_rs (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (rs_valid_dp2alu),
        .datain       (rs_dp2alu),
      // read
        .pop          (pop_alu2rs),
        .dataout      (uop_rs2alu),
      // fifo status
        .full         (alu_rs_full),
        .almost_full  (alu_rs_almost_full),
        .empty        (fifo_empty_rs2alu),
        .almost_empty (fifo_almost_empty_rs2alu),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

    assign rs_ready_alu2dp[0] = ~alu_rs_full;
    generate
      for (i=1;i<`NUM_DP_UOP;i++) begin: alu_rs_ready
        assign rs_ready_alu2dp[i] = !alu_rs_almost_full[i];
      end
    endgenerate

  `ifdef ASSERT_ON
    PopFromAluRSQueue: `rvv_expect((pop_alu2rs) inside {2'b11, 2'b01, 2'b00})
      else $error("Pop from ALU Reservation Station out-of-order: %2b", $sampled(pop_alu2rs));
  `endif // ASSERT_ON

    // PMTRDT RS, Permutation + Reduction
    multi_fifo #(
        .T                (PMT_RDT_RS_t),
        .M                (`NUM_DP_UOP),
        .N                (`NUM_PMTRDT),
        .DEPTH            (`PMTRDT_RS_DEPTH),
        .CHAOS_PUSH       (1'b1),
        .DATAOUT_REG      (1'b1)
    ) u_pmtrdt_rs (
      // global
        .clk              (clk),
        .rst_n            (rst_n),
      // write
        .push             (rs_valid_dp2pmtrdt),
        .datain           (rs_dp2pmtrdt),
      // read
        .pop              (pop_pmtrdt2rs),
        .dataout          (uop_rs2pmtrdt),
      // fifo status
        .full             (pmtrdt_rs_full),
        .almost_full      (pmtrdt_rs_almost_full),
        .empty            (fifo_empty_rs2pmtrdt),
        .almost_empty     (fifo_almost_empty_rs2pmtrdt),
        .clear            (trap_flush_rvv),
        .fifo_data        (all_uop_rs2pmtrdt),
        .wptr             (),
        .rptr             (),
        .entry_count      (valid_cnt_rs2pmtrdt)
    );

    assign rs_ready_pmtrdt2dp[0] = ~pmtrdt_rs_full;
    generate
      for (i=1;i<`NUM_DP_UOP;i++) begin: pmtrdt_rs_ready
        assign rs_ready_pmtrdt2dp[i] = !pmtrdt_rs_almost_full[i];
      end
    endgenerate

  `ifdef ASSERT_ON
     PopFromPmtrdtRSQueue: `rvv_expect((pop_pmtrdt2rs) inside {1'b1, 1'b0})
       else $error("Pop from PMTRDT Reservation Station out-of-order: %1b", $sampled(pop_pmtrdt2rs));
  `endif // ASSERT_ON

    // MUL RS, Multiply + Multiply-accumulate
    multi_fifo #(
        .T              (MUL_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_MUL),
        .DEPTH          (`MUL_RS_DEPTH),
        .CHAOS_PUSH     (1'b1)
    ) u_mul_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2mul),
        .datain         (rs_dp2mul),
      // read
        .pop            (pop_mul2rs),
        .dataout        (uop_rs2mul),
      // fifo status
        .full           (mul_rs_full),
        .almost_full    (mul_rs_almost_full),
        .empty          (fifo_empty_rs2mul),
        .almost_empty   (fifo_almost_empty_rs2mul),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

    assign rs_ready_mul2dp[0] = ~mul_rs_full;
    generate
      for (i=1;i<`NUM_DP_UOP;i++) begin: mul_rs_ready
        assign rs_ready_mul2dp[i] = !mul_rs_almost_full[i];
      end
    endgenerate

  `ifdef ASSERT_ON
    // PopFromMulRSQueue: `rvv_expect((pop_mul2rs) inside {2'b11, 2'b01, 2'b00})
    //   else $error("Pop from MUL Reservation Station out-of-order: %2b", $sampled(pop_mul2rs));
  `endif // ASSERT_ON

    // DIV RS
    multi_fifo #(
        .T              (DIV_RS_t),
        .M              (`NUM_DP_UOP),
        .N              (`NUM_DIV),
        .DEPTH          (`DIV_RS_DEPTH),
        .CHAOS_PUSH     (1'b1)
    ) u_div_rs (
      // global
        .clk            (clk),
        .rst_n          (rst_n),
      // write
        .push           (rs_valid_dp2div),
        .datain         (rs_dp2div),
      // read
        .pop            (pop_div2rs),
        .dataout        (uop_rs2div),
      // fifo status
        .full           (div_rs_full),
        .almost_full    (div_rs_almost_full),
        .empty          (fifo_empty_rs2div),
        .almost_empty   (fifo_almost_empty_rs2div),
        .clear          (trap_flush_rvv),
        .fifo_data      (),
        .wptr           (),
        .rptr           (),
        .entry_count    ()
    );

    assign rs_ready_div2dp[0] = ~div_rs_full;
    generate
      for (i=1;i<`NUM_DP_UOP;i++) begin: div_rs_ready
        assign rs_ready_div2dp[i] = !div_rs_almost_full[i];
      end
    endgenerate

  `ifdef ASSERT_ON
     PopFromDivRSQueue: `rvv_expect((pop_div2rs) inside {1'b1, 1'b0})
       else $error("Pop from DIV Reservation Station out-of-order: %1b", $sampled(pop_div2rs));
  `endif // ASSERT_ON

    // LSU RS
    multi_fifo #(
        .T            (UOP_RVV2LSU_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_LSU),
        .DEPTH        (`LSU_RS_DEPTH),
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_rs (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (rs_valid_dp2lsu),
        .datain       (rs_dp2lsu),
      // read
        .pop          (uop_lsu_valid_rvv2lsu & uop_lsu_ready_lsu2rvv),
        .dataout      (uop_lsu_rvv2lsu),
      // fifo status
        .full         (lsu_rs_full),
        .almost_full  (lsu_rs_almost_full),
        .empty        (lsu_rs_empty),
        .almost_empty (lsu_rs_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );
    // LSU RS full signal for dispatch unit
    assign rs_ready_lsu2dp[0] = ~lsu_rs_full;
    generate
      for (i=1;i<`NUM_DP_UOP;i++) begin: lsu_rs_ready
        assign rs_ready_lsu2dp[i] = !lsu_rs_almost_full[i];
      end
    endgenerate

    // output valid and data to LSU
    assign uop_lsu_valid_rvv2lsu[0] = ~lsu_rs_empty;
    generate
      for (i=1;i<`NUM_LSU;i++) begin: gen_uop_lsu_valid
        assign uop_lsu_valid_rvv2lsu[i] = ~lsu_rs_almost_empty[i];
      end
    endgenerate

    // LSU MAP INFO
    multi_fifo #(
        .T            (LSU_MAP_INFO_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_LSU),
        .DEPTH        (`LSU_RS_DEPTH),
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_map_info (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (mapinfo_valid_dp2lsu),
        .datain       (mapinfo_dp2lsu),
      // read
        .pop          (pop_mapinfo),
        .dataout      (mapinfo),
      // fifo status
        .full         (mapinfo_full),
        .almost_full  (mapinfo_almost_full),
        .empty        (mapinfo_empty),
        .almost_empty (mapinfo_almost_empty),
        .clear        (trap_flush_rvv),
        .fifo_data    (),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

    assign mapinfo_ready_lsu2dp[0] = ~mapinfo_full;
    generate
      for (i=1;i<`NUM_DP_UOP;i++) begin: mapinfo_ready
        assign mapinfo_ready_lsu2dp[i] = !mapinfo_almost_full[i];
      end
    endgenerate

  // trap handler
    // make sure all lsu uops before the trapping uop have been pushed into LSU_RES_FIFO
    assign trap_en = trap_valid_rvs2rvv & (uop_lsu_valid_lsu2rvv=='b0) & (!lsu_res_full) & (!is_trapping);

    cdffr
    trap_valid
    (
      .clk            (clk),
      .rst_n          (rst_n),
      .e              (trap_en),
      .c              (trap_flush_rvv),
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
        .CHAOS_PUSH   (1'b1)
    ) u_lsu_res (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // write
        .push         (uop_lsu_valid&uop_lsu_ready_rvv2lsu),
        .datain       (uop_lsu),
      // read
        .pop          (pop_lsu_res),
        .dataout      (lsu_res),
      // fifo status
        .full         (lsu_res_full),
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
    assign uop_lsu_ready[0] = !lsu_res_full;
    generate
      for (i=1;i<`NUM_LSU;i++) begin: lsu_res_ready
        assign uop_lsu_ready[i] = !lsu_res_almost_full[i];
      end
    endgenerate

    assign uop_lsu_ready_rvv2lsu = is_trapping ? 'b0 : uop_lsu_ready;

  // PU, Process unit
    // ALU
    rvv_backend_alu #(
    ) u_alu (
      // ALU_RS to ALU
        .clk                        (clk),
        .rst_n                      (rst_n),
        .pop_ex2rs                  (pop_alu2rs),
        .alu_uop_rs2ex              (uop_rs2alu),
        .fifo_empty_rs2ex           (fifo_empty_rs2alu),
        .fifo_almost_empty_rs2ex    (fifo_almost_empty_rs2alu),
      // ALU to ROB  
        .result_valid_ex2rob        (wr_valid_alu2rob),
        .result_ex2rob              (wr_alu2rob),
        .result_ready_rob2alu       (wr_ready_rob2alu),
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
        .fifo_empty_rs2ex           (fifo_empty_rs2pmtrdt),
        .fifo_almost_empty_rs2ex    (fifo_almost_empty_rs2pmtrdt),
        .all_uop_data               (all_uop_rs2pmtrdt),
        .all_uop_cnt                (valid_cnt_rs2pmtrdt),
      // PMTRDT to ROB
        .result_valid_ex2rob        (wr_valid_pmtrdt2rob),
        .result_ex2rob              (wr_pmtrdt2rob),
        .result_ready_rob2ex        (wr_ready_rob2pmtrdt),
      // trap-flush
        .trap_flush_rvv             (trap_flush_rvv)
    );
    
    // MULMAC
    rvv_backend_mulmac u_mulmac (
      .clk                        (clk),
      .rst_n                      (rst_n),
    // MUL_RS to MULMAC
      .ex2rs_fifo_pop             (pop_mul2rs),
      .rs2ex_uop_data             (uop_rs2mul),
      .rs2ex_fifo_empty           (fifo_empty_rs2mul),
      .rs2ex_fifo_1left_to_empty  (fifo_almost_empty_rs2mul[1]),
    //MULMAC to ROB
      .ex2rob_valid               (wr_valid_mul2rob),
      .ex2rob_data                (wr_mul2rob),
      .rob2ex_ready               (wr_ready_rob2mul),
    // trap-flush
      .trap_flush_rvv             (trap_flush_rvv)
    );
    
    // DIV
    rvv_backend_div u_div
    (  
      .clk                      (clk),
      .rst_n                    (rst_n),
      // DIV_RS to DIV
      .pop_ex2rs                (pop_div2rs),
      .div_uop_rs2ex            (uop_rs2div),
      .fifo_empty_rs2ex         (fifo_empty_rs2div),
      .fifo_almost_empty_rs2ex  (fifo_almost_empty_rs2div),
      // DIV to ROB
      .result_valid_ex2rob      (wr_valid_div2rob),
      .result_ex2rob            (wr_div2rob),
      .result_ready_rob2div     (wr_ready_rob2div),
      // trap-flush
      .trap_flush_rvv           (trap_flush_rvv)
    );

    // LSU remap
    rvv_backend_lsu_remap
    u_lsu_remap
    (
      .mapinfo                (mapinfo),
      .lsu_res                (lsu_res),
      .mapinfo_empty          (mapinfo_empty),
      .mapinfo_almost_empty   (mapinfo_almost_empty),
      .lsu_res_empty          (lsu_res_empty),
      .lsu_res_almost_empty   (lsu_res_almost_empty),
      .pop_mapinfo            (pop_mapinfo),
      .pop_lsu_res            (pop_lsu_res),
      .result_valid_lsu2rob   (wr_valid_lsu2rob),
      .result_lsu2rob         (wr_lsu2rob),      
      .result_ready_rob2lsu   (wr_ready_rob2lsu),
      .trap_valid_rmp2rob     (trap_valid_rmp2rob),
      .trap_rob_entry_rmp2rob (trap_rob_entry_rmp2rob),
      .trap_ready_rob2rmp     (trap_ready_rob2rmp)
    );

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
        .uop_index_rob2dp       (uop_index_rob2dp),
      // ALU to ROB
        .wr_valid_alu2rob       (wr_valid_alu2rob),
        .wr_alu2rob             (wr_alu2rob),
        .wr_ready_rob2alu       (wr_ready_rob2alu),
      // PMTRDT to ROB
        .wr_valid_pmtrdt2rob    (wr_valid_pmtrdt2rob),
        .wr_pmtrdt2rob          (wr_pmtrdt2rob),
        .wr_ready_rob2pmtrdt    (wr_ready_rob2pmtrdt),
      // MUL to ROB
        .wr_valid_mul2rob       (wr_valid_mul2rob),
        .wr_mul2rob             (wr_mul2rob),
        .wr_ready_rob2mul       (wr_ready_rob2mul),
      // DIV to ROB
        .wr_valid_div2rob       (wr_valid_div2rob),
        .wr_div2rob             (wr_div2rob),
        .wr_ready_rob2div       (wr_ready_rob2div),
      // LSU to ROB
        .wr_valid_lsu2rob       (wr_valid_lsu2rob),
        .wr_lsu2rob             (wr_lsu2rob),
        .wr_ready_rob2lsu       (wr_ready_rob2lsu),
      // ROB to RT
        .rd_valid_rob2rt        (rd_valid_rob2rt),
        .rd_rob2rt              (rd_rob2rt),
        .rd_ready_rt2rob        (rd_ready_rt2rob),
      // ROB to DP
        .uop_rob2dp             (uop_rob2dp),
      // Trap
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
      // RT to RVS.XRF
        .rt2xrf_write_valid     (rt_xrf_valid_rvv2rvs),
        .rt2xrf_write_data      (rt_xrf_rvv2rvs),
        .xrf2rt_write_ready     (rt_xrf_ready_rvs2rvv),
      // RT to VRF
        .rt2vrf_write_valid     (wr_valid_rt2vrf),
        .rt2vrf_write_data      (wr_data_rt2vrf),
      // write to update vcsr   
        .rt2vcsr_write_valid    (vcsr_valid),
        .rt2vcsr_write_data     (vector_csr),
        .vcsr2rt_write_ready    (vcsr_ready),
      // update to vxsat
        .rt2vxsat_write_valid   (wr_vxsat_valid),
        .rt2vxsat_write_data    (wr_vxsat),
        .vxsat2rt_write_ready   (wr_vxsat_ready)
    );

  // VRF, Vector Register File
    rvv_backend_vrf #(
    ) u_vrf (
      // global signal
        .clk             (clk),
        .rst_n           (rst_n),
      // DP to VRF
        .dp2vrf_rd_index (rd_index_dp2vrf),
      // VRF to DP
        .vrf2dp_rd_data  (rd_data_vrf2dp),
        .vrf2dp_v0_data  (v0_mask_vrf2dp),
      // RT to VRF
        .rt2vrf_wr_valid (wr_valid_rt2vrf),
        .rt2vrf_wr_data  (wr_data_rt2vrf)
    );

  // retire information
`ifdef TB_SUPPORT
  assign rd_valid_rob2rt_o = rd_valid_rob2rt & rd_ready_rt2rob;
`endif

  // rvv_backend IDLE
  assign rvv_idle = fifo_empty_cq2de&uq_empty&rob_empty;
  assign rd_rob2rt_o = rd_rob2rt;

`endif // TB_BRINGUP

endmodule
