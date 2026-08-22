module fp_align#(
  parameter int unsigned IN_EXP_BITS  = 10,
  parameter int unsigned IN_SIG_BITS  = 23+2+2,  // for 4-way FP32 adder, 2 as guard bits, 2 for R & S bit
  parameter int unsigned OUT_EXP_BITS = 8,
  parameter int unsigned OUT_SIG_BITS = 24,
  parameter bit          USE_EXT_LZC     = 1'b0,  // 1'b1: use ext_lzc_cnt & ext_in_zero

  // 1'b1: widen the shift by one bit and apply a small_norm +1 correction
  // intended for USE_EXT_LZC with LZA.
  parameter bit          USE_LZA_POSTFIX = 1'b0
) (
  // input data
  input logic signed [IN_EXP_BITS-1:0] in_exponent,
  input logic        [IN_SIG_BITS-1:0] in_significand,

  // external leading-zero count (consumed only when USE_EXT_LZC == 1)
  input logic [$clog2(IN_SIG_BITS)-1:0] ext_lzc_cnt,
  input logic                           ext_in_zero,

  // align additional
  // These signals are for fadd and RVBNA, where all raw exponent is exported, the largest chosen, overflow checked,
  // and imported as align_minimum_exponent, i.e.:
  // E_align = max(1, Ei) for i in 0, ..., vec_len-1
  // align_overflow = max(Ei) >= 2**W_e-1
  // also, prod_exponent=(raw < E_align) ? trimmed : raw
  //
  // For ordinary subnormal align mode, set minimum = 1, trimmed = 0
  input  logic [OUT_EXP_BITS-1:0]      align_minimum_exponent, // reference exponent, Em
  input  logic [OUT_EXP_BITS-1:0]      align_trimmed_exponent, // trimmed exponent, ET, see "2."

  // normal product
  output logic [OUT_EXP_BITS-1:0]      out_exponent,
  output logic [OUT_SIG_BITS-1:0]      out_significand,
  output logic                         out_round_bit,
  output logic                         out_sticky_bit,
  output logic                         out_sticky_msb,  // for UF detection

  output logic                         overflow
);
  // Instantiate LZC for product, or from external LZA
  logic [$clog2(IN_SIG_BITS)-1:0] lzc_cnt;
  logic in_zero;
  generate if (USE_EXT_LZC) begin: g_ext_lzc
    assign lzc_cnt = ext_lzc_cnt;
    assign in_zero = ext_in_zero;
  end else begin: g_int_lzc
    lzc #(.WIDTH(IN_SIG_BITS), .MODE(1)  // MODE=1 counts leading zeroes
    ) u_sig_lzc (
      .in_i(in_significand),
      .cnt_o(lzc_cnt),
      .empty_o(in_zero));
  end endgenerate

  wire [$clog2(IN_SIG_BITS+1)-1:0] lzc_cnt_fix = ($clog2(IN_SIG_BITS+1))'(in_zero ? IN_SIG_BITS : lzc_cnt);

  // 1. lzc compensate & point move, make sure S1[MSB]=1
  //    S1(P=1) = S0(P=1) << LZC, E1=E0-LZC
  //    S0(e.g.):    0 0.0001xxx << LZC
  //    S1:          1.x xx00000
  //
  // 2. subnormal trim, align:
  //    S1: 0 0000 0 1.x xx00000  << shamt
  //        <-WO-> R <---WI---->
  //    S2: 1.xxx0 0 0 0 0000000
  //        ^ MSB min weight is E=Em for subnormal or batch-normalize
  //    E2=(E1 >= Em ? E1 : ET)
  //
  // Merging 1&2, we have
  //    S2=S0 <<(a)  LZC,        LZC> E0-Em+WO+1*
  //            (b)  E0-Em+WO+1, LZC<=E0-Em+WO+1< LZC+WO+1
  //            (c)  LZC+WO+1,        E0-Em     >=LZC
  //    E2=     (ab) ET,              E0-Em     < LZC
  //            (c)  E0-LZC,          E0-Em     >=LZC
  // *: when LZC==E0-Em+W0+1, the MSB 1 of this significand is aligned at MSB of sticky.
  // To make sure sticky_msb is correctly providing "0.25" info, we should set sticky_msb to 0 on condition (a)
  // and there is no need to shift

  logic [$clog2(OUT_SIG_BITS+1+IN_SIG_BITS+1)-1:0] shamt;  // range [0, 3P]
  logic exponent_too_tiny;  // the signal providing "*" info above

  localparam int unsigned MAX_EXP_BITS = 32'(2 + (IN_EXP_BITS > OUT_EXP_BITS ? IN_EXP_BITS : OUT_EXP_BITS));
  wire signed[MAX_EXP_BITS-1:0] align_exponent_distance = MAX_EXP_BITS'($signed(in_exponent - align_minimum_exponent)); // Er=E0-Em
  // Compute t in the wider signed exponent domain so we can catch very-negative Er that would
  // otherwise wrap into a spurious small positive when truncated to the narrow shamt width.
  wire signed [MAX_EXP_BITS-1:0] tiny_shamt_wide = align_exponent_distance + MAX_EXP_BITS'(OUT_SIG_BITS + 1);
  wire tiny_shamt_negative = tiny_shamt_wide[MAX_EXP_BITS-1];
  wire [$clog2(OUT_SIG_BITS+1+IN_SIG_BITS+1)-1:0] tiny_shamt = tiny_shamt_wide[$clog2(OUT_SIG_BITS+1+IN_SIG_BITS+1)-1:0];
  // t=Er+WO+1=E0-Em+WO+1+1
  logic signed[MAX_EXP_BITS-1:0] out_exponent_raw;

  // see cases above and below
  wire in_case_c = ($signed(align_exponent_distance) >= MAX_EXP_BITS'($signed({1'b0, lzc_cnt_fix})));

  always_comb begin
    exponent_too_tiny = 1'b0;
    if (in_zero) begin
      shamt = '0;
      out_exponent_raw = (MAX_EXP_BITS)'(align_trimmed_exponent);
    end else if (in_case_c) begin
      // (c) can be aligned to MSB
      shamt = {1'b0, lzc_cnt} + {1'b0, OUT_SIG_BITS} + 1;
      out_exponent_raw = (MAX_EXP_BITS)'(in_exponent - lzc_cnt);
      // do not use lzc_cnt_fix:
      // 1. if in_sig == 0, shamt and out_exponent_raw won't affect final result
      // 2. in_sig should not be 0 (guarded by assertion)
    end else begin
      // (ab) cannot be aligned to MSB 
      out_exponent_raw = (MAX_EXP_BITS)'(align_trimmed_exponent);
      if (!tiny_shamt_negative && $unsigned(tiny_shamt) >= ($clog2(OUT_SIG_BITS+1+IN_SIG_BITS+1))'($unsigned(lzc_cnt_fix))) begin
        // (b) Still in significand/round_bit/stycky_msb range
        shamt = tiny_shamt;
      end else begin
        // (a) All in sticky range, can set shamt to 0
        shamt = 0;
        exponent_too_tiny = 1'b1;
      end
    end
  end

  // For LZA overshoot, exponent needs additional +1 fix
  logic signed [MAX_EXP_BITS-1:0] out_exponent_fix;

  generate if (USE_LZA_POSTFIX) begin: g_lza_postfix
    // Keep extra MSB when shift for fix in case of overshoot
    localparam int unsigned SHIFT_WIDTH = (OUT_SIG_BITS + IN_SIG_BITS + 1) + 1;
    logic [SHIFT_WIDTH-1:0] shifted_wide;
    assign shifted_wide = {1'b0, {OUT_SIG_BITS{1'b0}}, 1'b0, in_significand} << shamt;

    wire shifted_msb   = shifted_wide[SHIFT_WIDTH-2];
    wire lza_overshoot = shifted_wide[SHIFT_WIDTH-1];
    // LZA overshoot at the (b)/(c) boundary, when msb=1 in case (b),
    // exp needs to = align_minimum_exponent.
    wire boundary_bump  = !in_case_c && shifted_msb;

    always_comb begin
      if (lza_overshoot) begin
        // rsh by 1
        out_significand = shifted_wide[SHIFT_WIDTH-1 : IN_SIG_BITS+2];
        out_round_bit   = shifted_wide[IN_SIG_BITS+1];
        out_sticky_bit  = |shifted_wide[IN_SIG_BITS : 0];
        out_sticky_msb  = shifted_wide[IN_SIG_BITS] & !exponent_too_tiny;
      end else begin
        out_significand = shifted_wide[SHIFT_WIDTH-2 : IN_SIG_BITS+1];
        out_round_bit   = shifted_wide[IN_SIG_BITS];
        out_sticky_bit  = |shifted_wide[IN_SIG_BITS-1 : 0];
        out_sticky_msb  = shifted_wide[IN_SIG_BITS-1] & !exponent_too_tiny;
      end
    end

    assign out_exponent_fix = lza_overshoot ? (out_exponent_raw + 1) :
                              boundary_bump ? MAX_EXP_BITS'(align_minimum_exponent) :
                                              out_exponent_raw;

    `ifdef ASSERT_ON
      // fp_lza only over-predicts, so a case-(c) shift should never leave both top
      // bits clear. If it does, the LZA violated its over-predict-only contract.
      `rvv_forbid(in_case_c && !lza_overshoot && !shifted_msb)
        else $error("Undershoot detect, need additional logic for this");
    `endif
  end else begin: g_no_postfix
    // Original narrow shift: assumes lzc_cnt is exact.
    logic [IN_SIG_BITS-1:0] sticky_bits;
    assign {out_significand, out_round_bit, sticky_bits} = {{OUT_SIG_BITS{1'b0}}, 1'b0, in_significand} << shamt;
    assign out_sticky_bit   = |sticky_bits;
    assign out_sticky_msb   = sticky_bits[IN_SIG_BITS-1] & !exponent_too_tiny;
    assign out_exponent_fix = out_exponent_raw;
  end endgenerate

  assign overflow     = |out_exponent_fix[MAX_EXP_BITS-2:OUT_EXP_BITS];
  assign out_exponent = out_exponent_fix[OUT_EXP_BITS-1:0];
  `ifdef ASSERT_ON
    `rvv_forbid(out_exponent_fix[MAX_EXP_BITS-1])
      else $warning("Exponent must be non-negative in correct design");
  `endif

endmodule
