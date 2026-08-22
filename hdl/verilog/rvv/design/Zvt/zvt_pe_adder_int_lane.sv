module zvt_pe_adder_int_lane#(
  parameter int unsigned             NUM_MID_REGS = 1
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic[NUM_MID_REGS-1:0]      reg_enable,
  input  logic                        up_valid,

  input  logic [1:0][`WORD_WIDTH-1:0] operands,
  input  logic                        do_subtract,

  output logic [`WORD_WIDTH-1:0]      result,
  output fpnew_pkg::status_t          status,
  output logic                        down_valid
);

  wire in_valid = up_valid && reg_enable[0];

  wire [1:0][`WORD_WIDTH-1:0] iso_operands = in_valid ? operands : '0;
  wire iso_do_subtract = in_valid ? do_subtract : 1'b0;
 
  wire [`WORD_WIDTH-1:0] src2 = iso_do_subtract ? ~iso_operands[1] : iso_operands[1];
  wire carry_in = iso_do_subtract;

  wire [`WORD_WIDTH-1:0] sum = iso_operands[0] + src2 + carry_in; // let it overflow

  typedef struct packed {
    logic en;
    logic [`WORD_WIDTH-1:0] result;
  } mid_reg_t;
  mid_reg_t[0:NUM_MID_REGS] mid_pipe;

  assign mid_pipe[0].en = up_valid;
  assign mid_pipe[0].result = sum;

  // Generate the register stages
  for (genvar i = 0; i < NUM_MID_REGS; i++) begin: gen_mid_pipeline
    edff #(.T(mid_reg_t)) mid_reg(.q(mid_pipe[i+1]), .d(mid_pipe[i]), .e(reg_enable[i] & mid_pipe[i].en),
      .clk(clk), .rst_n(rst_n));
  end

  assign result = mid_pipe[NUM_MID_REGS].result;
  assign status = '0;
  assign down_valid = mid_pipe[NUM_MID_REGS].en;

endmodule
