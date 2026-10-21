
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef ALU_DEFINE_SVH
`include "rvv_backend_alu.svh"
`endif

module rvv_backend_alu_unit_addsub
(
  alu_uop_valid,
  alu_uop,
  result_valid,
  result
);
  parameter CMP_SUPPORT = 1'b0;

//
// interface signals
//
  // ALU RS handshake signals
  input   logic                           alu_uop_valid;
  input   ALU_RS_t                        alu_uop;
  // ALU send result signals to ROB
  output  logic                           result_valid;
  output  PIPE_DATA_t                     result;

//
// internal signals
//
  // ALU_RS_t struct signals
  FUNCT6_u                                uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]             uop_funct3;
  logic                                   vm; 
  logic   [`VLEN-1:0]                     v0_data;
  logic   [`VLEN-1:0]                     vs1_data;           
  logic   [`VLEN-1:0]                     vs2_data;	        
  EEW_e                                   vs2_eew;
  logic   [`XLEN-1:0] 	                  rs1_data;        
  logic   [$clog2(`EMUL_MAX)-1:0]         uop_index;          

  // execute 
  // add and sub instructions
  logic   [`VLENB-1:0]                    v0_data_in_use;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src2_data;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src1_data;
  logic   [`VLENB-1:0]                    src2_sgn;
  logic   [`VLENB-1:0]                    src1_sgn;
  logic   [`VLENB-1:0]                    cin;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   product8;
  logic   [`VLENB-1:0]                    cout8;
  ADDSUB_e                                opcode;
  
  // for-loop
  genvar                                  j;

//
// prepare source data to calculate    
//
  // split ALU_RS_t struct
  assign  uop_funct6     = alu_uop.uop_funct6;
  assign  uop_funct3     = alu_uop.uop_funct3;
  assign  vm             = alu_uop.vm;  
  assign  v0_data        = alu_uop.v0_data;
  assign  vs1_data       = alu_uop.vs1_data;
  assign  rs1_data       = alu_uop.vs1_data[`XLEN-1:0];
  assign  vs2_data       = alu_uop.vs2_data;
  assign  vs2_eew        = alu_uop.vs2_eew;
  assign  uop_index      = alu_uop.uop_index;

//  
// prepare source data 
//
  generate
    // prepare valid signal 
    always_comb begin
      // initial the data
      result_valid = 'b0;

      if(CMP_SUPPORT) begin
        case(uop_funct3) 
          OPIVV: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VRSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VRSUB,
              VSADD,
              VSADDU,
              VADC,
              VMADC,
              VMSEQ,
              VMSNE,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
        endcase
      end
      else begin
        case(uop_funct3) 
          OPIVV: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VRSUB,
              VSADD,
              VSSUB,
              VSADDU,
              VSSUBU,
              VADC,
              VSBC,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VRSUB,
              VSADD,
              VSADDU,
              VADC: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWADD,
              VWSUBU,
              VWSUB,
              VWADDU_W,
              VWADD_W,
              VWSUBU_W,
              VWSUB_W,
              VAADDU,
              VAADD,
              VASUBU,
              VASUB: begin
                result_valid = alu_uop_valid;
              end
            endcase
          end
        endcase
      end
    end

    // prepare source data
    always_comb begin
      // initial the data
      src2_data = vs2_data;
      src1_data = vs1_data;

      if(CMP_SUPPORT) begin
        case(uop_funct3) 
          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VADC,
              VSBC,
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VSADDU,
              VSADD,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VMSGTU,
              VMSGT,
              VRSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
                
                src1_data = vs2_data;
              end
            endcase
          end

          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VADC,          
              VMADC,
              VMSEQ,
              VMSNE,
              VMSLEU,
              VMSLE,
              VSADDU,
              VSADD: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VMSGTU,
              VMSGT,
              VRSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end

                src1_data = vs2_data;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W,
              VWSUBU_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0; 
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}}; 
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =  rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W,
              VWSUBU_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;
                    end
                    EEW32: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                    end
                    EEW32: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] =              rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                    end
                  endcase
                end
              end

              VAADDU,
              VASUBU,
              VAADD,
              VASUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
            endcase
          end
        endcase
      end
      else begin
        case(uop_funct3) 
          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VSUB,
              VADC,
              VSBC,
              VSADDU,
              VSADD,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VRSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
                
                src1_data = vs2_data;
              end
            endcase
          end

          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VADD,
              VADC,          
              VSADDU,
              VSADD: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
              
              VRSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src2_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src2_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src2_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src2_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end

                src1_data = vs2_data;
              end
            endcase
          end

          OPMVV: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;

                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};

                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W,
              VWSUBU_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0;
                        src1_data[4*i+2] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = 'b0; 
                        src1_data[4*i+2] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   = vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                      else begin
                        src1_data[4*i]   = vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = 'b0;
                        src1_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}}; 
                        src1_data[4*i+2] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}}; 
                      end
                    end
                    EEW32: begin
                      if(uop_index[0]==1'b0) begin
                        src1_data[4*i]   =              vs1_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src1_data[4*i]   =              vs1_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+1] =              vs1_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src1_data[4*i+2] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src1_data[4*i+3] = {`BYTE_WIDTH{vs1_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end
            endcase
          end
          
          OPMVX: begin
            case(uop_funct6.ari_funct6)
              VWADDU,
              VWSUBU: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =  rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = 'b0;
                        src2_data[4*i+2] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   = vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                      else begin
                        src2_data[4*i]   = vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = 'b0;
                        src2_data[4*i+3] = 'b0;
                      end
                    end
                  endcase
                end
              end

              VWADD,
              VWSUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+2] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};

                      if(uop_index[0]==1'b0) begin
                        src2_data[4*i]   =              vs2_data[(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                      else begin
                        src2_data[4*i]   =              vs2_data[`VLEN/2+(2*i  )*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+1] =              vs2_data[`VLEN/2+(2*i+1)*`BYTE_WIDTH +: `BYTE_WIDTH];
                        src2_data[4*i+2] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                        src2_data[4*i+3] = {`BYTE_WIDTH{vs2_data[`VLEN/2+(2*i+2)*`BYTE_WIDTH-1]}};
                      end
                    end
                  endcase
                end
              end

              VWADDU_W,
              VWSUBU_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = 'b0;
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = 'b0;
                    end
                    EEW32: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = 'b0;
                      src1_data[4*i+3] = 'b0;
                    end
                  endcase
                end
              end

              VWADD_W,
              VWSUB_W: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW16: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                      src1_data[4*i+2] =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[`BYTE_WIDTH-1]}};
                    end
                    EEW32: begin
                      src1_data[4*i]   =              rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] =              rs1_data[`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                      src1_data[4*i+3] = {`BYTE_WIDTH{rs1_data[2*`BYTE_WIDTH-1]}};
                    end
                  endcase
                end
              end

              VAADDU,
              VASUBU,
              VAADD,
              VASUB: begin
                for(int i=0;i<`VLENW;i=i+1) begin
                  case(vs2_eew)
                    EEW8: begin
                      src1_data[4*i]   = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0 +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[0 +: `BYTE_WIDTH];
                    end
                    EEW16: begin  
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                    EEW32: begin 
                      src1_data[4*i]   = rs1_data[0             +: `BYTE_WIDTH];
                      src1_data[4*i+1] = rs1_data[1*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+2] = rs1_data[2*`BYTE_WIDTH +: `BYTE_WIDTH];
                      src1_data[4*i+3] = rs1_data[3*`BYTE_WIDTH +: `BYTE_WIDTH];
                    end
                  endcase
                end
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

  // sgn of src2 and src1
  always_comb begin
    src2_sgn = 'b0;
    src1_sgn = 'b0;

    for(int i=0;i<`VLENB;i++) begin
      src2_sgn[i] = src2_data[i][`BYTE_WIDTH-1];
      src1_sgn[i] = src1_data[i][`BYTE_WIDTH-1];
    end
  end
 
  // prepare cin
  always_comb begin
    v0_data_in_use = 'b0;

    case(vs2_eew)
      EEW8: begin
        v0_data_in_use = v0_data[{uop_index,{($clog2(`VLENB)){1'b0}}} +: `VLENB];
      end
      EEW16: begin
        v0_data_in_use = (`VLENB)'(v0_data[{uop_index,{($clog2(`VLENB/2)){1'b0}}} +: `VLENB/2]);
      end
      EEW32: begin
        v0_data_in_use = (`VLENB)'(v0_data[{uop_index,{($clog2(`VLENB/4)){1'b0}}} +: `VLENB/4]);
      end
    endcase
  end

  generate
    for (j=0;j<`VLENW;j=j+1) begin: GET_CIN
      always_comb begin
        // initial the data
        cin[4*j]   = 'b0;
        cin[4*j+1] = 'b0;
        cin[4*j+2] = 'b0;
        cin[4*j+3] = 'b0;

        if(CMP_SUPPORT) begin
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADC,
                VSBC: begin
                  case(vs2_eew)
                    EEW8: begin                    
                      cin[4*j]   = v0_data_in_use[4*j];
                      cin[4*j+1] = v0_data_in_use[4*j+1];
                      cin[4*j+2] = v0_data_in_use[4*j+2];
                      cin[4*j+3] = v0_data_in_use[4*j+3];
                    end
                    EEW16: begin
                      cin[4*j]   = v0_data_in_use[2*j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = v0_data_in_use[2*j+1];
                      cin[4*j+3] = 'b0;
                    end
                    EEW32: begin
                      cin[4*j]   = v0_data_in_use[j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = 'b0;
                      cin[4*j+3] = 'b0;
                    end
                  endcase
                end
                VMADC,
                VMSBC: begin
                  case(vs2_eew)
                    EEW8: begin                    
                      cin[4*j]   = vm ? 'b0 : v0_data_in_use[4*j];
                      cin[4*j+1] = vm ? 'b0 : v0_data_in_use[4*j+1];
                      cin[4*j+2] = vm ? 'b0 : v0_data_in_use[4*j+2];
                      cin[4*j+3] = vm ? 'b0 : v0_data_in_use[4*j+3];
                    end
                    EEW16: begin
                      cin[4*j]   = vm ? 'b0 : v0_data_in_use[2*j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = vm ? 'b0 : v0_data_in_use[2*j+1];
                      cin[4*j+3] = 'b0;
                    end
                    EEW32: begin
                      cin[4*j]   = vm ? 'b0 : v0_data_in_use[j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = 'b0;
                      cin[4*j+3] = 'b0;
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
        else begin
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADC,
                VSBC: begin
                  case(vs2_eew)
                    EEW8: begin                    
                      cin[4*j]   = v0_data_in_use[4*j];
                      cin[4*j+1] = v0_data_in_use[4*j+1];
                      cin[4*j+2] = v0_data_in_use[4*j+2];
                      cin[4*j+3] = v0_data_in_use[4*j+3];
                    end
                    EEW16: begin
                      cin[4*j]   = v0_data_in_use[2*j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = v0_data_in_use[2*j+1];
                      cin[4*j+3] = 'b0;
                    end
                    EEW32: begin
                      cin[4*j]   = v0_data_in_use[j];
                      cin[4*j+1] = 'b0;
                      cin[4*j+2] = 'b0;
                      cin[4*j+3] = 'b0;
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
      end
    end

    // get opcode for f_addsub
    always_comb begin
      // initial the data
      opcode = ADDSUB_VADD;

      if(CMP_SUPPORT) begin
        // prepare source data
        case(uop_funct3) 
          OPIVV,
          OPIVX,
          OPIVI: begin
            case(uop_funct6.ari_funct6)    
              VADD,
              VADC,
              VMADC,
              VSADDU,
              VSADD: begin
                opcode = ADDSUB_VADD;
              end

              VSUB,
              VRSUB,
              VSBC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
          OPMVV,
          OPMVX: begin
            case(uop_funct6.ari_funct6)    
              VWADDU,
              VWADD,
              VWADDU_W,
              VWADD_W,
              VAADDU,
              VAADD: begin
                opcode = ADDSUB_VADD;
              end
              VWSUBU,
              VWSUB,
              VWSUBU_W,
              VWSUB_W,
              VASUBU,
              VASUB: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
        endcase
      end
      else begin
        // prepare source data
        case(uop_funct3) 
          OPIVV,
          OPIVX,
          OPIVI: begin
            case(uop_funct6.ari_funct6)    
              VADD,
              VADC,
              VSADDU,
              VSADD: begin
                opcode = ADDSUB_VADD;
              end

              VSUB,
              VRSUB,
              VSBC,
              VSSUBU,
              VSSUB,
              VMINU,
              VMIN,
              VMAXU,
              VMAX: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
          OPMVV,
          OPMVX: begin
            case(uop_funct6.ari_funct6)    
              VWADDU,
              VWADD,
              VWADDU_W,
              VWADD_W,
              VAADDU,
              VAADD: begin
                opcode = ADDSUB_VADD;
              end
              VWSUBU,
              VWSUB,
              VWSUBU_W,
              VWSUB_W,
              VASUBU,
              VASUB: begin
                opcode = ADDSUB_VSUB;
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

//    
// calculate the result
//
`ifdef CORALNPU_STRUCTURAL_DATAPATH
  generate
    for (j = 0; j < `VLENW; j = j + 1) begin : gen_alu_p0_lane
      rvv_backend_alu_addsub_p0_datapath u_alu_p0_dp (
        .is_sub       (opcode == ADDSUB_VSUB),
        .src2_data    ({src2_data[4*j+3], src2_data[4*j+2], src2_data[4*j+1], src2_data[4*j]}),
        .src1_data    ({src1_data[4*j+3], src1_data[4*j+2], src1_data[4*j+1], src1_data[4*j]}),
        .cin          (cin[4*j +: 4]),
        .product8_out ({product8[4*j+3], product8[4*j+2], product8[4*j+1], product8[4*j]}),
        .cout8_out    (cout8[4*j +: 4])
      );
    end
  endgenerate
`else
  // for add and sub instructions
  always_comb begin
    for(int i=0;i<`VLENB;i++) begin: VADDSUB_PROD8
      if (opcode==ADDSUB_VADD) 
        {cout8[i],product8[i]} = (`BYTE_WIDTH+1)'(src2_data[i]) + (`BYTE_WIDTH+1)'(src1_data[i]) + cin[i];
      else //(opcode==ADDSUB_VSUB)
        {cout8[i],product8[i]} = (`BYTE_WIDTH+1)'(src2_data[i]) - (`BYTE_WIDTH+1)'(src1_data[i]) - cin[i];      
    end
  end

`endif
//
// submit result to ROB
//
  `ifdef TB_SUPPORT
    assign result.uop_pc          = alu_uop.uop_pc;
  `endif
    assign result.rob_entry       = alu_uop.rob_entry;
    assign result.opcode          = opcode;
    assign result.uop_funct6      = alu_uop.uop_funct6;
    assign result.uop_funct3      = alu_uop.uop_funct3;
    assign result.is_addsub       = 'b1;
    assign result.is_cmp          = alu_uop.is_cmp;
    assign result.vstart          = alu_uop.vstart;
    assign result.vl              = alu_uop.vl;
    assign result.vm              = alu_uop.vm;
    assign result.vxrm            = alu_uop.vxrm;
    assign result.vs2_eew         = alu_uop.vs2_eew;
    assign result.w_valid         = 'b0;
    assign result.src2_sgn        = src2_sgn;
    assign result.src1_sgn        = src1_sgn;
    assign result.last_uop_valid  = alu_uop.last_uop_valid;
    assign result.uop_index       = alu_uop.uop_index;
    assign result.w_data          = product8;
    assign result.vsat_cout.cout  = cout8;
    
    always_comb begin
      result.v0_src2.v0 = v0_data;
      result.vd_src1.vd = alu_uop.vd_data;

      case(uop_funct3) 
        OPIVV,
        OPIVX: begin
          case(uop_funct6.ari_funct6)
            VMINU,
            VMIN,
            VMAXU,
            VMAX: begin
              result.v0_src2.src2 = src2_data;
              result.vd_src1.src1 = src1_data;
            end
          endcase
        end
      endcase
    end

endmodule
