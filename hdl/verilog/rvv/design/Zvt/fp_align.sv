module fp_align#(
  parameter int unsigned IN_EXP_BITS  = 10,
  parameter int unsigned IN_SIG_BITS  = 23+2+2,  // for 4-way FP32 adder, 2 as guard bits, 2 for R & S bit
  parameter int unsigned OUT_EXP_BITS = 8,
  parameter int unsigned OUT_SIG_BITS = 24
) (
  // input data
  input logic signed [IN_EXP_BITS-1:0] in_exponent,
  input logic        [IN_SIG_BITS-1:0] in_significand,

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
  // LZC for product
  logic [$clog2(IN_SIG_BITS)-1:0] lzc_cnt;
  logic in_zero;
  lzc #(.WIDTH(IN_SIG_BITS), .MODE(1)  // MODE=1 counts leading zeroes
  ) u_sig_lzc (
    .in_i(in_significand),
    .cnt_o(lzc_cnt),
    .empty_o(in_zero));

  `ifdef ASSERT_ON
    `rvv_expect(in_zero == (in_exponent == 0))
      else $warning("Input zero significand with non-zero exponent");
  `endif

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
  wire [$clog2(OUT_SIG_BITS+1+IN_SIG_BITS+1)-1:0] tiny_shamt = align_exponent_distance + OUT_SIG_BITS + 1;
  // t=Er+WO+1=E0-Em+WO+1+1
  logic signed[MAX_EXP_BITS-1:0] out_exponent_raw;

  always_comb begin 
    exponent_too_tiny = 1'b1;
    if ($signed(align_exponent_distance) >= MAX_EXP_BITS'($signed({1'b0, lzc_cnt_fix}))) begin
      // (c) can be aligned to MSB
      shamt = {1'b0, lzc_cnt} + {1'b0, OUT_SIG_BITS} + 1;
      out_exponent_raw = (MAX_EXP_BITS)'(in_exponent - lzc_cnt);
      // do not use lzc_cnt_fix:
      // 1. if in_sig == 0, shamt and out_exponent_raw won't affect final result
      // 2. in_sig should not be 0 (guarded by assertion)
    end else begin
      // (ab) cannot be aligned to MSB 
      out_exponent_raw = (MAX_EXP_BITS)'(align_trimmed_exponent);
      if ($unsigned(tiny_shamt) >= ($clog2(OUT_SIG_BITS+1+IN_SIG_BITS+1))'($unsigned(lzc_cnt_fix))) begin
        // (b) Still in significand/round_bit/stycky_msb range
        shamt = tiny_shamt;
      end else begin
        // (a) All in sticky range, can set shamt to 0
        shamt = 0;
        exponent_too_tiny = 0;
      end
    end
  end

  // Do left shift
  logic [IN_SIG_BITS-1:0] sticky_bits;
  assign {out_significand, out_round_bit, sticky_bits} = {{OUT_SIG_BITS{1'b0}}, 1'b0, in_significand} << shamt;
  assign out_sticky_bit = |sticky_bits;
  assign out_sticky_msb = sticky_bits[IN_SIG_BITS-1] & !exponent_too_tiny;
  assign overflow     = |out_exponent_raw[MAX_EXP_BITS-2:OUT_EXP_BITS];
  assign out_exponent = out_exponent_raw[OUT_EXP_BITS-1:0];
  `ifdef ASSERT_ON
    `rvv_forbid(out_exponent_raw[MAX_EXP_BITS-1])
      else $warning("Exponent must be non-negative in correct design");
  `endif

endmodule
