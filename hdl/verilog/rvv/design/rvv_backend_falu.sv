`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

// description
// this module decode floating point instruction to sub uop unit
// and pass results from these submodules to ROB

module rvv_backend_falu( 
  clk, 
  rst_n,          
  pop,            
  uop_valid,
  uop,     
  result_valid,
  result,  
  result_ready,
  trap_flush_rvv 
);

  // global signal
  input   logic                         clk;
  input   logic                         rst_n;
  // FALU RS to FALU unit
  output  logic       [`NUM_FALU-1:0]   pop;
  input   logic       [`NUM_FALU-1:0]   uop_valid;    
  input   FALU_RS_t   [`NUM_FALU-1:0]   uop;
  // submit FALU
  output  logic       [`NUM_FALU-1:0]   result_valid;
  output  PU2ROB_t    [`NUM_FALU-1:0]   result;
  input   logic       [`NUM_FALU-1:0]   result_ready;
  // trap-flush
  input   logic                         trap_flush_rvv; 

//
// internal signals
//
  //internal decode logic for subtype
  logic     [`NUM_FALU-1:0]       uop_addmul;
  logic     [`NUM_FALU-1:0]       uop_cmp;
  logic     [`NUM_FALU-1:0]       uop_cvt;
  logic     [`NUM_FALU-1:0]       uop_tbl;
  logic     [`NUM_FALU-1:0][3:0]  uop_type;
  logic     [`NUM_FALU-1:0][3:0]  falu_uop_type;

  logic     [`NUM_FALU-1:0]       falu_uop_vld;
  logic     [`NUM_FALU-1:0][3:0]  falu_uop_rdy;
  FALU_RS_t [`NUM_FALU-1:0]       falu_uop;

  logic     [`NUM_FALU-1:0]       falu_result_vld;
  logic     [`NUM_FALU-1:0]       falu_result_rdy;
  PU2ROB_t  [`NUM_FALU-1:0]       falu_result;

  genvar                          i;

//
// code start
//
  assign uop_addmul[0]  = uop[0].uop_exe_unit==FMA;
  assign uop_cmp[0]     = uop[0].uop_exe_unit==FNCMP || ((uop[0].uop_exe_unit==FCMP)&falu_uop_rdy[0][1]);
  assign uop_cvt[0]     = uop[0].uop_exe_unit==FCVT;
  assign uop_tbl[0]     = uop[0].uop_exe_unit==FTBL;
  assign uop_type[0]    = {uop_tbl[0], uop_cvt[0], uop_cmp[0], uop_addmul[0]};

  generate
    for(i=1;i<`NUM_FALU;i++) begin
      assign uop_addmul[i]  = uop[i].uop_exe_unit==FMA;
      assign uop_cmp[i]     = uop[i].uop_exe_unit==FNCMP;
      assign uop_cvt[i]     = uop[i].uop_exe_unit==FCVT;
      assign uop_tbl[i]     = uop[i].uop_exe_unit==FTBL;
      assign uop_type[i]    = {uop_tbl[i], uop_cvt[i], uop_cmp[i], uop_addmul[i]};
    end
  endgenerate

  //uop select
  //if unit0 available for uop0
  //  will always pass uop0 to unit0
  //if not
  //  check if unit1 available for uop0
  //    if so, further check if unit0 available for uop1
  //    if not, block all dispatched uop  
  always_comb
  begin
    falu_uop      = '0;
    falu_uop_vld  = '0;
    falu_uop_type = '0;
    pop           = '0;

    //unit0 ready for uo0
    if(|(uop_type[0]&falu_uop_rdy[0])) begin
      falu_uop[0]         = uop[0];
      falu_uop_vld[0]     = uop_valid[0];
      falu_uop_type[0]    = uop_type[0];
      pop[0]              = uop_valid[0];           
      //unit1 ready for uo1
      if(|(uop_type[1]&falu_uop_rdy[1])) begin
        falu_uop[1]       = uop[1];
        falu_uop_vld[1]   = uop_valid[1];
        falu_uop_type[1]  = uop_type[1];
        pop[1]            = uop_valid[1];
      end
    end
    else begin//unit0 not ready for uop0
      //check unit1 ready for uop0, since uop0 has higher pri
      if(|(uop_type[0]&falu_uop_rdy[1])) begin
        falu_uop[1]         = uop[0];
        falu_uop_vld[1]     = uop_valid[0];
        falu_uop_type[1]    = uop_type[0];
        pop[0]              = uop_valid[0];           
        //check unit0 ready for uop1
        if(|(uop_type[1]&falu_uop_rdy[0])) begin
          falu_uop[0]       = uop[1];
          falu_uop_vld[0]   = uop_valid[1];
          falu_uop_type[0]  = uop_type[1];
          pop[1]            = uop_valid[1];
        end
      end
    end
  end

  //for commitment, we support out-of-order
  //so directly pass 2 results to ROB
  assign result_valid   = falu_result_vld;
  assign result         = falu_result;
  assign falu_result_rdy = result_ready;

  generate
    for(i=0;i<`NUM_FALU;i++) begin:uop_unit
      rvv_backend_falu_unit #() 
      falu_uop_unit(
        //global
        .clk                  (clk),
        .rst_n                (rst_n),
        //rs in
        .falu_uop_vld         (falu_uop_vld[i]),
        .falu_uop             (falu_uop[i]),
        //dec type
        .falu_type            (falu_uop_type[i]),
        //rdy to rs
        .falu_uop_addmul_rdy  (falu_uop_rdy[i][0]),
        .falu_uop_cmp_rdy     (falu_uop_rdy[i][1]),
        .falu_uop_cvt_rdy     (falu_uop_rdy[i][2]),
        .falu_uop_tbl_rdy     (falu_uop_rdy[i][3]),
        //flush
        .trap_flush_rvv       (trap_flush_rvv),
        //result to rob
        .falu_result_vld      (falu_result_vld[i]),
        .falu_result          (falu_result[i]),
        //rob ready 2 unit
        .falu_result_rdy      (falu_result_rdy[i])
      );
    end
  endgenerate

endmodule
