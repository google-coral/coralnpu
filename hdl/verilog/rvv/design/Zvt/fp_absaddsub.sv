module fp_absaddsub#(
  parameter int unsigned IN_WIDTH = 32'd24,
  // Set VALID_HIGH_BITS < IN_WIDTH to enable the split path.  The caller
  // guarantees whichever of |a|,|b| is the larger operand has 0 in the low
  // (IN_WIDTH-VALID_HIGH_BITS) bits.  Default = IN_WIDTH keeps the original path.
  parameter int unsigned VALID_HIGH_BITS = IN_WIDTH,
  parameter logic PARALLEL_ADDSUB = 1'b1,  // 1'b1: use dedicate b-a logic, 1'b0: output -(a-b) if a-b is negative
  parameter bit ENABLE_LZA = 1'b0          // 1'b1: instantiate a parallel LZA
) (
  input  logic [IN_WIDTH-1:0] a,
  input  logic [IN_WIDTH-1:0] b,
  input  logic do_subtract,
  output logic [IN_WIDTH  :0] sum,
  output logic sum_negative,
  output logic [$clog2(IN_WIDTH+1)-1:0] lza_scnt  // when enable, actual lzc_cnt=lza_scnt or + 1
);

  localparam int unsigned LOW_BITS = IN_WIDTH - VALID_HIGH_BITS;

  generate if (LOW_BITS == 0) begin: g_no_split
    // Original full-width path
    // -b == ~b+1
    wire [IN_WIDTH-1:0] b_s = do_subtract ? ~b : b;
    wire carry_in = do_subtract;

    wire [IN_WIDTH:0] raw_sum = {1'b0, a}+{do_subtract, b_s}+carry_in;

    assign sum_negative = do_subtract && raw_sum[IN_WIDTH];

    if (PARALLEL_ADDSUB) begin
      assign sum = sum_negative ? ({1'b0, (b-a)}) : raw_sum;
    end else begin
      assign sum = sum_negative ? -raw_sum : raw_sum;
    end
  end else begin: g_split
    // Split path: caller guarantees the larger of |a|,|b| has 0 in the low
    // LOW_BITS bits, so the low half collapses to
    //   add : low = a_low | b_low                     (one operand is 0)
    //   sub : low = ~(a_low|b_low) + 1                (two's-complement negation)
    //         with a borrow into the high stage whenever nonzero_low != 0.
    // High stage runs the current (a+b)/|a-b| logic on the top VALID_HIGH_BITS
    // bits with carry_in adjusted for that borrow.
    wire [VALID_HIGH_BITS-1:0] a_high = a[IN_WIDTH-1 -: VALID_HIGH_BITS];
    wire [VALID_HIGH_BITS-1:0] b_high = b[IN_WIDTH-1 -: VALID_HIGH_BITS];
    wire [LOW_BITS       -1:0] a_low  = a[LOW_BITS-1:0];
    wire [LOW_BITS       -1:0] b_low  = b[LOW_BITS-1:0];

    wire [LOW_BITS-1:0] nonzero_low         = a_low | b_low;
    wire                nonzero_low_is_zero = ~|nonzero_low;

    wire [LOW_BITS-1:0] low_result = do_subtract ? (~nonzero_low + 1'b1) : nonzero_low;

    // High a-b path.  Carry-in comes from the low subtract:
    //   b_low == 0 -> no borrow -> carry_in_ab = 1 (standard a + ~b + 1)
    //   b_low != 0 -> borrowed  -> carry_in_ab = 0
    wire                       carry_in_ab = do_subtract & (~|b_low);
    wire [VALID_HIGH_BITS-1:0] b_high_s    = do_subtract ? ~b_high : b_high;
    wire [VALID_HIGH_BITS:0]   ab_high     = {1'b0, a_high} + {do_subtract, b_high_s} + carry_in_ab;

    assign sum_negative = do_subtract && ab_high[VALID_HIGH_BITS];

    if (PARALLEL_ADDSUB) begin: g_par
      // Dedicated b-a subtractor on the high slice (symmetric borrow rule).
      wire                       carry_in_ba = do_subtract & (~|a_low);
      wire [VALID_HIGH_BITS-1:0] a_high_s    = do_subtract ? ~a_high : a_high;
      wire [VALID_HIGH_BITS:0]   ba_high     = {1'b0, b_high} + a_high_s + carry_in_ba;
      wire [VALID_HIGH_BITS-1:0] sub_high    =
          sum_negative ? ba_high[VALID_HIGH_BITS-1:0]
                       : ab_high[VALID_HIGH_BITS-1:0];
      assign sum = {do_subtract ? {1'b0, sub_high} : ab_high, low_result};
    end else begin: g_neg
      // No dedicated b-a subtractor: derive b_high-a_high from ab_high[low]
      // via bitwise negation.  Since ab_high[low] already folds carry_in_ab in,
      // the +1 correction only fires when the low half didn't borrow (both
      // low halves were zero).
      wire [VALID_HIGH_BITS-1:0] ba_high_bits =
          ~ab_high[VALID_HIGH_BITS-1:0] + nonzero_low_is_zero;
      wire [VALID_HIGH_BITS-1:0] sub_high =
          sum_negative ? ba_high_bits : ab_high[VALID_HIGH_BITS-1:0];
      assign sum = {do_subtract ? {1'b0, sub_high} : ab_high, low_result};
    end
  end endgenerate

  generate if (ENABLE_LZA) begin: g_lza
    // Extending by 1 bit is needed by algorithm:
    // "...it would be useful to prefix the sequence with a T for subtraction and a Z for addition."
    // Ti == Ai xor Bi
    // Zi == ~Ai and ~Bi
    fp_lza #(.WIDTH(IN_WIDTH+1)) u_lza (
      .a   ({1'b0, a}),
      .b   ({do_subtract, do_subtract ? ~b : b}),
      .cin (do_subtract),
      .sub (do_subtract),
      .scnt(lza_scnt)
    );
  end else begin: g_no_lza
    assign lza_scnt = '0;
  end endgenerate

endmodule
