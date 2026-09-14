
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_decode_unit
(
  inst_valid,
  inst,
  lcmd_valid,
  lcmd
);
//
// interface signals
//
  // CQ to Decoder unit signals
  input   logic                 inst_valid;
  input   RVVCmd                inst;
  
  // Decoder unit to VCQ
  output  logic                 lcmd_valid;
  output  LCMD_t                lcmd;

//
// internal signals
//
  logic                         valid_ari;
  logic                         valid_lsu;
  // decoded arithmetic uops
  logic                         lcmd_valid_ari;
  LCMD_t                        lcmd_ari;
  // decoded LSU uops
  logic                         lcmd_valid_lsu;
  LCMD_t                        lcmd_lsu;

//
// decode
//
  // decode opcode
  assign valid_lsu    = inst_valid & ((inst.opcode==LOAD) | (inst.opcode==STORE));
  assign valid_ari    = inst_valid & (inst.opcode==RVV);
  
  // decode LSU instruction 
  rvv_backend_decode_unit_lsu u_lsu_decode
  (
    .inst_valid        (valid_lsu),
    .inst              (inst),
    .lcmd_valid        (lcmd_valid_lsu),
    .lcmd              (lcmd_lsu)
  );

  // decode arithmetic instruction
  rvv_backend_decode_unit_ari u_ari_decode
  (
    .inst_valid        (valid_ari),
    .inst              (inst),
    .lcmd_valid        (lcmd_valid_ari),
    .lcmd              (lcmd_ari)
  );

  // output
  always_comb begin 
    lcmd_valid     = 'b0;
    lcmd           = 'b0;
    
    case(1'b1)
      valid_lsu: begin
        lcmd_valid = lcmd_valid_lsu;
        lcmd       = lcmd_lsu;
      end
  
      valid_ari: begin
        lcmd_valid = lcmd_valid_ari;
        lcmd       = lcmd_ari;
      end
    endcase
  end

  `ifdef ASSERT_ON
    `rvv_forbid(inst_valid && !lcmd_valid)
    else $info("PC(0x%h) is a reserved/nop instruction. RvvBackend.Decoder retired it directly.\n",$sampled(inst.inst_pc));
  `endif

endmodule
