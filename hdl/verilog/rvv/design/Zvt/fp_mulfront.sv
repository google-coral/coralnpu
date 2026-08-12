`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module fp_mulfront#(
  parameter int unsigned IN_EXP_BITS  = 32'd8,              // Input exponent width
  parameter int unsigned IN_MANT_BITS = 32'd23,             // Input mantissa width
  parameter int unsigned OUT_EXP_BITS = 32'd9,              // Output exponent width
  parameter int unsigned OUT_SIG_BITS = 32'd24,             // Output significand width(WO), with leading "1"
  parameter int signed   BIAS = 32'(2**(IN_EXP_BITS-1)-1),  // for exponent calc, see "1."

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

  // align additional
  // These signals are for RVBNA, where all raw exponent is exported, the largest chosen, overflow/underflow checked,
  // and imported as align_minimum_exponent, i.e.:
  // E_align = max(1, Ei) for i in 0, ..., vec_len-1
  // align_overflow = max(Ei) >= 2**W_e-1
  // also, prod_exponent=(raw < E_align) ? trimmed : raw
  //
  // For ordinary subnormal align mode, set minimum = 1, trimmed = 0, raw output can be ignored
  output logic signed[IN_EXP_BITS+2-1:0] prod_exponent_raw,  // = Ea+Eb-BIAS, MSB +1b, sign +1b -> total +2b
  input  logic [OUT_EXP_BITS-1:0]        align_minimum_exponent, // reference exponent, Em
  input  logic [OUT_EXP_BITS-1:0]        align_trimmed_exponent, // trimmed exponent, ET, see "3."

  // normal product
  output logic                           prod_sign,
  output logic [OUT_EXP_BITS-1:0]        prod_exponent,
  output logic [OUT_SIG_BITS-1:0]        prod_significand,
  output logic                           prod_round_bit,
  output logic                           prod_sticky_bit,
  output logic                           prod_sticky_msb,  // for UF detection

  // special
  output logic                           special_nan,
  output logic                           special_inf,
  output logic                           special_invalid,
  output logic                           align_overflow
);

  `ifdef ASSERT_ON
    `rvv_expect(OUT_EXP_BITS >= IN_EXP_BITS+1)
      else $warning("Exponent overflow not supported in order to improve precision");
  `endif

  assign prod_sign = a_sign ^ b_sign;

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
    .NUM_OP(32'd2),
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

  // Special cases
  always_comb begin
    special_inf = 1'b0;
    special_nan = 1'b0;
    special_invalid = 1'b0;
    if ((a_is_inf && b_is_zero) || (b_is_inf && a_is_zero)) begin
      special_nan = 1'b1;
      special_invalid = 1'b1;
    end else if (a_is_nan || b_is_nan) begin
      special_nan = 1'b1;
      special_invalid = a_is_signal_nan | b_is_signal_nan;
    end else if (a_is_inf || b_is_inf) begin
      special_inf = 1'b1;
    end
  end

  // ----------
  // Significand generate and LZC pre-check
  // ----------
  // Both are fixed number with P=1
  // i.e. represent x.xxxx, range [0.0, 2.0)
  wire [IN_SIG_BITS-1:0] a_significand = {a_implicit_bit, a_mantissa},
                         b_significand = {b_implicit_bit, b_mantissa};

  // Per-operand LZCs — feed the internal fp_align via USE_EXT_LZC so we don't
  // pay for a full lzc(2*IN_SIG_BITS) on the raw product.
  logic [$clog2(IN_SIG_BITS)-1:0] lzc_a_cnt, lzc_b_cnt;
  logic                           a_zero, b_zero;
  lzc #(.WIDTH(IN_SIG_BITS), .MODE(1)) u_lzc_a (
    .in_i(a_significand), .cnt_o(lzc_a_cnt), .empty_o(a_zero));
  lzc #(.WIDTH(IN_SIG_BITS), .MODE(1)) u_lzc_b (
    .in_i(b_significand), .cnt_o(lzc_b_cnt), .empty_o(b_zero));

  // ----------
  // Product & LZC
  // ----------
  // 1. Do multiply, significand of product has P=2, i.e. xx.xxxx, range (0.0, 4.0)
  //    S (P=2)=SA*SB,   E=EA+EB-BIAS
  // 2. Adjust to P=1
  //    S'(P=1)=S(P=2), E'=E0+1
  // merge 1&2
  wire [IN_SIG_BITS*2-1:0] prod_significand_raw = {(IN_SIG_BITS)'('b0), a_significand} * {(IN_SIG_BITS)'('b0), b_significand};
  assign prod_exponent_raw =  // add MSB +1 bits, sign +1 bits -> total +2
    {2'b0, a_exponent + a_is_subnormal} + {2'b0, b_exponent + b_is_subnormal} - BIAS + 1;

  // LZA hint: LZC(prod) is either La+Lb or La+Lb+1 depending on whether the
  // MSB carry of the multiply lands. Choosing which requires a dynamic bit-
  // select on the raw product, so we over-predict by +1 and let fp_align's
  // USE_LZA_POSTFIX handle the possible 1-bit overshoot.
  localparam int unsigned RAW_LZC_WIDTH = 32'($clog2(IN_SIG_BITS*2));
  wire [RAW_LZC_WIDTH-1:0] lza_scnt = {1'b0, lzc_a_cnt} + {1'b0, lzc_b_cnt} + 1'b1;

  // 3. Align
  fp_align#(
    .IN_EXP_BITS(IN_EXP_BITS+2),
    .IN_SIG_BITS(IN_SIG_BITS*2),
    .OUT_EXP_BITS(OUT_EXP_BITS),
    .OUT_SIG_BITS(OUT_SIG_BITS),
    .USE_EXT_LZC(1'b1),
    .USE_LZA_POSTFIX(1'b1)
  ) u_align (
    .in_exponent(prod_exponent_raw),
    .in_significand(prod_significand_raw),

    // LZA hint from LZC(A)+LZC(B)+1 -- over-predicts by <=1
    .ext_lzc_cnt(lza_scnt),
    .ext_in_zero(a_zero | b_zero),

    .align_minimum_exponent(align_minimum_exponent),
    .align_trimmed_exponent(align_trimmed_exponent),

    .out_exponent   (prod_exponent),
    .out_significand(prod_significand),
    .out_round_bit  (prod_round_bit),
    .out_sticky_bit (prod_sticky_bit),
    .out_sticky_msb (prod_sticky_msb),

    .overflow       (align_overflow)
  );

  `ifdef ASSERT_ON
    // lza_scnt must over-predict LZC(prod) by 0 or 1.
    logic [RAW_LZC_WIDTH-1:0] ref_lzc_cnt;
    logic                     ref_lzc_empty;
    lzc #(.WIDTH(IN_SIG_BITS*2), .MODE(1)) u_ref_lzc (
      .in_i(prod_significand_raw),
      .cnt_o(ref_lzc_cnt),
      .empty_o(ref_lzc_empty));
    `rvv_expect(ref_lzc_empty || (lza_scnt == ref_lzc_cnt) || (lza_scnt == ref_lzc_cnt + 1'b1))
      else $warning("lza_scnt does not follow LZA condition of lzc_cnt");
  `endif

endmodule
