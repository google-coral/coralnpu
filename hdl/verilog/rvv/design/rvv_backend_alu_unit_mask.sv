
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_alu_unit_mask
(
  alu_uop_valid,
  alu_uop,
  result_valid,
  result
);
//
// interface signals
//
  // ALU RS handshake signals
  input   logic           alu_uop_valid;
  input   ALU_RS_t        alu_uop;

  // ALU send result signals to ROB
  output  logic           result_valid;
  output  PU2ROB_t        result;

//
// internal signals
//
  // ALU_RS_t struct signals
  logic   [`ROB_DEPTH_WIDTH-1:0]  rob_entry;
  FUNCT6_u                        uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]     uop_funct3;
  logic   [`VSTART_WIDTH-1:0]     vstart;
  logic   [`VLEN-1:0]             vstart_elements_tmp;
  logic   [`VLEN-1:0]             vstart_elements;
  logic   [`VL_WIDTH-1:0]         vl;       
  logic   [`VLEN-1:0]             v0_data;           
  logic   [`VLEN-1:0]             vd_data;           
  EEW_e                           vd_eew;
  logic   [`REGIDX_WIDTH-1:0]     vs1_opcode;              
  logic   [`VLEN-1:0]             vs1_data;           
  logic   [`VLEN-1:0]             vs2_data;	        
  EEW_e                           vs2_eew;
  logic   [`XLEN-1:0] 	          rs1_data;        
  logic   [$clog2(`EMUL_MAX)-1:0] uop_index;          

  // execute 
  logic   [`VLEN-1:0]             src2_data;
  logic   [`VLEN-1:0]             src2_data_sub1;
  logic   [`VLEN-1:0]             src1_data;
  logic   [`VLEN-1:0]             tail_mask;
  logic   [`VLEN-1:0]             result_data;
  logic   [`VLEN-1:0]             result_data_andn;
  logic   [`VLEN-1:0]             result_data_and; 
  logic   [`VLEN-1:0]             result_data_or;  
  logic   [`VLEN-1:0]             result_data_xor; 
  logic   [`VLEN-1:0]             result_data_orn; 
  logic   [`VLEN-1:0]             result_data_nand;
  logic   [`VLEN-1:0]             result_data_nor; 
  logic   [`VLEN-1:0]             result_data_xnor;
  logic   [`VLEN-1:0]             result_data_vmsof;
  logic   [`VLEN-1:0]             result_vmsif;
  logic   [`VLEN-1:0]             result_data_vmsif;
  logic   [`VLEN-1:0]             result_data_vmsbf;
  logic   [`VLEN-1:0]             result_data_vfirst;
  logic   [`VLEN-1:0]             result_data_vid8;
  logic   [`VLEN-1:0]             result_data_vid16;
  logic   [`VLEN-1:0]             result_data_vid32;

  // for-loop
  genvar                              j;
  genvar                              h;

//
// prepare source data to calculate    
//
  // split ALU_RS_t struct
  assign  rob_entry      = alu_uop.rob_entry;
  assign  uop_funct6     = alu_uop.uop_funct6;
  assign  uop_funct3     = alu_uop.uop_funct3;
  assign  vstart         = alu_uop.vstart;
  assign  vl             = alu_uop.vl;
  // assign  vm             = alu_uop.vm;
  assign  v0_data        = alu_uop.v0_data;
  assign  vd_data        = alu_uop.vd_data;
  assign  vd_eew         = alu_uop.vd_eew;
  assign  vs1_opcode     = alu_uop.vs1;
  assign  vs1_data       = alu_uop.vs1_data;
  assign  rs1_data       = alu_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data       = alu_uop.vs2_data;
  assign  vs2_eew        = alu_uop.vs2_eew;
  assign  uop_index      = alu_uop.uop_index;
  
//  
// prepare source data 
//
  // get tail mask
  //assign tail_mask = vl[`VL_WIDTH-1] ? '1 ((`VLEN)'('b1)<<vl[`VL_WIDTH-2:0]) - 1'b1;
  generate
    for(j=0;j<`VLEN;j++) assign tail_mask[j] = j[`VL_WIDTH-1:0] < vl;
  endgenerate

  // prepare valid signal
  always_comb begin
    // initial the data
    result_valid = 'b0;

    // prepare source data
    case(uop_funct3)
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VAND,
          VOR,
          VXOR: begin
            result_valid = alu_uop_valid;
          end
        endcase
      end

      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            result_valid = alu_uop_valid;
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF,
              VID: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
        endcase
      end
    endcase
  end

  // prepare source data
  always_comb begin
    // initial the data
    src2_data       = 'b0;
    src1_data       = 'b0;

    // prepare source data
    case(uop_funct3)
      OPIVV: begin
        case(uop_funct6.ari_funct6)
          VAND,
          VOR,
          VXOR: begin
            src2_data = vs2_data;
            src1_data = vs1_data;
          end
        endcase
      end
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VAND,
          VOR,
          VXOR: begin
            src2_data = vs2_data;
            for(int i=0;i<`VLEN/`WORD_WIDTH;i++) begin
              case(vs2_eew) 
                EEW8: begin
                  src1_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {(`WORD_WIDTH/`BYTE_WIDTH){rs1_data[0 +: `BYTE_WIDTH]}};
                end
                EEW16: begin
                  src1_data[i*`WORD_WIDTH +: `WORD_WIDTH] = {(`WORD_WIDTH/`HWORD_WIDTH){rs1_data[0 +: `HWORD_WIDTH]}};
                end
                EEW32: begin
                  src1_data[i*`WORD_WIDTH +: `WORD_WIDTH] = rs1_data;
                end
              endcase
            end
          end 
        endcase
      end
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            src2_data  = vs2_data;
            src1_data  = vs1_data;
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                if (alu_uop.vm==1'b1)
                  src2_data = vs2_data&tail_mask;
                else
                  src2_data = vs2_data&tail_mask&v0_data; 
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF: begin
                if (alu_uop.vm==1'b1)
                  src2_data = vs2_data;
                else
                  src2_data = vs2_data&v0_data; 
              end
              // no source operand for VID
            endcase
          end
        endcase
      end
    endcase
  end

//    
// calculate the result
//
  assign result_data_and   = src2_data & src1_data;  
  assign result_data_andn  = src2_data & (~src1_data);  
  assign result_data_or    = src2_data | src1_data;  
  assign result_data_xor   = src2_data ^ src1_data;  
  assign result_data_orn   = src2_data | (~src1_data);  
  assign result_data_nand  = ~(src2_data & src1_data);  
  assign result_data_nor   = ~(src2_data | src1_data);  
  assign result_data_xnor  = ~(src2_data ^ src1_data); 
  assign src2_data_sub1    = src2_data - 1'b1;
  assign result_data_vmsof = src2_data & (~src2_data_sub1);
  assign result_vmsif      = src2_data ^ src2_data_sub1;
  assign result_data_vmsif = (src2_data==0) ? {`VLEN{1'b1}} : result_vmsif;  
  assign result_data_vmsbf = (src2_data==0) ? {`VLEN{1'b1}} : {1'b0,result_vmsif[`VLEN-1:1]}; 
 
  // vfirst
  always_comb begin
    result_data_vfirst = 'b0;
    
    if (src2_data=='b0) 
      result_data_vfirst = {`VLEN{1'b1}};
    else begin
      for(int i=0;i<`VLEN;i++) begin
        if (result_data_vmsof[i]==1'b1)
          result_data_vfirst = (`VLEN)'(i);         // one-hot to 8421BCD. get the index of first 1
      end
    end
  end

  // vid
  generate
    for(j=0;j<`VLENB;j++) begin: GET_VID8
      assign result_data_vid8[j*`BYTE_WIDTH +: `BYTE_WIDTH] = (`BYTE_WIDTH)'({uop_index, j[$clog2(`VLENB)-1:0]});
    end
  endgenerate

  generate
    for(j=0;j<`VLEN/`HWORD_WIDTH;j++) begin: GET_VID16
      assign result_data_vid16[j*`HWORD_WIDTH +: `HWORD_WIDTH] = (`HWORD_WIDTH)'({uop_index, j[$clog2(`VLEN/`HWORD_WIDTH)-1:0]});
    end
  endgenerate

  generate
    for(j=0;j<`VLEN/`WORD_WIDTH;j++) begin: GET_VID32
      assign result_data_vid32[j*`WORD_WIDTH +: `WORD_WIDTH] = (`WORD_WIDTH)'({uop_index, j[$clog2(`VLEN/`WORD_WIDTH)-1:0]});
    end
  endgenerate

  // get result_data
  always_comb begin
    // initial the data
    result_data = 'b0; 
 
    // calculate result data
    case(uop_funct3)
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VAND: begin
            result_data = result_data_and;
          end
          VOR: begin
            result_data = result_data_or;
          end
          VXOR: begin
            result_data = result_data_xor;
          end
        endcase
      end
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN: begin
            result_data = result_data_andn;
          end
          VMAND: begin
            result_data = result_data_and; 
          end
          VMOR: begin
            result_data = result_data_or; 
          end
          VMXOR: begin
            result_data = result_data_xor; 
          end
          VMORN: begin
            result_data = result_data_orn; 
          end
          VMNAND: begin
            result_data = result_data_nand; 
          end
          VMNOR: begin
            result_data = result_data_nor; 
          end
          VMXNOR: begin
            result_data = result_data_xnor; 
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                result_data = result_data_vfirst;
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF: begin
                result_data = result_data_vmsbf;
              end
              VMSOF: begin
                result_data = result_data_vmsof;
              end
              VMSIF: begin
                result_data = result_data_vmsif;
              end
              VID: begin
                case(vd_eew)
                  EEW8: begin
                    result_data = result_data_vid8;
                  end
                  EEW16: begin
                    result_data = result_data_vid16;
                  end
                  EEW32: begin
                    result_data = result_data_vid32;
                  end
                endcase
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
  barrel_shifter #(.DATA_WIDTH(`VLEN)) 
  u_prestart (.din((`VLEN)'('1)), .shift_amount(vstart[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vstart_elements_tmp));
  assign vstart_elements  = ~vstart_elements_tmp;

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
          VAND,
          VOR,
          VXOR: begin
            result.w_data = result_data;
          end
        endcase
      end
      OPMVV: begin
        case(uop_funct6.ari_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            result.w_data = result_data&(~vstart_elements) | vd_data&vstart_elements;
          end
          VWRXUNARY0: begin
            case(vs1_opcode)
              VFIRST: begin
                result.w_data = result_data;
              end
            endcase
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF: begin
                if (alu_uop.vm==1'b1)
                  result.w_data = result_data;
                else 
                  result.w_data = result_data&v0_data | vd_data&(~v0_data);
              end
              VID: begin
                result.w_data = result_data;
              end
            endcase
          end
        endcase
      end
    endcase
  end   

endmodule
