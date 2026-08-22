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

  genvar i, j, k;

  // Pre-mask to utilized logic share
  logic [1:0][WIDTH-1:0]        operands_masked;
  generate
    for(i = 0; i < WIDTH/8; i++) begin: apply_mask
      assign operands_masked[0][i*8 +: 8] = (up_valid && mask[i]) ? operands[0][i*8 +: 8] : 8'b0;
      assign operands_masked[1][i*8 +: 8] = (up_valid && mask[i]) ? operands[1][i*8 +: 8] : 8'b0;
    end
  endgenerate

  // generate product instances, special conditions and rvbna reference exponents
  generate
    for(i = 0; i < NUM_FORMATS; i++) begin: fmt_product_gen
      if (!FP_FMT_CONFIG[i]) begin: disabled
        // set defaults
        assign fmt_products[i]         = '0;
        assign fmt_product_enable[i]   = '0;
        assign fmt_special_inf[i]      = 1'b0;
        assign fmt_special_inf_sign[i] = 1'b0;
        assign fmt_special_nan[i]      = 1'b0;
        assign fmt_special_invalid[i]  = 1'b0;
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
          if (max_exp_tree[EXP_TREE_STAGE][0] > (EXP_BITS+2)'($signed(1))) begin
            align_minimum_exponent = max_exp_tree[EXP_TREE_STAGE][0];
            align_trimmed_exponent = max_exp_tree[EXP_TREE_STAGE][0];
          end else begin
            align_minimum_exponent = 'b1;
            align_trimmed_exponent = 'b0;
          end
        end

        logic [FMT_VEC_LEN-1:0] component_inf, component_nan, component_invalid, component_inf_sign;

        for (j = FMT_VEC_LEN; j < VEC_LEN; j++) begin: untouched
          // attach unused signals to 0
          assign fmt_product_enable[i][j] = 1'b0;
          assign fmt_products[i][j] = '0;
        end
        for (j = 0; j < FMT_VEC_LEN; j++) begin: gen_vec
          // instanciate submodule, assert on batch-normalize exponent equality & sig/exp subnormal match
          assign fmt_product_enable[i][j] = mask[j * (VEC_LEN / FMT_VEC_LEN)];
          logic align_overflow;

          `ifdef ASSERT_ON
            `rvv_forbid(up_valid && reg_enable[0] && int'(src_fmt) == i &&
              |(mask[j*(VEC_LEN/FMT_VEC_LEN) +: (VEC_LEN/FMT_VEC_LEN)]) !=
              &(mask[j*(VEC_LEN/FMT_VEC_LEN) +: (VEC_LEN/FMT_VEC_LEN)]))
              else $warning("Partial mask detected on element #%d with src_fmt=%d!", j, i);
          `endif

          fp_mulfront#(
            .IN_EXP_BITS(EXP_BITS),       .IN_MANT_BITS(MAN_BITS),       // input as is
            .OUT_EXP_BITS(PROD_EXP_BITS), .OUT_SIG_BITS(PROD_SIG_BITS),  // output fp32
            // implementation: E=Ea+Eb-BIAS
            // For IEEE: E-B_dst=(Ea-B_src)+(Eb-B_src)
            // So, BIAS = 2*B_src-B_dst
            .BIAS((2**EXP_BITS)-(2**(SUPER_EXP_BITS-1))-1)
          ) u_mulfront (
            // inputs from bit extractions, with isolation
            .a_sign    (operands_masked[0][j*FMT_BITS+MAN_BITS+EXP_BITS]),
            .a_exponent(operands_masked[0][j*FMT_BITS+MAN_BITS           +: EXP_BITS]),
            .a_mantissa(operands_masked[0][j*FMT_BITS                    +: MAN_BITS]),
            .b_sign    (operands_masked[1][j*FMT_BITS+MAN_BITS+EXP_BITS]),
            .b_exponent(operands_masked[1][j*FMT_BITS+MAN_BITS           +: EXP_BITS]),
            .b_mantissa(operands_masked[1][j*FMT_BITS                    +: MAN_BITS]),
            
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
            `rvv_forbid(up_valid && reg_enable[0] && src_fmt == i &&
                ((!fmt_products[i][j].significand[PROD_SIG_BITS-1]) ^ (!(|fmt_products[i][j].exponent))))
              else $warning("Significand and exponent argue on multiply stage is a subnormal");
            if (j != 0) begin
              `rvv_forbid(up_valid && reg_enable[0] && src_fmt == i &&
                fmt_products[i][j].exponent != fmt_products[i][0].exponent)
                else $warning("Batch normalize failed on multiply stage");
            end
            `rvv_forbid(up_valid && reg_enable[0] && src_fmt == i && align_overflow)
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

  wire               special_inf      = fmt_special_inf[src_fmt];
  wire               special_inf_sign = fmt_special_inf_sign[src_fmt];
  wire               special_nan      = fmt_special_nan[src_fmt];
  wire               special_invalid  = fmt_special_invalid[src_fmt];

  // ----------
  // Mid pipeline
  // ----------

  // Control signals shared across all formats, one register per pipe stage.
  typedef struct packed {
    logic                       en;
    fpnew_pkg::fp_format_e      src_fmt;
    logic                       special_nan, special_inf, special_inf_sign, special_invalid;
    fpnew_pkg::fp_format_e      dst_fmt;
    fpnew_pkg::roundmode_e      rnd_mode;
  } fp_mid_ctrl_reg_t;

  // Per-format data payload, one register per format per pipe stage. Only the
  // register whose format matches src_fmt clocks new data each cycle; the
  // others hold, saving switching power on the wide fmt_products lanes.
  typedef struct packed {
    fpu_product_t [VEC_LEN-1:0] fmt_products;
    logic         [VEC_LEN-1:0] fmt_product_en;
  } fp_mid_data_reg_t;

  fp_mid_ctrl_reg_t [0:NUM_MID_REGS]                  mid_ctrl_pipe;
  fp_mid_data_reg_t [0:NUM_MID_REGS][NUM_FORMATS-1:0] mid_data_pipe;

  // Input stage
  assign mid_ctrl_pipe[0].en               = up_valid;
  assign mid_ctrl_pipe[0].src_fmt          = src_fmt;
  assign mid_ctrl_pipe[0].special_nan      = special_nan;
  assign mid_ctrl_pipe[0].special_inf      = special_inf;
  assign mid_ctrl_pipe[0].special_inf_sign = special_inf_sign;
  assign mid_ctrl_pipe[0].special_invalid  = special_invalid;
  assign mid_ctrl_pipe[0].dst_fmt          = dst_fmt;
  assign mid_ctrl_pipe[0].rnd_mode         = (src_fmt == dst_fmt) ? rnd_mode : fpnew_pkg::ROD;
  for (i = 0; i < NUM_FORMATS; i++) begin: gen_mid_data_in
    if (FP_FMT_CONFIG[i]) begin: enabled
      assign mid_data_pipe[0][i].fmt_products   = fmt_products[i];
      assign mid_data_pipe[0][i].fmt_product_en = fmt_product_enable[i];
    end else begin: disabled
      assign mid_data_pipe[0][i] = '0;
    end
  end

  // Generate the register stages
  for (i = 0; i < NUM_MID_REGS; i++) begin: gen_mid_pipeline
    edff #(.T(fp_mid_ctrl_reg_t)) ctrl_reg (
      .q(mid_ctrl_pipe[i+1]),
      .d(mid_ctrl_pipe[i]),
      .e(reg_enable[i] & mid_ctrl_pipe[i].en),
      .clk(clk), .rst_n(rst_n));
    for (j = 0; j < NUM_FORMATS; j++) begin: gen_mid_data_reg
      if (FP_FMT_CONFIG[j]) begin: enabled
        edff #(.T(fp_mid_data_reg_t)) data_reg (
          .q(mid_data_pipe[i+1][j]),
          .d(mid_data_pipe[i][j]),
          // Only clock the format that is actually in flight this cycle.
          .e(reg_enable[i] & mid_ctrl_pipe[i].en & (int'(mid_ctrl_pipe[i].src_fmt) == j)),
          .clk(clk), .rst_n(rst_n));
      end else begin: disabled
        assign mid_data_pipe[i+1][j] = '0;
      end
    end
  end
  // Output stage
  assign                      down_valid         = mid_ctrl_pipe[NUM_MID_REGS].en;
  wire fpnew_pkg::fp_format_e src_fmt_q          = mid_ctrl_pipe[NUM_MID_REGS].src_fmt;
  wire fpnew_pkg::fp_format_e dst_fmt_q          = mid_ctrl_pipe[NUM_MID_REGS].dst_fmt;
  
  // ----------
  // Stage 2: Add tree + rounding
  // ----------

  // Actually PROD_SIG_BITS+2 should be enough,
  // but let's trust EDA for this optimization since lower bits directly tie to 0.
  localparam int unsigned TREE_OUTPUT_SIG_WIDTH = PROD_SIG_BITS + OVERFLOW_BITS + 2;  // 2 for R and S

  // Per-format preround bundle. Single-lane formats fill this directly from
  // the mulfront-normalized product (no stage-2 lzc/fp_align needed).
  // Multi-lane formats build it from an adder tree + a shared fp_align.
  logic [NUM_FORMATS-1:0]                       fmt_preround_sign;
  logic [NUM_FORMATS-1:0]                       fmt_preround_lead_bit;
  logic [NUM_FORMATS-1:0][SUPER_MAN_BITS-1:0]   fmt_preround_mantissa;
  logic [NUM_FORMATS-1:0][SUPER_EXP_BITS:0]     fmt_preround_exponent;
  logic [NUM_FORMATS-1:0]                       fmt_preround_round_bit;
  logic [NUM_FORMATS-1:0]                       fmt_preround_sticky_bit;
  logic [NUM_FORMATS-1:0]                       fmt_preround_sticky_msb;
  logic [NUM_FORMATS-1:0]                       fmt_preround_align_overflow;

  // fmt_tree_* : per-format pre-align adder-tree result. Vector-lane branches
  // publish here; a src_fmt_q-mux selects one bundle to feed u_vec_align.
  logic [NUM_FORMATS-1:0][TREE_OUTPUT_SIG_WIDTH-1:0]                 fmt_tree_sig;
  logic signed [NUM_FORMATS-1:0][PROD_EXP_BITS+2-1:0]                fmt_tree_exp;
  logic [NUM_FORMATS-1:0][$clog2(TREE_OUTPUT_SIG_WIDTH)-1:0]         fmt_tree_scnt;
  logic [NUM_FORMATS-1:0]                                            fmt_tree_zero;

  // Shared vector aligner outputs -- declared early so vector-lane branches can
  // wire fmt_preround_*[i] straight to these signals. Driven by u_vec_align
  // instantiated after the generate block.
  logic [SUPER_MAN_BITS:0]  vec_out_sig;  // {lead, mantissa}
  logic [SUPER_EXP_BITS:0]  vec_out_exp;
  logic                     vec_out_round_bit, vec_out_sticky_bit, vec_out_sticky_msb, vec_out_overflow;

  generate
    for (i = 0; i < NUM_FORMATS; i++) begin: fmt_add_tree_gen
      if (!FP_FMT_CONFIG[i]) begin: disabled
        assign fmt_preround_sign[i]           = 1'b0;
        assign fmt_preround_lead_bit[i]       = 1'b0;
        assign fmt_preround_mantissa[i]       = '0;
        assign fmt_preround_exponent[i]       = '0;
        assign fmt_preround_round_bit[i]      = 1'b0;
        assign fmt_preround_sticky_bit[i]     = 1'b0;
        assign fmt_preround_sticky_msb[i]     = 1'b0;
        assign fmt_preround_align_overflow[i] = 1'b0;
        assign fmt_tree_sig[i]    = '0;
        assign fmt_tree_exp[i]    = '0;
        assign fmt_tree_scnt[i]   = '0;
        assign fmt_tree_zero[i]   = 1'b1;
      end else begin: enabled
        localparam int unsigned EXP_BITS    = fpnew_pkg::FP_ENCODINGS[i].exp_bits;
        localparam int unsigned MAN_BITS    = fpnew_pkg::FP_ENCODINGS[i].man_bits;
        localparam int unsigned FMT_BITS    = EXP_BITS + MAN_BITS + 1;
        localparam int unsigned FMT_VEC_LEN = WIDTH / FMT_BITS;

        if (FMT_VEC_LEN == 1) begin: bypass_stage2
          // Single-lane path: mulfront output is already fully normalized (P=1).
          // Fold GUARD_BITS of extra precision below the mantissa into round/sticky.
          //
          // Layout of this_prod.significand (PROD_SIG_BITS = SUPER_MAN_BITS+GUARD_BITS+1):
          //   [PROD_SIG_BITS-1]           = lead bit
          //   [PROD_SIG_BITS-2:GUARD_BITS]= mantissa (SUPER_MAN_BITS bits)
          //   [GUARD_BITS-1:0]            = guard bits (may be empty)
          wire fpu_product_t this_prod = mid_data_pipe[NUM_MID_REGS][i].fmt_products[0];

          assign fmt_preround_sign[i]           = this_prod.sign;
          assign fmt_preround_lead_bit[i]       = this_prod.significand[PROD_SIG_BITS-1];
          assign fmt_preround_mantissa[i]       = this_prod.significand[PROD_SIG_BITS-2 -: SUPER_MAN_BITS];
          assign fmt_preround_exponent[i]       = this_prod.exponent;
          assign fmt_preround_align_overflow[i] = 1'b0;  // guaranteed by mul-stage assertion
          if (GUARD_BITS >= 2) begin: g_multi_guard
            assign fmt_preround_round_bit[i]  = this_prod.significand[GUARD_BITS-1];
            assign fmt_preround_sticky_bit[i] = |this_prod.significand[GUARD_BITS-2:0] |
                                                this_prod.round_bit | this_prod.sticky_bit;
            assign fmt_preround_sticky_msb[i] = this_prod.significand[GUARD_BITS-2];
          end else if (GUARD_BITS == 1) begin: g_one_guard
            assign fmt_preround_round_bit[i]  = this_prod.significand[0];
            assign fmt_preround_sticky_bit[i] = this_prod.round_bit | this_prod.sticky_bit;
            assign fmt_preround_sticky_msb[i] = this_prod.round_bit;
          end else begin: g_no_guard  // GUARD_BITS == 0
            assign fmt_preround_round_bit[i]  = this_prod.round_bit;
            assign fmt_preround_sticky_bit[i] = this_prod.sticky_bit;
            assign fmt_preround_sticky_msb[i] = this_prod.sticky_msb;
          end
          // Tree bundle is unused for single-lane; tie to safe defaults.
          assign fmt_tree_sig[i]    = '0;
          assign fmt_tree_exp[i]    = '0;
          assign fmt_tree_scnt[i]   = '0;
          assign fmt_tree_zero[i]   = 1'b1;
        end else begin: multi_lane
          localparam int unsigned FMT_TREE_STAGE   = 32'($clog2(FMT_VEC_LEN));
          localparam int unsigned FMT_TREE_SIG_LEN = PROD_SIG_BITS + FMT_TREE_STAGE + 2;
          localparam int unsigned FMT_LSB_PAD      = TREE_OUTPUT_SIG_WIDTH - FMT_TREE_SIG_LEN;

          logic [FMT_TREE_STAGE:0][FMT_VEC_LEN-1:0]                       fmt_tree_sign;
          logic [FMT_TREE_STAGE:0][FMT_VEC_LEN-1:0][FMT_TREE_SIG_LEN-1:0] fmt_tree_significand;

          // Prepare input data
          for (k = 0; k < FMT_VEC_LEN; k = k + 1) begin: load
            wire fpu_product_t this_prod = mid_data_pipe[NUM_MID_REGS][i].fmt_products[k];
            assign fmt_tree_sign[0][k] = this_prod.sign;
            assign fmt_tree_significand[0][k] = mid_data_pipe[NUM_MID_REGS][i].fmt_product_en[k] ?
                                              {{FMT_TREE_STAGE{1'b0}},
                                               this_prod.significand,  // already contains lower guard bits
                                               this_prod.round_bit,
                                               this_prod.sticky_bit} :
                                              '0;
          end

          logic [$clog2(FMT_TREE_SIG_LEN)-1:0] fmt_scnt;
          logic                                fmt_zero;
          // Build the tree using fp_absaddsub
          for (j = 0; j < FMT_TREE_STAGE; j++) begin: add_tree
            // Each stage will reduce count of significands by a half.
            // Set higher entries to 0 to make spyglass happy.
            for (k = (1 << (FMT_TREE_STAGE-j-1)); k < FMT_VEC_LEN; k++) begin: untouched
              assign fmt_tree_significand[j+1][k] = '0;
            end
            for (k = 0; k < (1 << (FMT_TREE_STAGE-j)); k=k+2) begin: branch
              localparam bit LAST_STAGE = (j == (FMT_TREE_STAGE-1)) && (k == 0);
              localparam int unsigned STAGE_IN_WIDTH = PROD_SIG_BITS + j + 2;
              // When there is only one add stage, one of the operands has significand
              // whose valid bits occupy only the top 2*MAN_BITS+2, and the
              // low guard/round/sticky bits are all zero.  This enables the split
              // optimization in fp_absaddsub.  Otherwise keep VALID_HIGH_BITS =
              // IN_WIDTH to fall back to the original full-width path.
              localparam int unsigned STAGE_VALID_HIGH_BITS =
                  (FMT_TREE_STAGE == 1 && 2*MAN_BITS + 2 < STAGE_IN_WIDTH) ?
                  (2*MAN_BITS + 2) : STAGE_IN_WIDTH;
              logic sum_negative;
              logic [$clog2(PROD_SIG_BITS+j+2+1)-1:0] scnt_wire;
              // Build up each branch of the tree
              fp_absaddsub#(
                .IN_WIDTH        (STAGE_IN_WIDTH),
                .VALID_HIGH_BITS (STAGE_VALID_HIGH_BITS),
                .ENABLE_LZA      (LAST_STAGE)
              ) u_absaddsub(
                .a          (fmt_tree_significand[j][ k ][PROD_SIG_BITS+j+2-1:0]),
                .b          (fmt_tree_significand[j][k+1][PROD_SIG_BITS+j+2-1:0]),
                .do_subtract(fmt_tree_sign[j][k] != fmt_tree_sign[j][k+1]),
                .sum        (fmt_tree_significand[j+1][k/2][PROD_SIG_BITS+j+2:0]),
                .sum_negative(sum_negative),
                .lza_scnt   (scnt_wire));

              assign fmt_tree_sign[j+1][k/2] = fmt_tree_sign[j][k] ^ sum_negative;

              if (LAST_STAGE) begin: g_capture_lza
                assign fmt_scnt = scnt_wire;
                assign fmt_zero = ~|(fmt_tree_significand[j+1][k/2][PROD_SIG_BITS+j+2:0]);
              end
            end
          end

          // Left align tree result to the input of shared vector fp_align
          assign fmt_tree_sig[i]    = {fmt_tree_significand[FMT_TREE_STAGE][0], {FMT_LSB_PAD{1'b0}}};
          assign fmt_tree_exp[i]    = {2'b0, mid_data_pipe[NUM_MID_REGS][i].fmt_products[0].exponent} + FMT_TREE_STAGE;
          assign fmt_tree_scnt[i]   = fmt_scnt;
          assign fmt_tree_zero[i]   = fmt_zero;
          `ifdef ASSERT_ON
            `rvv_expect(PROD_EXP_BITS >= $clog2(FMT_TREE_STAGE + 1))
              else $warning("Overflow detect on fmt_tree_exp offset feeding u_vec_align.in_exponent!");
          `endif

          // Connect fp_align's output to fp_round input of this format
          assign fmt_preround_sign[i]           = fmt_tree_sign[FMT_TREE_STAGE][0];
          assign fmt_preround_lead_bit[i]       = vec_out_sig[SUPER_MAN_BITS];
          assign fmt_preround_mantissa[i]       = vec_out_sig[SUPER_MAN_BITS-1:0];
          assign fmt_preround_exponent[i]       = vec_out_exp;
          assign fmt_preround_round_bit[i]      = vec_out_round_bit;
          assign fmt_preround_sticky_bit[i]     = vec_out_sticky_bit;
          assign fmt_preround_sticky_msb[i]     = vec_out_sticky_msb;
          assign fmt_preround_align_overflow[i] = vec_out_overflow;
        end
      end
    end
  endgenerate

  // shared vector aligner
  fp_align#(
    .IN_EXP_BITS   (32'(PROD_EXP_BITS+2)),
    .IN_SIG_BITS   (32'(TREE_OUTPUT_SIG_WIDTH)),
    .OUT_EXP_BITS  (32'(SUPER_EXP_BITS + 1)),
    .OUT_SIG_BITS  (32'(SUPER_MAN_BITS + 1)),
    .USE_EXT_LZC   (1'b1),
    .USE_LZA_POSTFIX(1'b1)
  ) u_vec_align (
    .in_exponent   (fmt_tree_exp[src_fmt_q]),
    .in_significand(fmt_tree_sig[src_fmt_q]),
    .ext_lzc_cnt   (fmt_tree_scnt[src_fmt_q]),
    .ext_in_zero   (fmt_tree_zero[src_fmt_q]),
    .align_minimum_exponent((SUPER_EXP_BITS+1)'(1'b1)),  // subnormal align mode
    .align_trimmed_exponent((SUPER_EXP_BITS+1)'(1'b0)),
    .out_exponent   (vec_out_exp),
    .out_significand(vec_out_sig),
    .out_round_bit  (vec_out_round_bit),
    .out_sticky_bit (vec_out_sticky_bit),
    .out_sticky_msb (vec_out_sticky_msb),
    .overflow       (vec_out_overflow));

  // Final preround selection: a plain per-signal mux by src_fmt_q. Each
  // fmt_preround_*[i] slot was already routed to the right source inside its
  // generate branch (scalar bypass or shared aligner output).
  wire                       preround_sign         = fmt_preround_sign[src_fmt_q];
  wire                       preround_lead_bit     = fmt_preround_lead_bit[src_fmt_q];
  wire [SUPER_MAN_BITS-1:0]  preround_mantissa     = fmt_preround_mantissa[src_fmt_q];
  wire [SUPER_EXP_BITS:0]    preround_exponent     = fmt_preround_exponent[src_fmt_q];
  wire                       preround_round_bit    = fmt_preround_round_bit[src_fmt_q];
  wire                       preround_sticky_bit   = fmt_preround_sticky_bit[src_fmt_q];
  wire                       preround_sticky_msb   = fmt_preround_sticky_msb[src_fmt_q];
  wire                       final_align_overflow  = fmt_preround_align_overflow[src_fmt_q];

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
    .rnd_mode            (mid_ctrl_pipe[NUM_MID_REGS].rnd_mode),
    .exact_zero_keep_sign(mid_ctrl_pipe[NUM_MID_REGS].rnd_mode != fpnew_pkg::ROD),  // TODO: align behavior with model
    .preround_sign       (preround_sign),
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
    inf_sign = preround_sign;
    if (mid_ctrl_pipe[NUM_MID_REGS].special_nan) begin
      result = fmt_nan[dst_fmt_q];
      status = '{NV: mid_ctrl_pipe[NUM_MID_REGS].special_invalid, default: '0};
    end else if (mid_ctrl_pipe[NUM_MID_REGS].special_inf) begin
      inf_sign = mid_ctrl_pipe[NUM_MID_REGS].special_inf_sign;
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
