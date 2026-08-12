
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_retire_waw(
  valid,
  w_index,
  w_strobe,
  w_data,
  waw,
  res,
  res_strobe
);
  parameter UOP_NUM = 2;
//
// interface signals
//
  input   logic [UOP_NUM-1:0]                     valid;
  input   logic [UOP_NUM-1:0][`REGIDX_WIDTH-1:0]  w_index;
  input   logic [UOP_NUM-1:0][`VLENB-1:0]         w_strobe;
  input   logic [UOP_NUM-1:0][`VLEN-1:0]          w_data;
  output  logic [`NUM_RT_UOP-1:0]                 waw;
  output  logic [`VLEN-1:0]                       res;
  output  logic [`VLENB-1:0]                      res_strobe;
//
// internal signals
//
  logic   [UOP_NUM-1:0] vd_hit;
    
  always_comb begin
    res         = 'b0;
    res_strobe  = 'b0;
    vd_hit      = 'b0;

    for(int i=0;i<UOP_NUM;i++) begin
      vd_hit[i] = valid[i]&valid[UOP_NUM-1]&(w_index[i]==w_index[UOP_NUM-1]);
      
      for(int j=0;j<`VLENB;j++) begin
        if(vd_hit[i]&w_strobe[i][j]) begin
          res_strobe[j]                   = 'b1;
          res[j*`BYTE_WIDTH+:`BYTE_WIDTH] = w_data[i][j*`BYTE_WIDTH+:`BYTE_WIDTH];
        end
      end
    end
  end
  
  assign waw = (`NUM_RT_UOP)'(vd_hit[UOP_NUM-2:0]); 
endmodule
