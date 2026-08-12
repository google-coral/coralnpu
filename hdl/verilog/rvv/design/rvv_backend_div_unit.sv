
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef DIV_DEFINE_SVH
`include "rvv_backend_div.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_div_unit
(
  clk,
  rst_n,
  div_uop_valid,
  div_uop,
  div_uop_ready,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);
//
// interface signals
//
  // global signals
  input   logic     clk;
  input   logic     rst_n;

  // DIV RS handshake signals
  input   logic     div_uop_valid;
  input   DIV_RS_t  div_uop;
  output  logic     div_uop_ready;

  // DIV send result signals to ROB
  output  logic     result_valid;
  output  PU2ROB_t  result;
  input   logic     result_ready;

  // trap-flush
  input   logic     trap_flush_rvv;                

//
// internal signals
//
  // DIV_RS_t struct signals
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  FUNCT6_u                        uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3;
  logic   [`VLEN-1:0]             vs1_data;           
  logic   [`VLEN-1:0]             vs2_data;	        
  EEW_e                           vs2_eew;
  logic   [`XLEN-1:0] 	          rs1_data;        

  // execute 
  logic                                     uop_valid;
  logic                                     uop_valid_e;
  logic                                     uop_valid_d1;
  logic   [`VLENB/2-1:0]                    div_ready8;
  logic   [`VLENH/2-1:0]                    div_ready16;
  logic   [`VLENW-1:0]                      div_ready32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   src2_data8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  src2_data16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     src2_data32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   src1_data8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  src1_data16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     src1_data32;
  DIV_RES_t                                 res_info;
  DIV_RES_t                                 res_info_d1;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   quotient8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  quotient16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     quotient32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]   remainder8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]  remainder16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]     remainder32;
  logic   [`VLENB/2-1:0]                    result_valid8;
  logic   [`VLENH/2-1:0]                    result_valid16;
  logic   [`VLENW-1:0]                      result_valid32;
  logic   [`VLEN-1:0]                       result_data; 
  logic                                     result_all_valid; 

  // opcode
  logic                                     opcode;
  localparam                                DIV_SIGN=0;
  localparam                                DIV_ZERO=1;

  // for-loop
  genvar                                                j;

//
// prepare source data to calculate    
//
  // split ALU_RS_t struct
  assign  rob_entry   = div_uop.rob_entry;
  assign  uop_funct6  = div_uop.uop_funct6;
  assign  uop_funct3  = div_uop.uop_funct3;
  assign  vs1_data    = div_uop.vs1_data;
  assign  rs1_data    = div_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data    = div_uop.vs2_data;
  assign  vs2_eew     = div_uop.vs2_eew;
  
//  
// prepare source data 
//
  // prepare valid signal
  assign uop_valid = div_uop_valid&div_uop_ready;
 
  // prepare source data
  always_comb begin
    // initial the data
    src2_data8   = 'b0;
    src2_data16  = 'b0;
    src2_data32  = 'b0;
    src1_data8   = 'b0;
    src1_data16  = 'b0;
    src1_data32  = 'b0;

    case(uop_funct3) 
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VDIVU,
          VREMU: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {8'b0,vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {24'b0,vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = vs1_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                end             
              end
            endcase
          end

          VDIV,
          VREM: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {{8{vs1_data[(i+1)*`BYTE_WIDTH-1]}},vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {{24{vs1_data[(i+1)*`BYTE_WIDTH-1]}},vs1_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{vs1_data[(i+1)*`HWORD_WIDTH-1]}},vs1_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = vs1_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                end             
              end
            endcase
          end
        endcase
      end
      OPMVX: begin
        case(uop_funct6.ari_funct6)
          VDIVU,
          VREMU: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = rs1_data[0             +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {8'b0,rs1_data[0             +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {24'b0,rs1_data[0             +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = rs1_data[0              +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {16'b0,rs1_data[0              +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = rs1_data[0             +: `WORD_WIDTH];
                end             
              end
            endcase
          end

          VDIV,
          VREM: begin
            case(vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  src2_data8[i] = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  src1_data8[i] = rs1_data[0             +: `BYTE_WIDTH];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  src2_data16[i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data16[i-`VLENB/2] = {{8{rs1_data[      `BYTE_WIDTH-1]}},rs1_data[0             +: `BYTE_WIDTH]};
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  src2_data32[i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  src1_data32[i-`VLENB*3/4] = {{24{rs1_data[      `BYTE_WIDTH-1]}},rs1_data[0             +: `BYTE_WIDTH]};
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  src1_data16[i] = rs1_data[0              +: `HWORD_WIDTH];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  src2_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  src1_data32[i-`VLEN/`HWORD_WIDTH/2] = {{16{rs1_data[      `HWORD_WIDTH-1]}},rs1_data[0              +: `HWORD_WIDTH]};
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  src1_data32[i] = rs1_data[0             +: `WORD_WIDTH];
                end             
              end
            endcase
          end
        endcase
      end
    endcase
  end

  // get opcode for divider
  always_comb begin
    // initial the data
    opcode = DIV_SIGN;

    // prepare source data
    case(uop_funct3) 
      OPMVV,
      OPMVX: begin
        case(uop_funct6.ari_funct6)    
          VDIV,
          VREM: begin
            opcode = DIV_SIGN;
          end
          VDIVU,
          VREMU: begin
            opcode = DIV_ZERO;
          end
        endcase
      end
    endcase
  end

//    
// calculate the result
//
  // register valid
  assign uop_valid_e = uop_valid || result_valid&result_ready;

  cdffr 
  div_vld
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (uop_valid_e),
    .c      (trap_flush_rvv),
    .d      (uop_valid),
    .q      (uop_valid_d1)
  );

  // register information 
`ifdef TB_SUPPORT
  assign res_info.uop_pc      = div_uop.uop_pc;
`endif
  assign res_info.uop_funct6  = uop_funct6;
  assign res_info.uop_funct3  = uop_funct3;
  assign res_info.rob_entry   = rob_entry;
  assign res_info.vs2_eew     = vs2_eew;

  edff #(
    .T      (DIV_RES_t),
    .INIT   (($bits(DIV_RES_t))'({'0,EEW_NONE}))
  ) res_information
  (
    .clk    (clk),
    .rst_n  (rst_n),
    .e      (uop_valid),
    .d      (res_info),
    .q      (res_info_d1)
  );

  generate
    for(j=0;j<`VLENB/2;j++) begin: DIVIDER8
      intdivider
      #(
        .DIV_WIDTH          (8'd`BYTE_WIDTH)
      )
      divider_8bit
      (
        .clk                (clk),
        .rst_n              (rst_n),
        .div_valid          (uop_valid&(vs2_eew==EEW8) || uop_valid_d1&(res_info_d1.vs2_eew==EEW8)),
        .div_ready          (div_ready8[j]),
        .opcode             (opcode), 
        .src2_dividend      (src2_data8[j]),
        .src1_divisor       (src1_data8[j]),
        .result_quotient    (quotient8[j]),
        .result_remainder   (remainder8[j]),
        .result_valid       (result_valid8[j]),
        .result_ready       (result_ready&result_valid),
        .trap_flush_rvv     (trap_flush_rvv)
      );     
    end
  endgenerate 

  generate
    for(j=0;j<`VLENH/2;j++) begin: DIVIDER16
      intdivider
      #(
        .DIV_WIDTH          (8'd`HWORD_WIDTH)
      )
      divider_16bit
      (
        .clk                (clk),
        .rst_n              (rst_n),
        .div_valid          (uop_valid&(vs2_eew!=EEW32) || uop_valid_d1&(res_info_d1.vs2_eew!=EEW32)),
        .div_ready          (div_ready16[j]),
        .opcode             (opcode), 
        .src2_dividend      (src2_data16[j]),
        .src1_divisor       (src1_data16[j]),
        .result_quotient    (quotient16[j]),
        .result_remainder   (remainder16[j]),
        .result_valid       (result_valid16[j]),
        .result_ready       (result_ready&result_valid),
        .trap_flush_rvv     (trap_flush_rvv)
      );     
    end
  endgenerate 

  generate
    for(j=0;j<`VLENW;j++) begin: DIVIDER32
      intdivider
      #(
        .DIV_WIDTH          (8'd`WORD_WIDTH)
      )
      divider_32bit
      (
        .clk                (clk),
        .rst_n              (rst_n),
        .div_valid          (uop_valid || uop_valid_d1),
        .div_ready          (div_ready32[j]),
        .opcode             (opcode), 
        .src2_dividend      (src2_data32[j]),
        .src1_divisor       (src1_data32[j]),
        .result_quotient    (quotient32[j]),
        .result_remainder   (remainder32[j]),
        .result_valid       (result_valid32[j]),
        .result_ready       (result_ready&result_valid),
        .trap_flush_rvv     (trap_flush_rvv)
      );     
    end
  endgenerate
  
  // divider is ready to receive a new uop
  always_comb begin
    case(vs2_eew)
      EEW8:    div_uop_ready = &{div_ready32,div_ready16,div_ready8}; 
      EEW16:   div_uop_ready = &{div_ready32,div_ready16};
      EEW32:   div_uop_ready = &{div_ready32};
      default: div_uop_ready = 'b0;
    endcase
  end

  // check whether all the results are gotten
  always_comb begin
    result_all_valid = 'b0;
    
    case(res_info_d1.vs2_eew)
      EEW8: begin
        result_all_valid = ({result_valid8,result_valid16,result_valid32}=='1);
      end
      EEW16: begin
        result_all_valid = ({result_valid16,result_valid32}=='1);
      end
      EEW32: begin
        result_all_valid = (result_valid32=='1);
      end
    endcase
  end

  // assign to result_data
  always_comb begin
    // initial the data
    result_data = 'b0;

    case(res_info_d1.uop_funct3) 
      OPMVV,
      OPMVX: begin
        case(res_info_d1.uop_funct6.ari_funct6)
          VDIVU,
          VDIV: begin
            case(res_info_d1.vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = quotient8[i];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = quotient16[i-`VLENB/2][0 +: `BYTE_WIDTH];
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = quotient32[i-`VLENB*3/4][0 +: `BYTE_WIDTH];
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = quotient16[i];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = quotient32[i-`VLEN/`HWORD_WIDTH/2][0 +: `HWORD_WIDTH];
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = quotient32[i];
                end             
              end
            endcase
          end

          VREMU,
          VREM: begin
            case(res_info_d1.vs2_eew)
              EEW8: begin
                for (int i=0;i<`VLENB/2;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = remainder8[i];
                end
                for (int i=`VLENB/2;i<`VLENB*3/4;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = remainder16[i-`VLENB/2][0 +: `BYTE_WIDTH];
                end
                for (int i=`VLENB*3/4;i<`VLENB;i++) begin
                  result_data[i*`BYTE_WIDTH +: `BYTE_WIDTH] = remainder32[i-`VLENB*3/4][0 +: `BYTE_WIDTH];
                end
              end
              EEW16: begin
                for (int i=0;i<`VLEN/`HWORD_WIDTH/2;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = remainder16[i];
                end
                for (int i=`VLEN/`HWORD_WIDTH/2;i<`VLEN/`HWORD_WIDTH;i++) begin
                  result_data[i*`HWORD_WIDTH +: `HWORD_WIDTH] = remainder32[i-`VLEN/`HWORD_WIDTH/2][0 +: `HWORD_WIDTH];
                end
              end             
              EEW32: begin
                for (int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = remainder32[i];
                end             
              end
            endcase
          end
        endcase
      end
    endcase
  end

//
// submit result to ROB
//
`ifdef TB_SUPPORT
  assign result.uop_pc    = res_info_d1.uop_pc;
`endif
  assign result_valid     = result_all_valid;
  assign result.rob_entry = res_info_d1.rob_entry;
  assign result.w_data    = result_data;
  assign result.w_valid   = result_all_valid;
  assign result.vsaturate = 'b0;
`ifdef ZVE32F_ON
  assign result.fpexp     = 'b0;
`endif

endmodule
