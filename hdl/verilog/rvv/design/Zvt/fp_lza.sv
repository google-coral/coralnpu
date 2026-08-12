// Two-operand Leading Zero Anticipator based on the Schmookler-Nowka algorithm
// for two equal-width operands.
//
// Predicts the leading-zero count of |a +/- b| in parallel with the actual
// add/subtract. Output can over-predict by 1 in the carry-into-leading-zero
// case; the caller is expected to apply the same correction
// (compare sum bit at the predicted leading-1 position).

module fp_lza #(
  parameter int unsigned WIDTH = 32
) (
  input  logic [WIDTH-1:0]           a,
  input  logic [WIDTH-1:0]           b,
  input  logic                       cin,   // carry-in into add (do_subtract for two's-comp ~b+1)
  input  logic                       sub,   // effective subtract
  output logic [$clog2(WIDTH+1)-1:0] scnt
);

  logic [WIDTH:0]   f;
  logic [WIDTH-1:0] p, g, k;
  logic [WIDTH-1:0] pp1, gm1, km1;

  assign p = a ^ b;
  assign g = a & b;
  assign k = ~a & ~b;

  assign pp1 = {sub, p[WIDTH-1:1]};
  assign gm1 = {g[WIDTH-2:0], cin};
  assign km1 = {k[WIDTH-2:0], ~cin};

  assign f[WIDTH]     = ~sub & p[WIDTH-1];
  assign f[WIDTH-1:0] = (pp1 & (g & ~km1 | k & ~gm1)) | (~pp1 & (k & ~km1 | g & ~gm1));

  lzc #(
    .WIDTH ( WIDTH+1 ),
    .MODE  ( 1       )
  ) i_lzc (
    .in_i    ( f    ),
    .cnt_o   ( scnt ),
    .empty_o (      )
  );

endmodule
