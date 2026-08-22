
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_vrf(/*AUTOARG*/
  clk, 
  rst_n, 
  dp2vrf_rd_index, 
  vrf2dp_rd_data, 
  vrf2dp_v0_data, 
  pmt2vrf_rd_index,
  vrf2pmt_rd_data,
  rt2vrf_wr_valid, 
  rt2vrf_wr_data
`ifdef RVVI_ON
  ,vrf_data
`endif
);  
// global signal
input   logic                   clk;
input   logic                   rst_n;
    
// Dispatch unit to VRF unit
// Vs_data would be return from VRF at the current cycle.
input   logic     [`NUM_DP_VRF-1:0][`REGIDX_WIDTH-1:0] dp2vrf_rd_index;

// VRF to Dispatch read data
output  logic     [`NUM_DP_VRF-1:0][`VLEN-1:0]  vrf2dp_rd_data;
output  logic                      [`VLEN-1:0]  vrf2dp_v0_data;

// Permutation unit to VRF unit
input   logic     [`REGIDX_WIDTH-1:0]           pmt2vrf_rd_index;

// VRF to Permutation read data
output  logic     [`VLEN-1:0]                   vrf2pmt_rd_data;

// Write back to VRF
input   logic     [`NUM_RT_UOP-1:0]             rt2vrf_wr_valid;
input   RT2VRF_t  [`NUM_RT_UOP-1:0]             rt2vrf_wr_data;

`ifdef RVVI_ON
// send VRF updating value to RVVI, corresponding to rt2vrf_wr_data;
output  logic     [`NUM_VRF-1:0][`VLEN-1:0] vrf_data;
`endif

//
// code start
//
logic [`NUM_RT_UOP-1:0]                           wr_valid;
logic [`NUM_RT_UOP-1:0][`REGIDX_WIDTH-1:0]        wr_addr;
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]                wr_data;
logic [`NUM_RT_UOP-1:0][`VLENB-1:0]               wr_we;              // byte enable
logic [`NUM_RT_UOP-1:0][`VLEN-1:0]                wr_web;             // bit enable
logic [`NUM_RT_UOP-1:0][`NUM_VRF-1:0][`VLENB-1:0] vrf_wr_wen;
logic [`NUM_RT_UOP-1:0][`NUM_VRF-1:0][`VLEN-1:0]  vrf_wr_data;
logic [`NUM_VRF-1:0][`VLENB-1:0]                  vrf_wr_wen_full;
logic [`NUM_VRF-1:0][`VLEN-1:0]                   vrf_wr_data_full;
logic [`NUM_VRF-1:0][`VLEN-1:0]                   vrf_rd_data_full;   // full 32 VLEN data from VRF

// RT2VRF data unpack
for (genvar j=0;j<`NUM_RT_UOP;j++) begin: GET_WT_DATA
  assign wr_valid[j] = rt2vrf_wr_valid[j];
  assign wr_addr[j]  = rt2vrf_wr_data[j].rt_index;
  assign wr_data[j]  = rt2vrf_wr_data[j].rt_data;
  assign wr_we[j]    = rt2vrf_wr_data[j].rt_strobe;
  
  // generate write bit-enable
  for(genvar k=0;k<`VLENB;k++) begin: GET_WE_BIT
    assign wr_web[j][k*`BYTE_WIDTH +: `BYTE_WIDTH] = {`BYTE_WIDTH{wr_we[j][k]}};
  end

  // access VRF. Only write will update input
  always_comb begin
    vrf_wr_wen[j]  = 'b0;
    vrf_wr_data[j] = 'b0;

    if(wr_valid[j]) begin
      vrf_wr_wen[j][wr_addr[j]] = wr_we[j];
      vrf_wr_data[j][wr_addr[j]] = wr_data[j]&wr_web[j];
    end
  end
end

// merge all retire data
always_comb begin
  vrf_wr_wen_full = 'b0;
  vrf_wr_data_full = 'b0;

  for(int i=0; i<`NUM_VRF; i++) begin
    for(int h=0; h<`NUM_RT_UOP; h++) begin
      vrf_wr_wen_full[i] = vrf_wr_wen_full[i] | vrf_wr_wen[h][i];
      vrf_wr_data_full[i] = vrf_wr_data_full[i] | vrf_wr_data[h][i];
    end
  end
end

//VRF core
rvv_backend_vrf_reg 
vrf_reg (
  //Outputs
  .vreg   (vrf_rd_data_full), 
  //Inputs
  .clk    (clk), 
  .rst_n  (rst_n),
  .wen    (vrf_wr_wen_full), 
  .wdata  (vrf_wr_data_full)
);

`ifdef RVVI_ON
assign vrf_data = vrf_rd_data_full;
`endif

// VRF2DP data pack
assign vrf2dp_v0_data = vrf_rd_data_full[0];

for (genvar j=0;j<`NUM_DP_VRF;j++) begin: GET_RD_DATA
  assign vrf2dp_rd_data[j] = vrf_rd_data_full[dp2vrf_rd_index[j]];
end

// VRF2PMT data pack
assign vrf2pmt_rd_data = vrf_rd_data_full[pmt2vrf_rd_index];

endmodule
