`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module fp_classifier#(
  parameter int unsigned NUM_OP   = 32'd1,
  parameter int unsigned EXP_BITS = 32'd8,
  parameter int unsigned MAN_BITS = 32'd23
) (
  input logic [NUM_OP-1:0][EXP_BITS-1:0] exponent,
  input logic [NUM_OP-1:0][MAN_BITS-1:0] mantissa,

  output logic [NUM_OP-1:0] is_nan,
  output logic [NUM_OP-1:0] is_signal_nan,
  output logic [NUM_OP-1:0] is_inf,
  output logic [NUM_OP-1:0] is_subnormal,
  output logic [NUM_OP-1:0] is_zero,
  output logic [NUM_OP-1:0] implicit_bit
);

  for(genvar op = 0; op < NUM_OP; op++) begin: gen
    // Per-op slice. Original used the full `exponent` bus, so for NUM_OP>=2
    // exp_zero / exp_all_1 only fired when *every* operand met the
    // condition -- silently corrupted implicit_bit for ops with zero or
    // inf exponent whenever another lane was normal.
    wire   exp_zero          = exponent[op] == '0;
    wire   exp_all_1         = exponent[op] == '1;
    wire   man_zero          = mantissa[op] == '0;
    assign is_nan[op]        = exp_all_1 && ~man_zero;
    assign is_signal_nan[op] = is_nan[op] && ~mantissa[op][MAN_BITS-1];
    assign is_inf[op]        = exp_all_1 &&  man_zero;
    assign is_subnormal[op]  = exp_zero && ~man_zero;
    assign is_zero[op]       = exp_zero && man_zero;
    assign implicit_bit[op]  = ~exp_zero;

    // TODO: OCP FP8 E4M3 nan
  end

endmodule
