`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module fp_addfront#(
  parameter int unsigned IN_EXP_BITS  = 32'd8,             // Input exponent width
  parameter int unsigned IN_MANT_BITS = 32'd23,            // Input mantissa width
  parameter int unsigned OUT_EXP_BITS = 32'd9,             // Output exponent width
  parameter int unsigned OUT_SIG_BITS = 32'd24,            // Output significand width, with leading "1"

  localparam int unsigned IN_SIG_BITS = IN_MANT_BITS+1 // (Wi)
) (
  // input a
  input logic                            a_sign,
  input logic [IN_EXP_BITS-1:0]          a_exponent,
  input logic [IN_MANT_BITS-1:0]         a_mantissa,

  // input b
  input logic                            b_sign,
  input logic [IN_EXP_BITS-1:0]          b_exponent,
  input logic [IN_MANT_BITS-1:0]         b_mantissa,

  // input control,
  input logic                            do_subtract,
  // Only used to pick the sign of an exact-zero sum (IEEE 754 6.3: + in all
  // rounding modes except roundTowardNegative).
  input fpnew_pkg::roundmode_e          rnd_mode,

  // normal resultuct
  output logic                           result_sign,
  output logic [OUT_EXP_BITS-1:0]        result_exponent,
  output logic [OUT_SIG_BITS-1:0]        result_significand,
  output logic                           result_round_bit,
  output logic                           result_sticky_bit,
  output logic                           result_sticky_msb,  // for UF detection

  // special
  output logic                           special_nan,
  output logic                           special_inf,
  output logic                           special_inf_sign,
  output logic                           special_invalid,
  output logic                           align_overflow
);

  // ----------
  // Special detection
  // ----------
  logic b_is_nan       , a_is_nan       ;
  logic b_is_signal_nan, a_is_signal_nan;
  logic b_is_inf       , a_is_inf       ;
  logic b_is_subnormal , a_is_subnormal ;
  logic b_is_zero      , a_is_zero      ;
  logic b_implicit_bit , a_implicit_bit ;
  fp_classifier #(
    .NUM_OP(2),
    .EXP_BITS(IN_EXP_BITS),
    .MAN_BITS(IN_MANT_BITS)
  ) u_classifier (
    .exponent     ({b_exponent,      a_exponent     }),
    .mantissa     ({b_mantissa,      a_mantissa     }),
    .is_nan       ({b_is_nan       , a_is_nan       }),
    .is_signal_nan({b_is_signal_nan, a_is_signal_nan}),
    .is_inf       ({b_is_inf       , a_is_inf       }),
    .is_subnormal ({b_is_subnormal , a_is_subnormal }),
    .is_zero      ({b_is_zero      , a_is_zero      }),
    .implicit_bit ({b_implicit_bit , a_implicit_bit })
  );

  // special detect
  always_comb begin
    special_nan = 1'b0;
    special_invalid = 1'b0;
    special_inf = 1'b0;
    special_inf_sign = 1'b0;
    if (a_is_inf && b_is_inf && (a_sign ^ b_sign ^ do_subtract)) begin
      special_nan = 1'b1;
      special_invalid = 1'b1;
    end else if (a_is_nan || b_is_nan) begin
      special_nan = 1'b1;
      special_invalid = a_is_signal_nan || b_is_signal_nan;
    end else if (a_is_inf || b_is_inf) begin
      special_inf = 1'b1;
      special_inf_sign = a_is_inf ? a_sign : (b_sign ^ do_subtract);
    end
  end

  // keep max_exponent == 0 when a_exp and b_exp == 0
  wire [IN_EXP_BITS-1:0] max_exponent = a_exponent > b_exponent ? a_exponent : b_exponent;

  wire [IN_EXP_BITS-1:0] subnormal_fix_align_exp = max_exponent > 1 ? max_exponent : (IN_EXP_BITS)'(1'd1);

  // fp_align needs real exponents...
  wire signed[1:0][IN_EXP_BITS:0] in_exponents;
  assign in_exponents[0] = {1'b0, a_exponent[IN_EXP_BITS-1:1], a_exponent[0] | ~a_implicit_bit};
  assign in_exponents[1] = {1'b0, b_exponent[IN_EXP_BITS-1:1], b_exponent[0] | ~b_implicit_bit};

  // ... and real significands
  wire [1:0][IN_SIG_BITS-1:0] in_significands;
  assign in_significands[0] = {a_implicit_bit, a_mantissa};
  assign in_significands[1] = {b_implicit_bit, b_mantissa};

  wire [1:0][IN_EXP_BITS-1:0]  aligned_exponents;
  wire [1:0][OUT_SIG_BITS+1:0] aligned_significands;
  wire [1:0]                   aligned_round_bits, aligned_sticky_bits, aligned_sticky_msbs;
  wire [1:0]                   overflow;

  // align first, keep minimum bit width with precision
  for (genvar i = 0; i < 2; i++) begin: gen_in_align
    fp_align#(
      .IN_EXP_BITS(IN_EXP_BITS + 1),  // align needs signed input
      .IN_SIG_BITS(IN_SIG_BITS),
      .OUT_EXP_BITS(IN_EXP_BITS),
      .OUT_SIG_BITS(OUT_SIG_BITS + 2)  // 2 bit guard bit, one for subtract borrow guard, one for precise sticky msb
    ) u_in_align (
      .in_exponent   (in_exponents[i]),
      .in_significand(in_significands[i]),
      .ext_lzc_cnt   ('1), // dont care
      .ext_in_zero   ('1), // dont care

      .align_minimum_exponent(subnormal_fix_align_exp),
      .align_trimmed_exponent(max_exponent),

      .out_exponent   (aligned_exponents[i]),
      .out_significand(aligned_significands[i]),
      .out_round_bit  (aligned_round_bits[i]),
      .out_sticky_bit (aligned_sticky_bits[i]),
      .out_sticky_msb (aligned_sticky_msbs[i]),  // unused
      .overflow       (overflow[i])
    );

    `ifdef ASSERT_ON
      `rvv_forbid(aligned_exponents[0] != max_exponent ||
                  aligned_exponents[1] != max_exponent)
        else $error("Aligned exponent should be equal to max_exponent by design");
      `rvv_forbid((aligned_exponents[0] == 0 && aligned_significands[0][IN_SIG_BITS-1]))
        else $error("Exponent and significand argue on it is subnormal for input a");
      `rvv_forbid((aligned_exponents[1] == 0 && aligned_significands[1][IN_SIG_BITS-1]))
        else $error("Exponent and significand argue on it is subnormal for input b");
      `rvv_forbid(|overflow)
        else $error("Overflow should not happen on align stage in correct design");
    `endif
  end

  `ifdef ASSERT_ON
    `rvv_expect(aligned_exponents[0] == aligned_exponents[1])
      else $error("Why align failed?");
  `endif

  wire [OUT_SIG_BITS+2+1-1:0] sum_significand;  // another MSB for overflow
  wire [IN_EXP_BITS-1:0] sum_exponent = max_exponent;
  wire sum_round_bit, sum_sticky_bit;
  wire sum_negative;

  localparam int unsigned SUM_LZA_WIDTH   = OUT_SIG_BITS + 4; // absaddsub input width
  localparam int unsigned SUM_TOTAL_WIDTH = OUT_SIG_BITS + 5; // absaddsub output width (with carry)

  // do significand add/subtract with overflow bit, and LZA in parallel
  logic [$clog2(SUM_LZA_WIDTH+1)-1:0] lza_scnt;
  fp_absaddsub#(
    .IN_WIDTH   (SUM_LZA_WIDTH),
    .ENABLE_LZA (1'b1)
  ) u_addsub (
    .a({aligned_significands[0], aligned_round_bits[0], aligned_sticky_bits[0]}),
    .b({aligned_significands[1], aligned_round_bits[1], aligned_sticky_bits[1]}),
    .do_subtract(a_sign ^ b_sign ^ do_subtract),
    .sum({sum_significand, sum_round_bit, sum_sticky_bit}),
    .sum_negative(sum_negative),
    .lza_scnt(lza_scnt)
  );

  wire [SUM_TOTAL_WIDTH-1:0] sum_concat = {sum_significand, sum_round_bit, sum_sticky_bit};
  wire                       sum_is_zero = ~|sum_concat;

  // post add/sub align to
  // 1. fix leading bit
  // 2. trim down to OUT_SIG_BITS + round + sticky
  fp_align#(
    .IN_EXP_BITS(IN_EXP_BITS+2),
    .IN_SIG_BITS(SUM_TOTAL_WIDTH),
    .OUT_EXP_BITS(OUT_EXP_BITS),
    .OUT_SIG_BITS(OUT_SIG_BITS),
    .USE_EXT_LZC(1'b1),
    .USE_LZA_POSTFIX(1'b1)
  ) u_sum_align (
    .in_exponent(signed'({2'b0, sum_exponent}) + 1'b1),  // +1 to adjust point position, P(sum) == 2
    .in_significand(sum_concat),

    .ext_lzc_cnt(lza_scnt),
    .ext_in_zero(sum_is_zero),

    .align_minimum_exponent({{OUT_EXP_BITS-1{1'b0}}, 1'b1}),
    .align_trimmed_exponent('0),

    .out_exponent(result_exponent),
    .out_significand(result_significand),
    .out_round_bit(result_round_bit),
    .out_sticky_bit(result_sticky_bit),
    .out_sticky_msb(result_sticky_msb),

    .overflow(align_overflow)
  );

  // Exact-zero sums from an effective subtraction are +0 in every rounding
  // mode except roundTowardNegative; an effective addition of zeros keeps the
  // operands' common sign.
  wire effective_subtraction = a_sign ^ b_sign ^ do_subtract;
  assign result_sign = sum_is_zero
      ? (effective_subtraction ? (rnd_mode == fpnew_pkg::RDN) : a_sign)
      : (a_sign ^ sum_negative);

endmodule
