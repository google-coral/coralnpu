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

  `ifdef ASSERT_ON
    `rvv_expect(~(a[WIDTH-1] & b[WIDTH-1]))
      else $error("Schmookler-Nowka algorithm needs MSB of either a or b is 0 to generate p");
      // "...it would be useful to prefix the sequence with a T for subtraction and a Z for addition."
      // Implemented by caller extending 1 bit, see instantiation in fp_absaddsub.
      // Schmookler, M.S. & Nowka, K.J. (2001). Leading zero anticipation and detection-
      // a comparison of methods.
  `endif

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

  logic                       f_empty;
  logic [$clog2(WIDTH+1)-1:0] scnt_raw;

  lzc #(
    .WIDTH ( WIDTH+1 ),
    .MODE  ( 1       )
  ) i_lzc (
    .in_i    ( f        ),
    .cnt_o   ( scnt_raw ),
    .empty_o ( f_empty  )
  );

  // f == 0 carries no transition to anticipate.  It happens exactly when
  // |result| <= 1: a subtract of two adjacent operands, whose two's-complement
  // form is the all-ones string (a-b == -1), or an exact zero.  lzc then reports
  // cnt_o = 0, which under-predicts by the full width and breaks the
  // over-predict-only contract.  In both cases the magnitude's leading 1 (if any)
  // sits at bit 0 of the WIDTH-bit result, so the exact count is WIDTH-1.
  // |result| == 0 is reported to the caller separately (fp_absaddsub.sum_is_zero).
  assign scnt = f_empty ? ($clog2(WIDTH+1))'(WIDTH-1) : scnt_raw;

endmodule
