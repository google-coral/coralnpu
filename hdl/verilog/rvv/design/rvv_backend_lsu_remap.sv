`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_lsu_remap
(
  mapinfo_valid,
  mapinfo,
  pop_mapinfo,
  lsu_res_valid,
  lsu_res,
  pop_lsu_res,
  result_valid,
  result,
  result_ready,
  trap_valid_rmp2rob,
  trap_rob_entry_rmp2rob,
  trap_ready_rob2rmp
);

//
// interface signals
//
  // MAP INFO and LSU RES
  input   logic           [`NUM_LSU-1:0]  mapinfo_valid;
  input   LSU_MAP_INFO_t  [`NUM_LSU-1:0]  mapinfo;
  output  logic           [`NUM_LSU-1:0]  pop_mapinfo;
  input   logic           [`NUM_LSU-1:0]  lsu_res_valid;
  input   UOP_LSU_t       [`NUM_LSU-1:0]  lsu_res;
  output  logic           [`NUM_LSU-1:0]  pop_lsu_res;

  // submit LSU result to ROB
  output  logic           [`NUM_LSU-1:0]  result_valid;
  output  PU2ROB_t        [`NUM_LSU-1:0]  result;
  input   logic           [`NUM_LSU-1:0]  result_ready;

  // submit trap to ROB
  output  logic                           trap_valid_rmp2rob;
  output  logic   [`ROB_DEPTH_WIDTH-1:0]  trap_rob_entry_rmp2rob;
  input   logic                           trap_ready_rob2rmp;   

//
// internal signals
//
  genvar                i;

//
// logic start 
//
  // result valid 
  generate
    for(i=0;i<`NUM_LSU;i++) begin: RES_VALID
      assign result_valid[i] = mapinfo_valid[i]&lsu_res_valid[i]&mapinfo[i].valid&(!lsu_res[i].trap_valid)&(
                               (!mapinfo[i].lsu_is_store) & lsu_res[i].uop_lsu2rvv.vregfile_write_valid || 
                                (mapinfo[i].lsu_is_store) & lsu_res[i].uop_lsu2rvv.lsu_vstore_last);
    end
  endgenerate

  // remap
  generate
    for(i=0;i<`NUM_LSU;i++) begin: GET_RESULT
      `ifdef TB_SUPPORT
        assign result[i].uop_pc    = mapinfo[i].uop_pc;
      `endif
        assign result[i].rob_entry = mapinfo[i].rob_entry;
        assign result[i].w_data    = lsu_res[i].uop_lsu2rvv.vregfile_write_data;
        assign result[i].w_valid   = (!mapinfo[i].lsu_is_store)&
                                     lsu_res[i].uop_lsu2rvv.vregfile_write_valid&
                                     (lsu_res[i].uop_lsu2rvv.vregfile_write_addr==mapinfo[i].vregfile_write_addr);
        assign result[i].vsaturate = 'b0;
      `ifdef ZVE32F_ON
        assign result[i].fpexp     = 'b0;
      `endif
    end
  endgenerate

  always_comb begin
    trap_valid_rmp2rob = 'b0;
    trap_rob_entry_rmp2rob = 'b0;

    for (int j=0;j<`NUM_LSU;j++) begin
      if (lsu_res[j].trap_valid&lsu_res_valid[j]&mapinfo_valid[j]) begin
        trap_valid_rmp2rob     = 'b1;
        trap_rob_entry_rmp2rob = mapinfo[j].rob_entry;
      end
    end
  end

  // pop signal
  generate
    for(i=0;i<`NUM_LSU;i++) begin: GET_POP
      assign pop_mapinfo[i] = (!lsu_res[i].trap_valid)&result_valid[i]&result_ready[i]||
                                lsu_res[i].trap_valid&mapinfo_valid[i]&lsu_res_valid[i]&trap_ready_rob2rmp;
      assign pop_lsu_res[i] = pop_mapinfo[i];
    end
  endgenerate


endmodule
