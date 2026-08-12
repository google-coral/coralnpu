
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_div
( 
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

//
// interface signals
//
  // global signals
  input   logic     clk;
  input   logic     rst_n;

  // DIV RS to DIV unit
  input   logic     [`NUM_DIV-1:0]  uop_valid;
  input   DIV_RS_t  [`NUM_DIV-1:0]  uop;
  output  logic     [`NUM_DIV-1:0]  pop;

  // submit DIV result to ROB
  output  logic     [`NUM_DIV-1:0]  result_valid;
  output  PU2ROB_t  [`NUM_DIV-1:0]  result;
  input   logic     [`NUM_DIV-1:0]  result_ready;
  
  // trap-flush
  input   logic                     trap_flush_rvv;  

//
// internal signals
//
  //fix point signal
  logic             [`NUM_DIV-1:0]  x_uop_vld;
  logic             [`NUM_DIV-1:0]  x_uop_rdy;
  logic             [`NUM_DIV-1:0]  x_result_vld;
  PU2ROB_t          [`NUM_DIV-1:0]  x_result;
  logic             [`NUM_DIV-1:0]  x_result_rdy;

`ifdef ZVE32F_ON
  //floating point signal for fpnew div
  logic             [`NUM_DIV-1:0]  fp_uop_vld;
  logic             [`NUM_DIV-1:0]  fp_uop_rdy;
  logic             [`NUM_DIV-1:0]  fp_result_vld;
  PU2ROB_t          [`NUM_DIV-1:0]  fp_result;
  logic             [`NUM_DIV-1:0]  fp_result_rdy;

  logic                      [1:0]  arb_req;
  logic                      [1:0]  arb_grt;
`endif

  // for-loop
  genvar                            i;

//
// Instantiate rvv_backend_div_unit
//
  // instantiate
  generate
    for (i=0;i<`NUM_DIV;i++) begin: DIV_UNIT
      assign x_uop_vld[i] = uop_valid[i] & uop[i].is_div; 

      rvv_backend_div_unit u_div_unit
        (
          .clk            (clk),
          .rst_n          (rst_n),
          .div_uop_valid  (x_uop_vld[i]),
          .div_uop        (uop[i]),
          .div_uop_ready  (x_uop_rdy[i]),
          .result_valid   (x_result_vld[i]),
          .result         (x_result[i]),
          .result_ready   (x_result_rdy[i]),
          .trap_flush_rvv (trap_flush_rvv)
        );

    `ifdef ZVE32F_ON
      assign fp_uop_vld[i] = uop_valid[i] & !uop[i].is_div; 

      rvv_backend_fdiv_unit u_fdiv_unit
        (
          .clk            (clk),
          .rst_n          (rst_n),
          .fdiv_uop_valid (fp_uop_vld[i]),
          .fdiv_uop       (uop[i]),
          .fdiv_uop_ready (fp_uop_rdy[i]),
          .result_valid   (fp_result_vld[i]),
          .result         (fp_result[i]),
          .result_ready   (fp_result_rdy[i]),
          .trap_flush_rvv (trap_flush_rvv)
        );
    `endif
    end

    // generate pop signals
    assign pop[0] = x_uop_vld[0]&x_uop_rdy[0] 
                  `ifdef ZVE32F_ON
                    || fp_uop_vld[0]&fp_uop_rdy[0]
                  `endif
                    ;
  endgenerate

`ifdef ZVE32F_ON
  assign arb_req = {fp_result_vld[0], x_result_vld[0]};

  arb_round_robin #(
    .REQ_NUM    (2),
    .T          (PU2ROB_t)
  ) arb2rob (
    .clk        (clk), 
    .rst_n      (rst_n), 
    .req        (arb_req), 
    .reqData    ({fp_result[0], x_result[0]}),
    .grant      (arb_grt),
    .grantData  (result[0])
  );

  assign result_valid[0]  = |arb_req;
  assign x_result_rdy[0]  = arb_grt[0] & result_ready[0];
  assign fp_result_rdy[0] = arb_grt[1] & result_ready[0];
`else
  assign result_valid[0]  = x_result_vld[0];
  assign result[0]        = x_result[0];
  assign x_result_rdy[0]  = result_ready[0];
`endif

endmodule
