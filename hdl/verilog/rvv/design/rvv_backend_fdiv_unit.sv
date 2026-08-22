`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef DIV_DEFINE_SVH
`include "rvv_backend_div.svh"
`endif

module rvv_backend_fdiv_unit(
  clk,
  rst_n,
  fdiv_uop_valid,
  fdiv_uop,
  fdiv_uop_ready,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);
  // global signals
  input   logic     clk;
  input   logic     rst_n;

  // DIV RS handshake signals
  input   logic     fdiv_uop_valid;
  input   DIV_RS_t  fdiv_uop;
  output  logic     fdiv_uop_ready;

  // DIV send result signals to ROB
  output  logic     result_valid;
  output  PU2ROB_t  result;
  input   logic     result_ready;

  // trap-flush
  input   logic     trap_flush_rvv;

//
// internal signals
//
  fpnew_pkg::operation_e              op_type;
  logic [`VLEN-1:0]                   src2;
  logic [`VLEN-1:0]                   src1;
  logic                               fdiv_busy;
  logic                               fdiv_busy_c;
  logic                               fdiv_valid;
  logic [`VLENW-1:0]                  fdiv_ready;
  FDIV_RES_t                          uop_info;
  FDIV_RES_t                          uop_info_q;
  logic [`VLEN-1:0]                   sub_result;
  logic [`VLENW-1:0]                  sub_result_vld;
  fpnew_pkg::status_t  [`VLENW-1:0]   sub_fpexp;
  
  // prepare source data
  always_comb begin
    op_type = fpnew_pkg::DIV;
    src2    = 'b0;
    src1    = 'b0;

    case(fdiv_uop.uop_funct6.ari_funct6)
      VFDIV: begin
        op_type = fpnew_pkg::DIV;
        src2    = fdiv_uop.vs2_data;

        if(fdiv_uop.uop_funct3==OPFVV) 
          src1  = fdiv_uop.vs1_data;
        else 
          src1  = {`VLENW{fdiv_uop.vs1_data[`WORD_WIDTH-1:0]}};
      end
      VFRDIV: begin
        op_type = fpnew_pkg::DIV;
        src2    = {`VLENW{fdiv_uop.vs1_data[`WORD_WIDTH-1:0]}};
        src1    = fdiv_uop.vs2_data;
      end
      VFUNARY1: begin
        op_type = fpnew_pkg::SQRT;
        src2    = fdiv_uop.vs2_data;
      end
    endcase
  end
  
  // FDIV is busy
  assign fdiv_busy_c = result_valid && result_ready || trap_flush_rvv;
  assign fdiv_valid  = !fdiv_busy && fdiv_uop_valid && (&fdiv_ready);
  // ready to receive
  assign fdiv_uop_ready = fdiv_valid;

  cdffr busy(.q(fdiv_busy), .clk(clk), .rst_n(rst_n), .c(fdiv_busy_c), .e(fdiv_valid), .d(1'b1));

  // register information 
`ifdef TB_SUPPORT
  assign uop_info.uop_pc    = fdiv_uop.uop_pc;
`endif
  assign uop_info.rob_entry = fdiv_uop.rob_entry;

  edff #(
    .T      (FDIV_RES_t)
  ) uop_information
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (fdiv_uop_valid&fdiv_uop_ready),
    .d      (uop_info),
    .q      (uop_info_q)
  );

  for(genvar i=0;i<`VLENW;i++) begin:fdiv
    fpnew_divsqrt_th_64_multi #(
      .FpFmtConfig        (5'b10000),
      .NumPipeRegs        (32'd1),
      .PipeConfig         (fpnew_pkg::BEFORE)
    )
    fdiv(
      .clk_i              (clk),
      .rst_ni             (rst_n),
      // Input signals
      .operands_i         ({src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]}), // 2 operands
      .is_boxed_i         ('1), // 2 operands
      .rnd_mode_i         (fpnew_pkg::roundmode_e'(fdiv_uop.frm)),
      .op_i               (op_type),
      .dst_fmt_i          (fpnew_pkg::FP32),
      .tag_i              ('0),
      .mask_i             ('0),
      .aux_i              ('0),
      .vectorial_op_i     ('0),
      // Input Handshake
      .in_valid_i         (fdiv_valid),
      .in_ready_o         (fdiv_ready[i]),
      .divsqrt_done_o     (),
      .simd_synch_done_i  ('0),
      .divsqrt_ready_o    (),
      .simd_synch_rdy_i   ('0),
      .flush_i            (trap_flush_rvv),
      // Output signals
      .result_o           (sub_result[i*`WORD_WIDTH +: `WORD_WIDTH]),
      .status_o           (sub_fpexp[i]),
      .extension_bit_o    (),
      .tag_o              (),
      .mask_o             (),
      .aux_o              (),
      // Output handshake 
      .out_valid_o        (sub_result_vld[i]),
      .out_ready_i        (result_valid&result_ready),
      // Indication of valid data in flight
      .busy_o             (),
      // External register enable override
      .reg_ena_i          ('0),
      // Early valid for external structural hazard generation
      .early_out_valid_o  ()
    );

  // submit result to ROB
    assign result.fpexp[i*4+:4] = {4{sub_fpexp[i]}};
  end
    
  assign result_valid     = &sub_result_vld;
`ifdef TB_SUPPORT
  assign result.uop_pc    = uop_info_q.uop_pc;
`endif
  assign result.rob_entry = uop_info_q.rob_entry;
  assign result.w_data    = sub_result;
  assign result.w_valid   = 'b1;
  assign result.vsaturate = 'b0;

endmodule
