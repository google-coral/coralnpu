
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

// TODO: tail uops

module rvv_backend_decode_unit_ari_de2
(
  lcmd_valid,
  lcmd,
  uop_index_remain,
  uop_valid,
  uop
);
//
// interface signals
//
  input   logic                               lcmd_valid;
  input   LCMD_t                              lcmd;

  input   logic       [`UOP_INDEX_WIDTH-1:0]  uop_index_remain;
  output  logic       [`NUM_DE_UOP-1:0]       uop_valid;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0]       uop;

//
// internal signals
//
  // split INST_t struct signals
  logic   [`FUNCT6_WIDTH-1:0]                 inst_funct6;      // inst original encoding[31:26]  
  logic   [`VM_WIDTH-1:0]                     inst_vm;          // inst original encoding[25]      
  logic   [`REGIDX_WIDTH-1:0]                 inst_vs2;         // inst original encoding[24:20]
  logic   [`REGIDX_WIDTH-1:0]                 inst_vs1;         // inst original encoding[19:15]
  logic   [`IMM_WIDTH-1:0]                    inst_imm;         // inst original encoding[19:15]
  logic   [`FUNCT3_WIDTH-1:0]                 inst_funct3;      // inst original encoding[14:12]
  logic   [`REGIDX_WIDTH-1:0]                 inst_vd;          // inst original encoding[11:7]
  logic   [`REGIDX_WIDTH-1:0]                 inst_rd;          // inst original encoding[11:7]
  logic   [`UOP_INDEX_WIDTH-1:0]              uop_vstart;         
  logic   [`XLEN-1:0]                         rs1;
  logic   [`REGIDX_WIDTH-1:0]                 vs1_opcode;
  logic   [`REGIDX_WIDTH-1:0]                 vs2_opcode;
  RVVConfigState                              vector_csr_ari;
  logic   [`VSTART_WIDTH-1:0]                 csr_vstart;
  logic   [`UOP_INDEX_WIDTH-1:0]              uop_index_max;         
  EMUL_e                                      emul_vd;          
  EMUL_e                                      emul_vs2;          
  EMUL_e                                      emul_vs1;          
  EMUL_e                                      emul_max; 
  EEW_e                                       eew_max; 

`ifdef TB_SUPPORT
  logic   [`NUM_DE_UOP-1:0]                   res_updating_end;
`endif
  logic                                       valid_opi;
  logic                                       valid_opm;
`ifdef ZVE32F_ON
  logic                                       valid_opf;
`endif
  logic   [`UOP_INDEX_WIDTH-1:0]                      uop_index_base;         
  logic   [`NUM_DE_UOP-1:0][`UOP_INDEX_WIDTH:0]       uop_index_current;   
  logic   [`NUM_DE_UOP-1:0]                           first_uop_valid;    
  logic   [`NUM_DE_UOP-1:0]                           last_uop_valid; 
  EXE_UNIT_e                                          uop_exe_unit; 
  UOP_CLASS_e     [`NUM_DE_UOP-1:0]                   uop_class;   
  RVVConfigState  [`NUM_DE_UOP-1:0]                   vector_csr; 
  logic                                               ignore_vma;
  logic                                               ignore_vta;  
  logic   [`NUM_DE_UOP-1:0]                           v0_valid;           
  logic   [`NUM_DE_UOP-1:0][`REGIDX_WIDTH-1:0]        vd_index;           
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vd_offset;
  logic   [`NUM_DE_UOP-1:0]                           vd_valid;
  logic   [`NUM_DE_UOP-1:0]                           vs3_valid;          
  logic   [`NUM_DE_UOP-1:0][`REGIDX_WIDTH-1:0]        vs1;              
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vs1_offset;
  logic   [`NUM_DE_UOP-1:0]                           vs1_valid;
  logic   [`NUM_DE_UOP-1:0][`REGIDX_WIDTH-1:0]        vs2_index; 	        
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    vs2_offset;
  logic   [`NUM_DE_UOP-1:0]                           vs2_valid;
  logic                                               xd_valid; 
`ifdef ZVE32F_ON
  logic                                               fd_valid; 
`endif
`ifdef ZVT_ON
  logic                                               mt_valid; 
`endif
  logic   [`XLEN-1:0] 	                              rs1_data;           
  logic        	                                      rs1_data_valid;     
  logic   [`NUM_DE_UOP-1:0][`UOP_INDEX_WIDTH-1:0]     uop_index;          
  logic   [`NUM_DE_UOP-1:0][$clog2(`EMUL_MAX)-1:0]    seg_field_index;
  logic   [`NUM_DE_UOP-1:0]                           pshrob_valid;  
  genvar                                              j;

//
// decode
//
  assign inst_funct6    = lcmd_valid ? lcmd.cmd.bits[24:19] : 'b0;
  assign inst_vm        = lcmd_valid ? lcmd.cmd.bits[18] : 'b0;
  assign inst_vs2       = lcmd_valid ? lcmd.cmd.bits[17:13] : 'b0;
  assign vs2_opcode     = lcmd_valid ? lcmd.cmd.bits[17:13] : 'b0;
  assign inst_vs1       = lcmd_valid ? lcmd.cmd.bits[12:8] : 'b0;
  assign vs1_opcode     = lcmd_valid ? lcmd.cmd.bits[12:8] : 'b0;
  assign inst_imm       = lcmd_valid ? lcmd.cmd.bits[12:8] : 'b0;
  assign inst_funct3    = lcmd_valid ? lcmd.cmd.bits[7:5] : 'b0;
  assign inst_vd        = lcmd_valid ? lcmd.cmd.bits[4:0] : 'b0;
  assign inst_rd        = lcmd_valid ? lcmd.cmd.bits[4:0] : 'b0;
  assign vector_csr_ari = lcmd_valid ? lcmd.cmd.arch_state : 'b0;
  assign csr_vstart     = lcmd_valid ? lcmd.cmd.arch_state.vstart : 'b0;
  assign rs1            = lcmd_valid ? lcmd.cmd.rs1 : 'b0;
  assign uop_vstart     = lcmd_valid ? lcmd.uop_vstart : 'b0;
  assign uop_index_max  = lcmd_valid ? lcmd.uop_index_max : 'b0;
  assign emul_vd        = lcmd_valid ? lcmd.emul_vd : EMUL_NONE; 
  assign emul_vs2       = lcmd_valid ? lcmd.emul_vs2 : EMUL_NONE;
  assign emul_vs1       = lcmd_valid ? lcmd.emul_vs1 : EMUL_NONE;
  assign emul_max       = lcmd_valid ? lcmd.emul_max : EMUL_NONE;
  assign eew_max        = lcmd_valid ? lcmd.eew_max : EEW_NONE;

  always_comb begin
    // initial the data
    valid_opi = 'b0;
    valid_opm = 'b0;
    `ifdef ZVE32F_ON
    valid_opf = 'b0;
    `endif    

    case(inst_funct3)
      OPIVV,
      OPIVX,
      OPIVI: valid_opi = lcmd_valid;
      OPMVV,
      OPMVX: valid_opm = lcmd_valid;
    `ifdef ZVE32F_ON
      OPFVV,
      OPFVF: valid_opf = lcmd_valid;
    `endif    
    endcase
  end 

//
// split instruction to uops
//
  // select uop_vstart and uop_index_remain as the base uop_index
  always_comb begin
    // initial
    uop_index_base = (|uop_index_remain) ? uop_index_remain : uop_vstart;

    case(1'b1)
      valid_opi: begin
        case(inst_funct6)
          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin
            uop_index_base = uop_index_remain;
          end
        endcase
      end

      valid_opm: begin
        case(inst_funct6)
          VSLIDE1UP: begin
            uop_index_base = uop_index_remain;
          end
        endcase
      end

    `ifdef ZVE32F_ON
      valid_opf: begin
        case(inst_funct6)
          VFSLIDE1UP: begin
            uop_index_base = uop_index_remain;
          end
        endcase
      end
    `endif
    endcase
  end

  // calculate the uop_index used in decoding uops 
  generate
    for(j=0;j<`NUM_DE_UOP;j++) begin: GET_UOP_INDEX
      assign uop_index_current[j] = {1'b0, uop_index_base} + j[`UOP_INDEX_WIDTH:0];
    end
  endgenerate

  // generate uop valid
  always_comb begin        
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_VALID
      uop_valid[i] = lcmd_valid & ({1'b1, uop_index_base} <= ({1'b1,uop_index_max}-i[`UOP_INDEX_WIDTH:0]));
    end
  end

  // update first_uop valid
  always_comb begin
    // initial 
    first_uop_valid = 'b0;
    
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_FIRST
      first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == uop_vstart;

      case(1'b1)
        valid_opi: begin
          case(inst_funct6)
            VSLIDEUP_RGATHEREI16,
            VRGATHER: begin
              first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == 'b0;
            end
          endcase
        end
        valid_opm: begin
          case(inst_funct6)
            VSLIDE1UP: begin
              first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == 'b0;
            end
          endcase
        end
      `ifdef ZVE32F_ON
        valid_opf: begin
          case(inst_funct6)
            VFSLIDE1UP: begin
              first_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == 'b0;
            end
          endcase
        end
      `endif
      endcase
    end
  end

  // update last_uop valid
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_LAST
      last_uop_valid[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0] == uop_index_max;
    end
  end

  // allocate uop to execution unit
  always_comb begin
    // initial
    uop_exe_unit = VEU_ALU;
    
    case(1'b1)
      valid_opi: begin
        // allocate OPI* uop to execution unit
        case(inst_funct6)
          VADD,
          VSUB,
          VRSUB,
          VADC,
          VSBC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VNSRL,
          VNSRA,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VMERGE_VMV,
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSSRL,
          VSSRA,
          VNCLIPU,
          VNCLIP: begin
            uop_exe_unit = VEU_ALU;
          end 
          
          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLTU,
          VMSLT,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT:begin
            uop_exe_unit = VEU_CMP;
          end
          
          VWREDSUMU,
          VWREDSUM: begin
            uop_exe_unit = VEU_RDT;
          end

          VSLIDEUP_RGATHEREI16,
          VSLIDEDOWN,
          VRGATHER: begin
            uop_exe_unit = VEU_PMT;
          end

          VSMUL_VMVNRR: begin
            uop_exe_unit = (inst_funct3==OPIVI) ? VEU_ALU : VEU_MUL;
          end

        `ifdef ZVT_ON
          VTXMMXTVV: begin
            uop_exe_unit = VME;
          end
        `endif
        endcase
      end

      valid_opm: begin
        // allocate OPM* uop to execution unit
        case(inst_funct6)
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W,
          VXUNARY0,
          VAADDU,
          VAADD,
          VASUBU,
          VASUB,
          VMAND,
          VMNAND,
          VMANDN,
          VMXOR,
          VMOR,
          VMNOR,
          VMORN,
          VMXNOR: begin
            uop_exe_unit = VEU_ALU;
          end

          VMUL,
          VMULH,
          VMULHU,
          VMULHSU,
          VWMUL,
          VWMULU,
          VWMULSU: begin
            uop_exe_unit = VEU_MUL;
          end

          VDIVU,
          VDIV,
          VREMU,
          VREM: begin
            uop_exe_unit = VEU_DIV;
          end
          
          VMACC,
          VNMSAC,
          VMADD,
          VNMSUB,
          VWMACCU,
          VWMACC,
          VWMACCSU,
          VWMACCUS: begin
            uop_exe_unit = VEU_MAC;
          end

          // reduction
          VREDSUM,
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN,
          VREDAND,
          VREDOR,
          VREDXOR: begin
            uop_exe_unit = VEU_RDT;
          end

          VWRXUNARY0: begin
            if(inst_funct3==OPMVV)
              uop_exe_unit = (vs1_opcode==VCPOP) ? VEU_MISC : VEU_ALU;
            else begin
              case(vs2_opcode)
                VMV_S_X: uop_exe_unit = VEU_ALU;
              `ifdef ZVT_ON
                VTMVVT,
                VTZERO:  uop_exe_unit = VME;
              `endif
              endcase
            end
          end
          
          VMUNARY0: begin
            uop_exe_unit = (vs1_opcode==VIOTA) ? VEU_MISC : VEU_ALU;
          end

          VSLIDE1UP,
          VSLIDE1DOWN: begin
            uop_exe_unit = VEU_PMT;
          end

          VCOMPRESS_VTMVTV: begin
            if(inst_funct3==OPMVV)
              uop_exe_unit = VEU_PMT;
            `ifdef ZVT_ON
            else // vtmv.t.v
              uop_exe_unit = VME;
            `endif
          end
        endcase
      end

      `ifdef ZVE32F_ON
      valid_opf: begin
        // allocate OPF* uop to execution unit
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16,
          `endif
          VFADD,
          VFSUB,      
          VFRSUB,     
          VFMUL,      
          VFMACC,     
          VFNMACC,    
          VFMSAC,     
          VFNMSAC,    
          VFMADD,     
          VFNMADD,    
          VFMSUB,     
          VFNMSUB: begin
            uop_exe_unit = VEU_FMA;
          end

          VFDIV,      
          VFRDIV: begin
            uop_exe_unit = VEU_FDIV;
          end

          VFUNARY1: begin
            case(vs1_opcode)
              VFSQRT: begin
                uop_exe_unit = VEU_FDIV;
              end
              VFRSQRT7,
              VFREC7: begin
                uop_exe_unit = VEU_FTBL;
              end
              VFCLASS: begin
                uop_exe_unit = VEU_FNCMP;
              end
            endcase
          end

          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX: begin
            uop_exe_unit = VEU_FNCMP;
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE: begin
            uop_exe_unit = VEU_FCMP;
          end

          VFMERGE_VFMV,
          VWRFUNARY0: begin
            uop_exe_unit = VEU_ALU;
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16,
              VFWCVTBF16,
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV,
              VFWCVTFXU, 
              VFWCVTFX,
              VFNCVTXUF,
              VFNCVTXF,
              VFNCVTRTZXUF,
              VFNCVTRTZXF: begin
                uop_exe_unit = VEU_FCVT;
              end
            endcase
          end

          VFREDOSUM,
          VFREDUSUM,
          VFREDMAX,
          VFREDMIN: begin
            uop_exe_unit = VEU_FRDT;
          end

          VFSLIDE1UP,
          VFSLIDE1DOWN: begin
            uop_exe_unit = VEU_PMT;
          end

        `ifdef ZVT_ON
          VTXMMXTVV: begin
            uop_exe_unit = VME;
          end
        `endif
        endcase
      end
      `endif  
    endcase
  end

  // update uop class
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_CLASS
      // initial 
      uop_class[i] = XXX;
      
      case(1'b1)
        valid_opi: begin
          // OPI*
          case(inst_funct6)
            VADD,
            VSUB,
            VRSUB,
            VADC,
            VSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VNSRL,
            VNSRA,
            VMINU,
            VMIN,
            VMAXU,
            VMAX,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VNCLIPU,
            VNCLIP: begin
              if(inst_funct3==OPIVV)
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VWREDSUMU,
            VWREDSUM: begin
              if(first_uop_valid[i])
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VMADC,
            VMSBC,
            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMSGTU,
            VMSGT: begin
              if(last_uop_valid[i])
                uop_class[i] = inst_funct3==OPIVV ? VVV : VVX;
              else
                uop_class[i] = inst_funct3==OPIVV ? XVV : XVX;
            end

            VMERGE_VMV: begin
              if(inst_funct3==OPIVV)
                uop_class[i] = inst_vm ? XXV : XVV;
              else
                uop_class[i] = inst_vm ? XXX : XVX;
            end

            VSLIDEUP_RGATHEREI16,
            VSLIDEDOWN,
            VRGATHER: begin
              if(inst_funct3==OPIVV)
                uop_class[i] = XXV;
              else   
                uop_class[i] = XXX;
            end

          `ifdef ZVT_ON
            VTXMMXTVV: begin
              uop_class[i] = XVV;
            end
          `endif
          endcase
        end

        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VWMUL,
            VWMULU,
            VWMULSU,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB: begin
              if(inst_funct3==OPMVV)
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            // reduction
            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR: begin
              if(first_uop_valid[i])
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VSLIDE1UP,
            VSLIDE1DOWN: begin
                uop_class[i] = XXX;
            end 
            
            VXUNARY0: begin
              uop_class[i]  = XVX;
            end

            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VWMACCUS: begin
              if(inst_funct3==OPMVV)
                uop_class[i] = VVV;
              else
                uop_class[i] = VVX;
            end

            // permutation
            VCOMPRESS_VTMVTV: begin
              if(inst_funct3==OPMVV)
                uop_class[i] = first_uop_valid[i] ? XXV : XXX;
              `ifdef ZVT_ON
              else  // vtmv.t.v
                uop_class[i] = XVX;
              `endif
            end

            // mask
            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin
              uop_class[i] = (csr_vstart=='b0) ? XVV : VVV;
            end

            VWRXUNARY0: begin
              if(inst_funct3==OPMVV)
                uop_class[i] = XVX;
              else
                uop_class[i] = XXX;
            end

            VMUNARY0: begin
              case(vs1_opcode)
                VMSBF,
                VMSIF,
                VMSOF: begin
                  uop_class[i] = inst_vm ? XVX: VVX;
                end
                VIOTA: begin
                  uop_class[i] = first_uop_valid[i] ? XVX : XXX;
                end
                VID: begin
                  uop_class[i] = XXX;
                end
              endcase
            end
          endcase
        end

        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* instruction
          case(inst_funct6)
            VFADD,          
            VFSUB,      
            VFRSUB,
            VFMUL,      
            VFDIV,      
            VFRDIV,     
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VFSLIDE1UP,
            VFSLIDE1DOWN: begin
              if(inst_funct3==OPFVV)
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end 

            `ifdef ZVFBFWMA_ON
            VFWMACCBF16,
            `endif
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB:begin
              if(inst_funct3==OPFVV)
                uop_class[i] = VVV;
              else
                uop_class[i] = VVX;
            end

            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              if(first_uop_valid[i])
                uop_class[i] = XVV;
              else
                uop_class[i] = XVX;
            end

            VFUNARY0,
            VFUNARY1: begin
              uop_class[i] = XVX;
            end

            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              if(last_uop_valid[i]) 
                uop_class[i] = inst_funct3==OPFVV ? VVV : VVX;
              else
                uop_class[i] = inst_funct3==OPFVV ? XVV : XVX;
            end

            VFMERGE_VFMV: begin
              if(inst_vm)
                uop_class[i] = XXX;
              else
                uop_class[i] = XVX;
            end

            VWRFUNARY0: begin
              if(inst_funct3==OPFVV)
                uop_class[i] = XVX;
              else
                uop_class[i] = XXX;
            end

          `ifdef ZVT_ON
            VTXMMXTVV: begin
              uop_class[i] = XVV;
            end
          `endif
          endcase
        end
        `endif
      endcase
    end
  end

  // update vector_csr and vstart
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_VCSR
      vector_csr[i] = vector_csr_ari;

      // update vstart of every uop
      if(uop_index_current[i]>{1'b0,uop_vstart}) begin
        case(1'b1)
          valid_opi: begin
            // OPI*
            case(inst_funct6)
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
              VWREDSUMU,
              VWREDSUM: begin
                vector_csr[i].vstart = vector_csr_ari.vstart;
              end
              default: begin 
                case(eew_max)
                  EEW8: begin
                    vector_csr[i].vstart  = {uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLENB)){1'b0}}};
                  end
                  EEW16: begin
                    vector_csr[i].vstart  = {1'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`HWORD_WIDTH)){1'b0}}};
                  end
                  EEW32: begin
                    vector_csr[i].vstart  = {2'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`WORD_WIDTH)){1'b0}}};
                  end
                endcase
              end
            endcase
          end
          valid_opm: begin
            // OPM*
            case(inst_funct6)
              VREDSUM,
              VREDMAXU,
              VREDMAX,
              VREDMINU,
              VREDMIN,
              VREDAND,
              VREDOR,
              VREDXOR,
              VCOMPRESS_VTMVTV: begin
                vector_csr[i].vstart = vector_csr_ari.vstart;
              end
              default: begin 
                case(eew_max)
                  EEW8: begin
                    vector_csr[i].vstart  = {uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLENB)){1'b0}}};
                  end
                  EEW16: begin
                    vector_csr[i].vstart  = {1'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`HWORD_WIDTH)){1'b0}}};
                  end
                  EEW32: begin
                    vector_csr[i].vstart  = {2'b0,uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0],{($clog2(`VLEN/`WORD_WIDTH)){1'b0}}};
                  end
                endcase
              end
            endcase
          end

          `ifdef ZVE32F_ON
          valid_opf: begin
            // OPF* instruction
            case(inst_funct6)
              VMFEQ,
              VMFNE,
              VMFLT,
              VMFLE,
              VMFGT,
              VMFGE,
              VFREDOSUM,
              VFREDUSUM,
              VFREDMAX,
              VFREDMIN: begin
                vector_csr[i].vstart = vector_csr_ari.vstart;
              end
              default: begin 
                case(eew_max)
                  EEW8: begin
                    vector_csr[i].vstart  = {uop_index_current[i][`UOP_INDEX_WIDTH-1:0],{($clog2(`VLENB)){1'b0}}};
                  end
                  EEW16: begin
                    vector_csr[i].vstart  = {1'b0,uop_index_current[i][`UOP_INDEX_WIDTH-1:0],{($clog2(`VLEN/`HWORD_WIDTH)){1'b0}}};
                  end
                  EEW32: begin
                    vector_csr[i].vstart  = {2'b0,uop_index_current[i][`UOP_INDEX_WIDTH-1:0],{($clog2(`VLEN/`WORD_WIDTH)){1'b0}}};
                  end
                endcase
              end
            endcase
          end
          `endif
        endcase
      end
    end
  end

  // update ignore_vma and ignore_vta
  // some instructions use vm as an extra opcode, so it needs ignore vma policy.
  // the instructions whose EEW_vd=1b can write the result to TAIL elements, so it needs ignore vta policy.
  always_comb begin
    // initial 
    ignore_vma = 'b0;
    ignore_vta = 'b0;
      
    case(inst_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(inst_funct6)
          VADC,
          VSBC: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b0;
          end
          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLTU,
          VMSLT,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b1;
          end
          VMERGE_VMV: begin
            if (inst_vm=='b0) begin
              ignore_vma = 1'b1;
            end
          end
        endcase
      end

      OPMVV: begin
        case(inst_funct6)
          VMANDN,
          VMAND,
          VMOR,
          VMXOR,
          VMORN,
          VMNAND,
          VMNOR,
          VMXNOR: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b1;
          end
          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSOF,
              VMSIF: begin
                ignore_vma = 1'b1;
                ignore_vta = 1'b1;
              end
            endcase
          end
        endcase
      end

    `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b1;
          end
          VWRFUNARY0: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b0;
          end
        endcase
      end
      OPFVF: begin
        case(inst_funct6)
          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b1;
          end
          VFMERGE_VFMV,
          VWRFUNARY0: begin
            ignore_vma = 1'b1;
            ignore_vta = 1'b0;
          end
        endcase
      end
    `endif
    endcase
  end
  
  // some uop need v0 as the vector operand
  always_comb begin
    // initial 
    v0_valid = 'b0;
       
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_UOP_V0
      case(1'b1)
        valid_opi: begin
          // OPI*
          case(inst_funct6)
            VADC,
            VMADC,
            VSBC,
            VMSBC,
            VMERGE_VMV: begin
              v0_valid[i] = !inst_vm;
            end

            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMSGTU,
            VMSGT: begin
              v0_valid[i] = inst_vm ? 'b0 : last_uop_valid[i]; 
            end
          endcase
        end
        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VWRXUNARY0: begin
              case(vs1_opcode)
                VCPOP,
                VFIRST: begin
                  v0_valid[i] = !inst_vm;
                end
              endcase
            end
            VMUNARY0: begin
              case(vs1_opcode)
                VMSBF,
                VMSOF,
                VMSIF,
                VIOTA: begin
                  v0_valid[i] = !inst_vm;
                end
              endcase
            end
          endcase
        end
        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* instruction
          case(inst_funct6)
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              v0_valid[i] = inst_vm ? 'b0 : last_uop_valid[i]; 
            end
            VFMERGE_VFMV: begin
              v0_valid[i] = !inst_vm;
            end
          endcase
        end
        `endif        
      endcase
    end
  end    
  
  // update vd_offset and valid
  always_comb begin
    vd_offset        = 'b0;
    vd_valid         = 'b0;
  `ifdef TB_SUPPORT
    res_updating_end = '1;
  `endif

    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VD_OFFSET  
      case(1'b1)
        valid_opi: begin
          case(inst_funct6)
            VADD,
            VSUB,
            VRSUB,
            VADC,
            VSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VMINU,
            VMIN,
            VMAXU,
            VMAX,
            VMERGE_VMV,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VSLIDEDOWN,
            VRGATHER: begin
              vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vd_valid[i]  = 1'b1;
            end

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
            VWREDSUMU,
            VWREDSUM: begin
              vd_offset[i] = 'b0;
              vd_valid[i]  = last_uop_valid[i];
            end

            VNSRL,
            VNSRA,
            VNCLIPU,
            VNCLIP: begin
              vd_offset[i]        = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vd_valid[i]         = 1'b1;
            `ifdef TB_SUPPORT
              res_updating_end[i] = (emul_max==EMUL1) || (uop_index_max=='b0) || uop_index_current[i][0];              
            `endif
            end

            VSLIDEUP_RGATHEREI16: begin
              case(inst_funct3)
                OPIVV: begin
                  case({emul_max,emul_vd})
                    {EMUL1,EMUL1},
                    {EMUL2,EMUL2},
                    {EMUL4,EMUL4},
                    {EMUL8,EMUL8}: begin
                      vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                      vd_valid[i]  = 1'b1;
                    end
                    {EMUL2,EMUL1},
                    {EMUL4,EMUL2},
                    {EMUL8,EMUL4}: begin
                      vd_offset[i]        = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                      vd_valid[i]         = 1'b1;                    
                    `ifdef TB_SUPPORT
                      res_updating_end[i] = uop_index_current[i][0];              
                    `endif
                    end
                  endcase
                end
                OPIVX,
                OPIVI: begin  
                  vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vd_valid[i]  = 1'b1;
                end 
              endcase
            end
          endcase
        end

        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VXUNARY0,
            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VWMUL,
            VWMULU,
            VWMULSU,
            VWMACCUS,
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB,
            VSLIDE1UP,
            VSLIDE1DOWN,
            VCOMPRESS_VTMVTV: begin
              vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vd_valid[i]  = 1'b1;
            end   

            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR: begin
              vd_offset[i] = 'b0;
              vd_valid[i]  = last_uop_valid[i];
            end
             
            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin
              vd_offset[i] = 'b0;
              vd_valid[i]  = 1'b1;
            end

            VWRXUNARY0: begin
              case(inst_funct3)
                OPMVX: begin
                  case(vs2_opcode)
                    VMV_S_X: begin
                      vd_offset[i] = 'b0;
                      vd_valid[i]  = 1'b1;
                    end
                  `ifdef ZVT_ON
                    VTMVVT: begin
                      vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                      vd_valid[i]  = inst_vs2[0]; 
                    end   
                  `endif
                  endcase
                end
              endcase
            end
         
            VMUNARY0: begin
              case(vs1_opcode)
                VMSBF,
                VMSIF,
                VMSOF: begin
                  vd_offset[i] = 'b0;
                  vd_valid[i]  = 1'b1;
                end
                VIOTA,
                VID: begin
                  vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vd_valid[i]  = 1'b1;
                end
              endcase
            end
          endcase
        end

        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* instruction
          case(inst_funct6)
            `ifdef ZVFBFWMA_ON
            VFWMACCBF16,
            `endif
            VFADD,  
            VFSUB,      
            VFRSUB,     
            VFMUL,      
            VFDIV,      
            VFRDIV,     
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB,    
            VFUNARY1,
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VFMERGE_VFMV,
            VFSLIDE1UP,
            VFSLIDE1DOWN: begin
              vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vd_valid[i]  = 1'b1;
            end

            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE,
            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              vd_offset[i] = 'b0;
              vd_valid[i]  = last_uop_valid[i];
            end

            VFUNARY0: begin
              case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
                VFWCVTBF16,
              `endif
                VFCVT_XUFV, 
                VFCVT_XFV,
                VFCVT_RTZXUFV,
                VFCVT_RTZXFV,
                VFCVT_FXUV,
                VFCVT_FXV,
                VFWCVTFXU, 
                VFWCVTFX: begin
                  vd_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vd_valid[i]  = 1'b1;
                end
              `ifdef ZVFBFWMA_ON
                VFNCVTBF16,
              `endif
                VFNCVTXUF,
                VFNCVTXF,
                VFNCVTRTZXUF,
                VFNCVTRTZXF: begin
                  vd_offset[i]        = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                  vd_valid[i]         = 1'b1;
                `ifdef TB_SUPPORT
                  res_updating_end[i] = (emul_max==EMUL1) || (uop_index_max=='b0) || uop_index_current[i][0];              
                `endif
                end
              endcase              
            end

            VWRFUNARY0: begin
              case(inst_funct3)
                OPFVF: begin
                  vd_offset[i] = 'b0;
                  vd_valid[i]  = 1'b1;
                end
              endcase
            end
          endcase
        end
        `endif        
      endcase
    end
  end

  // update vd_index and eew 
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VD_OFFSET
      vd_index[i] = inst_vd + {2'b0, vd_offset[i]};
    end
  end

  // some uop need vd as the vs3 vector operand
  always_comb begin
    // initial
    vs3_valid = 'b0;

    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS3_VALID
      case(1'b1)
        valid_opi: begin
          // OPI*
          case(inst_funct6)
            VMADC,
            VMSBC,
            VMSEQ,
            VMSNE,
            VMSLEU,
            VMSLE,
            VMSLTU,
            VMSLT,
            VMSGTU,
            VMSGT: begin
              vs3_valid[i] = last_uop_valid[i];
            end
          endcase
        end

        valid_opm: begin
          // OPM*
          case(inst_funct6)
            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR : begin
              vs3_valid[i] = (csr_vstart!='b0);
            end
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VWMACCUS: begin
              vs3_valid[i] = 1'b1;
            end
            VMUNARY0: begin
              case(inst_funct3)
                OPMVV: begin
                  case(vs1_opcode)
                    VMSBF,
                    VMSIF,
                    VMSOF: begin
                      vs3_valid[i] = (inst_vm==1'b0);
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
        `ifdef ZVE32F_ON
        valid_opf: begin
          // OPF* instruction
          case(inst_funct6)
          `ifdef ZVFBFWMA_ON
            VFWMACCBF16,
          `endif
            VFMACC,
            VFNMACC,
            VFMSAC,
            VFNMSAC,
            VFMADD,
            VFNMADD,
            VFMSUB,
            VFNMSUB: begin
              vs3_valid[i] = 1'b1;
            end
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              vs3_valid[i] = last_uop_valid[i];
            end
          endcase
        end
        `endif      
      endcase
    end
  end
  
  // update vs1_offset and valid
  always_comb begin
    vs1_offset = 'b0; 
    vs1_valid  = 'b0;
      
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS1_OFFSET
      case(inst_funct3)
        OPIVV: begin
          case(inst_funct6)
            VADD,
            VSUB,
            VADC,
            VMADC,
            VSBC,
            VMSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VMSEQ,
            VMSNE,
            VMSLTU,
            VMSLT,
            VMSLEU,
            VMSLE,
            VMINU,
            VMIN,
            VMAXU,
            VMAX,
            VMERGE_VMV,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VRGATHER: begin
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = 1'b1;   
            end
            
            VNSRL,
            VNSRA,
            VNCLIPU,
            VNCLIP: begin
              vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs1_valid[i]  = 1'b1;
            end
            
            VWREDSUMU,
            VWREDSUM: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];
            end        
            
            VSLIDEUP_RGATHEREI16: begin
              case({emul_max,emul_vs1})
                {EMUL1,EMUL1},
                {EMUL2,EMUL2},
                {EMUL4,EMUL4},
                {EMUL8,EMUL8}: begin
                  vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vs1_valid[i]  = 1'b1;
                end
                {EMUL2,EMUL1},
                {EMUL4,EMUL2},
                {EMUL8,EMUL4}: begin              
                  vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                  vs1_valid[i]  = 1'b1;
                end
              endcase
            end

          `ifdef ZVT_ON
            VTXMMXTVV: begin
              case(lcmd.eew_vs1)
                EEW8: begin
                  vs1_offset[i] = {uop_index_current[i][`UOP_INDEX_WIDTH_ALU-2:0], 1'b0};
                end
              `ifdef ZVTI16I32_ON
                EEW16: begin
                  vs1_offset[i] = {uop_index_current[i][1], 1'b0, uop_index_current[i][0]};
                end
              `endif
              endcase
              vs1_valid[i]  = 1'b1;
            end
          `endif
          endcase
        end

        OPMVV: begin
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VWMUL,
            VWMULU,
            VWMULSU,
            VWMACCU,
            VWMACC,
            VWMACCSU: begin
              vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs1_valid[i]  = 1'b1;        
            end

            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB: begin
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = 1'b1;        
            end

            // reduction
            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];
            end

            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = 1'b1;
            end

            VCOMPRESS_VTMVTV: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];        
            end
          endcase
        end
        
        `ifdef ZVE32F_ON
        OPFVV: begin
          case(inst_funct6)
            `ifdef ZVFBFWMA_ON
            VFWMACCBF16: begin
              vs1_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs1_valid[i]  = 1'b1;        
            end

            `endif
            VFADD,          
            VFSUB,      
            VFMUL,      
            VFDIV,      
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB,    
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE: begin
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = 1'b1;        
            end

            VFMERGE_VFMV: begin
              vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs1_valid[i]  = !inst_vm;        
            end

            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              vs1_offset[i] = 'b0;
              vs1_valid[i]  = first_uop_valid[i];
            end

          `ifdef ZVT_ON
            VTXMMXTVV: begin
              case(lcmd.eew_vs1)
                EEW16: begin
                  vs1_offset[i] = {uop_index_current[i][1], 1'b0, uop_index_current[i][0]};
                end
                EEW32: begin
                  vs1_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                end
              endcase
              vs1_valid[i]  = 1'b1;
            end
          `endif
          endcase
        end
        `endif
      endcase
    end
  end

  // update vs1(index or opcode) and eew
  always_comb begin 
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS1
      vs1[i] = inst_vs1 + {2'b0, vs1_offset[i]}; 
    end
  end

  // update vs2 offset and valid  
  always_comb begin
    // initial
    vs2_offset = 'b0; 
    vs2_valid = 'b0; 
      
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS2_OFFSET
      case(1'b1)
        valid_opi: begin
          // OPI*
          case(inst_funct6)
            VADD,
            VSUB,
            VRSUB,
            VADC,
            VSBC,
            VMADC,
            VMSBC,
            VAND,
            VOR,
            VXOR,
            VSLL,
            VSRL,
            VSRA,
            VNSRL,
            VNSRA,
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
            VMAX,
            VSADDU,
            VSADD,
            VSSUBU,
            VSSUB,
            VSMUL_VMVNRR,
            VSSRL,
            VSSRA,
            VNCLIPU,
            VNCLIP,
            VWREDSUMU,
            VWREDSUM: begin
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;
            end

            VMERGE_VMV: begin
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = !inst_vm;
            end

          `ifdef ZVT_ON
            VTXMMXTVV: begin
              case(lcmd.eew_vs2)
                EEW8: begin
                  vs2_offset[i] = {uop_index_current[i][`UOP_INDEX_WIDTH_ALU-2:0], 1'b0};
                end
              `ifdef ZVTI16I32_ON
                EEW16: begin
                  vs2_offset[i] = {uop_index_current[i][1], 1'b0, uop_index_current[i][0]};
                end
              `endif
              endcase
              vs2_valid[i]  = 1'b1;
            end
          `endif
          endcase
        end

        valid_opm: begin
          // OPM* 
          case(inst_funct6)
            VWADDU,
            VWSUBU,
            VWADD,
            VWSUB,
            VWMUL,
            VWMULU,
            VWMULSU,
            VWMACCU,
            VWMACC,
            VWMACCSU,
            VWMACCUS: begin
              vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs2_valid[i]  = 1'b1;        
            end
            
            VWADDU_W,
            VWSUBU_W,
            VWADD_W,
            VWSUB_W,
            VMUL,
            VMULH,
            VMULHU,
            VMULHSU,
            VDIVU,
            VDIV,
            VREMU,
            VREM,
            VMACC,
            VNMSAC,
            VMADD,
            VNMSUB,
            VAADDU,
            VAADD,
            VASUBU,
            VASUB,
            VREDSUM,
            VREDMAXU,
            VREDMAX,
            VREDMINU,
            VREDMIN,
            VREDAND,
            VREDOR,
            VREDXOR: begin
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;        
            end

            VWRXUNARY0:begin
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;        
            `ifdef ZVT_ON
              // vtzero/vtmv.v.t (OPMVX) carry an opcode in the vs2 field, not
              // a register. Offsetting it per-uop breaks zvt_ctrl's decode of
              // uops 1..3, and marking it valid creates false RAW hazards.
              if(inst_funct3==OPMVX && (vs2_opcode==VTZERO || vs2_opcode==VTMVVT)) begin
                vs2_offset[i] = 'b0;
                vs2_valid[i]  = 1'b0;
              end
            `endif
            end

            VXUNARY0: begin
              case(inst_funct3)
                OPMVV: begin
                  case({emul_max,emul_vs2})
                    {EMUL1,EMUL1},
                    {EMUL2,EMUL1},
                    {EMUL4,EMUL1}: begin
                      vs2_offset[i] = 'b0;
                      vs2_valid[i]  = 1'b1;
                    end
                    {EMUL4,EMUL2},
                    {EMUL8,EMUL4}: begin
                      vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                      vs2_valid[i]  = 1'b1;
                    end
                    {EMUL8,EMUL2}: begin
                      vs2_offset[i] = {2'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:2]};
                      vs2_valid[i]  = 1'b1;
                    end
                  endcase
                end
              endcase
            end

            VMAND,
            VMNAND,
            VMANDN,
            VMXOR,
            VMOR,
            VMNOR,
            VMORN,
            VMXNOR: begin
              vs2_offset[i] = 'b0;
              vs2_valid[i]  = 1'b1;   
            end

            VMUNARY0: begin
              case(inst_funct3)
                OPMVV: begin
                  case(vs1_opcode)
                    VMSBF,
                    VMSIF,
                    VMSOF,
                    VIOTA: begin
                      vs2_offset[i] = 'b0;
                      vs2_valid[i]  = 1'b1;   
                    end
                  endcase
                end
              endcase
            end

          `ifdef ZVT_ON
            VCOMPRESS_VTMVTV: begin
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;
            end
          `endif
          endcase
        end

        `ifdef ZVE32F_ON
        valid_opf: begin
          case(inst_funct6)
            `ifdef ZVFBFWMA_ON
            VFWMACCBF16: begin
              vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
              vs2_valid[i]  = 1'b1;        
            end
            `endif

            VFADD,          
            VFSUB,      
            VFRSUB,     
            VFMUL,      
            VFDIV,      
            VFRDIV,     
            VFMACC,     
            VFNMACC,    
            VFMSAC,     
            VFNMSAC,    
            VFMADD,     
            VFNMADD,    
            VFMSUB,     
            VFNMSUB,    
            VFUNARY1,
            VFMIN,
            VFMAX,
            VFSGNJ,
            VFSGNJN,
            VFSGNJX,
            VMFEQ,
            VMFNE,
            VMFLT,
            VMFLE,
            VMFGT,
            VMFGE,
            VFREDOSUM,
            VFREDUSUM,
            VFREDMAX,
            VFREDMIN: begin
              vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
              vs2_valid[i]  = 1'b1;        
            end

            VFMERGE_VFMV: begin
              if(!inst_vm) begin
                vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                vs2_valid[i]  = 1'b1; 
              end
            end

            VFUNARY0: begin
              case(vs1_opcode)
                `ifdef ZVFBFWMA_ON
                VFWCVTBF16: begin
                  vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                  vs2_valid[i]  = 1'b1;        
                end

                VFNCVTBF16,
                `endif
                VFCVT_XUFV,
                VFCVT_XFV,  
                VFCVT_RTZXUFV,
                VFCVT_RTZXFV,
                VFCVT_FXUV,
                VFCVT_FXV,
                VFNCVTXUF,
                VFNCVTXF,
                VFNCVTRTZXUF,
                VFNCVTRTZXF: begin
                  vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                  vs2_valid[i]  = 1'b1;        
                end
                VFWCVTFXU, 
                VFWCVTFX: begin
                  vs2_offset[i] = {1'b0, uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:1]};
                  vs2_valid[i]  = 1'b1;        
                end
              endcase
            end

            VWRFUNARY0: begin
              if(inst_vm) begin
                vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                vs2_valid[i]  = 1'b1; 
              end
            end

          `ifdef ZVT_ON
            VTXMMXTVV: begin
              case(lcmd.eew_vs2)
                EEW16: begin
                  vs2_offset[i] = {uop_index_current[i][1], 1'b0, uop_index_current[i][0]};
                end
                EEW32: begin
                  vs2_offset[i] = uop_index_current[i][`UOP_INDEX_WIDTH_ALU-1:0];
                end
              endcase
              vs2_valid[i]  = 1'b1;
            end
          `endif
          endcase
        end
        `endif
      endcase
    end
  end

  // update vs2 index and eew   
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: GET_VS2
      vs2_index[i] = inst_vs2 + {2'b0, vs2_offset[i]}; 
    end
  end

  // update scalar dst_index and valid
  always_comb begin
    // initial
    xd_valid = 'b0;
  `ifdef ZVE32F_ON
    fd_valid = 'b0;
  `endif
  `ifdef ZVT_ON
    mt_valid = 'b0;
  `endif

    case(inst_funct3)
    `ifdef ZVT_ON
      OPIVV: begin
        case(inst_funct6)
          VTXMMXTVV: mt_valid = 1'b1;
        endcase
      end

      OPMVX: begin
        case(inst_funct6)
          VCOMPRESS_VTMVTV: mt_valid = 1'b1;
          VWRXUNARY0:       mt_valid = vs2_opcode==VTZERO;
        endcase
      end
    `endif

      OPMVV: begin
        case(inst_funct6)
          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST,
              VMV_X_S: begin
                xd_valid = 1'b1;
              end
            endcase
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
          VWRFUNARY0: begin
            fd_valid = 1'b1;
          end
        `ifdef ZVT_ON
          VTXMMXTVV: begin
            mt_valid = 1'b1;
          end
        `endif
        endcase
      end
      `endif
    endcase
  end

  // update rs1_data and rs1_data_valid 
  always_comb begin
    // initial
    rs1_data       = rs1;
    rs1_data_valid = 'b0;
      
    case(inst_funct3)
      OPIVX: begin
        case(inst_funct6)
          VADD,
          VSUB,
          VRSUB,
          VADC,
          VMADC,
          VSBC,
          VMSBC,
          VAND,
          VOR,
          VXOR,
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
          VMAX,
          VMERGE_VMV,
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSLL,
          VSRL,
          VSRA,
          VNSRL,
          VNSRA,
          VSSRL,
          VSSRA,
          VNCLIPU,
          VNCLIP,
          VSLIDEUP_RGATHEREI16,
          VSLIDEDOWN,
          VRGATHER: begin
            rs1_data_valid = 1'b1;
          end
        endcase
      end

      OPIVI: begin
        case(inst_funct6)
          VADD,
          VRSUB,
          VADC,
          VMADC,
          VAND,
          VOR,
          VXOR,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT,
          VMERGE_VMV,
          VSADDU,
          VSADD: begin
            rs1_data       = {{(`XLEN-`IMM_WIDTH){inst_imm[`IMM_WIDTH-1]}},inst_imm[`IMM_WIDTH-1:0]};
            rs1_data_valid = 1'b1;
          end

          VSLL,
          VSRL,
          VSRA,
          VNSRL,
          VNSRA,
          VSSRL,
          VSSRA,
          VNCLIPU,
          VNCLIP,
          VSLIDEUP_RGATHEREI16,
          VSLIDEDOWN,
          VRGATHER: begin
            rs1_data       = {{(`XLEN-`IMM_WIDTH){1'b0}},inst_imm[`IMM_WIDTH-1:0]};
            rs1_data_valid = 1'b1;
          end
        endcase
      end
      
      OPMVX: begin
        case(inst_funct6)
        `ifdef ZVT_ON
          VCOMPRESS_VTMVTV,
        `endif
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W,
          VMUL,
          VMULH,
          VMULHU,
          VMULHSU,
          VDIVU,
          VDIV,
          VREMU,
          VREM,
          VWMUL,
          VWMULU,
          VWMULSU,
          VMACC,
          VNMSAC,
          VMADD,
          VNMSUB,
          VWMACCU,
          VWMACC,
          VWMACCSU,
          VWMACCUS,
          VAADDU,
          VAADD,
          VASUBU,
          VASUB,
          VSLIDE1UP,
          VSLIDE1DOWN: begin
            rs1_data_valid = 1'b1;
          end

          VWRXUNARY0: begin
            case(vs2_opcode)
              VMV_S_X: rs1_data_valid = 1'b1;
            `ifdef ZVT_ON
              VTMVVT:  rs1_data_valid = 1'b1;
            `endif
            endcase
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVF: begin
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16,
          `endif
          VFADD,          
          VFSUB,      
          VFRSUB,     
          VFMUL,      
          VFDIV,      
          VFRDIV,     
          VFMACC,     
          VFNMACC,    
          VFMSAC,     
          VFNMSAC,    
          VFMADD,     
          VFNMADD,    
          VFMSUB,     
          VFNMSUB,    
          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX,
          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE,
          VFMERGE_VFMV,
          VFSLIDE1UP,
          VFSLIDE1DOWN: begin
            rs1_data_valid = 1'b1;
          end

          VWRFUNARY0: begin
            rs1_data_valid = inst_vm;
          end
        endcase
      end
      `endif      
    endcase
  end

  // update uop index
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: ASSIGN_UOP_INDEX
      uop_index[i] = uop_index_current[i][`UOP_INDEX_WIDTH-1:0];
    end
  end
  
  // pshrob_valid decide on whether this uop is pushed into ROB.
  always_comb begin
    for(int i=0;i<`NUM_DE_UOP;i++) begin: PSHROB_VLD
      case(uop_exe_unit)
      `ifdef ZVT_ON
        // VME uops that only touch tile state (vtzero, vtmv.t.v) don't
        // need a ROB slot. vtmv.v.t (VTMVVT) writes a vector register
        // and MUST occupy an ROB entry so its VRF writeback can retire.
        VME: pshrob_valid[i] = (inst_funct3 == OPMVX) &&
                               (inst_funct6 == VWRXUNARY0) &&
                               (vs2_opcode == VTMVVT);
      `endif
      `ifdef ZVE32F_ON
        VEU_FCMP,
        VEU_FRDT,
      `endif
        VEU_CMP,
        VEU_RDT: pshrob_valid[i] = last_uop_valid[i];
        default: pshrob_valid[i] = 1'b1;
      endcase
    end
  end

  // assign result to output
  generate
    for(j=0;j<`NUM_DE_UOP;j++) begin: ASSIGN_RES
    `ifdef TB_SUPPORT
      assign uop[j].uop_pc                = lcmd.cmd.inst_pc;
      assign uop[j].res_updating_end      = res_updating_end[j];
    `endif  
      assign uop[j].uop_funct3            = inst_funct3;
      assign uop[j].uop_funct6.ari_funct6 = inst_funct6;
      assign uop[j].uop_exe_unit          = uop_exe_unit; 
      assign uop[j].uop_class             = uop_class[j];   
      assign uop[j].lsu_is_store          = 'b0;   
      assign uop[j].vector_csr            = vector_csr[j];  
      assign uop[j].vs_evl                = lcmd.evl;            
      assign uop[j].ignore_vma            = ignore_vma;
      assign uop[j].ignore_vta            = ignore_vta;
      assign uop[j].force_vma_agnostic    = lcmd.force_vma_agnostic;
      assign uop[j].force_vta_agnostic    = lcmd.force_vta_agnostic;
      assign uop[j].vm                    = inst_vm;                
      assign uop[j].v0_valid              = v0_valid[j];          
      assign uop[j].dst_index             = xd_valid
    `ifdef ZVE32F_ON
                                            || fd_valid 
    `endif
    `ifdef ZVT_ON
                                            || mt_valid
    `endif
                                            ? inst_vd : vd_index[j];          
      assign uop[j].vd_eew                = lcmd.eew_vd;  
      assign uop[j].vd_valid              = vd_valid[j];
      assign uop[j].vs3_valid             = vs3_valid[j];         
      assign uop[j].xd_valid              = xd_valid; 
    `ifdef ZVE32F_ON
      assign uop[j].fd_valid              = fd_valid; 
    `endif
    `ifdef ZVT_ON
      assign uop[j].mt_valid              = mt_valid;
      assign uop[j].mt_eew                = lcmd.eew_mt;
    `endif
      assign uop[j].vs1                   = vs1[j];              
      assign uop[j].vs1_eew               = lcmd.eew_vs1;           
      assign uop[j].vs1_valid             = vs1_valid[j];
      assign uop[j].vs2_index 	          = vs2_index[j]; 	       
      assign uop[j].vs2_eew               = lcmd.eew_vs2;
      assign uop[j].vs2_valid             = vs2_valid[j];
      assign uop[j].rs1_data              = rs1_data;           
      assign uop[j].rs1_data_valid        = rs1_data_valid;    
      assign uop[j].uop_index             = uop_index[j];         
      assign uop[j].first_uop_valid       = first_uop_valid[j];   
      assign uop[j].last_uop_valid        = last_uop_valid[j];    
      assign uop[j].seg_field_index       = 'b0;   
      assign uop[j].pshrob_valid          = pshrob_valid[j];   
      assign uop[j].pshlsu_valid          = 'b0;   
    end
  endgenerate


endmodule
