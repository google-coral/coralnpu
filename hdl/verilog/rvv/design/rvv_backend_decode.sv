
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_decode
(
  inst_valid,
  inst,
  lcmd_valid,
  lcmd,
  de2rvvi_valid,
  de2rvvi_data
);
//
// interface signals
//
  input   logic     [`NUM_DE_INST-1:0]  inst_valid; 
  input   RVVCmd    [`NUM_DE_INST-1:0]  inst; 

  output  logic     [`NUM_DE_INST-1:0]  lcmd_valid;
  output  LCMD_t    [`NUM_DE_INST-1:0]  lcmd;

  // retire information for reserved instruction
  output  logic     [`NUM_DE_INST-1:0]  de2rvvi_valid; // always ready to receive.
  output  ROB2RT_t  [`NUM_DE_INST-1:0]  de2rvvi_data;  

//
// decode
//
  // decode unit
  generate 
    for(genvar i=0;i<`NUM_DE_INST;i=i+1) begin: DECODE_UNIT
      rvv_backend_decode_unit u_decode_unit
      (
        .inst_valid   (inst_valid[i]),
        .inst         (inst[i]),
        .lcmd_valid   (lcmd_valid[i]),
        .lcmd         (lcmd[i])  
      );    
    end
  endgenerate

  // Retire information for reserved/un-decoded instructions:
  // In verification testbenches, generate dummy 0-write retirement records so
  // RVVI tracers stay synchronized for discarded instructions.
  // In synthesis, this logic is excluded as un-decoded instructions trap directly
  // in the scalar core.
  always_comb begin
    for(int i=0;i<`NUM_DE_INST;i++) begin
      de2rvvi_valid[i]                  = inst_valid[i] & !lcmd_valid[i];
      
    `ifdef TB_SUPPORT
      de2rvvi_data[i].uop_pc            = inst[i].inst_pc;
      de2rvvi_data[i].last_uop_valid    = 'b1;
      de2rvvi_data[i].res_updating_end  = 'b0;
    `endif
      de2rvvi_data[i].w_valid           = 'b0;  // update nothing         
      de2rvvi_data[i].w_index           = 'b0;
      de2rvvi_data[i].w_data            = 'b0; 
      de2rvvi_data[i].w_type            = VRF; 
      de2rvvi_data[i].vd_type           = {`VLENB{NOT_CHANGE}};
      de2rvvi_data[i].trap_flag         = 'b0;
      de2rvvi_data[i].vector_csr        = inst[i].arch_state;
      de2rvvi_data[i].vxsaturate        = 'b0;
    `ifdef ZVE32F_ON
      de2rvvi_data[i].fpexp             = 'b0;
    `endif
    end
  end
  
endmodule
