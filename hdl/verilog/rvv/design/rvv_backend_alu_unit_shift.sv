
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_alu_unit_shift
(
  alu_uop_valid,
  alu_uop,
  result_valid,
  result
);
  localparam  SHIFT_SLL   = 2'b00;
  localparam  SHIFT_SRL   = 2'b01;
  localparam  SHIFT_SRA   = 2'b10;
//
// interface signals
//
  // ALU RS handshake signals
  input   logic                   alu_uop_valid;
  input   ALU_RS_t                alu_uop;

  // ALU send result signals to ROB
  output  logic                   result_valid;
  output  PU2ROB_t                result;

`ifdef CORALNPU_STRUCTURAL_DATAPATH
  rvv_backend_alu_shift_datapath u_shift_structural_dp (
    .alu_uop_valid (alu_uop_valid),
    .alu_uop       (alu_uop),
    .result_valid  (result_valid),
    .result        (result)
  );
`else
//
// internal signals
//

  // ALU_RS_t struct signals
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  FUNCT6_u                        uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3;
  RVVXRM                          vxrm;       
  logic   [`VLEN-1:0]             vs1_data;           
  logic   [`VLEN-1:0]             vs2_data;	        
  EEW_e                           vs2_eew;
  logic   [`XLEN-1:0] 	          rs1_data;        
  logic   [$clog2(`EMUL_MAX)-1:0] uop_index;          

  // execute 
  // add and sub instructions
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]           src2_data8;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]          src2_data16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             src2_data32;
  logic   [`VLENB/2-1:0][$clog2(`BYTE_WIDTH)-1:0]   shift_amount8;
  logic   [`VLENH/2-1:0][$clog2(`HWORD_WIDTH)-1:0]  shift_amount16;
  logic   [`VLENW-1:0][$clog2(`WORD_WIDTH)-1:0]     shift_amount32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]           product8_tmp;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]          product16_tmp;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             product32_tmp;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]             product8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]            product16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             product32;
  logic   [`VLENB/2-1:0][`BYTE_WIDTH-1:0]           round_bits8_tmp;
  logic   [`VLENH/2-1:0][`HWORD_WIDTH-1:0]          round_bits16_tmp;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             round_bits32_tmp;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]             round_bits8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]            round_bits16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             round_bits32;
  logic   [`VLENB-1:0]                              round_increment8;
  logic   [`VLENH-1:0]                              round_increment16;
  logic   [`VLENW-1:0]                              round_increment32;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]             round8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]            round16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]             round32;
  logic   [`VLENH-1:0]                              cout16;
  logic   [`VLENW-1:0]                              cout32;
  logic   [`VLENB-1:0]                              upoverflow;
  logic   [`VLENB-1:0]                              underoverflow;
  logic   [`VLEN-1:0]                               result_data; 
  logic   [1:0]                                     shift_mode;
  
  // for-loop
  genvar                                            j;

//
// prepare source data to calculate    
//
  // split ALU_RS_t struct
  assign  rob_entry      = alu_uop.rob_entry;
  assign  uop_funct6     = alu_uop.uop_funct6;
  assign  uop_funct3     = alu_uop.uop_funct3;
  assign  vxrm           = alu_uop.vxrm;
  assign  vs1_data       = alu_uop.vs1_data;
  assign  rs1_data       = alu_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data       = alu_uop.vs2_data;
  assign  vs2_eew        = alu_uop.vs2_eew;
  assign  uop_index      = alu_uop.uop_index;
  
//  
// prepare source data 
//
  // prepare valid signal 
  always_comb begin
    // initial the data
    result_valid   = 'b0;

    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VSLL,
          VSRL,
          VSRA,
          VSSRL,
          VSSRA,
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end
    endcase
  end

  // prepare source data
  always_comb begin
    // initial the data
    src2_data8     = 'b0;
    src2_data16    = 'b0;
    src2_data32    = 'b0;
    shift_amount8  = 'b0;
    shift_amount16 = 'b0;
    shift_amount32 = 'b0;

    case(uop_funct3) 
      OPIVV: begin
        case(uop_funct6.ari_funct6)
          VSLL,
          VSRL,
          VSSRL: begin
            case(vs2_eew)
              EEW8: begin
                for(int i=0;i<`VLENB/2;i=i+1) begin
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)];
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
                  src2_data16[   i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
                  src2_data32[   i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0, vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = vs1_data[i*`WORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase
          end

          VSRA,
          VSSRA: begin
             case(vs2_eew)
              EEW8: begin
                for(int i=0;i<`VLENB/2;i=i+1) begin
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)];
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
                  src2_data16[   i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
                  src2_data32[   i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0,vs1_data[i*`BYTE_WIDTH +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0,vs1_data[i*`HWORD_WIDTH +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = vs1_data[i*`WORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase         
          end

          VNSRL,
          VNCLIPU: begin
            case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  if (uop_index[0]==1'b0)
                    shift_amount16[i] = vs1_data[i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                  else
                    shift_amount16[i] = vs1_data[`VLEN/2+i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  if (uop_index[0]==1'b0)
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)]};
                  else
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[`VLEN/2+i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH  +: `WORD_WIDTH];
                  if (uop_index[0]==1'b0)
                    shift_amount32[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                  else
                    shift_amount32[i] = vs1_data[`VLEN/2+i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase
          end

          VNSRA,
          VNCLIP: begin
             case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i] = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  if (uop_index[0]==1'b0)
                    shift_amount16[i] = vs1_data[i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                  else
                    shift_amount16[i] = vs1_data[`VLEN/2+i*`BYTE_WIDTH  +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  if (uop_index[0]==1'b0)
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[i*`BYTE_WIDTH +: $clog2(`HWORD_WIDTH)]};
                  else
                    shift_amount32[i-`VLENH/2] = {1'b0, vs1_data[`VLEN/2+i*`BYTE_WIDTH +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i] = vs2_data[i*`WORD_WIDTH  +: `WORD_WIDTH];
                  if (uop_index[0]==1'b0)
                    shift_amount32[i] = vs1_data[i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                  else
                    shift_amount32[i] = vs1_data[`VLEN/2+i*`HWORD_WIDTH +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase  
          end
        endcase
      end

      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VSLL,
          VSRL,
          VSSRL: begin
             case(vs2_eew)
              EEW8: begin
                for(int i=0;i<`VLENB/2;i=i+1) begin
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = rs1_data[0             +: $clog2(`BYTE_WIDTH)];
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
                  src2_data16[   i-`VLENB/2] = {8'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,rs1_data[0             +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
                  src2_data32[   i-`VLENB*3/4] = {24'b0,vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0, rs1_data[0             +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0, rs1_data[0              +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0             +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase       
          end

          VSRA,
          VSSRA: begin
            case(vs2_eew)
              EEW8: begin
                for(int i=0;i<`VLENB/2;i=i+1) begin
                  src2_data8[i]    = vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH];
                  shift_amount8[i] = rs1_data[0             +: $clog2(`BYTE_WIDTH)];
                end
                for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
                  src2_data16[   i-`VLENB/2] = {{8{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount16[i-`VLENB/2] = {1'b0,rs1_data[0 +: $clog2(`BYTE_WIDTH)]};
                end         
                for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
                  src2_data32[   i-`VLENB*3/4] = {{24{vs2_data[(i+1)*`BYTE_WIDTH-1]}},vs2_data[i*`BYTE_WIDTH +: `BYTE_WIDTH]};
                  shift_amount32[i-`VLENB*3/4] = {2'b0,rs1_data[0 +: $clog2(`BYTE_WIDTH)]};
                end
              end
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0,rs1_data[0 +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0 +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase          
          end

          VNSRL,
          VNCLIPU: begin
            case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {16'b0,vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0, rs1_data[0              +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0             +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase  
          end

          VNSRA,
          VNCLIP: begin
            case(vs2_eew)
              EEW16: begin
                for(int i=0;i<`VLENH/2;i=i+1) begin
                  src2_data16[i]    = vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH];
                  shift_amount16[i] = rs1_data[0              +: $clog2(`HWORD_WIDTH)];
                end
                for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
                  src2_data32[   i-`VLENH/2] = {{16{vs2_data[(i+1)*`HWORD_WIDTH-1]}},vs2_data[i*`HWORD_WIDTH +: `HWORD_WIDTH]};
                  shift_amount32[i-`VLENH/2] = {1'b0,rs1_data[0 +: $clog2(`HWORD_WIDTH)]};
                end   
              end
              EEW32: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  src2_data32[i]    = vs2_data[i*`WORD_WIDTH +: `WORD_WIDTH];
                  shift_amount32[i] = rs1_data[0 +: $clog2(`WORD_WIDTH)];
                end
              end
            endcase 
          end
        endcase
      end
    endcase
  end

  // get mode for f_addsub
  always_comb begin
    // initial the data
    shift_mode = SHIFT_SLL;

    // prepare source data
    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)    
          VSLL: begin
            shift_mode = SHIFT_SLL;
          end
          VSRL,
          VNSRL,
          VSSRL,
          VNCLIPU: begin
            shift_mode = SHIFT_SRL;
          end
          VSRA,
          VNSRA,
          VSSRA,
          VNCLIP: begin
            shift_mode = SHIFT_SRA;
          end
        endcase
      end
    endcase
  end

//    
// calculate the result
//
  // shift instructions
  generate
    for (j=0;j<`VLENB/2;j=j+1) begin: EXE_PROD8
      barrel_shifter #(
        .DATA_WIDTH   (`BYTE_WIDTH*2)
      ) shifter8 (
        .din          ({src2_data8[j],`BYTE_WIDTH'b0}),            
        .shift_amount ({1'b0,shift_amount8[j]}),
        .shift_mode   (shift_mode),     
        .dout         ({product8_tmp[j], round_bits8_tmp[j]}) 
      );
    end
  
    for (j=0;j<`VLENH/2;j=j+1) begin: EXE_PROD16
      barrel_shifter #(
        .DATA_WIDTH   (`HWORD_WIDTH*2)
      ) shifter16 (
        .din          ({src2_data16[j],`HWORD_WIDTH'b0}),            
        .shift_amount ({1'b0,shift_amount16[j]}),
        .shift_mode   (shift_mode),     
        .dout         ({product16_tmp[j], round_bits16_tmp[j]}) 
      );
    end

    for (j=0;j<`VLENW;j=j+1) begin: EXE_PROD32
      barrel_shifter #(
        .DATA_WIDTH   (`WORD_WIDTH*2)
      ) shifter32 (
        .din          ({src2_data32[j],`WORD_WIDTH'b0}),            
        .shift_amount ({1'b0,shift_amount32[j]}),
        .shift_mode   (shift_mode),     
        .dout         ({product32_tmp[j], round_bits32_tmp[j]}) 
      );
    end
  endgenerate 
  
  always_comb begin
    product8    = 'b0;
    round_bits8 = 'b0;

    for(int i=0;i<`VLENB/2;i=i+1) begin
      product8[i]    = product8_tmp[i];
      round_bits8[i] = round_bits8_tmp[i];
    end
    for(int i=`VLENB/2;i<`VLENB*3/4;i=i+1) begin
      product8[i]    = product16_tmp[   i-`VLENB/2][0           +: `BYTE_WIDTH];
      round_bits8[i] = round_bits16_tmp[i-`VLENB/2][`BYTE_WIDTH +: `BYTE_WIDTH];
    end         
    for(int i=`VLENB*3/4;i<`VLENB;i=i+1) begin
      product8[i]    = product32_tmp[   i-`VLENB*3/4][0             +: `BYTE_WIDTH];
      round_bits8[i] = round_bits32_tmp[i-`VLENB*3/4][3*`BYTE_WIDTH +: `BYTE_WIDTH];
    end
  end
 
  always_comb begin
    product16    = 'b0;
    round_bits16 = 'b0;

    for(int i=0;i<`VLENH/2;i=i+1) begin
      product16[i]    = product16_tmp[i];
      round_bits16[i] = round_bits16_tmp[i];
    end
    for(int i=`VLENH/2;i<`VLENH;i=i+1) begin
      product16[i]    = product32_tmp[   i-`VLENH/2][0            +: `HWORD_WIDTH];
      round_bits16[i] = round_bits32_tmp[i-`VLENH/2][`HWORD_WIDTH +: `HWORD_WIDTH];
    end   
  end

  always_comb begin
    product32    = 'b0;
    round_bits32 = 'b0;

    for(int i=0;i<`VLENW;i=i+1) begin
      product32[i]    = product32_tmp[i];
      round_bits32[i] = round_bits32_tmp[i];
    end
  end

  // round increment
  generate
    for (j=0;j<`VLENB;j++) begin: INCREMENT8
      always_comb begin
        round_increment8[j] = 'b0;
        
        case(vxrm)
          RNU: begin
            round_increment8[j] = round_bits8[j][`BYTE_WIDTH-1];
          end
          RNE: begin
            round_increment8[j] = round_bits8[j][`BYTE_WIDTH-1] & ((round_bits8[j][`BYTE_WIDTH-2:0]!='b0) | product8[j][0]);
          end
          RDN: begin
            round_increment8[j] = 'b0;
          end
          ROD: begin
            round_increment8[j] = (!product8[j][0]) & (round_bits8[j]!='b0);
          end
        endcase
      end
    end
  endgenerate

  generate
    for (j=0;j<`VLENH;j++) begin: INCREMENT16
      always_comb begin
        round_increment16[j] = 'b0;
        
        case(vxrm)
          RNU: begin
            round_increment16[j] = round_bits16[j][`HWORD_WIDTH-1];
          end
          RNE: begin
            round_increment16[j] = round_bits16[j][`HWORD_WIDTH-1] & ((round_bits16[j][`HWORD_WIDTH-2:0]!='b0) | product16[j][0]);
          end
          RDN: begin
            round_increment16[j] = 'b0;
          end
          ROD: begin
            round_increment16[j] = (!product16[j][0]) & (round_bits16[j]!='b0);
          end
        endcase
      end
    end
  endgenerate

  generate
    for (j=0;j<`VLENW;j++) begin: INCREMENT32
      always_comb begin
        round_increment32[j] = 'b0;
        
        case(vxrm)
          RNU: begin
            round_increment32[j] = round_bits32[j][`WORD_WIDTH-1];
          end
          RNE: begin
            round_increment32[j] = round_bits32[j][`WORD_WIDTH-1] & ((round_bits32[j][`WORD_WIDTH-2:0]!='b0) | product32[j][0]);
          end
          RDN: begin
            round_increment32[j] = 'b0;
          end
          ROD: begin
            round_increment32[j] = (!product32[j][0]) & (round_bits32[j]!='b0);
          end
        endcase
      end
    end
  endgenerate

  // rounding result
  always_comb begin
    for(int i=0;i<`VLENB;i++) begin: ROUND8
      if (shift_mode == SHIFT_SLL)
        round8[i] = 'b0;
      else
        round8[i] = round_increment8[i] ? product8[i]+'b1 : product8[i]; 
    end
  end

  always_comb begin
    for(int i=0;i<`VLENH;i++) begin: ROUND16
      if (shift_mode == SHIFT_SRL)
        {cout16[i], round16[i]} = round_increment16[i] ? {1'b0, product16[i]}+'b1 : {1'b0, product16[i]}; 
      else if (shift_mode == SHIFT_SRA)
        {cout16[i], round16[i]} = round_increment16[i] ? {product16[i][`HWORD_WIDTH-1], product16[i]}+'b1 : {product16[i][`HWORD_WIDTH-1], product16[i]}; 
      else begin
        cout16[i]  = 'b0; 
        round16[i] = 'b0;
      end
    end
  end

  always_comb begin
    for(int i=0;i<`VLENW;i++) begin: ROUND32
      if (shift_mode == SHIFT_SRL)
        {cout32[i], round32[i]} = round_increment32[i] ? {1'b0, product32[i]}+'b1 : {1'b0, product32[i]}; 
      else if (shift_mode == SHIFT_SRA)
        {cout32[i], round32[i]} = round_increment32[i] ? {product32[i][`WORD_WIDTH-1], product32[i]}+'b1 : {product32[i][`WORD_WIDTH-1], product32[i]}; 
      else begin
        cout32[i]  = 'b0; 
        round32[i] = 'b0;
      end
    end
  end

  // overflow check for vnclipu and vnclip 
  generate 
    for (j=0;j<`VLENW/2;j++) begin: GET_OVERFLOW
      always_comb begin
        // initial
        upoverflow[   4*j +: 4] = 'b0;
        underoverflow[4*j +: 4] = 'b0;
        upoverflow[   4*(j+`VLENW/2) +: 4] = 'b0;
        underoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
          
        case(vs2_eew)
          EEW16: begin
            case(shift_mode)
              SHIFT_SRL: begin
              // unsigned overflow check for vnclipu
                if(uop_index[0]==1'b0) begin
                  upoverflow[4*j +: 4] = {
                    ({cout16[4*j+3], round16[4*j+3][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j+2], round16[4*j+2][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j+1], round16[4*j+1][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j  ], round16[4*j  ][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0)};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;

                  upoverflow[4*(j+`VLENW/2) +: 4] = {
                    ({cout16[4*j+3], round16[4*j+3][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j+2], round16[4*j+2][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j+1], round16[4*j+1][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0),
                    ({cout16[4*j  ], round16[4*j  ][`BYTE_WIDTH +: `BYTE_WIDTH]}!='b0)};
                end
              end
              SHIFT_SRA: begin
              // signed overflow check for vnclip
                if(uop_index[0]==1'b0) begin
                  upoverflow[4*j +: 4] = {
                    (cout16[4*j+3]=='b0)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+2]=='b0)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+1]=='b0)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j  ]=='b0)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0)};

                  underoverflow[4*j +: 4] = {
                    (cout16[4*j+3]=='b1)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+2]=='b1)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+1]=='b1)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j  ]=='b1)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff)};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                  underoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;
                  underoverflow[4*j +: 4] = 'b0;

                  upoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout16[4*j+3]=='b0)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+2]=='b0)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j+1]=='b0)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0),
                    (cout16[4*j  ]=='b0)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='b0)};

                  underoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout16[4*j+3]=='b1)&(round16[4*j+3][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+2]=='b1)&(round16[4*j+2][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j+1]=='b1)&(round16[4*j+1][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff),
                    (cout16[4*j  ]=='b1)&(round16[4*j  ][`BYTE_WIDTH-1 +: `BYTE_WIDTH+1]!='h1ff)};
                end
              end
            endcase
          end
          EEW32: begin
            case(shift_mode)
              SHIFT_SRL: begin
              // unsigned overflow check for vnclipu
                if(uop_index[0]==1'b0) begin
                  upoverflow[4*j +: 4] = {
                    ({cout32[2*j+1], round32[2*j+1][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0,
                    ({cout32[2*j  ], round32[2*j  ][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;

                  upoverflow[4*(j+`VLENW/2) +: 4] = {
                    ({cout32[2*j+1], round32[2*j+1][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0,
                    ({cout32[2*j  ], round32[2*j  ][`HWORD_WIDTH +: `HWORD_WIDTH]}!='b0),1'b0};
                end
              end
              SHIFT_SRA: begin
              // unsigned overflow check for vnclip
                if(uop_index[0]==1'b0) begin
                  upoverflow[4*j +: 4] = {
                    (cout32[2*j+1]=='b0)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0,
                    (cout32[2*j  ]=='b0)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0};

                  underoverflow[4*j +: 4] = {
                    (cout32[2*j+1]=='b1)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0,
                    (cout32[2*j  ]=='b1)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0};

                  upoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                  underoverflow[4*(j+`VLENW/2) +: 4] = 'b0;
                end
                else begin
                  upoverflow[4*j +: 4] = 'b0;
                  underoverflow[4*j +: 4] = 'b0;

                  upoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout32[2*j+1]=='b0)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0,
                    (cout32[2*j  ]=='b0)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='b0),1'b0};

                  underoverflow[4*(j+`VLEN/`WORD_WIDTH/2) +: 4] = {
                    (cout32[2*j+1]=='b1)&(round32[2*j+1][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0,
                    (cout32[2*j  ]=='b1)&(round32[2*j  ][`HWORD_WIDTH-1 +: `HWORD_WIDTH+1]!='h1ffff),1'b0};
                end
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

  // assign to result_data
  always_comb begin
    // initial the data
    result_data = 'b0;
 
    for(int i=0;i<`VLENW;i++) begin
      // calculate result data
      case(uop_funct3) 
        OPIVV,
        OPIVX,
        OPIVI: begin
          case(uop_funct6.ari_funct6)
            VSLL,
            VSRL,
            VSRA: begin
              case(vs2_eew)
                EEW8: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {product8[4*i+3],product8[4*i+2],product8[4*i+1],product8[4*i]};
                end
                EEW16: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*i+1],product16[2*i]};
                end
                EEW32: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = product32[i];
                end
              endcase
            end
  
            VNSRL,
            VNSRA: begin
              case(vs2_eew)
                EEW16: begin
                  if (uop_index[0]==1'b0)
                    result_data[i*`HWORD_WIDTH         +: `HWORD_WIDTH] = {product16[2*i+1][`BYTE_WIDTH-1:0],product16[2*i][`BYTE_WIDTH-1:0]};
                  else
                    result_data[`VLEN/2+i*`HWORD_WIDTH +: `HWORD_WIDTH] = {product16[2*i+1][`BYTE_WIDTH-1:0],product16[2*i][`BYTE_WIDTH-1:0]};
                end
                EEW32: begin
                  if (uop_index[0]==1'b0)
                    result_data[i*`HWORD_WIDTH         +: `HWORD_WIDTH] = product32[i][`HWORD_WIDTH-1:0];
                  else
                    result_data[`VLEN/2+i*`HWORD_WIDTH +: `HWORD_WIDTH] = product32[i][`HWORD_WIDTH-1:0];
                end
              endcase
            end

            VSSRL,
            VSSRA: begin
              case(vs2_eew)
                EEW8: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {round8[4*i+3],round8[4*i+2],round8[4*i+1],round8[4*i]};
                end
                EEW16: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {round16[2*i+1],round16[2*i]};
                end
                EEW32: begin
                  result_data[i*`WORD_WIDTH +: `WORD_WIDTH] = round32[i];
                end
              endcase
            end

            VNCLIPU: begin
              case(vs2_eew)
                EEW16: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+3][`BYTE_WIDTH-1 : 0];
                  end
                  else begin
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+3][`BYTE_WIDTH-1 : 0];
                  end
                end
                EEW32: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i+1][`HWORD_WIDTH-1 : 0];
                  end
                  else begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)+1][`HWORD_WIDTH-1 : 0];
                  end
                end
              endcase
            end

            VNCLIP: begin
              case(vs2_eew)
                EEW16: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*i+3][`BYTE_WIDTH-1 : 0];
                  end
                  else begin
                    if (upoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i])
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+1])
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+1][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+2])
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+2)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+2][`BYTE_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                    else if (underoverflow[4*i+3])
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                    else
                      result_data[(4*i+3)*`BYTE_WIDTH +: `BYTE_WIDTH] = round16[4*(i-`VLENW/2)+3][`BYTE_WIDTH-1 : 0];
                  end
                end
                EEW32: begin
                  if (i<`VLENW/2) begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*i+1][`HWORD_WIDTH-1 : 0];
                  end
                  else begin
                    if (upoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+1])
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)][`HWORD_WIDTH-1 : 0];

                    if (upoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                    else if (underoverflow[4*i+3])
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                    else
                      result_data[(2*i+1)*`HWORD_WIDTH +: `HWORD_WIDTH] = round32[2*(i-`VLENW/2)+1][`HWORD_WIDTH-1 : 0];
                  end
                end
              endcase
            end
          endcase
        end
      endcase
    end
  end

//
// submit result to ROB
//
  // saturate signal
  always_comb begin
    // initial
  `ifdef TB_SUPPORT
    result.uop_pc    = alu_uop.uop_pc;
  `endif
    result.rob_entry = rob_entry;
    result.w_data    = result_data;
    result.w_valid   = result_valid;
    result.vsaturate = 'b0;
  `ifdef ZVE32F_ON
    result.fpexp     = 'b0;
  `endif

    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VNCLIPU: begin
            result.vsaturate = upoverflow;
          end
          VNCLIP: begin
            result.vsaturate = underoverflow|upoverflow;
          end
        endcase
      end
    endcase
  end
`endif // !CORALNPU_STRUCTURAL_DATAPATH

endmodule
