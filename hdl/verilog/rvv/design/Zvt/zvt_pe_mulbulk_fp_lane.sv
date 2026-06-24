`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module zvt_pe_mulbulk_fp_lane#(
  parameter fpnew_pkg::fmt_logic_t   FP_FMT_CONFIG = 5'b10001,          // Indicates which data types are supported
  parameter int unsigned             NUM_MID_REGS = 1,
  // Do not change
  localparam int unsigned WIDTH          = fpnew_pkg::max_fp_width(FP_FMT_CONFIG),
  localparam int unsigned NUM_FORMATS    = fpnew_pkg::NUM_FP_FORMATS
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic[NUM_MID_REGS-1:0]      reg_enable,
  input  logic                        up_valid,
  
  // Input signals
  input logic [1:0][WIDTH-1:0]        operands,
  input fpnew_pkg::roundmode_e        rnd_mode,
  input logic [WIDTH/8-1:0]           mask,
  input fpnew_pkg::fp_format_e        src_fmt,
  input fpnew_pkg::fp_format_e        dst_fmt,
  // Output signals
  output logic [WIDTH-1:0]            result,
  output fpnew_pkg::status_t          status,
  output logic                        down_valid
);

  // assert format is supported
  `ifdef ASSERT_ON
    `rvv_forbid(up_valid && reg_enable[0] && (!FP_FMT_CONFIG[src_fmt] || !FP_FMT_CONFIG[dst_fmt]))
      else $warning("Unsupported source format detected");
    `rvv_forbid(up_valid && reg_enable[0] && dst_fmt != fpnew_pkg::FP32)
      else $warning("Destination format is not FP32");
  `endif

  // The super-format that can hold all input formats
  localparam fpnew_pkg::fp_encoding_t SUPER_FORMAT = fpnew_pkg::super_format(FP_FMT_CONFIG);

  localparam int unsigned SUPER_EXP_BITS = SUPER_FORMAT.exp_bits;
  localparam int unsigned SUPER_MAN_BITS = SUPER_FORMAT.man_bits;

  // vector length calculation
  function automatic int unsigned vec_len_calc();
    int unsigned result = 0;
    int unsigned w;
    for (int i = 0; i < NUM_FORMATS; i++) begin
      w = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(i));
      if (WIDTH / w > result) result = WIDTH / w;
    end
    return result;
  endfunction

  localparam int unsigned VEC_LEN = vec_len_calc();
  localparam int unsigned GUARD_BITS = 32'($clog2(VEC_LEN));
  localparam int unsigned OVERFLOW_BITS = 32'($clog2(VEC_LEN));

  // ----------
  // Stage 1: multiplication & Batch-normalization
  // ----------
  localparam int unsigned PROD_EXP_BITS = SUPER_EXP_BITS+1;
  localparam int unsigned PROD_SIG_BITS = SUPER_MAN_BITS+GUARD_BITS+1;

  // defines for fmt_products of all supported formats
  typedef struct packed {
    logic sign;
    logic [PROD_EXP_BITS-1:0] exponent;
    logic [PROD_SIG_BITS-1:0] significand;
    logic round_bit, sticky_bit, sticky_msb;
  } fpu_product_t;
  fpu_product_t [NUM_FORMATS-1:0][VEC_LEN-1:0] fmt_products;
  logic         [NUM_FORMATS-1:0][VEC_LEN-1:0] fmt_product_enable;  // enable bit mask for each product

  logic [NUM_FORMATS-1:0] fmt_special_inf, fmt_special_inf_sign, fmt_special_nan, fmt_special_invalid;

  // generate product instances, special conditions and rvbna reference exponents
  genvar i, j;
  generate
    for(i = 0; i < NUM_FORMATS; i++) begin: fmt_product_gen
      if (!FP_FMT_CONFIG[i]) begin: disabled
        // set defaults
        assign fmt_products[i]         = '1;
        assign fmt_product_enable[i]   = '0;
        assign fmt_special_inf[i]      = 1'b0;
        assign fmt_special_inf_sign[i] = 1'b0;
        assign fmt_special_nan[i]      = 1'b1;
        assign fmt_special_invalid[i]  = 1'b1;
      end else begin: enabled
        // width calculation
        localparam EXP_BITS = fpnew_pkg::FP_ENCODINGS[i].exp_bits;
        localparam MAN_BITS = fpnew_pkg::FP_ENCODINGS[i].man_bits;
        localparam FMT_BITS = EXP_BITS+MAN_BITS+1;
        `ifdef ASSERT_ON
          `rvv_forbid(WIDTH % FMT_BITS != 0)
            else $warning("Format needs padding");
        `endif
        localparam FMT_VEC_LEN = WIDTH/FMT_BITS;

        logic signed[FMT_VEC_LEN-1:0][EXP_BITS+2-1:0] prod_exponent_raw;
        logic [EXP_BITS:0] align_minimum_exponent;
        logic [EXP_BITS:0] align_trimmed_exponent;

        // Build up a balanced tree for maximum exponent selection
        localparam int unsigned EXP_TREE_STAGE = 32'($clog2(FMT_VEC_LEN));
        logic signed[EXP_TREE_STAGE:0][FMT_VEC_LEN-1:0][EXP_BITS+2-1:0] max_exp_tree;
        // inputs are raw exponents
        always_comb begin
          // Only build up the tree when in vector mode. In scalar mode, use subnormal align pattern
          max_exp_tree = '0;
          if (FMT_VEC_LEN != 1) begin
            // build the tree up
            max_exp_tree[0] = prod_exponent_raw;
            for (int x = 0; x < EXP_TREE_STAGE; x++) begin: exp_tree_stage
              for (int y = 0; y < (FMT_VEC_LEN >> x); y=y+2) begin: branch
                max_exp_tree[x+1][y/2] = (max_exp_tree[x][y] > max_exp_tree[x][y+1]) ?
                                          max_exp_tree[x][y] : max_exp_tree[x][y+1];
              end
            end
          end
          // select max exponent as align input
          // if all are within subnormal range, use subnormal pattern
          // In scalar mode, this is always subnormal pattern
          if (max_exp_tree[EXP_TREE_STAGE][0] > 1) begin
            align_minimum_exponent = max_exp_tree[EXP_TREE_STAGE][0];
            align_trimmed_exponent = max_exp_tree[EXP_TREE_STAGE][0];
          end else begin
            align_minimum_exponent = 'b1;
            align_trimmed_exponent = 'b0;
          end
        end

        logic [FMT_VEC_LEN-1:0] component_inf, component_nan, component_invalid, component_inf_sign;

        for (j = FMT_VEC_LEN; j < VEC_LEN; j++) begin: assign_unused_signals
          // attach unused signals to 0
          assign fmt_product_enable[i][j] = 1'b0;
          assign fmt_products[i][j] = '0;
        end
        for (j = 0; j < FMT_VEC_LEN; j++) begin: gen_vec
          // instanciate submodule, assert on batch-normalize exponent equality & sig/exp subnormal match
          assign fmt_product_enable[i][j] = up_valid && int'(src_fmt) == i && mask[j * (VEC_LEN / FMT_VEC_LEN)];
          wire m = fmt_product_enable[i][j];
          logic align_overflow;

          fp_mulfront#(
            .IN_EXP_BITS(EXP_BITS),       .IN_MANT_BITS(MAN_BITS),       // input as is
            .OUT_EXP_BITS(PROD_EXP_BITS), .OUT_SIG_BITS(PROD_SIG_BITS),  // output fp32
            // implementation: E=Ea+Eb-BIAS
            // For IEEE: E-B_dst=(Ea-B_src)+(Eb-B_src)
            // So, BIAS = 2*B_src-B_dst
            .BIAS((2**EXP_BITS)-(2**(SUPER_EXP_BITS-1))-1)
          ) u_mulfront (
            // inputs from bit extractions, with isolation
            .a_sign    (m ? operands[0][j*FMT_BITS+MAN_BITS+EXP_BITS]              : '1),
            .a_exponent(m ? operands[0][j*FMT_BITS+MAN_BITS           +: EXP_BITS] : '1),
            .a_mantissa(m ? operands[0][j*FMT_BITS                    +: MAN_BITS] : '1),
            .b_sign    (m ? operands[1][j*FMT_BITS+MAN_BITS+EXP_BITS]              : '1),
            .b_exponent(m ? operands[1][j*FMT_BITS+MAN_BITS           +: EXP_BITS] : '1),
            .b_mantissa(m ? operands[1][j*FMT_BITS                    +: MAN_BITS] : '1),
            
            // export signals for batch-normalize
            .prod_exponent_raw(prod_exponent_raw[j]),
            .align_minimum_exponent(align_minimum_exponent),
            .align_trimmed_exponent(align_trimmed_exponent),

            // final output
            .prod_sign       (fmt_products[i][j].sign),
            .prod_exponent   (fmt_products[i][j].exponent),
            .prod_significand(fmt_products[i][j].significand),
            .prod_round_bit  (fmt_products[i][j].round_bit),
            .prod_sticky_bit (fmt_products[i][j].sticky_bit),
            .prod_sticky_msb (fmt_products[i][j].sticky_msb),

            // special cases for multiply
            .special_nan     (component_nan     [j]),
            .special_inf     (component_inf     [j]),
            .special_invalid (component_invalid [j]),
            .align_overflow  (align_overflow       )
          );

          assign component_inf_sign[j] = fmt_products[i][j].sign;

          `ifdef ASSERT_ON
            `rvv_forbid(up_valid && reg_enable[0] && ((!fmt_products[i][j].significand[SUPER_MAN_BITS])^(!|fmt_products[i][j].exponent)))
              else $warning("Significand and exponent argue on multiply stage is a subnormal");
            if (j != 0) begin
              `rvv_forbid(up_valid && reg_enable[0] && fmt_products[i][j].exponent != fmt_products[i][0].exponent)
                else $warning("Batch normalize failed on multiply stage");
            end
            `rvv_forbid(up_valid && reg_enable[0] && align_overflow)
              else $warning("Mul-bulk should not overflow at mul-stage. Is SUPER_EXP_BITS too narrow?");
          `endif
        end

        wire inf_minus_inf = (|(component_inf &  component_inf_sign))   // 1. any channel is negative inf, and
                           &&(|(component_inf & ~component_inf_sign));  // 2. any channel is positive inf

        assign fmt_special_nan[i] = (|component_nan) || inf_minus_inf; // if any channel is nan, or inf-inf occurs
        assign fmt_special_inf[i] = !fmt_special_nan[i] && |component_inf; 
        assign fmt_special_inf_sign[i] = |(component_inf & component_inf_sign);
        assign fmt_special_invalid[i] = |{inf_minus_inf, component_invalid};
      end
    end
  endgenerate

  wire [VEC_LEN-1:0] product_enable   = fmt_product_enable[src_fmt];
  wire               special_inf      = fmt_special_inf[src_fmt];
  wire               special_inf_sign = fmt_special_inf_sign[src_fmt];
  wire               special_nan      = fmt_special_nan[src_fmt];
  wire               special_invalid  = fmt_special_invalid[src_fmt];
  fpu_product_t [VEC_LEN-1:0] products;
  assign products = fmt_products[src_fmt];

  // ----------
  // Mid pipeline
  // ----------

  typedef struct packed {
    logic                       en;
    fpu_product_t [VEC_LEN-1:0] products;
    logic         [VEC_LEN-1:0] product_en;
    logic                       special_nan, special_inf, special_inf_sign, special_invalid;
    fpnew_pkg::fp_format_e      dst_fmt;
    fpnew_pkg::roundmode_e      rnd_mode;
  } fs_mid_reg_t;
  // pipeline signals
  fs_mid_reg_t[0:NUM_MID_REGS] mid_pipe;
  // Input stage
  assign mid_pipe[0].en               = up_valid;
  assign mid_pipe[0].products         = products;
  assign mid_pipe[0].product_en       = product_enable;
  assign mid_pipe[0].special_nan      = special_nan;
  assign mid_pipe[0].special_inf      = special_inf;
  assign mid_pipe[0].special_inf_sign = special_inf_sign;
  assign mid_pipe[0].special_invalid  = special_invalid;
  assign mid_pipe[0].dst_fmt          = dst_fmt;
  assign mid_pipe[0].rnd_mode         = (src_fmt == dst_fmt) ? rnd_mode : fpnew_pkg::ROD;

  // Generate the register stages
  for (i = 0; i < NUM_MID_REGS; i++) begin: gen_mid_pipeline
    edff #(.T(fs_mid_reg_t)) mid_reg(.q(mid_pipe[i+1]), .d(mid_pipe[i]), .e(reg_enable[i] & mid_pipe[i].en),
      .clk(clk), .rst_n(rst_n));
  end
  // Output stage
  assign                      down_valid         = mid_pipe[NUM_MID_REGS].en;
  wire                        special_nan_q      = mid_pipe[NUM_MID_REGS].special_nan;
  wire                        special_inf_q      = mid_pipe[NUM_MID_REGS].special_inf;
  wire                        special_invalid_q  = mid_pipe[NUM_MID_REGS].special_invalid;
  wire fpnew_pkg::fp_format_e dst_fmt_q          = mid_pipe[NUM_MID_REGS].dst_fmt;
  
  // ----------
  // Stage 2: Add tree + rounding
  // ----------

  localparam int unsigned ADD_TREE_STAGE = 32'($clog2(VEC_LEN));
  `ifdef ASSERT_ON
    `rvv_expect(ADD_TREE_STAGE == OVERFLOW_BITS);
  `endif
  logic [ADD_TREE_STAGE:0][VEC_LEN-1:0] tree_sign;
  logic [ADD_TREE_STAGE:0][VEC_LEN-1:0][PROD_SIG_BITS+OVERFLOW_BITS+2-1:0] tree_significand;
  generate for (i = 0; i < VEC_LEN; i++) begin
    // Prepare input data
    wire fpu_product_t this_prod = mid_pipe[NUM_MID_REGS].products[i];
    assign tree_sign[0][i] = mid_pipe[NUM_MID_REGS].products[i].sign;
    assign tree_significand[0][i] = mid_pipe[NUM_MID_REGS].product_en[i] ?
                                    {{OVERFLOW_BITS{1'b0}},
                                     this_prod.significand,  // already contains lower guard bits
                                     this_prod.round_bit,
                                     this_prod.sticky_bit} :
                                    '0;
  end endgenerate
  generate
    // Build the tree using fp_absaddsub
    for (i = 0; i < ADD_TREE_STAGE; i++) begin: add_tree
      for (j = 0; j < (1 << (ADD_TREE_STAGE-i)); j=j+2) begin: branch
        logic sum_negative;
        // Build up each branch of the tree
        fp_absaddsub#(.IN_WIDTH(PROD_SIG_BITS+i+2)) u_absaddsub(
          .a(tree_significand[i][ j ][PROD_SIG_BITS+i+2-1:0]),
          .b(tree_significand[i][j+1][PROD_SIG_BITS+i+2-1:0]),
          .do_subtract(tree_sign[i][j] != tree_sign[i][j+1]),
          .sum(tree_significand[i+1][j/2][PROD_SIG_BITS+i+2:0]),
          .sum_negative(sum_negative));

        assign tree_sign[i+1][j/2] = tree_sign[i][j] ^ sum_negative;
      end
    end
  endgenerate

  // Now we have Si=tree_significand[OVERFLOW_BITS][0], P=OVERFLOW_BITS+1
  // and Ei=mid_pipe[NUM_MID_REGS].products[0].exponent
  // We need So(P=1), and Eo>=0 (wrt subnormal)
  // Let's do a full align, i.e. suppose GUARD_BITS==OVERFLOW_BITS==3
  // For normal(exp >= 1)
  //     <O> <-------WP------> <G> R S
  // Si: xxx x.xxxxxxxxxxxxxxx xxx x x
  // adjust to P=1 first, and align
  wire signed [PROD_EXP_BITS+2-1:0] prealign_exponent = {2'b0, mid_pipe[NUM_MID_REGS].products[0].exponent} + ADD_TREE_STAGE;
  logic preround_lead_bit;
  logic [SUPER_EXP_BITS:0] preround_exponent;
  logic [SUPER_MAN_BITS-1:0] preround_mantissa;
  logic preround_round_bit, preround_sticky_bit, preround_sticky_msb;
  logic final_align_overflow;
  fp_align#(
    .IN_EXP_BITS(32'(PROD_EXP_BITS+2)),
    .IN_SIG_BITS(32'(PROD_SIG_BITS + OVERFLOW_BITS + 2)),  // 2 for R and S
    .OUT_EXP_BITS(32'(SUPER_EXP_BITS + 1)),
    .OUT_SIG_BITS(32'(SUPER_MAN_BITS + 1))
  ) u_align (
    .in_exponent(prealign_exponent),
    .in_significand(tree_significand[ADD_TREE_STAGE][0]),

    .align_minimum_exponent((SUPER_EXP_BITS+1)'(1'b1)),  // subnormal align mode
    .align_trimmed_exponent((SUPER_EXP_BITS+1)'(1'b0)),

    .out_exponent   (preround_exponent),
    .out_significand({preround_lead_bit, preround_mantissa}),
    .out_round_bit  (preround_round_bit),
    .out_sticky_bit (preround_sticky_bit),
    .out_sticky_msb (preround_sticky_msb),
    .overflow       (final_align_overflow)
  );

  `ifdef ASSERT_ON
    `rvv_expect(!down_valid || ((preround_exponent != 0) == preround_lead_bit))
      else $warning("Significand and exponent argue on rounding stage is a subnormal");
  `endif
  // ----------
  // rounding to dst_fmt
  // ----------
  logic [WIDTH-1:0]        round_normal_result;
  fpnew_pkg::status_t      round_status;
  fp_rounding#(
    .FP_FMT_CONFIG(FP_FMT_CONFIG)
  ) u_rounding (
    .dst_fmt             (dst_fmt_q),
    .rnd_mode            (mid_pipe[NUM_MID_REGS].rnd_mode),
    .exact_zero_keep_sign(mid_pipe[NUM_MID_REGS].rnd_mode != fpnew_pkg::ROD),  // TODO: align behavior with model
    .preround_sign       (tree_sign[ADD_TREE_STAGE][0]),
    .preround_exponent   (preround_exponent),
    .preround_mantissa   (preround_mantissa),
    .round_bit           (preround_round_bit),
    .sticky_bit          (preround_sticky_bit),
    .sticky_msb          (preround_sticky_msb),
    .round_normal_result (round_normal_result),
    .status              (round_status));

  logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_nan, fmt_inf;
  logic inf_sign;
  for (i = 0; i < NUM_FORMATS; i++) begin
    localparam EXP_BITS = fpnew_pkg::FP_ENCODINGS[i].exp_bits;
    localparam MAN_BITS = fpnew_pkg::FP_ENCODINGS[i].man_bits;
    assign fmt_nan[i] = {1'b0,     {EXP_BITS{1'b1}}, 1'b1, {WIDTH-1-EXP_BITS-1{1'b0}}};
    assign fmt_inf[i] = {inf_sign, {EXP_BITS{1'b1}}, {WIDTH-1-EXP_BITS{1'b0}}        };
  end

  // special mux
  always_comb begin
    inf_sign = tree_sign[ADD_TREE_STAGE][0];
    if (mid_pipe[NUM_MID_REGS].special_nan) begin
      result = fmt_nan[dst_fmt_q];
      status = '{NV: mid_pipe[NUM_MID_REGS].special_invalid, default: '0};
    end else if (mid_pipe[NUM_MID_REGS].special_inf) begin
      inf_sign = mid_pipe[NUM_MID_REGS].special_inf_sign;
      result = fmt_inf[dst_fmt_q];
      status = '0;
    end else if (final_align_overflow) begin
      result = fmt_inf[dst_fmt_q];
      status = '{OF: 1'b1, default: '0};
    end else begin
      result = round_status.OF ? fmt_inf[dst_fmt_q] : round_normal_result;
      status = round_status;
    end
  end
endmodule
