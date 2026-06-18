`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_pe_adder_fp_lane#(
  parameter int unsigned  NUM_MID_REGS = 32'd1,
  // Do not change
  localparam int unsigned WIDTH        = 32'd32
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic[NUM_MID_REGS-1:0]      reg_enable,
  input  logic                        up_valid,
  
  // Input signals
  input logic [1:0][`WORD_WIDTH-1:0]  operands,
  input logic                         do_subtract,  // 1: result=operands[0]-operands[1]
  input fpnew_pkg::roundmode_e        rnd_mode,

  // Output signals
  output logic [`WORD_WIDTH-1:0]      result,
  output fpnew_pkg::status_t          status,
  output logic                        down_valid
);

  // ----------
  // Add / subtract with align
  // ----------
  logic sum_sign;
  logic [8:0] sum_exponent;
  logic [23:0]sum_significand;
  logic sum_round_bit, sum_sticky_bit, sum_sticky_msb;
  logic special_nan, special_inf, special_inf_sign, special_invalid, align_overflow;

  fp_addfront#(
    .IN_EXP_BITS (32'd8),
    .IN_MANT_BITS(32'd23),
    .OUT_EXP_BITS(32'd9),
    .OUT_SIG_BITS(32'd24)
  ) u_addfront (
    .a_sign     (operands[0][31]),
    .a_exponent (operands[0][30:23]),
    .a_mantissa (operands[0][22: 0]),
    .b_sign     (operands[1][31]),
    .b_exponent (operands[1][30:23]),
    .b_mantissa (operands[1][22: 0]),
    .do_subtract(do_subtract),

    // add/subtract output
    .result_sign       (sum_sign       ),
    .result_exponent   (sum_exponent   ),
    .result_significand(sum_significand),
    .result_round_bit  (sum_round_bit  ),
    .result_sticky_bit (sum_sticky_bit ),
    .result_sticky_msb (sum_sticky_msb ),
            
    // special cases for sum
    .special_nan     (special_nan     ),
    .special_inf     (special_inf     ),
    .special_inf_sign(special_inf_sign),
    .special_invalid (special_invalid ),
    .align_overflow  (align_overflow  )
  );

  `ifdef ASSERT_ON
    `rvv_expect(`WORD_WIDTH == 32)
      else $warning("We only support FP32 currently");
    `rvv_forbid(up_valid && reg_enable[0] && sum_significand[23] != (sum_exponent == 0))
      else $warning("Significand and exponent argue on sum stage is a subnormal");
  `endif

  // ----------
  // Mid pipeline
  // ----------
  typedef struct packed {
    logic                  en;
    logic                  sign;
    logic [8:0]            exponent;
    logic [22:0]           mantissa;
    logic                  round_bit, sticky_bit, sticky_msb;
    logic                  special_nan, special_inf, special_inf_sign, special_invalid;
    logic                  align_overflow;
    fpnew_pkg::roundmode_e rnd_mode;
  } mid_reg_t;
  mid_reg_t [0:NUM_MID_REGS] mid_pipe;

  assign mid_pipe[0].en               = up_valid;
  assign mid_pipe[0].sign             = sum_sign;
  assign mid_pipe[0].exponent         = sum_exponent;
  assign mid_pipe[0].mantissa         = sum_significand[22:0];
  assign mid_pipe[0].round_bit        = sum_round_bit;
  assign mid_pipe[0].sticky_bit       = sum_sticky_bit;
  assign mid_pipe[0].sticky_msb       = sum_sticky_msb;
  assign mid_pipe[0].special_nan      = special_nan;
  assign mid_pipe[0].special_inf      = special_inf;
  assign mid_pipe[0].special_inf_sign = special_inf_sign;
  assign mid_pipe[0].special_invalid  = special_invalid;
  assign mid_pipe[0].align_overflow   = align_overflow;
  assign mid_pipe[0].rnd_mode         = rnd_mode;

  // Generate the register stages
  for (genvar i = 0; i < NUM_MID_REGS; i++) begin: gen_mid_pipeline
    edff #(.T(mid_reg_t)) mid_reg(.q(mid_pipe[i+1]), .d(mid_pipe[i]), .e(reg_enable[i] & mid_pipe[i].en),
      .clk(clk), .rst_n(rst_n));
  end

  // Output stage
  wire fpnew_pkg::roundmode_e rnd_mode_q = mid_pipe[NUM_MID_REGS].rnd_mode;
  assign down_valid                      = mid_pipe[NUM_MID_REGS].en; 
  // ----------
  // rounding
  // ----------

  logic [WIDTH-1:0]        round_normal_result;
  fpnew_pkg::status_t      round_status;
  fp_rounding#(
    .FP_FMT_CONFIG(5'b10001) // only FP32 should be fine, but lint failed
  ) u_rounding (
    .dst_fmt             (fpnew_pkg::FP32),
    .rnd_mode            (rnd_mode_q),
    .exact_zero_keep_sign(rnd_mode_q != fpnew_pkg::ROD),  // TODO: align behavior with model
    .preround_sign       (mid_pipe[NUM_MID_REGS].sign),
    .preround_exponent   (mid_pipe[NUM_MID_REGS].exponent),
    .preround_mantissa   (mid_pipe[NUM_MID_REGS].mantissa),
    .round_bit           (mid_pipe[NUM_MID_REGS].round_bit),
    .sticky_bit          (mid_pipe[NUM_MID_REGS].sticky_bit),
    .sticky_msb          (mid_pipe[NUM_MID_REGS].sticky_msb),

    .round_normal_result (round_normal_result),
    .status              (round_status));


  wire [31:0] fp32_inf = {mid_pipe[NUM_MID_REGS].special_inf_sign, 8'b1, 23'b0};
   // special mux
  always_comb begin
    if (mid_pipe[NUM_MID_REGS].special_nan) begin
      result = {1'b0, 8'b1, 1'b1, 22'b0};  // qNaN
      status = '{NV: mid_pipe[NUM_MID_REGS].special_invalid, default: '0};
    end else if (mid_pipe[NUM_MID_REGS].special_inf) begin
      result = fp32_inf;
      status = '0;
    end else begin
      result = round_status.OF ? fp32_inf : round_normal_result;
      status = round_status;
    end
  end
endmodule
