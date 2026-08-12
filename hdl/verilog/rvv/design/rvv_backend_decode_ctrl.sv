//
// description:
// 1. control to pop data from Command Queue and push data into Uop Queue. 
//
// features:
// 1. decode_ctrl will push data to Uops Queue only when Uops Queue has 4 free spaces at least.

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_decode_ctrl
(
  clk,
  rst_n,
  de_uop_valid,
  de_uop,   
  uop_index_remain,
  pop,
  push,
  uop,
  uq_ready,
  trap_flush_rvv
);
//
// interface signals
//
  // global signals
  input   logic                                           clk;
  input   logic                                           rst_n;
  // decoded uops
  input   logic       [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] de_uop_valid;
  input   UOP_QUEUE_t [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] de_uop;
  // uop_index for decode_unit
  output  logic       [`UOP_INDEX_WIDTH-1:0]              uop_index_remain;
  // pop signals for command queue
  output  logic       [`NUM_DE_INST-1:0]                  pop;
  // signals from Uops Quue
  output  logic       [`NUM_DE_UOP-1:0]                   push;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0]                   uop;
  input   logic       [`NUM_DE_UOP-1:0]                   uq_ready;
  // trap-flush
  input   logic                                           trap_flush_rvv; 

//
// internal signals
//
  // last uop signal for pop
  logic [`NUM_DE_UOP-1:0]                                 last_uop;
  // signals in uop_index DFF 
  logic                                                   uop_index_en;
  logic [`UOP_INDEX_WIDTH-1:0]                            uop_index_din;
  
  // for-loop
  integer                                                 i;
  genvar                                                  j;

  `ifdef ASSERT_ON
    `rvv_expect(`NUM_DE_INST<=`NUM_DE_UOP)
    else $error("`NUM_DE_INST=%d is greater than `NUM_DE_UOP=%d.", `NUM_DE_INST, `NUM_DE_UOP);
  `endif

  generate
    // push data into Uops Queue
    assign push[0] = de_uop_valid[0][0]&uq_ready[0];
    assign uop[0]  = de_uop[0][0];

    if (`NUM_DE_INST>=3'd2) begin : gen_push1_uop1
      if(`NUM_DE_UOP>=3'd2) begin
        assign push[1] = (de_uop_valid[0][1]|de_uop_valid[1][0]) ? uq_ready[1] : 'b0;
        assign uop[1]  =  de_uop_valid[0][1] ? de_uop[0][1] : de_uop[1][0];
      end
    end

    if (`NUM_DE_INST==3'd2) begin : if_inst_eq_2 // `NUM_DE_INST==2
      if(`NUM_DE_UOP>=3'd3) begin : gen_push2_uop2
        always_comb begin
          casez({de_uop_valid[1][1:0],de_uop_valid[0][2:1]})
            4'b??_11: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[0][2];
            end
            4'b?1_01: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][0];
            end
            4'b11_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][1];
            end
            default: begin 
              push[2] = 'b0;
              uop[2]  = de_uop[0][2];
            end
          endcase
        end
      end // NUM_DE_UOP==3
    
      if(`NUM_DE_UOP>=3'd4) begin : gen_push3_uop3
        always_comb begin
          casez({de_uop_valid[1][2:0],de_uop_valid[0][3:1]})
            6'b???_111: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[0][3];
            end
            6'b??1_011: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][0];
            end
            6'b?11_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][1];
            end
            6'b111_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][2];
            end
            default: begin 
              push[3] = 'b0;
              uop[3]  = de_uop[0][3];
            end
          endcase
        end
      end // NUM_DE_UOP==4

      if(`NUM_DE_UOP>=3'd5) begin : gen_push4_uop4
        always_comb begin
          casez({de_uop_valid[1][3:0],de_uop_valid[0][4:1]})
            8'b????_1111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[0][4];
            end
            8'b???1_0111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][0];
            end
            8'b??11_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][1];
            end
            8'b?111_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][2];
            end
            8'b1111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][3];
            end
            default: begin 
              push[4] = 'b0;
              uop[4]  = de_uop[0][4];
            end
          endcase
        end
      end // NUM_DE_UOP==5

      if(`NUM_DE_UOP>=3'd6) begin : gen_push5_uop5
        always_comb begin
          casez({de_uop_valid[1][4:0],de_uop_valid[0][5:1]})
            10'b?????_11111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[0][5];
            end
            10'b????1_01111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][0];
            end
            10'b???11_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][1];
            end
            10'b??111_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][2];
            end
            10'b?1111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][3];
            end
            10'b11111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][4];
            end
            default: begin 
              push[5] = 'b0;
              uop[5]  = de_uop[0][5];
            end
          endcase
        end
      end // NUM_DE_UOP==6
    end // NUM_DE_INST==2

    if (`NUM_DE_INST==3'd3) begin : if_inst_eq_3
      if(`NUM_DE_UOP>=3'd3) begin : gen_push2_uop2
        always_comb begin
          casez({de_uop_valid[2][0],de_uop_valid[1][1:0],de_uop_valid[0][2:1]})
            5'b?_??_11: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[0][2];
            end
            5'b?_?1_01: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][0];
            end
            5'b?_11_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][1];
            end
            5'b1_01_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[2][0];
            end
            default: begin 
              push[2] = 'b0;
              uop[2]  = de_uop[0][2];
            end
          endcase
        end
      end // NUM_DE_UOP==3
    
      if(`NUM_DE_UOP>=3'd4) begin : gen_push3_uop3
        always_comb begin
          casez({de_uop_valid[2][1:0],de_uop_valid[1][2:0],de_uop_valid[0][3:1]})
            8'b??_???_111: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[0][3];
            end
            8'b??_??1_011: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][0];
            end
            8'b??_?11_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][1];
            end
            8'b?1_?01_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            8'b??_111_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][2];
            end
            8'b?1_011_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            8'b11_?01_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][1];
            end
            default: begin 
              push[3] = 'b0;
              uop[3]  = de_uop[0][3];
            end
          endcase
        end
      end // NUM_DE_UOP==4

      if(`NUM_DE_UOP>=3'd5) begin : gen_push4_uop4
        always_comb begin
          casez({de_uop_valid[2][2:0],de_uop_valid[1][3:0],de_uop_valid[0][4:1]})
            11'b???_????_1111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[0][4];
            end
            11'b???_???1_0111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][0];
            end
            11'b???_??11_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][1];
            end
            11'b??1_??01_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            11'b???_?111_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][2];
            end
            11'b??1_?011_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            11'b?11_??01_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            11'b???_1111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][3];
            end
            11'b??1_0111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            11'b?11_?011_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            11'b111_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][2];
            end
            default: begin 
              push[4] = 'b0;
              uop[4]  = de_uop[0][4];
            end
          endcase
        end
      end // NUM_DE_UOP==5

      if(`NUM_DE_UOP>=3'd6) begin : gen_push5_uop5
        always_comb begin
          casez({de_uop_valid[2][3:0],de_uop_valid[1][4:0],de_uop_valid[0][5:1]})
            14'b????_?????_11111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[0][5];
            end
            14'b????_????1_01111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][0];
            end
            14'b????_???11_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][1];
            end
            14'b???1_???01_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b????_??111_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][2];
            end
            14'b???1_??011_??011: begin            
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b??11_???01_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            14'b????_?1111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][3];
            end
            14'b???1_?0111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b??11_??011_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            14'b?111_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            14'b????_11111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][4];
            end
            14'b???1_01111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            14'b??11_?0111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            14'b?111_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            14'b1111_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][3];
            end
            default: begin 
              push[5] = 'b0;
              uop[5]  = de_uop[0][5];
            end
          endcase
        end
      end // NUM_DE_UOP==6 
    end // NUM_DE_INST==3

    if (`NUM_DE_INST==3'd4) begin : if_inst_eq_4
      if(`NUM_DE_UOP>=3'd3) begin : gen_push2_uop2
        always_comb begin
          casez({de_uop_valid[2][0],de_uop_valid[1][1:0],de_uop_valid[0][2:1]})
            5'b?_??_11: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[0][2];
            end
            5'b?_?1_01: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][0];
            end
            5'b?_11_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[1][1];
            end
            5'b1_01_?0: begin
              push[2] = uq_ready[2];
              uop[2]  = de_uop[2][0];
            end
            default: begin 
              push[2] = 'b0;
              uop[2]  = de_uop[0][2];
            end
          endcase
        end
      end // NUM_DE_UOP==3
    
      if(`NUM_DE_UOP>=3'd4) begin : gen_push3_uop3
        always_comb begin
          casez({de_uop_valid[3][0],de_uop_valid[2][1:0],de_uop_valid[1][2:0],de_uop_valid[0][3:1]})
            9'b?_??_???_111: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[0][3];
            end
            9'b?_??_??1_011: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][0];
            end
            9'b?_??_?11_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][1];
            end
            9'b?_?1_?01_?01: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            9'b?_??_111_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[1][2];
            end
            9'b?_?1_011_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][0];
            end
            9'b?_11_?01_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[2][1];
            end
            9'b1_01_?01_??0: begin
              push[3] = uq_ready[3];
              uop[3]  = de_uop[3][0];
            end
            default: begin 
              push[3] = 'b0;
              uop[3]  = de_uop[0][3];
            end
          endcase
        end
      end // NUM_DE_UOP==4

      if(`NUM_DE_UOP>=3'd5) begin : gen_push4_uop4
        always_comb begin
          casez({de_uop_valid[3][1:0],de_uop_valid[2][2:0],de_uop_valid[1][3:0],de_uop_valid[0][4:1]})
            13'b??_???_????_1111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[0][4];
            end
            13'b??_???_???1_0111: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][0];
            end
            13'b??_???_??11_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][1];
            end
            13'b??_??1_??01_?011: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            13'b??_???_?111_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][2];
            end
            13'b??_??1_?011_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            13'b??_?11_??01_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            13'b?1_?01_??01_??01: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][0];
            end
            13'b??_???_1111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[1][3];
            end
            13'b??_??1_0111_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][0];
            end
            13'b??_?11_?011_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][1];
            end
            13'b?1_?01_?011_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][0];
            end
            13'b??_111_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[2][2];
            end
            13'b?1_011_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][0];
            end
            13'b11_?01_??01_???0: begin
              push[4] = uq_ready[4];
              uop[4]  = de_uop[3][1];
            end
            default: begin 
              push[4] = 'b0;
              uop[4]  = de_uop[0][4];
            end
          endcase
        end
      end // NUM_DE_UOP==5

      if(`NUM_DE_UOP>=3'd6) begin : gen_push5_uop5
        always_comb begin
          casez({de_uop_valid[3][2:0],de_uop_valid[2][3:0],de_uop_valid[1][4:0],de_uop_valid[0][5:1]})
            17'b???_????_?????_11111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[0][5];
            end
            17'b???_????_????1_01111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][0];
            end
            17'b???_????_???11_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][1];
            end
            17'b???_???1_???01_?0111: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_????_??111_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][2];
            end
            17'b???_???1_??011_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_??11_???01_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            17'b??1_??01_???01_??011: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b???_????_?1111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][3];
            end
            17'b???_???1_?0111_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_??11_??011_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            17'b??1_??01_??011_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b???_?111_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            17'b??1_?011_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b?11_??01_???01_???01: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][1];
            end
            17'b???_????_11111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[1][4];
            end
            17'b???_???1_01111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][0];
            end
            17'b???_??11_?0111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][1];
            end
            17'b??1_??01_?0111_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b???_?111_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][2];
            end
            17'b??1_?011_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b?11_??01_??011_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][1];
            end
            17'b???_1111_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[2][3];
            end
            17'b??1_0111_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][0];
            end
            17'b?11_?011_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][1];
            end
            17'b111_??01_???01_????0: begin
              push[5] = uq_ready[5];
              uop[5]  = de_uop[3][2];
            end
            default: begin 
              push[5] = 'b0;
              uop[5]  = de_uop[0][5];
            end
          endcase
        end
      end // NUM_DE_UOP==6 
    end // NUM_DE_INST==3
      
    // calculate pop siganl for LCQ
    for(j=0;j<`NUM_DE_UOP;j++) begin : gen_last_uop
      assign last_uop[j] = push[j]&uop[j].last_uop_valid;
    end
  endgenerate

  always_comb begin
    pop = 'b0;
    i   = 0;

    for(int k=0;k<`NUM_DE_UOP;k++) begin
      if (i < `NUM_DE_INST) begin
        if (last_uop[k]) begin
          pop[i] = 1'b1;
          i      = i + 1;
        end
      end
    end
  end
  
  // uop index remain
  always_comb begin
    uop_index_din = 'b0;

    for(int k=0;k<`NUM_DE_UOP;k++) begin
      if(push[k])
        uop_index_din = uop[k].last_uop_valid ? 'b0 : uop[k].uop_index + (`UOP_INDEX_WIDTH)'('d1);
    end
  end

  assign uop_index_en = |push;

  cdffr 
  #(
    .T         (logic[`UOP_INDEX_WIDTH-1:0])
  )
  uop_index_cdffr
  ( 
    .clk       (clk), 
    .rst_n     (rst_n), 
    .c         (trap_flush_rvv), 
    .e         (uop_index_en), 
    .d         (uop_index_din),
    .q         (uop_index_remain)
  ); 

endmodule
