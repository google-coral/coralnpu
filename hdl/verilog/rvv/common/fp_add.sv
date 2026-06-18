module fp_add #(
  parameter fpnew_pkg::fmt_logic_t   FP_FMT_CONFIG    = 5'b10000,                // Indicates which data types are supported
  parameter int unsigned             NUM_PIPE_REGS    = 0,                       // Configurable pipeline length
  parameter fpnew_pkg::pipe_config_t PIPE_CONFIG      = fpnew_pkg::BEFORE,       // Pipeline layout.
  parameter type                     TAG_TYPE         = logic,                   // Extra information pipeline.
  parameter                          REMV_PIPE_BUBBLE = 1,
  // Do not change
  localparam int unsigned WIDTH          = fpnew_pkg::max_fp_width(FpFmtConfig),
  localparam int unsigned NUM_FORMATS    = fpnew_pkg::NUM_FP_FORMATS
) (
  input  logic                        clk,
  input  logic                        rst_n,
  // Input signals
  input  logic [1:0][WIDTH-1:0]       operands,   // The operands. operands_i[0]:src1, operands_i[1]:src2
  input  fpnew_pkg::roundmode_e       rnd_mode,   // rounding mode
  input  logic                        op_mod,     // 0: result=src1+src2; 1: result=src1-src2.
  input  fpnew_pkg::fp_format_e       src_fmt,    // format of the source
  input  fpnew_pkg::fp_format_e       dst_fmt,    // format of the result
  input  TagType                      in_tag,     // Command information
  // Input Handshake
  input  logic                        in_valid,   
  output logic                        in_ready,
  input  logic                        flush,      // flush all valid registers
  // Output signals
  output logic [WIDTH-1:0]            result,   
  output fpnew_pkg::status_t          status,     // fp exception
  output TagType [NumPipeRegs:1]      out_tag,    // Command information.
  // Output handshake
  output logic [NumPipeRegs:1]        out_valid,
  input  logic                        out_ready,
  // Indication of valid data in flight
  output logic                        busy
);

  // ----------
  // Handshake & control logic
  // ----------
  logic [0:NUM_PIPE_REGS-1] reg_enable;  // reg_ena[i] indicates data reg enable signal on i-th stage
  handshake_multistage_ctrl#(
    .NUM_PIPE_REGS(NUM_PIPE_REGS),
    .REMV_PIPE_BUBBLE(REMV_PIPE_BUBBLE)
  ) u_handshake (
    .up_valid(in_valid),
    .up_ready(in_ready),
    .down_valid(out_valid),
    .down_ready(out_ready),
    .reg_enable(reg_enable),
    .busy(busy)
  );

  // ----------
  // Global data channel(tag)
  // ----------
  TAG_TYPE [0:NUM_PIPE_REGS] pip_tag;
  assign pip_tag[0] = in_tag;
  assign out_tag = pip_tag[NUM_PIPE_REGS];
  for (genvar i = 0; i < NUM_PIPE_REGS; i++) begin: gen_tag_pip
    edff #(.T(TAG_TYPE)) tag_reg(.q(pip_tag[i+1]), .d(pip_tag[i]), .e(reg_enable[i]), clk(clk), .rst_n(rst_n));
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
    fpnew_pkg::roundmode_e       rnd_mode;
    logic                        op_mod  ;
    fpnew_pkg::fp_format_e       src_fmt ;
    fpnew_pkg::fp_format_e       dst_fmt ;
  } input_reg_t;
  // pipeline signals
  input_reg_t [0:NUM_INP_REGS] input_pipe;
  // Input stage
  assign input_pipe[0].operands = operands;
  assign input_pipe[0].mask     = mask    ;
  assign input_pipe[0].rnd_mode = rnd_mode;
  assign input_pipe[0].op_mod   = op_mod  ;
  assign input_pipe[0].src_fmt  = src_fmt ;
  assign input_pipe[0].dst_fmt  = dst_fmt ;

  for (genvar i = 0; i < NUM_INP_REGS; i++) begin: gen_input_pipeline
    edff #(.T(input_reg_t)) input_reg(.q(input_pipe[i+1]), .d(input_pipe[i]), .e(reg_enable[i]),
      .clk(clk), .rst_n(rst_n));
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


endmodule
