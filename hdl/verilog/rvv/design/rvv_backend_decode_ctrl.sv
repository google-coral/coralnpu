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
  pkg_valid,
  uop_valid_de2uq,
  uop_de2uq,
  uop_index_remain,
  pop,
  push,
  dataout,
  fifo_full_uq2de, 
  fifo_almost_full_uq2de,
  trap_flush_rvv
);
//
// interface signals
//
  // global signals
  input   logic                                           clk;
  input   logic                                           rst_n;

  // decoded uops
  input   logic       [`NUM_DE_INST-1:0]                  pkg_valid;
  input   logic       [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] uop_valid_de2uq;
  input   UOP_QUEUE_t [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] uop_de2uq;
  
  // uop_index for decode_unit
  output  logic       [`UOP_INDEX_WIDTH-1:0]              uop_index_remain;
  
  // pop signals for command queue
  output  logic       [`NUM_DE_INST-1:0]                  pop;

  // signals from Uops Quue
  output  logic       [`NUM_DE_UOP-1:0]                   push;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0]                   dataout;
  input   logic                                           fifo_full_uq2de;
  input   logic       [`NUM_DE_UOP-1:0]                   fifo_almost_full_uq2de;

  // trap-flush
  input   logic                                           trap_flush_rvv;

//
// internal signals
//
  // get last uop signal 
  logic [`NUM_DE_UOP-1:0]         uop1_last_valid;
  logic [`NUM_DE_INST-1:0]        last_uop_unit;
  logic [`NUM_DE_UOP-1:0]         get_unit1_last_signal;

  // compress uop_valid
  logic [`NUM_DE_UOP-1:0]         compress_valid;

  // fifo is ready when it has `NUM_DE_UOP free spaces at least
  logic                           fifo_ready;
  
  // signals in uop_index DFF 
  logic                           uop_index_clear;   
  logic                           uop_index_enable_unit0;
  logic                           uop_index_enable_unit1;
  logic                           uop_index_enable;
  logic [`UOP_INDEX_WIDTH-1:0]    uop_index_din;
  
  // used in getting push0-3
  logic [`NUM_DE_UOP-1:0]         push_valid;
  
  // for-loop
  genvar                          i;

//
// ctroller
//
  generate
    // get unit1 last uop signal
    for (i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP1_LAST
      assign uop1_last_valid[i] = uop_de2uq[1][i].last_uop_valid;
    end

    for (i=0;i<`NUM_DE_UOP;i++) begin: GET_UNIT1_LAST
      assign get_unit1_last_signal[i] = |uop1_last_valid[(`NUM_DE_UOP-1-i):0];
    end

    if(`NUM_DE_UOP==6) begin
      // get unit0 last uop signal
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0001,
          6'b00_0011,
          6'b00_0111,
          6'b00_1111,
          6'b01_1111: last_uop_unit[0] = 'b1;
          6'b11_1111: last_uop_unit[0] = uop_de2uq[0][`NUM_DE_UOP-1].last_uop_valid;
          default   : last_uop_unit[0] = 'b0;
        endcase
      end
    
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0000: last_uop_unit[1] = get_unit1_last_signal[0];
          6'b00_0001: last_uop_unit[1] = get_unit1_last_signal[1];
          6'b00_0011: last_uop_unit[1] = get_unit1_last_signal[2];
          6'b00_0111: last_uop_unit[1] = get_unit1_last_signal[3];
          6'b00_1111: last_uop_unit[1] = get_unit1_last_signal[4];
          6'b01_1111: last_uop_unit[1] = get_unit1_last_signal[5]; 
          default   : last_uop_unit[1] = 'b0;
        endcase
      end

      // compress uop_valid
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0001: compress_valid = {uop_valid_de2uq[1][4:0],1'b1}; 
          6'b00_0011: compress_valid = {uop_valid_de2uq[1][3:0],2'b11}; 
          6'b00_0111: compress_valid = {uop_valid_de2uq[1][2:0],3'b111}; 
          6'b00_1111: compress_valid = {uop_valid_de2uq[1][1:0],4'b1111}; 
          6'b01_1111: compress_valid = {uop_valid_de2uq[1][0]  ,5'b1_1111}; 
          6'b11_1111: compress_valid = 6'b11_1111; 
          default   : compress_valid = 'b0; 
        endcase
      end

    end
    else begin //if(`NUM_DE_UOP==4)
      // get unit0 last uop signal
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          4'b0001,
          4'b0011,
          4'b0111: last_uop_unit[0] = 'b1;
          4'b1111: last_uop_unit[0] = uop_de2uq[0][`NUM_DE_UOP-1].last_uop_valid;
          default: last_uop_unit[0] = 'b0;
        endcase
      end
    
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          4'b0000: last_uop_unit[1] = get_unit1_last_signal[0];
          4'b0001: last_uop_unit[1] = get_unit1_last_signal[1];
          4'b0011: last_uop_unit[1] = get_unit1_last_signal[2];
          4'b0111: last_uop_unit[1] = get_unit1_last_signal[3];
          default: last_uop_unit[1] = 'b0;
        endcase
      end

      // compress uop_valid
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          4'b0001: compress_valid = {uop_valid_de2uq[1][2:0],1'b1}; 
          4'b0011: compress_valid = {uop_valid_de2uq[1][1:0],2'b11}; 
          4'b0111: compress_valid = {uop_valid_de2uq[1][0]  ,3'b111}; 
          4'b1111: compress_valid = 4'b1111; 
          default: compress_valid = 'b0; 
        endcase
      end

    end
  endgenerate

  // get fifo_ready
  assign fifo_ready = (compress_valid=='b0) ? 'b0 : ((compress_valid&fifo_almost_full_uq2de)=='b0);
      
  // get pop signal to Command Queue
  assign pop[0] =          pkg_valid[0]&((last_uop_unit[0]&fifo_ready) || (uop_valid_de2uq[0][`NUM_DE_UOP-1:0]=='b0));
  assign pop[1] = pop[0] ? pkg_valid[1]&((last_uop_unit[1]&fifo_ready) || (uop_valid_de2uq[1][`NUM_DE_UOP-1:0]=='b0)) : 'b0;
  
  // instantiate cdffr for uop_index
  // clear signal
  assign uop_index_clear = (pop[0]&(!pkg_valid[1])) | pop[1];
  
  // enable signal
  assign uop_index_enable_unit0 =          pkg_valid[0]&(uop_valid_de2uq[0][`NUM_DE_UOP-1:0]!='b0)&(last_uop_unit[0]=='b0)&fifo_ready;
  assign uop_index_enable_unit1 = pop[0] ? pkg_valid[1]&(uop_valid_de2uq[1][`NUM_DE_UOP-1:0]!='b0)&(last_uop_unit[1]=='b0)&fifo_ready : 'b0;
  assign uop_index_enable       = uop_index_enable_unit0 | uop_index_enable_unit1;  
  
  // uop index remain
  cdffr 
  #(
    .T         (logic[`UOP_INDEX_WIDTH-1:0])
  )
  uop_index_cdffr
  (
    .clk       (clk), 
    .rst_n     (rst_n), 
    .c         (uop_index_clear|trap_flush_rvv),
    .e         (uop_index_enable), 
    .d         (uop_index_din),
    .q         (uop_index_remain)
  ); 

  generate
    if(`NUM_DE_UOP==6) begin
      // datain signal
      always_comb begin
        // initial
        uop_index_din = uop_index_remain;    
        
        case(1'b1)
          uop_index_enable_unit0: 
            uop_index_din = uop_de2uq[0][`NUM_DE_UOP-1].uop_index + 1'b1;    
          uop_index_enable_unit1: begin
            case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
              6'b00_0000: uop_index_din = uop_de2uq[1][5].uop_index + 1'b1; 
              6'b00_0001: uop_index_din = uop_de2uq[1][4].uop_index + 1'b1; 
              6'b00_0011: uop_index_din = uop_de2uq[1][3].uop_index + 1'b1; 
              6'b00_0111: uop_index_din = uop_de2uq[1][2].uop_index + 1'b1; 
              6'b00_1111: uop_index_din = uop_de2uq[1][1].uop_index + 1'b1; 
              6'b01_1111: uop_index_din = uop_de2uq[1][0].uop_index + 1'b1; 
              6'b11_1111: uop_index_din = 'b0; 
            endcase
          end
        endcase
      end
    
      // push signal and push data into Uops Queue
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0000: begin
            push_valid[0] = uop_valid_de2uq[1][0];
            dataout[0]    = uop_de2uq[1][0];
          end
          6'b00_0001, 
          6'b00_0011, 
          6'b00_0111, 
          6'b00_1111, 
          6'b01_1111, 
          6'b11_1111: begin 
            push_valid[0] = uop_valid_de2uq[0][0];
            dataout[0]    = uop_de2uq[0][0];
          end
          default: begin 
            push_valid[0] = 'b0;
            dataout[0]    = 'b0;
          end
        endcase
      end

      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0000: begin
            push_valid[1] = uop_valid_de2uq[1][1];
            dataout[1]    = uop_de2uq[1][1];
          end
          6'b00_0001: begin
            push_valid[1] = uop_valid_de2uq[1][0];
            dataout[1]    = uop_de2uq[1][0];
          end
          6'b00_0011, 
          6'b00_0111, 
          6'b00_1111, 
          6'b01_1111, 
          6'b11_1111: begin 
            push_valid[1] = uop_valid_de2uq[0][1];
            dataout[1]    = uop_de2uq[0][1];
          end
          default: begin 
            push_valid[1] = 'b0;
            dataout[1]    = 'b0;
          end
        endcase
      end

      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0000: begin
            push_valid[2] = uop_valid_de2uq[1][2];
            dataout[2]    = uop_de2uq[1][2];
          end
          6'b00_0001: begin
            push_valid[2] = uop_valid_de2uq[1][1];
            dataout[2]    = uop_de2uq[1][1];
          end
          6'b00_0011: begin 
            push_valid[2] = uop_valid_de2uq[1][0];
            dataout[2]    = uop_de2uq[1][0];
          end
          6'b00_0111, 
          6'b00_1111, 
          6'b01_1111, 
          6'b11_1111: begin 
            push_valid[2] = uop_valid_de2uq[0][2];
            dataout[2]    = uop_de2uq[0][2];
          end
          default: begin 
            push_valid[2] = 'b0;
            dataout[2]    = 'b0;
          end
        endcase
      end
    
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0000: begin
            push_valid[3] = uop_valid_de2uq[1][3];
            dataout[3]    = uop_de2uq[1][3];
          end
          6'b00_0001: begin
            push_valid[3] = uop_valid_de2uq[1][2];
            dataout[3]    = uop_de2uq[1][2];
          end
          6'b00_0011: begin 
            push_valid[3] = uop_valid_de2uq[1][1];
            dataout[3]    = uop_de2uq[1][1];
          end
          6'b00_0111: begin
            push_valid[3] = uop_valid_de2uq[1][0];
            dataout[3]    = uop_de2uq[1][0];
          end
          6'b00_1111, 
          6'b01_1111, 
          6'b11_1111: begin 
            push_valid[3] = uop_valid_de2uq[0][3];
            dataout[3]    = uop_de2uq[0][3];
          end
          default: begin 
            push_valid[3] = 'b0;
            dataout[3]    = 'b0;
          end
        endcase
      end
    
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0000: begin
            push_valid[4] = uop_valid_de2uq[1][4];
            dataout[4]    = uop_de2uq[1][4];
          end
          6'b00_0001: begin
            push_valid[4] = uop_valid_de2uq[1][3];
            dataout[4]    = uop_de2uq[1][3];
          end
          6'b00_0011: begin 
            push_valid[4] = uop_valid_de2uq[1][2];
            dataout[4]    = uop_de2uq[1][2];
          end
          6'b00_0111: begin
            push_valid[4] = uop_valid_de2uq[1][1];
            dataout[4]    = uop_de2uq[1][1];
          end
          6'b00_1111: begin 
            push_valid[4] = uop_valid_de2uq[1][0];
            dataout[4]    = uop_de2uq[1][0];
          end
          6'b01_1111, 
          6'b11_1111: begin 
            push_valid[4] = uop_valid_de2uq[0][4];
            dataout[4]    = uop_de2uq[0][4];
          end
          default: begin 
            push_valid[4] = 'b0;
            dataout[4]    = 'b0;
          end
        endcase
      end

      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          6'b00_0000: begin
            push_valid[5] = uop_valid_de2uq[1][5];
            dataout[5]    = uop_de2uq[1][5];
          end
          6'b00_0001: begin
            push_valid[5] = uop_valid_de2uq[1][4];
            dataout[5]    = uop_de2uq[1][4];
          end
          6'b00_0011: begin 
            push_valid[5] = uop_valid_de2uq[1][3];
            dataout[5]    = uop_de2uq[1][3];
          end
          6'b00_0111: begin
            push_valid[5] = uop_valid_de2uq[1][2];
            dataout[5]    = uop_de2uq[1][2];
          end
          6'b00_1111: begin 
            push_valid[5] = uop_valid_de2uq[1][1];
            dataout[5]    = uop_de2uq[1][1];
          end
          6'b01_1111: begin
            push_valid[5] = uop_valid_de2uq[1][0];
            dataout[5]    = uop_de2uq[1][0];
          end
          6'b11_1111: begin 
            push_valid[5] = uop_valid_de2uq[0][5];
            dataout[5]    = uop_de2uq[0][5];
          end
          default: begin 
            push_valid[5] = 'b0;
            dataout[5]    = 'b0;
          end
        endcase
      end

    end //`NUM_DE_UOP==6
    else begin //if(`NUM_DE_UOP==4)
      // datain signal
      always_comb begin
        // initial
        uop_index_din = uop_index_remain;    
        
        case(1'b1)
          uop_index_enable_unit0: 
            uop_index_din = uop_de2uq[0][`NUM_DE_UOP-1].uop_index + 1'b1;    
          uop_index_enable_unit1: begin
            case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
              4'b0000: uop_index_din = uop_de2uq[1][3].uop_index + 1'b1; 
              4'b0001: uop_index_din = uop_de2uq[1][2].uop_index + 1'b1; 
              4'b0011: uop_index_din = uop_de2uq[1][1].uop_index + 1'b1; 
              4'b0111: uop_index_din = uop_de2uq[1][0].uop_index + 1'b1; 
              4'b1111: uop_index_din = 'b0; 
            endcase
          end
        endcase
      end
      
      // push signal and push data into Uops Queue
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          4'b0000: begin
            push_valid[0] = uop_valid_de2uq[1][0];
            dataout[0]    = uop_de2uq[1][0];
          end
          4'b0001,
          4'b0011,
          4'b0111,
          4'b1111: begin
            push_valid[0] = uop_valid_de2uq[0][0];
            dataout[0]    = uop_de2uq[0][0];
          end
          default: begin
            push_valid[0] = 'b0;
            dataout[0]    = 'b0;
          end
        endcase
      end

      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          4'b0000: begin
            push_valid[1] = uop_valid_de2uq[1][1];
            dataout[1]    = uop_de2uq[1][1];
          end
          4'b0001: begin
            push_valid[1] = uop_valid_de2uq[1][0];
            dataout[1]    = uop_de2uq[1][0];
          end
          4'b0011,
          4'b0111,
          4'b1111: begin
            push_valid[1] = uop_valid_de2uq[0][1];
            dataout[1]    = uop_de2uq[0][1];
          end
          default: begin
            push_valid[1] = 'b0;
            dataout[1]    = 'b0;
          end
        endcase
      end
      
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          4'b0000: begin
            push_valid[2] = uop_valid_de2uq[1][2];
            dataout[2]    = uop_de2uq[1][2];
          end
          4'b0001: begin
            push_valid[2] = uop_valid_de2uq[1][1];
            dataout[2]    = uop_de2uq[1][1];
          end
          4'b0011: begin
            push_valid[2] = uop_valid_de2uq[1][0];
            dataout[2]    = uop_de2uq[1][0];
          end
          4'b0111,
          4'b1111: begin
            push_valid[2] = uop_valid_de2uq[0][2];
            dataout[2]    = uop_de2uq[0][2];
          end
          default: begin
            push_valid[2] = 'b0;
            dataout[2]    = 'b0;
          end
        endcase
      end
    
      always_comb begin
        case(uop_valid_de2uq[0][`NUM_DE_UOP-1:0])
          4'b0000: begin
            push_valid[3] = uop_valid_de2uq[1][3];
            dataout[3]    = uop_de2uq[1][3];
          end
          4'b0001: begin
            push_valid[3] = uop_valid_de2uq[1][2];
            dataout[3]    = uop_de2uq[1][2];
          end
          4'b0011: begin
            push_valid[3] = uop_valid_de2uq[1][1];
            dataout[3]    = uop_de2uq[1][1];
          end
          4'b0111: begin
            push_valid[3] = uop_valid_de2uq[1][0];
            dataout[3]    = uop_de2uq[1][0];
          end
          4'b1111: begin
            push_valid[3] = uop_valid_de2uq[0][3];
            dataout[3]    = uop_de2uq[0][3];
          end
          default: begin
            push_valid[3] = 'b0;
            dataout[3]    = 'b0;
          end
        endcase
      end
    
    end //`NUM_DE_UOP==4
  endgenerate

  generate 
    for (i=0;i<`NUM_DE_UOP;i++) begin: GET_PUSH
      assign push[i] = push_valid[i]&fifo_ready;
    end
  endgenerate

endmodule
