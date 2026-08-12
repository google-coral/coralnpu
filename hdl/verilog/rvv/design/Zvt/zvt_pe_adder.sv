`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_pe_adder #(
  parameter int unsigned             NUM_PIPE_REGS = 32'b0,              // Configurable pipeline length
  parameter fpnew_pkg::pipe_config_t PIPE_CONFIG   = fpnew_pkg::BEFORE,  // Pipeline layout.
  parameter type                     TAG_TYPE     = logic,               // Extra information pipeline.
  parameter                          REMV_PIPE_BUBBLE = 0
) (
  input  logic                        clk,
  input  logic                        rst_n,
  // Input signals
  input  logic [1:0][`WORD_WIDTH-1:0] operands,   // The operands. operands_i[0]:src1, operands_i[1]:src2
  input  fpnew_pkg::roundmode_e       rnd_mode,   // rounding mode
  input  logic                        op_mod,     // 0: result=src1+src2; 1: result=src1-src2.
  input  logic                        op,         // opcode. 0: int32 adder; 1: FP32 adder.
  input  TAG_TYPE                     in_tag,     // Command information
  // Input Handshake
  input  logic                        in_valid,   
  output logic                        in_ready,
  input  logic                        flush,      // flush all valid registers
  // Output signals
  output logic [`WORD_WIDTH-1:0]      result,   
  output fpnew_pkg::status_t          status,     // fp exception
  output TAG_TYPE [NUM_PIPE_REGS:1]   out_tag,    // Command information.
  // Output handshake
  output logic   [NUM_PIPE_REGS:1]    out_valid,
  input  logic                        out_ready,
  // Indication of valid data in flight
  output logic                        busy
);

  // ----------
  // Handshake & control logic
  // ----------
  logic down_valid;  // unused
  // Descending range to match `handshake_multistage_ctrl`'s [N-1:0]
  // declaration (see comment in zvt_pe_mulbulk.sv).
  logic [NUM_PIPE_REGS-1:0] reg_enable;  // reg_ena[i] indicates data reg enable signal on i-th stage
  handshake_multistage_ctrl#(
    .NUM_PIPE_REGS(NUM_PIPE_REGS),
    .REMV_PIPE_BUBBLE(REMV_PIPE_BUBBLE)
  ) u_handshake (
    .clk(clk),
    .rst_n(rst_n),
    .flush(flush),
    .up_valid(in_valid),
    .up_ready(in_ready),
    .down_valid(down_valid),
    .down_ready(out_ready),
    .reg_enable(reg_enable),
    .valids(out_valid),
    .busy(busy)
  );

  // ----------
  // Global data channel(tag)
  // ----------
  TAG_TYPE [NUM_PIPE_REGS:0] pip_tag;
  assign pip_tag[0] = in_tag;
  assign out_tag = pip_tag[NUM_PIPE_REGS:1];
  for (genvar i = 0; i < NUM_PIPE_REGS; i++) begin: gen_tag_pip
    edff #(.T(TAG_TYPE)) tag_reg(.q(pip_tag[i+1]), .d(pip_tag[i]), .e(reg_enable[i]), .clk(clk), .rst_n(rst_n));
  end

  // ----------
  // Constants 
  // ----------
  localparam NUM_INP_REGS = PIPE_CONFIG == fpnew_pkg::BEFORE
                            ? NUM_PIPE_REGS
                            : (PIPE_CONFIG == fpnew_pkg::DISTRIBUTED
                               ? ((NUM_PIPE_REGS + 1) / 3) // Second to get distributed regs
                               : 0); // no regs here otherwise
  localparam NUM_MID_REGS = PIPE_CONFIG == fpnew_pkg::INSIDE
                          ? NUM_PIPE_REGS
                          : (PIPE_CONFIG == fpnew_pkg::DISTRIBUTED
                             ? ((NUM_PIPE_REGS + 2) / 3) // First to get distributed regs
                             : 0); // no regs here otherwise
  localparam NUM_OUT_REGS = PIPE_CONFIG == fpnew_pkg::AFTER
                            ? NUM_PIPE_REGS
                            : (PIPE_CONFIG == fpnew_pkg::DISTRIBUTED
                               ? (NUM_PIPE_REGS / 3) // Last to get distributed regs
                               : 0); // no regs here otherwise

  // ----------
  // Input pipeline
  // ----------
  typedef struct packed {
    logic [1:0][`WORD_WIDTH-1:0] operands;
    fpnew_pkg::roundmode_e       rnd_mode;
    logic                        op      ;
    logic                        op_mod  ;
  } input_reg_t;
  // pipeline signals
  input_reg_t [0:NUM_INP_REGS] input_pipe;
  // Input stage
  assign input_pipe[0].operands = operands;
  assign input_pipe[0].rnd_mode = rnd_mode;
  assign input_pipe[0].op       = op      ;
  assign input_pipe[0].op_mod   = op_mod  ;

  for (genvar i = 0; i < NUM_INP_REGS; i++) begin: gen_input_pipeline
    edff #(.T(input_reg_t)) input_reg(.q(input_pipe[i+1]), .d(input_pipe[i]), .e(reg_enable[i]),
      .clk(clk), .rst_n(rst_n));
  end
  // Output stage
  wire [1:0][`WORD_WIDTH-1:0]  operands_q = input_pipe[NUM_INP_REGS].operands;
  wire fpnew_pkg::roundmode_e  rnd_mode_q = input_pipe[NUM_INP_REGS].rnd_mode;
  wire logic                   op_q       = input_pipe[NUM_INP_REGS].op      ;
  wire                         op_mod_q   = input_pipe[NUM_INP_REGS].op_mod  ;

  // ----------
  // Lane classify
  // ----------
  wire inp_lane_fp  = op_q == 1'b1;  // floating-point lane
  wire inp_lane_int = op_q == 1'b0;  // integer lane

  `ifdef ASSERT_ON
    `rvv_forbid(reg_enable[NUM_INP_REGS] && !(inp_lane_fp | inp_lane_int));
  `endif

  // ----------
  // Lane dispatch & collect
  // ----------
  wire [NUM_MID_REGS-1:0] mid_reg_enable = reg_enable[NUM_INP_REGS +: NUM_MID_REGS];
  logic [`WORD_WIDTH-1:0] fp_result, int_result, lanes_result;
  fpnew_pkg::status_t     fp_status, int_status, lanes_status;
  logic                   fp_valid,  int_valid;
  `ifdef ASSERT_ON
    `rvv_forbid(reg_enable[NUM_INP_REGS+NUM_MID_REGS] & (fp_valid == int_valid))
      else $warning("Mul-Bulk output pipeline valid when not exactly one of fp/int_valid is assert");
  `endif

  always_comb begin
    if (fp_valid) begin
      lanes_result = fp_result;
      lanes_status = fp_status;
    end else begin
      lanes_result = int_result;
      lanes_status = int_status;
    end
  end

  zvt_pe_adder_fp_lane#(
    .NUM_MID_REGS(NUM_MID_REGS)
  ) u_float_lane (
    .clk(clk),
    .rst_n(rst_n),
    .reg_enable(mid_reg_enable),
    .up_valid(inp_lane_fp),

    .operands(operands_q),
    .do_subtract(op_mod_q),
    .rnd_mode(rnd_mode_q),

    .result(fp_result),
    .status(fp_status),
    .down_valid(fp_valid)
  );

  zvt_pe_adder_int_lane#(
    .NUM_MID_REGS(NUM_MID_REGS)
  ) u_int_lane (
    .clk(clk),
    .rst_n(rst_n),
    .reg_enable(mid_reg_enable),
    .up_valid(inp_lane_int),

    .operands(operands_q),
    .do_subtract(op_mod_q),


    .result(int_result),
    .status(int_status),
    .down_valid(int_valid)
  );
  
  // ----------
  // Output pipeline
  // ----------
  wire [NUM_OUT_REGS-1:0] out_reg_enable = reg_enable[NUM_INP_REGS+NUM_MID_REGS +: NUM_OUT_REGS];
  typedef struct packed {
    logic [`WORD_WIDTH-1:0]   result;
    fpnew_pkg::status_t status;
  } output_reg_t;
  // pipeline signals
  output_reg_t [0:NUM_OUT_REGS] output_pipe;
  // Input stage
  assign output_pipe[0].result = lanes_result;
  assign output_pipe[0].status = lanes_status;
  // Generate the register stages
  for (genvar i = 0; i < NUM_OUT_REGS; i++) begin
    edff #(.T(output_reg_t)) output_reg(.q(output_pipe[i+1]), .d(output_pipe[i]), .e(out_reg_enable[i]),
      .clk(clk), .rst_n(rst_n));
  end
  // Output stage
  assign result = output_pipe[NUM_OUT_REGS].result;
  assign status = output_pipe[NUM_OUT_REGS].status;


endmodule
