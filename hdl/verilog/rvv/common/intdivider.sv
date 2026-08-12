
module intdivider
(
  clk,
  rst_n,
  div_valid,
  div_ready,
  opcode,
  src2_dividend,
  src1_divisor,
  result_quotient,
  result_remainder,
  result_valid,
  result_ready,
  trap_flush_rvv
);
//
// parameter
//
  parameter  logic[7:0] DIV_WIDTH = 8'd32;
  localparam            DIV_SIGN  = 0;
  localparam            DIV_ZERO  = 1;

//
// interface signals
//
  // global signals
  input   logic                 clk;
  input   logic                 rst_n;

  // opcode 
  input   logic                 opcode;

  // operand 
  input   logic                 div_valid;
  output  logic                 div_ready;
  input   logic [DIV_WIDTH-1:0] src2_dividend;
  input   logic [DIV_WIDTH-1:0] src1_divisor;

  // result
  output  logic [DIV_WIDTH-1:0] result_quotient;
  output  logic [DIV_WIDTH-1:0] result_remainder;
  output  logic                 result_valid;
  input   logic                 result_ready;

  // trap-flush
  input   logic                 trap_flush_rvv;  

//
// internal signals
//
  // FSM
  typedef enum logic [1:0] {DIV_IDLE, DIV_WORKING, DIV_PRINT} state_e;
  state_e                       state, next_state;
  
  // number of leading zero bits
  logic [$clog2(DIV_WIDTH):0]   cnt_clzb;
  logic [$clog2(DIV_WIDTH):0]   clzb;
  logic [$clog2(DIV_WIDTH):0]   count_shift;

  // processing round for divider
  logic [DIV_WIDTH-1:0]         quotient_r1;
  logic [DIV_WIDTH-1:0]         quotient_r2;
  logic [DIV_WIDTH-1:0]         quotient_r3;
  logic [DIV_WIDTH-1:0]         remainder_r1;
  logic [DIV_WIDTH-1:0]         remainder_r2;
  logic [DIV_WIDTH-1:0]         remainder_r3;
  logic [$clog2(DIV_WIDTH):0]   count_r1;
  logic [$clog2(DIV_WIDTH):0]   count_r2;
  logic [$clog2(DIV_WIDTH):0]   count_r3;

  // register signals
  logic                         dividend_en;
  logic [DIV_WIDTH-1:0]         dividend_d;
  logic [DIV_WIDTH-1:0]         dividend_q;
  logic                         divisor_en;
  logic [DIV_WIDTH-1:0]         divisor_d;
  logic [DIV_WIDTH-1:0]         divisor_q;
  logic                         quotient_en;
  logic [DIV_WIDTH-1:0]         quotient_d;
  logic [DIV_WIDTH-1:0]         quotient_q;
  logic                         remainder_en;
  logic [DIV_WIDTH-1:0]         remainder_d;
  logic [DIV_WIDTH-1:0]         remainder_q;
  logic                         count_en;
  logic [$clog2(DIV_WIDTH):0]   count_d;
  logic [$clog2(DIV_WIDTH):0]   count_q;
  logic                         q_sgn_en;
  logic                         q_sgn_d;
  logic                         q_sgn_q;
  logic                         r_sgn_en;
  logic                         r_sgn_d;
  logic                         r_sgn_q;
`ifdef TB_SUPPORT
  logic                         res_reuse_valid_p0;
`endif
  
//
// register
//
  // dividend
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  dividend
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (dividend_en),
    .c      (trap_flush_rvv),
    .d      (dividend_d),
    .q      (dividend_q)
  );
  // divisor
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  divisor
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (divisor_en),
    .c      (trap_flush_rvv),
    .d      (divisor_d),
    .q      (divisor_q)
  );
  // quotient
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  quotient
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (quotient_en),
    .c      (trap_flush_rvv),
    .d      (quotient_d),
    .q      (quotient_q)
  );
  // remainder
  cdffr
  #(
    .T      (logic [DIV_WIDTH-1:0])
  )
  remainder
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (remainder_en),
    .c      (trap_flush_rvv),
    .d      (remainder_d),
    .q      (remainder_q)
  );
  // count
  edff
  #(
  .T        (logic [$clog2(DIV_WIDTH):0])
  )
  count
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (count_en),
    .d      (count_d),
    .q      (count_q)
  );
  // record quotient sgn-bit
  cdffr
  q_sgn
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (q_sgn_en),
    .c      (trap_flush_rvv),
    .d      (q_sgn_d),
    .q      (q_sgn_q)
  );
  // record remainder sgn-bit
  cdffr
  r_sgn
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (r_sgn_en),
    .c      (trap_flush_rvv),
    .d      (r_sgn_d),
    .q      (r_sgn_q)
  );

//
// FSM
//
  edff
  #(
  .T        (state_e),
  .INIT     (DIV_IDLE)
  )
  fsm_state
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (next_state!=state),
    .d      (next_state),
    .q      (state)
  );
  
  // state transition
  always_comb begin
    next_state = state;

    case(state)
      DIV_IDLE: begin
        if(div_valid&(!trap_flush_rvv)) begin
          if ((count_en=='b1)&(count_d=='b1))
            next_state = DIV_PRINT;
          else
            next_state = DIV_WORKING;
        end
        else
          next_state = DIV_IDLE;
      end
      DIV_WORKING: begin
        if(div_valid&(!trap_flush_rvv)) begin
          if ((count_en=='b1)&(count_d=='b1))
            next_state = DIV_PRINT;
          else
            next_state = DIV_WORKING;
        end
        else
          next_state = DIV_IDLE;
      end
      DIV_PRINT: begin
        if (div_valid&(!result_ready)&(!trap_flush_rvv))
          next_state = DIV_PRINT;
        else
          next_state = DIV_IDLE;
      end
    endcase
  end

  // count leading zero
  clz #(
    .WIDTH  (DIV_WIDTH)
  ) u_clz (
    .src    (dividend_d),
    .mode   (1'b0),
    .cnt    (clzb)
  );

  assign count_shift = ($clog2(DIV_WIDTH)+1)'(DIV_WIDTH+1) - clzb;

  // div is ready to receive a new uop
  assign div_ready = state==DIV_IDLE; 
  
  // FSM
  always_comb begin
    // initial
    dividend_en      = 'b0;
    dividend_d       = 'b0;
    divisor_en       = 'b0;
    divisor_d        = 'b0;
    quotient_en      = 'b0;
    quotient_d       = 'b0;
    remainder_en     = 'b0;
    remainder_d      = 'b0;
    count_en         = 'b0;
    count_d          = 'b0;
    q_sgn_en         = 'b0;
    q_sgn_d          = 'b0;         
    r_sgn_en         = 'b0;
    r_sgn_d          = 'b0;
    cnt_clzb         = 'b0;
    quotient_r1      = 'b0;
    quotient_r2      = 'b0;
    quotient_r3      = 'b0;
    remainder_r1     = 'b0;
    remainder_r2     = 'b0;
    remainder_r3     = 'b0;
    count_r1         = 'b0;
    count_r2         = 'b0;
    count_r3         = 'b0;
    result_quotient  = 'b0;
    result_remainder = 'b0;
    result_valid     = 'b0;
`ifdef TB_SUPPORT
    res_reuse_valid_p0 = 'b0;
`endif

    case(state)
      DIV_IDLE: begin
        if(div_valid) begin
          // check whether divisor is 0
          if(src1_divisor=='b0) begin
            dividend_en = 'b1;
            dividend_d  = 'b0;

            divisor_en = 'b1;
            divisor_d  = 'b0;

            quotient_en = 'b1;
            quotient_d  = '1;

            remainder_en = 'b1;
            remainder_d  = src2_dividend;

            q_sgn_en = 'b1;
            q_sgn_d  = 'b0;

            r_sgn_en = 'b1;
            r_sgn_d  = 'b0;

            count_en = 'b1;
            count_d  = 'b1;
          end
          // check whether is -2^(WIDTH-1)/-1. The result will overflow.
          else if ((opcode==DIV_SIGN)&(src2_dividend=={1'b1,{(DIV_WIDTH-1){1'b0}}})&(src1_divisor=='1)) begin
            dividend_en = 'b1;
            dividend_d  = 'b0;

            divisor_en = 'b1;
            divisor_d  = 'b0;

            quotient_en = 'b1;
            quotient_d  = {1'b1,{(DIV_WIDTH-1){1'b0}}};

            remainder_en = 'b1;
            remainder_d  = 'b0;

            q_sgn_en = 'b1;
            q_sgn_d  = 'b0;

            r_sgn_en = 'b1;
            r_sgn_d  = 'b0;

            count_en = 'b1;
            count_d  = 'b1;
          end
          // start to initialize
          else begin
            if(opcode==DIV_SIGN) begin
              // convert signed data to unsigned data
              dividend_d  = src2_dividend[DIV_WIDTH-1] ? (~(src2_dividend)+1) : src2_dividend;
              divisor_d  = src1_divisor[DIV_WIDTH-1] ? (~(src1_divisor )+1) : src1_divisor;
              
              q_sgn_d   = src2_dividend[DIV_WIDTH-1]^src1_divisor[DIV_WIDTH-1];
              r_sgn_d   = src2_dividend[DIV_WIDTH-1];
            end
            else begin
              dividend_d  = src2_dividend;
              divisor_d  = src1_divisor;

              q_sgn_d  = 'b0;
              r_sgn_d  = 'b0;
            end

            // check whether dividend and divisor equal to last source data
            if ((dividend_d==dividend_q)&(divisor_d==divisor_q)&(q_sgn_d==q_sgn_q)&(r_sgn_d==r_sgn_q)) begin
              dividend_en = 'b0; 
              divisor_en = 'b0;

              q_sgn_en  = 'b0;
              r_sgn_en  = 'b0;
              
              count_en = 'b1;
              count_d  = 'b1;

`ifdef TB_SUPPORT
              res_reuse_valid_p0 = 1'b1;
`endif
            end
            else begin
              dividend_en = 'b1; 
              divisor_en = 'b1;

              q_sgn_en  = 'b1;
              r_sgn_en  = 'b1;

              // count leading zero bits in dividend
              cnt_clzb  = clzb;
              count_en  = 'b1;
              count_d   = count_shift;            

              // initialize quotient and remainder
              quotient_en = 'b1;   
              quotient_d  = dividend_d<<cnt_clzb;

              remainder_en = 'b1;
              remainder_d  = 'b0;
            end
          end
        end
      end
      DIV_WORKING: begin
        if(div_valid) begin
          // processing
          f_div_step (remainder_q ,quotient_q ,divisor_q,remainder_r1,quotient_r1);
          f_div_step (remainder_r1,quotient_r1,divisor_q,remainder_r2,quotient_r2);
          f_div_step (remainder_r2,quotient_r2,divisor_q,remainder_r3,quotient_r3);
          
          count_r1 = count_q - 'd1;
          count_r2 = count_q - 'd2;
          count_r3 = count_q - 'd3;
          
          quotient_en = 'b1;   
          remainder_en = 'b1;
          count_en = 'b1;

          case({{($clog2(DIV_WIDTH)-1){1'b0}},1'b1})
            count_r1: begin
              quotient_d  = quotient_r1;
              remainder_d = remainder_r1;
              count_d     = 'b1; 
            end
            count_r2: begin
              quotient_d  = quotient_r2;
              remainder_d = remainder_r2;
              count_d     = 'b1;            
            end
            default: begin
              quotient_d  = quotient_r3;
              remainder_d = remainder_r3;
              count_d     = count_r3;            
            end
          endcase
        end  
      end
      // get result to ouput and wait for ready signal
      DIV_PRINT: begin
        result_valid = 'b1;
        
        result_quotient  = q_sgn_q ? ((~quotient_q )+'d1) : quotient_q;
        result_remainder = r_sgn_q ? ((~remainder_q)+'d1) : remainder_q;
    
        count_en = result_ready;
        count_d  = 'b0;
      end
    endcase
  end

//
// function unit
//
  // div step: shift and subtract
  function void f_div_step
  (
    input  logic [DIV_WIDTH-1:0] remainder_in,
    input  logic [DIV_WIDTH-1:0] quotient_in,
    input  logic [DIV_WIDTH-1:0] divisor_in,
    output logic [DIV_WIDTH-1:0] remainder_out,
    output logic [DIV_WIDTH-1:0] quotient_out
  );

    logic [DIV_WIDTH-1:0] remainder_tmp;
    logic [DIV_WIDTH  :0] diff;
    
    remainder_tmp = {remainder_in[DIV_WIDTH-2:0],quotient_in[DIV_WIDTH-1]};
    diff = {1'b0,remainder_tmp} - {1'b0,divisor_in};

    if (diff[DIV_WIDTH]) begin
      remainder_out = remainder_tmp;
      quotient_out  = {quotient_in[DIV_WIDTH-2:0],1'b0};
    end
    else begin
      remainder_out = diff[DIV_WIDTH-1:0];
      quotient_out  = {quotient_in[DIV_WIDTH-2:0],1'b1};
    end
  endfunction

endmodule
