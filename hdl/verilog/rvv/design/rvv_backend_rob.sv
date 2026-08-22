/*
description: 
1. the ROB module receives uop information from Dispatch unit and uop result from Processor Unit (PU).
2. the ROB module provides all status for dispatch unit to foreward operand from ROB.
3. the ROB module send retire request to retire unit.
4. the ROB module receives trap information from LSU and flush buffer(s)

feature list:
1. the ROB can receive 2 uop information form Dispatch unit at most per cycle.
2. the ROB can receive 9 uop result from PU at most per cycle.
    a. However, U-arch of RVV limit the result number from 9 to 8.
3. the ROB can send 4 retire uops to writeback unit at most per cycle.
4. the ROB infomation for dispatch need to be sorted, which depends on program order.
*/

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_rob
(
    clk,
    rst_n,
    uop_valid_dp2rob,
    uop_dp2rob,
    uop_ready_rob2dp,
    rob_empty,
    rob_entry_rob2dp,
    wr_valid_pu2rob,
    wr_pu2rob,
    ff_tail_index,
    rd_valid_rob2rt,
    rd_rob2rt,
    rd_ready_rt2rob,
    rob_entry_rob2rt,
    uop_rob2dp,
`ifdef ZVT_ON
    vme_lsuflush_vld,
    vme_lsuflush_rdy,
`endif
    trap_valid_rmp2rob,
    trap_rob_entry_rmp2rob,
    trap_ready_rob2rmp,
    trap_ready_rvv2rvs,
    trap_flush_rvv    
);  
// global signal
    input   logic                             clk;
    input   logic                             rst_n;

// push uop infomation to ROB
// Dispatch to ROB
    input   logic     [`NUM_DP_UOP-1:0]       uop_valid_dp2rob;
    input   DP2ROB_t  [`NUM_DP_UOP-1:0]       uop_dp2rob;
    output  logic     [`NUM_DP_UOP-1:0]       uop_ready_rob2dp;
    output  logic                             rob_empty;
    output  logic     [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2dp;

// push uop result to ROB
// PU to ROB
    input   logic     [`NUM_SMPORT-1:0]                   wr_valid_pu2rob;
    input   PU2ROB_t  [`NUM_SMPORT-1:0]                   wr_pu2rob;
    input   logic     [`NUM_SMPORT-1:0][$clog2(`VLENB):0] ff_tail_index;  

// retire uops
// pop vd_data from ROB and write to VRF
    output  logic     [`NUM_RT_UOP-1:0]       rd_valid_rob2rt;
    output  ROB2RT_t  [`NUM_RT_UOP-1:0]       rd_rob2rt;
    input   logic     [`NUM_RT_UOP-1:0]       rd_ready_rt2rob;
    output  logic     [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2rt;

// bypass all rob entries to Dispatch unit
// rob_entries must be in program order instead of entry_index
    output  ROB2DP_t  [`ROB_DEPTH-1:0]        uop_rob2dp;

// trap signal handshake
`ifdef ZVT_ON
    input   logic                             vme_lsuflush_vld;
    output  logic                             vme_lsuflush_rdy;
`endif
    input   logic                             trap_valid_rmp2rob;
    input   logic   [`ROB_DEPTH_WIDTH-1:0]    trap_rob_entry_rmp2rob;
    output  logic                             trap_ready_rob2rmp;
    output  logic                             trap_ready_rvv2rvs;    
    output  logic                             trap_flush_rvv;        

// ---internal signal definition--------------------------------------
    logic                               trap_in;
    logic                               is_trapping;

  // Uop info
    DP2ROB_t  [`NUM_RT_UOP-1:0]         uop_rob2rt;
    logic     [`NUM_RT_UOP-1:0]         uop_valid_rob2rt;
    DP2ROB_t  [`ROB_DEPTH-1:0]          alluop_info;
    logic     [`ROB_DEPTH-1:0]          entry_valid;

    logic     [`ROB_DEPTH_WIDTH-1:0]    uop_wptr;
    logic     [`ROB_DEPTH_WIDTH-1:0]    uop_rptr;

  // Uop result
    RES_ROB_t [`ROB_DEPTH-1:0]          res_mem;
    logic     [`ROB_DEPTH-1:0]          uop_done;

  // trap
    logic     [`ROB_DEPTH-1:0]          trap_flag;

  // temp signal
    logic     [`ROB_DEPTH_WIDTH-1:0]    wind_uop_wptr [`ROB_DEPTH-1:0];
    logic     [`ROB_DEPTH_WIDTH-1:0]    wind_uop_rptr [`ROB_DEPTH-1:0];

// ---code start------------------------------------------------------
  // Uop info FIFO
    multi_fifo #(
        .T            (DP2ROB_t),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_RT_UOP),
        .DEPTH        (`ROB_DEPTH),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1),
        .FULL_PUSH    (1'b1)
    ) u_uop_info_fifo (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // push side
        .push         (uop_valid_dp2rob),
        .pushRdy      (uop_ready_rob2dp),
        .datain       (uop_dp2rob),
        .full         (),
        .almost_full  (),
      // pop side
        .pop          (rd_valid_rob2rt & rd_ready_rt2rob),
        .dataout      (uop_rob2rt),
        .empty        (rob_empty),
        .almost_empty (),
      // fifo info
        .clear        (trap_flush_rvv),
        .fifo_data    (alluop_info),
        .wptr         (uop_wptr),
        .rptr         (uop_rptr),
        .entry_count  ()
    );

    assign rob_entry_rob2dp = uop_wptr;

  // entry valid
  // set if DP push uop into ROB
  // clear if RT pop uop from ROB
  // reset once flush ROB
    multi_fifo #(
        .T            (logic),
        .M            (`NUM_DP_UOP),
        .N            (`NUM_RT_UOP),
        .DEPTH        (`ROB_DEPTH),
        .POP_CLEAR    (1'b1),
        .ASYNC_RSTN   (1'b1),
        .CHAOS_PUSH   (1'b1),
        .FULL_PUSH    (1'b1)
    ) u_uop_valid_fifo (
      // global
        .clk          (clk),
        .rst_n        (rst_n),
      // push side
        .push         (uop_valid_dp2rob),
        .pushRdy      (),
        .datain       (uop_valid_dp2rob),
        .full         (),
        .almost_full  (),
      // pop side
        .pop          (rd_valid_rob2rt & rd_ready_rt2rob),
        .dataout      (uop_valid_rob2rt),
        .empty        (),
        .almost_empty (),
      // fifo info
        .clear        (trap_flush_rvv),
        .fifo_data    (entry_valid),
        .wptr         (),
        .rptr         (),
        .entry_count  ()
    );

  // update PU result to result memory
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n)
            res_mem <= 'b0;
        else begin
            for (int k=0; k<`NUM_SMPORT; k++) begin
                if (wr_valid_pu2rob[k]) begin
                  `ifdef TB_SUPPORT
                    res_mem[wr_pu2rob[k].rob_entry].uop_pc        <= wr_pu2rob[k].uop_pc;
                  `endif                
                    res_mem[wr_pu2rob[k].rob_entry].w_valid       <= wr_pu2rob[k].w_valid;
                    res_mem[wr_pu2rob[k].rob_entry].w_data        <= wr_pu2rob[k].w_data;
                    res_mem[wr_pu2rob[k].rob_entry].ff_tail_index <= ff_tail_index[k];
                    res_mem[wr_pu2rob[k].rob_entry].vsaturate     <= wr_pu2rob[k].vsaturate;
                  `ifdef ZVE32F_ON
                    res_mem[wr_pu2rob[k].rob_entry].fpexp         <= wr_pu2rob[k].fpexp;
                  `endif
                end
            end
        end
    end

  // uop done
  // set if PU update uop result
  // clear if RT pop uop reuslt from ROB
  // reset once flush ROB.

  // wind back pointer
     for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_wind_uop_ptr
       assign wind_uop_rptr[i] = uop_rptr+i;
       assign wind_uop_wptr[i] = uop_wptr+i;
     end
    
     always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            uop_done <= '0;
        else if (trap_flush_rvv)
            uop_done <= '0;
        else begin
            for (int k=0; k<`NUM_RT_UOP; k++) begin
                if (rd_valid_rob2rt[k] && rd_ready_rt2rob[k])
                    uop_done[wind_uop_rptr[k]] <= 1'b0;
            end
            for (int k=0; k<`NUM_SMPORT; k++) begin
                if (wr_valid_pu2rob[k])
                    uop_done[wr_pu2rob[k].rob_entry] <= 1'b1;
            end
        end
    end

  `ifdef ASSERT_ON 
    logic [`ROB_DEPTH-1:0][`NUM_SMPORT-1:0] res_sel; // one hot code for each entry
    for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_res_sel
        for (genvar j=0; j<`NUM_SMPORT; j++) begin : gen_smport    
            assign res_sel[i][j] = wr_valid_pu2rob[j] && (wr_pu2rob[j].rob_entry == i);
        end

        `rvv_expect($onehot0(res_sel[i])) 
        else $error("ROB: Multiple PU results write same entry: index %d, PU %d\n", i, $sampled(res_sel[i]));

    end
  `endif

  `ifdef ASSERT_ON
    for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_res_write_check
      `rvv_forbid( uop_done[wind_uop_rptr[i]] && !entry_valid[i] )
      else $error("ROB: Write back to ROB entry[%d] while entry is invalid", i);

    `ifdef TB_SUPPORT
      `rvv_forbid( uop_done[wind_uop_rptr[i]] && entry_valid[i] && (res_mem[wind_uop_rptr[i]].uop_pc !== alluop_info[i].uop_pc) )
      else $error("ROB: Result pc written back to ROB is mismacth: res_mem[%d].uop_pc(0x%08x) != alluop_info[%d].uop_pc(0x%08x)", i, res_mem[wind_uop_rptr[i]].uop_pc, i, alluop_info[i].uop_pc);
    `endif
    end
  `endif

  // trap flag
  // write trap to ROB when trap occurs
  // flush all fifo when the uop triggering trap is the oldest uop in ROB
  always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n)
          trap_flag <= '0;
      else if (trap_flush_rvv)
          trap_flag <= '0;
      else if (trap_valid_rmp2rob & trap_ready_rob2rmp)
          trap_flag[trap_rob_entry_rmp2rob] <= 1'b1;
  end

  // trap ready is always 1
  assign trap_ready_rob2rmp = 1'b1;

  // retire uop(s)
  logic [`ROB_DEPTH-1:0][$clog2(`VLENB):0] rt_ff_tail_index;
  logic [`ROB_DEPTH-1:0][`VLENB-1:0]       rt_ff_strobe;
  logic [`ROB_DEPTH-1:0]                   is_ff;

  for (genvar i=0; i<`ROB_DEPTH; i++) begin
    // write strobe
      assign rt_ff_tail_index[i] = res_mem[wind_uop_rptr[i]].ff_tail_index;
      assign is_ff[i]            = alluop_info[i].is_ff;
      assign rt_ff_strobe[i]     = ~((`VLENB)'('1)<<rt_ff_tail_index[i]);
  end

  for (genvar i=0; i<`NUM_RT_UOP; i++) begin : gen_rob2rt
    // retire_uop valid
      if (i==0) begin : gen_0
        assign rd_valid_rob2rt[0] = uop_valid_rob2rt[0] & (uop_done[wind_uop_rptr[0]]|trap_flag[wind_uop_rptr[i]]);
      end else begin : gen_i
        assign rd_valid_rob2rt[i] = uop_valid_rob2rt[i] & uop_done[wind_uop_rptr[i]] & rd_valid_rob2rt[i-1] & ~trap_flag[wind_uop_rptr[i]-1'b1];
      end
    // retire_uop data
    `ifdef TB_SUPPORT          
      assign rd_rob2rt[i].uop_pc           = uop_rob2rt[i].uop_pc;
      assign rd_rob2rt[i].last_uop_valid   = uop_rob2rt[i].last_uop_valid;
      assign rd_rob2rt[i].res_updating_end = uop_rob2rt[i].res_updating_end;          
    `endif          
      assign rd_rob2rt[i].w_valid         = res_mem[wind_uop_rptr[i]].w_valid & uop_done[wind_uop_rptr[i]];
      assign rd_rob2rt[i].w_index         = uop_rob2rt[i].w_index;
      assign rd_rob2rt[i].w_data          = res_mem[wind_uop_rptr[i]].w_data;
      assign rd_rob2rt[i].w_type          = uop_rob2rt[i].w_type;
      assign rd_rob2rt[i].trap_flag       = trap_flag[wind_uop_rptr[i]];
      assign rd_rob2rt[i].vector_csr      = uop_rob2rt[i].vector_csr;
      assign rd_rob2rt[i].vxsaturate      = res_mem[wind_uop_rptr[i]].vsaturate;
    `ifdef ZVE32F_ON
      assign rd_rob2rt[i].fpexp           = res_mem[wind_uop_rptr[i]].fpexp;
    `endif

      always_comb begin
          for(int j=0;j<`VLENB;j++) begin
              rd_rob2rt[i].vd_type[j] = (is_ff[i] && !rt_ff_strobe[i][j]) ? TAIL : uop_rob2rt[i].byte_type[j];
          end
      end
  end

  assign rob_entry_rob2rt = uop_rptr;
  
  // trap handle ready and flush signal
  assign trap_in = uop_valid_rob2rt[0] & rd_rob2rt[0].trap_flag & rd_ready_rt2rob[0]
                  `ifdef ZVT_ON
                   || vme_lsuflush_vld
                  `endif
                   ;

  dff regTrapFlush (.q(is_trapping), .d(trap_in&(!is_trapping)), .clk(clk), .rst_n(rst_n));

  assign trap_flush_rvv = trap_in || is_trapping; // flush 2 cycles

  assign trap_ready_rvv2rvs = is_trapping;
`ifdef ZVT_ON
  assign vme_lsuflush_rdy = is_trapping;
`endif

  // bypass ROB info to Dispatch
  for (genvar i=0; i<`ROB_DEPTH; i++) begin : gen_rob2dp
    `ifdef TB_SUPPORT
      assign uop_rob2dp[i].uop_pc     = alluop_info[i].uop_pc;
    `endif
      assign uop_rob2dp[i].valid      = entry_valid[i];
      assign uop_rob2dp[i].w_valid    = res_mem[wind_uop_rptr[i]].w_valid & uop_done[wind_uop_rptr[i]];
      assign uop_rob2dp[i].w_index    = alluop_info[i].w_index;
      assign uop_rob2dp[i].w_type     = alluop_info[i].w_type;
      assign uop_rob2dp[i].w_data     = res_mem[wind_uop_rptr[i]].w_data;
      assign uop_rob2dp[i].vector_csr = alluop_info[i].vector_csr;

      always_comb begin
          for(int j=0;j<`VLENB;j++) begin
              uop_rob2dp[i].byte_type[j] = (is_ff[i] && !rt_ff_strobe[i][j]) ? TAIL : alluop_info[i].byte_type[j];
          end
      end
  end
  
endmodule
