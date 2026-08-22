`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module zvt_pe_mulbulk_int_lane#(
  parameter int unsigned             WIDTH = 32,
  parameter logic [1:0]              INT_FMT_CONFIG = 2'b11,    // 2'b11:{1'b1(int16), 1'b1(int8)}
  parameter int unsigned             NUM_MID_REGS = 1
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic[NUM_MID_REGS-1:0]      reg_enable,
  input  logic                        up_valid,

  input  logic [1:0]                  operand_signed,
  input  logic [1:0][WIDTH-1:0]       operands,
  input  logic [WIDTH/8-1:0]          mask,
  input  fpnew_pkg::int_format_e      src_fmt,
  input  fpnew_pkg::int_format_e      dst_fmt,

  output logic [WIDTH-1:0]            result,
  output fpnew_pkg::status_t          status,
  output logic                        down_valid
);

  // type requirements
  `ifdef ASSERT_ON
    `rvv_expect(!(up_valid && reg_enable[0]) || (
                fpnew_pkg::int_width(src_fmt)<=WIDTH && WIDTH%fpnew_pkg::int_width(src_fmt) == 0))
      else $warning("Input type too wide!");
    `rvv_expect(!(up_valid && reg_enable[0]) || (
                  (INT_FMT_CONFIG[0] && (src_fmt == fpnew_pkg::INT8 )) ||
                  (INT_FMT_CONFIG[1] && (src_fmt == fpnew_pkg::INT16))))
      else $warning("Input type not supported");
    `rvv_expect(!(up_valid && reg_enable[0]) || fpnew_pkg::int_width(dst_fmt)==WIDTH)
      else $warning("Output type not supported");
  `endif

  // ----------
  // Stage 1: multiply
  // ----------
  genvar i, j, k;

  logic signed[WIDTH/8-1:0][8:0]               A, B;
  logic signed[WIDTH/8-1:0][WIDTH/8-1:0][17:0] pp_raw;
  logic signed[WIDTH/8-1:0][WIDTH/8-1:0][15:0] pp;        // pp[x][y]: x->operands[0], y->operands[1]
  logic signed[WIDTH/8-1:0][WIDTH/8-1:0]       pp_enable;
  generate for (i = 0; i < WIDTH/8; i++) begin: gen_pp_a
    // 1. split inputs to 8-bit groups, with input masking and sign injection to form 9-bit A[i]&B[i]
    wire inject_en = (INT_FMT_CONFIG[0] && (src_fmt == fpnew_pkg::INT8 )         ) ||
                     (INT_FMT_CONFIG[1] && (src_fmt == fpnew_pkg::INT16) && i[0]);
    assign A[i] = (up_valid & mask[i]) ? {inject_en&operand_signed[0]&operands[0][i*8+7], operands[0][i*8 +: 8]} : 9'b0;
    assign B[i] = (up_valid & mask[i]) ? {inject_en&operand_signed[1]&operands[1][i*8+7], operands[1][i*8 +: 8]} : 9'b0;
    
    // 2. make partial products (pp=Ai*Bj)
    for (j = 0; j < WIDTH/8; j++) begin: pp_b
      assign pp_raw[i][j] = signed'({{9{A[i][8]}}, A[i]}) * signed'({{9{B[j][8]}}, B[j]});
      assign pp[i][j] = pp_raw[i][j][15:0];  // no overflow when actual input is [u]int8, guarded
      `ifdef ASSERT_ON
        wire inject_en_j = (INT_FMT_CONFIG[0] && (src_fmt == fpnew_pkg::INT8 )) ||
                           (INT_FMT_CONFIG[1] && (src_fmt == fpnew_pkg::INT16) && j[0]);
        wire byte_A_signed = inject_en   & operand_signed[0];
        wire byte_B_signed = inject_en_j & operand_signed[1];
        wire any_signed    = byte_A_signed | byte_B_signed;

        `rvv_expect(any_signed
          ? (pp_raw[i][j][17] == pp_raw[i][j][16]
          && pp_raw[i][j][16] == pp_raw[i][j][15])   // signed:   fits in int16
          : (pp_raw[i][j][17] == 1'b0
          && pp_raw[i][j][16] == 1'b0))              // unsigned: fits in uint16
          else $warning("pp_raw does not fit in 16-bit %s range", any_signed ? "signed" : "unsigned");
      `endif

      // 3. select enable bits from src_fmt
      //   for int8, only pp[i][i] is needed
      //   for int16 pp[i*2 +: 2][i*2 +: 2] are needed
      assign pp_enable[i][j] = up_valid && (
        (INT_FMT_CONFIG[0] && (src_fmt == fpnew_pkg::INT8 )) ? (i == j) :
        (INT_FMT_CONFIG[1] && (src_fmt == fpnew_pkg::INT16)) ? ((i>>1) == (j>>1)):
                                                                 1'b0);
    end
  end endgenerate

  // ----------
  // Mid pipeline
  // ----------

  logic [0:NUM_MID_REGS][1:0] pp_signed_pipe;
  fpnew_pkg::int_format_e [0:NUM_MID_REGS] src_fmt_pipe;
  logic [0:NUM_MID_REGS][WIDTH/8-1:0][WIDTH/8-1:0][15:0] pp_pipe;
  logic [0:NUM_MID_REGS][WIDTH/8-1:0][WIDTH/8-1:0] pp_enable_pipe;
  // Input stage
  assign pp_pipe[0] = pp;
  assign pp_signed_pipe[0] = operand_signed;
  assign src_fmt_pipe[0] = src_fmt;
  assign pp_enable_pipe[0] = pp_enable;
  // Pipeline
  generate for (i = 0; i < NUM_MID_REGS; i++) begin: gen_pip
    edff#(.T(logic [1:0]))                     sign_reg     (.q(pp_signed_pipe[i+1]), .d(pp_signed_pipe[i]),
      .e(reg_enable[i]), .clk(clk), .rst_n(rst_n));
    edff#(.T(fpnew_pkg::int_format_e))         fmt_reg      (.q(src_fmt_pipe[i+1]),   .d(src_fmt_pipe[i]),
      .e(reg_enable[i]), .clk(clk), .rst_n(rst_n));
    edff#(.T(logic[WIDTH/8-1:0][WIDTH/8-1:0])) pp_enable_reg(.q(pp_enable_pipe[i+1]), .d(pp_enable_pipe[i]),
      .e(reg_enable[i]), .clk(clk), .rst_n(rst_n));
    for (j = 0; j < WIDTH/8; j++) begin
      for (k = 0; k < WIDTH/8; k++) begin
        edff#(.T(logic[15:0])) pp_reg(.q(pp_pipe[i+1][j][k]), .d(pp_pipe[i][j][k]),
          .e(pp_enable_pipe[i][j][k]&&reg_enable[i]), .clk(clk), .rst_n(rst_n));
      end
    end
  end endgenerate
  // Output stage
  wire [1:0]                            pp_signed_q = pp_signed_pipe[NUM_MID_REGS];
  wire [WIDTH/8-1:0][WIDTH/8-1:0][15:0] pp_q        = pp_pipe[NUM_MID_REGS];
  wire fpnew_pkg::int_format_e          src_fmt_q   = src_fmt_pipe[NUM_MID_REGS];

  // ----------
  // Stage 2: Add up
  // ----------

  logic[WIDTH-1:0] int8_result;
  logic[WIDTH-1:0] int16_result;

  always_comb begin
    int8_result = '0;
    int16_result = '0;

    // let eda to simplify the add trees
    if (INT_FMT_CONFIG[0] && (src_fmt_q == fpnew_pkg::INT8)) begin
      for (int x = 0; x < WIDTH/8; x++)
        int8_result = int8_result
                    + { {(WIDTH - 16){(|pp_signed_q)&pp_q[x][x][15]}}, pp_q[x][x]};
    end
    if (INT_FMT_CONFIG[1] && (src_fmt_q == fpnew_pkg::INT16)) begin
      for (int x = 0; x < WIDTH/8; x = x + 2)
        int16_result = int16_result
                     + { {(WIDTH-24){pp_signed_q[0]&pp_q[x+1][  x][15]}},    pp_q[x+1][x], 8'b0}
                     + { {(WIDTH-24){pp_signed_q[1]&pp_q[  x][x+1][15]}},    pp_q[x][x+1], 8'b0}
                     + { {(WIDTH-32){(|pp_signed_q)&pp_q[x+1][x+1][15]}}, pp_q[x+1][x+1], pp_q[x][x]};
    end

  end

  assign result = '0
    | ((INT_FMT_CONFIG[0] && (src_fmt_q == fpnew_pkg::INT8))  ? int8_result  : '0)
    | ((INT_FMT_CONFIG[1] && (src_fmt_q == fpnew_pkg::INT16)) ? int16_result : '0)
  ;
  assign status = '{default: '0};
  assign down_valid = |pp_enable_pipe[NUM_MID_REGS];

endmodule
