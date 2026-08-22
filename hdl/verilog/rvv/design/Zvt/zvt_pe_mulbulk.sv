`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module zvt_pe_mulbulk #(
  parameter fpnew_pkg::fmt_logic_t   FP_FMT_CONFIG    = 5'b10001,          // Indicates which data types are supported
  parameter logic [1:0]              INT_FMT_CONFIG   = 2'b11,             // 2'b11:{1'b1(int16), 1'b1(int8)}
  parameter int unsigned             NUM_PIPE_REGS    = 32'b0,             // Configurable pipeline length
  parameter fpnew_pkg::pipe_config_t PIPE_CONFIG      = fpnew_pkg::BEFORE, // Pipeline layout.
  parameter type                     TAG_TYPE         = logic,             // Extra information pipeline.
  parameter                          REMV_PIPE_BUBBLE = 0,
  // Do not change
  localparam int unsigned WIDTH      = 32'd32  // originally fpnew_pkg::max_fp_width(FP_FMT_CONFIG), will error with int and without FP32 support
) (
  input  logic                        clk,
  input  logic                        rst_n,
  // Input signals
  input  logic [1:0][WIDTH-1:0]       operands,   // The operands. operands[0]:src1, operands[1]:src2
  input  fpnew_pkg::roundmode_e       rnd_mode,   // rounding mode
  input  PEOPCODE_e                   op,         // opcode
  input  logic                        op_mod,     // altfmt for src1.
  input  fpnew_pkg::fp_format_e       fsrc_fmt,   // format of the fp source
  input  fpnew_pkg::int_format_e      isrc_fmt,   // format of the int source
  input  fpnew_pkg::fp_format_e       fdst_fmt,   // format of the fp result
  input  fpnew_pkg::int_format_e      idst_fmt,   // format of the int result
  input  TAG_TYPE                     in_tag,     // Command information
  input  logic [WIDTH/8-1:0]          mask,       // byte-mask for the source
  // Input Handshake
  input  logic                        in_valid,   
  output logic                        in_ready,
  input  logic                        flush,      // flush all valid registers
  // Output signals
  output logic [WIDTH-1:0]            result,   
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
  // Descending range to match `handshake_multistage_ctrl`'s port declaration
  // (output [N-1:0] reg_enable). Mixing ascending [0:N-1] here causes
  // SystemVerilog port-connection rules to reverse the bit order, so the
  // input register would fire on what handshake intended as the output
  // stage enable -- the input operands clear before the input reg captures.
  logic [NUM_PIPE_REGS-1:0] reg_enable;  // reg_ena[i] indicates data reg enable signal on i-th stage
  handshake_multistage_ctrl#(
    .NUM_PIPE_REGS(NUM_PIPE_REGS),
    .REMV_PIPE_BUBBLE(REMV_PIPE_BUBBLE)
  ) u_handshake (
    .clk        (clk),
    .rst_n      (rst_n),
    .flush      (flush),
    .up_valid   (in_valid),
    .up_ready   (in_ready),
    .down_valid (/*unused*/),
    .down_ready (out_ready),
    .reg_enable (reg_enable),
    .valids     (out_valid),
    .busy       (busy)
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
    logic [1:0][WIDTH-1:0]       operands;
    logic [WIDTH/8-1:0]          mask    ;
    fpnew_pkg::roundmode_e       rnd_mode;
    PEOPCODE_e                   op      ;
    logic                        op_mod  ;
    fpnew_pkg::fp_format_e       fsrc_fmt;
    fpnew_pkg::int_format_e      isrc_fmt;
    fpnew_pkg::fp_format_e       fdst_fmt;
    fpnew_pkg::int_format_e      idst_fmt;
  } input_reg_t;
  // pipeline signals
  input_reg_t [0:NUM_INP_REGS] input_pipe;
  // Input stage
  assign input_pipe[0].operands = operands;
  assign input_pipe[0].mask     = mask    ;
  assign input_pipe[0].rnd_mode = rnd_mode;
  assign input_pipe[0].op       = op      ;
  assign input_pipe[0].op_mod   = op_mod  ;
  assign input_pipe[0].fsrc_fmt = fsrc_fmt;
  assign input_pipe[0].isrc_fmt = isrc_fmt;
  assign input_pipe[0].fdst_fmt = fdst_fmt;
  assign input_pipe[0].idst_fmt = idst_fmt;
  // Generate the register stages
  for (genvar i = 0; i < NUM_INP_REGS; i++) begin: gen_input_pipeline
    edff #(.T(input_reg_t)) input_reg(.q(input_pipe[i+1]), .d(input_pipe[i]), .e(reg_enable[i]), .clk(clk), .rst_n(rst_n));
  end
  // Output stage
  wire [1:0][WIDTH-1:0]        operands_q = input_pipe[NUM_INP_REGS].operands;
  wire [WIDTH/8-1:0]           mask_q     = input_pipe[NUM_INP_REGS].mask    ;
  wire fpnew_pkg::roundmode_e  rnd_mode_q = input_pipe[NUM_INP_REGS].rnd_mode;
  wire PEOPCODE_e              op_q       = input_pipe[NUM_INP_REGS].op      ;
  wire                         op_mod_q   = input_pipe[NUM_INP_REGS].op_mod  ;
  wire fpnew_pkg::fp_format_e  fsrc_fmt_q = input_pipe[NUM_INP_REGS].fsrc_fmt;
  wire fpnew_pkg::int_format_e isrc_fmt_q = input_pipe[NUM_INP_REGS].isrc_fmt;
  wire fpnew_pkg::fp_format_e  fdst_fmt_q = input_pipe[NUM_INP_REGS].fdst_fmt;
  wire fpnew_pkg::int_format_e idst_fmt_q = input_pipe[NUM_INP_REGS].idst_fmt;

  // ----------
  // Lane classify
  // ----------
  logic inp_lane_fp;  // floating-point lane
  logic inp_lane_int; // integer lane
  assign inp_lane_fp  = op_q == FPMUL;
  assign inp_lane_int = op_q == INTMUL || op_q == UINTMUL;  // Do not validate input op now

  `ifdef ASSERT_ON
    `rvv_forbid(reg_enable[NUM_INP_REGS] && !(inp_lane_fp | inp_lane_int))
      else $warning("MulBulk input handshaked with no lane hit");
 `endif

  // ----------
  // Lane dispatch & collect
  // ----------

  wire [NUM_MID_REGS-1:0] mid_reg_enable = reg_enable[NUM_INP_REGS +: NUM_MID_REGS];
  logic [WIDTH-1:0]   fp_result, int_result, lanes_result;
  fpnew_pkg::status_t fp_status, int_status, lanes_status;
  logic               fp_valid,  int_valid;
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

  zvt_pe_mulbulk_fp_lane#(
    .FP_FMT_CONFIG(FP_FMT_CONFIG),
    .NUM_MID_REGS(NUM_MID_REGS)
  ) u_float_lane (
    .clk(clk),
    .rst_n(rst_n),
    .reg_enable(mid_reg_enable),
    .up_valid(inp_lane_fp),

    .operands(operands_q),
    .rnd_mode(rnd_mode_q),
    .mask(mask_q),
    .src_fmt(fsrc_fmt_q),
    .dst_fmt(fdst_fmt_q),

    .result(fp_result),
    .status(fp_status),
    .down_valid(fp_valid)
  );

  zvt_pe_mulbulk_int_lane#(
    .WIDTH(WIDTH),
    .INT_FMT_CONFIG(INT_FMT_CONFIG),
    .NUM_MID_REGS(NUM_MID_REGS)
  ) u_int_lane (
    .clk(clk),
    .rst_n(rst_n),
    .reg_enable(mid_reg_enable),
    .up_valid(inp_lane_int),

    .operand_signed({op_mod_q, op_q == INTMUL}),
    .operands(operands_q),
    .mask(mask_q),
    .src_fmt(isrc_fmt_q),
    .dst_fmt(idst_fmt_q),
    .result(int_result),
    .status(int_status),
    .down_valid(int_valid)
  );

  // ----------
  // Output pipeline
  // ----------
  localparam OUT_REG_START =     NUM_OUT_REGS < 1 ? 0 : (NUM_INP_REGS+NUM_MID_REGS);
  localparam NUM_OUT_REGS_OR_1 = NUM_OUT_REGS < 1 ? 1 : NUM_OUT_REGS;  // in case of error on below line when NUM_OUT_REGS==0
  wire [NUM_OUT_REGS_OR_1-1:0] out_reg_enable = reg_enable[OUT_REG_START +: NUM_OUT_REGS_OR_1];
  typedef struct packed {
    logic [WIDTH-1:0]   result;
    fpnew_pkg::status_t status;
  } output_reg_t;
  // pipeline signals
  output_reg_t [0:NUM_OUT_REGS] output_pipe;
  // Input stage
  assign output_pipe[0].result = lanes_result;
  assign output_pipe[0].status = lanes_status;
  // Generate the register stages
  for (genvar i = 0; i < NUM_OUT_REGS; i++) begin
    edff #(.T(output_reg_t)) output_reg(.q(output_pipe[i+1]), .d(output_pipe[i]), .e(out_reg_enable[i]), .clk(clk), .rst_n(rst_n));
  end
  // Output stage
  assign result = output_pipe[NUM_OUT_REGS].result;
  assign status = output_pipe[NUM_OUT_REGS].status;

endmodule
