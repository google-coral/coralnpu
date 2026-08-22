module fp_rounding#(
  parameter fpnew_pkg::fmt_logic_t   FP_FMT_CONFIG = 5'b10001,          // Indicates which data types are supported

  localparam int unsigned WIDTH                    = fpnew_pkg::max_fp_width(FP_FMT_CONFIG),
  localparam fpnew_pkg::fp_encoding_t SUPER_FORMAT = fpnew_pkg::super_format(FP_FMT_CONFIG),
  localparam int unsigned SUPER_EXP_BITS           = SUPER_FORMAT.exp_bits,
  localparam int unsigned SUPER_MAN_BITS           = SUPER_FORMAT.man_bits,
  localparam int unsigned NUM_FORMATS              = fpnew_pkg::NUM_FP_FORMATS
) (
  // Controls
  input fpnew_pkg::fp_format_e    dst_fmt,              // output format
  input fpnew_pkg::roundmode_e    rnd_mode,             // rounding mode
  input logic                     exact_zero_keep_sign, // whether to output +0 on exact +-0 input

  // Input numeric
  input logic                     preround_sign,        // sign
  input logic[SUPER_EXP_BITS:0]   preround_exponent,    // exponent, 1 bit extended for pre-round overflow check
  input logic[SUPER_MAN_BITS-1:0] preround_mantissa,    // mantissa without implicit leading, exp!=0 implies lead=1
  input logic                     round_bit,            // mantissa "0.5 bit"
  input logic                     sticky_bit,           // mantissa lower bits or-ed up
  input logic                     sticky_msb,           // mantissa "0.25 bit" for IEEE UF check

  // Output numeric
  output logic [WIDTH-1:0]        round_normal_result,  // output WHEN NOT OVERFLOW
  output fpnew_pkg::status_t      status                // rounding status, will raise OF/UF/NX on condition
);

  // Pre-round overflow check
  wire preround_overflow  = preround_exponent[SUPER_EXP_BITS] || &preround_exponent[SUPER_EXP_BITS-1:0];
  wire preround_underflow = preround_exponent == 0;

  wire input_is_zero = preround_underflow && !(|{preround_mantissa, round_bit, sticky_bit});

  // Bit extraction for formats
  wire [SUPER_MAN_BITS+2-1:0] preround_visible_bits = preround_overflow ? '0 : { preround_mantissa, round_bit, sticky_msb };
  logic [NUM_FORMATS-1:0] fmt_guard_bit, fmt_round_bit, fmt_sticky_bit, fmt_sticky_msb;

  for(genvar i = 0; i < NUM_FORMATS; i++) begin: fmt_rounding
    localparam EXP_WIDTH = fpnew_pkg::FP_ENCODINGS[i].exp_bits;
    localparam MAN_WIDTH = fpnew_pkg::FP_ENCODINGS[i].man_bits;

    if (!FP_FMT_CONFIG[i]) begin
      assign fmt_guard_bit[i] = 1'b0;
      assign fmt_round_bit[i] = 1'b0;
      assign fmt_sticky_bit[i] = 1'b0;
      assign fmt_sticky_msb[i] = 1'b0;
    end else begin
      assign fmt_guard_bit[i]  =  preround_visible_bits[SUPER_MAN_BITS+2-1 - MAN_WIDTH+1];
      assign fmt_round_bit[i]  =  preround_visible_bits[SUPER_MAN_BITS+2-1 - MAN_WIDTH];
      assign fmt_sticky_msb[i] =  preround_visible_bits[SUPER_MAN_BITS+2-1 - MAN_WIDTH-1];
      assign fmt_sticky_bit[i] = |{preround_visible_bits[SUPER_MAN_BITS+2-1 - MAN_WIDTH-1 : 0], sticky_bit};
    end
  end


  wire result_guard_bit  = fmt_guard_bit[dst_fmt];
  wire result_round_bit  = fmt_round_bit[dst_fmt];
  wire result_sticky_bit = fmt_sticky_bit[dst_fmt];
  wire result_sticky_msb = fmt_sticky_msb[dst_fmt];


  // Take the rounding decision according to RISC-V spec, copied from FPnew
  // RoundMode | Mnemonic | Meaning
  // :--------:|:--------:|:-------
  //    000    |   RNE    | Round to Nearest, ties to Even
  //    001    |   RTZ    | Round towards Zero
  //    010    |   RDN    | Round Down (towards -\infty)
  //    011    |   RUP    | Round Up (towards \infty)
  //    100    |   RMM    | Round to Nearest, ties to Max Magnitude
  //    101    |   ROD    | Round towards odd (this mode is not define in RISC-V FP-SPEC)
  //  others   |          | *invalid*
  logic round_up;
  always_comb begin : rounding_decision
    unique case (rnd_mode)
      fpnew_pkg::RNE: // Decide accoring to round/sticky bits
        unique case ({result_round_bit, result_sticky_bit})
          2'b00,
          2'b01: round_up = 1'b0;              // < ulp/2 away, round down
          2'b10: round_up = result_guard_bit;  // = ulp/2 away, round towards even result
          2'b11: round_up = 1'b1;              // > ulp/2 away, round up
          default: round_up = fpnew_pkg::DONT_CARE;
        endcase
      fpnew_pkg::RTZ: round_up = 1'b0; // always round down
      fpnew_pkg::RDN: round_up = (result_round_bit | result_sticky_bit) ? preround_sign  : 1'b0; // to 0 if +, away if -
      fpnew_pkg::RUP: round_up = (result_round_bit | result_sticky_bit) ? ~preround_sign : 1'b0; // to 0 if -, away if +
      fpnew_pkg::RMM: round_up = result_round_bit; // round down if < ulp/2 away, else up
      fpnew_pkg::ROD: round_up = ~result_guard_bit & (result_round_bit | result_sticky_bit);
      default: round_up = fpnew_pkg::DONT_CARE; // propagate x
    endcase
  end

  logic [NUM_FORMATS-1:0][SUPER_MAN_BITS+2-1:0] fmt_carry_in_bits;
  for (genvar i = 0; i < NUM_FORMATS; i++) begin
    assign fmt_carry_in_bits[i] = ((SUPER_MAN_BITS+2)'(FP_FMT_CONFIG[i]))
                                    << (SUPER_MAN_BITS+2-1-fpnew_pkg::FP_ENCODINGS[i].man_bits);
  end
  wire [SUPER_MAN_BITS+2-1:0] carry_in_bits = round_up ? fmt_carry_in_bits[dst_fmt] : '0;

  // Round it up
  logic [SUPER_MAN_BITS-1:0] round_mantissa;
  logic [SUPER_EXP_BITS-1:0] round_exponent;
  assign {round_exponent, round_mantissa} = {preround_exponent, preround_mantissa} + carry_in_bits;
  // This is likely to be auto-optimizable after constant propagation. e.g.
  // MSB - B - B - B - B - B - B - B - B - B
  //           +                   +       +
  //        carry_1             carry_2 carry_3
  // where carry_* is the carry_in bit of different format, one of carry_1/2/3 is 1, the other 2 are 0,
  // and on bits carry_1 and carry_2 use full_adder, every other bits use half adder

  // post rounding overflow / underflow check

  logic postround_overflow;
  logic postround_underflow;
  logic [NUM_FORMATS-1:0] fmt_postround_overflow, fmt_postround_underflow;
  for(genvar i = 0; i < NUM_FORMATS; i++) begin: postround_check
      localparam EXP_BITS = fpnew_pkg::FP_ENCODINGS[i].exp_bits;
      if (FP_FMT_CONFIG[i])
        assign fmt_postround_overflow[i] = round_exponent[EXP_BITS-1:0] == '1;
      else
        assign fmt_postround_overflow[i] = 1'b1;
  end
  assign postround_overflow = fmt_postround_overflow[dst_fmt];
  assign postround_underflow = round_exponent == 0
    || ((preround_exponent == 0) && (round_exponent == 1) &&
        (!(result_round_bit & result_sticky_bit) || (!result_sticky_msb && (rnd_mode == fpnew_pkg::RNE || rnd_mode == fpnew_pkg::RMM))));

  wire result_sign = (input_is_zero && !exact_zero_keep_sign) ? 1'b0 : preround_sign;
  assign round_normal_result = {result_sign, round_exponent, round_mantissa};
  assign status.NV = 1'b0;
  assign status.DZ = 1'b0;
  assign status.OF = preround_overflow | postround_overflow;
  assign status.UF = postround_underflow & status.NX;
  assign status.NX = result_round_bit | result_sticky_bit;

endmodule
