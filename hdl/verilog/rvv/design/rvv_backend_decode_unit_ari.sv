`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

// TODO: tail uops

module rvv_backend_decode_unit_ari
(
  inst_valid,
  inst,
  lcmd_valid,
  lcmd
);
//
// interface signals
//
  input   logic                       inst_valid;
  input   RVVCmd                      inst;
  
  output  logic                       lcmd_valid;
  output  LCMD_t                      lcmd;

//
// internal signals
//
  // split INST_t struct signals
  logic   [`FUNCT6_WIDTH-1:0]     inst_funct6;      // inst original encoding[31:26]    
  logic   [`VM_WIDTH-1:0]         inst_vm;          // inst original encoding[25]      
  logic   [`REGIDX_WIDTH-1:0]     inst_vs2;         // inst original encoding[24:20]
  logic   [`REGIDX_WIDTH-1:0]     inst_vs1;         // inst original encoding[19:15]
  logic   [`IMM_WIDTH-1:0]        inst_imm;         // inst original encoding[19:15]
  logic   [`FUNCT3_WIDTH-1:0]     inst_funct3;      // inst original encoding[14:12]
  logic   [`REGIDX_WIDTH-1:0]     inst_vd;          // inst original encoding[11:7]
  logic   [`NREG_WIDTH-1:0]       inst_nr;          // inst original encoding[17:15]
  logic   [`REGIDX_WIDTH-1:0]     vs1_opcode;
  logic   [`REGIDX_WIDTH-1:0]     vs2_opcode;
   
  logic   [`XLEN-1:0]             rs1;    
  logic   [`XLEN-1:0]             offset; 
  logic                           csr_vill;
  logic   [`VSTART_WIDTH-1:0]     csr_vstart;
  logic   [`VSTART_WIDTH:0]       evstart;
  logic   [`VL_WIDTH-1:0]         csr_vl;
  logic   [`VL_WIDTH-1:0]         evl;
  RVVSEW                          csr_sew;
  RVVLMUL                         csr_lmul;
  RVVLMUL                         reduced_lmul;  
`ifdef ZVT_ON
  logic                           csr_altfmt;
  logic   [1:0]                   csr_mtwiden;
  logic   [$clog2(`TE):0]         csr_tm;
  logic   [$clog2(`TE):0]         csr_tn;
  logic   [2:0]                   csr_tk;
  TSS_t                           tss;
`endif  
  EMUL_e                          emul_vd;          
  EMUL_e                          emul_vs2;          
  EMUL_e                          emul_vs1;          
  EMUL_e                          emul_max; 
  EEW_e                           eew_vd;          
`ifdef ZVT_ON
  EEW_e                           eew_mt;
`endif
  EEW_e                           eew_vs2;          
  EEW_e                           eew_vs1;
  EEW_e                           eew_max;          
  logic                           valid_opi;
  logic                           valid_opm;
`ifdef ZVE32F_ON
  logic                           valid_opf;
`endif
  logic                           inst_encoding_correct;
  logic                           check_special;
  logic                           check_vd_overlap_v0;
  logic                           check_vd_part_overlap_vs2;
  logic                           check_vd_part_overlap_vs1;
  logic                           check_vd_overlap_vs2;
  logic                           check_vd_overlap_vs1;
  logic                           check_vs2_part_overlap_vd_2_1;
  logic                           check_vs1_part_overlap_vd_2_1;
  logic                           check_vs2_part_overlap_vd_4_1;
`ifdef ZVT_ON
  logic                           check_mtd_align;
  logic                           check_vme_vs1_align;
  logic                           check_vme_vs2_align;
  logic                           check_tm;
  logic                           check_tn;
  logic                           check_tk;
  logic                           isVmeAlu;
`endif
  logic                           check_common;
  logic                           check_vd_align;
  logic                           check_vs2_align;
  logic                           check_vs1_align;
  logic                           check_sew;
  logic                           check_lmul;
  logic                           check_vl_not_0;
  logic                           check_vstart_sle_vl;
  logic                           check_frm;
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_vstart;         
  logic   [`UOP_INDEX_WIDTH-1:0]  uop_index_max;         

  logic                           force_vma_agnostic; 
  logic                           force_vta_agnostic; 
   
  // use for for-loop 
  genvar                          j;

//
// decode
//
  assign inst_funct6    = inst_valid ? inst.bits[24:19] : 'b0;
  assign inst_vm        = inst_valid ? inst.bits[18] : 'b0;
  assign inst_vs2       = inst_valid ? inst.bits[17:13] : 'b0;
  assign vs2_opcode     = inst_valid ? inst.bits[17:13] : 'b0;
  assign inst_vs1       = inst_valid ? inst.bits[12:8] : 'b0;
  assign vs1_opcode     = inst_valid ? inst.bits[12:8] : 'b0;
  assign inst_imm       = inst_valid ? inst.bits[12:8] : 'b0;
  assign inst_funct3    = inst_valid ? inst.bits[7:5] : 'b0;
  assign inst_vd        = inst_valid ? inst.bits[4:0] : 'b0;
  assign inst_nr        = inst_valid ? inst_vs1[`NREG_WIDTH-1:0] : 'b0;
  assign rs1            = inst_valid ? inst.rs1 : 'b0;
  assign csr_vill       = inst_valid ? inst.arch_state.vill : 'b0;
  assign csr_vstart     = inst_valid ? inst.arch_state.vstart : 'b0;
  assign csr_vl         = inst_valid ? inst.arch_state.vl : 'b0;
  assign csr_sew        = inst_valid ? inst.arch_state.sew : SEW8;
  assign csr_lmul       = inst_valid ? inst.arch_state.lmul_orig : LMUL1;
  assign reduced_lmul   = inst_valid ? inst.arch_state.lmul : LMUL1;  
`ifdef ZVT_ON
  assign csr_altfmt     = inst_valid ? inst.arch_state.altfmt : 'b0;
  assign csr_mtwiden    = inst_valid ? inst.arch_state.mtwiden : 'b0;
  assign csr_tm         = inst_valid ? inst.arch_state.tm : 'b0;
  assign csr_tn         = csr_vl[$clog2(`TE):0];
  assign csr_tk         = inst_valid ? inst.arch_state.tk : 'b0;
  assign tss.tile       = rs1[30:27];
  assign tss.pattern    = rs1[24];
  assign tss.index      = rs1[$clog2(`TE)-1:0];
`endif

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
      OPIVI: valid_opi = inst_valid;
      OPMVV,
      OPMVX: valid_opm = inst_valid;
    `ifdef ZVE32F_ON
      OPFVV,
      OPFVF: valid_opf = inst_valid;
    `endif    
    endcase
  end 

  // get EMUL
  always_comb begin
    // initial
    emul_vd       = EMUL_NONE;
    emul_vs2      = EMUL_NONE;
    emul_vs1      = EMUL_NONE;
    emul_max      = EMUL_NONE;
    uop_index_max = 'd0;

    case(inst_funct3)
      OPIVV: begin
        // OPI* instruction
        case(inst_funct6)
          VADD,
          VADC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VRGATHER,
          VSUB,
          VSBC,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // destination vector register is mask register
          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSLTU,
          VMSLT: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // narrowing instructions
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP:begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase 
          end
          
          VMERGE_VMV: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          // widening instructions
          VWREDSUMU,
          VWREDSUM: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end

          VSLIDEUP_RGATHEREI16: begin        
            // VRGATHEREI16
            case(csr_lmul)
              LMUL1_4: begin
                case(csr_sew)
                  SEW8,
                  SEW16: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_vs1    = EMUL1;
                    emul_max    = EMUL1;
                  end
                endcase
              end
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                case(csr_sew)
                  SEW8: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_vs1    = EMUL2;
                    emul_max    = EMUL2;
                    case(reduced_lmul)
                      LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    endcase
                  end
                  SEW16,
                  SEW32: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_vs1    = EMUL1;
                    emul_max    = EMUL1;
                  end
                endcase
              end
              LMUL2: begin                  
                case(csr_sew)
                  SEW8: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_vs1    = EMUL4;
                    emul_max    = EMUL4;
                    case(reduced_lmul)
                      LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                      LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    endcase
                  end
                  SEW16: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_vs1    = EMUL2;
                    emul_max    = EMUL2;
                    case(reduced_lmul)
                      LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    endcase
                  end
                  SEW32: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_vs1    = EMUL1;
                    emul_max    = EMUL2;
                    case(reduced_lmul)
                      LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    endcase
                  end
                endcase
              end
              LMUL4: begin
                case(csr_sew)
                  SEW8: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_vs1    = EMUL8;
                    emul_max    = EMUL8;
                    case(reduced_lmul)
                      LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                      LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                      LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    endcase
                  end
                  SEW16: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_vs1    = EMUL4;
                    emul_max    = EMUL4;
                    case(reduced_lmul)
                      LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                      LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    endcase
                  end
                  SEW32: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_vs1    = EMUL2;
                    emul_max    = EMUL4;
                    case(reduced_lmul)
                      LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                      LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    endcase
                  end
                endcase
              end
              LMUL8: begin
                case(reduced_lmul)
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_sew)
                  SEW16: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_vs1    = EMUL8;
                    emul_max    = EMUL8;
                  end
                  SEW32: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_vs1    = EMUL4;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end

        `ifdef ZVT_ON
          VTXMMXTVV: begin
            case(1'b1)
              ((csr_sew==SEW8 )&&(csr_lmul==LMUL1)),
              ((csr_sew==SEW16)&&(csr_lmul==LMUL2)),
              ((csr_sew==SEW32)&&(csr_lmul==LMUL4)): begin
                uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                emul_vs2      = EMUL4;
                emul_vs1      = EMUL4;
                emul_max      = EMUL4;
              end
            endcase
          end
        `endif          
        endcase
      end
      
      OPIVX: begin
        // OPI* instruction
        case(inst_funct6)
          VADD,
          VADC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VRGATHER,
          VSUB,
          VSBC,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSSUBU,
          VSSUB,
          VRSUB,
          VSLIDEDOWN,
          VSMUL_VMVNRR,
          VSLIDEUP_RGATHEREI16: begin        
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // destination vector register is mask register
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
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // narrowing instructions
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP:begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VMERGE_VMV: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
        endcase
      end
      
      OPIVI: begin
        // OPI* instruction
        case(inst_funct6)
          VADD,
          VADC,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VRGATHER,
          VRSUB,
          VSLIDEDOWN,
          VSLIDEUP_RGATHEREI16: begin        
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // destination vector register is mask register
          VMADC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // narrowing instructions
          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP:begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          VMERGE_VMV: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if (inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VSMUL_VMVNRR: begin
            // vmv<nr>r.v instruction
            case(inst_nr)
              NREG1: begin
                emul_vd       = EMUL1;
                emul_vs2      = EMUL1;
                emul_max      = EMUL1;
              end
              NREG2: begin
                emul_vd       = EMUL2;
                emul_vs2      = EMUL2;
                emul_max      = EMUL2;
                uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              end
              NREG4: begin
                emul_vd       = EMUL4;
                emul_vs2      = EMUL4;
                emul_max      = EMUL4;
                uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              end
              NREG8: begin
                emul_vd       = EMUL8;
                emul_vs2      = EMUL8;
                emul_max      = EMUL8;
                uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
              end
            endcase
          end
        endcase
      end

      OPMVV: begin
        // OPM* instruction
        case(inst_funct6)
          // widening instructions: 2SEW = SEW op SEW
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWMUL,
          VWMULU,
          VWMULSU,
          VWMACCU,
          VWMACC,
          VWMACCSU: begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          // widening instructions: 2SEW = 2SEW op SEW
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
          end

          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2: begin
                case(reduced_lmul)
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL8;
                  end
                endcase
              end
              VZEXT_VF4,
              VSEXT_VF4: begin
                case(reduced_lmul)
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end
 
          // SEW = SEW op SEW
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
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
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
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
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
            emul_vd     = EMUL1;
            emul_vs2    = EMUL1;
            emul_vs1    = EMUL1;
            emul_max    = EMUL1;
          end

          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST,
              VMV_X_S: begin
                emul_vs2  = EMUL1;
                emul_max  = EMUL1;
              end
            endcase
          end

          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSIF,
              VMSOF: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              VIOTA: begin
                case(reduced_lmul)
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL8;
                  end
                endcase
              end
              VID: begin
                case(reduced_lmul)
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end

          VCOMPRESS_VTMVTV: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end
        endcase
      end

      OPMVX: begin
        // OPM* instruction
        case(inst_funct6)
          // widening instructions: 2SEW = SEW op SEW
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWMUL,
          VWMULU,
          VWMULSU,
          VWMACCU,
          VWMACC,
          VWMACCSU: begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
          end
          
          // widening instructions: 2SEW = 2SEW op SEW
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          // SEW = SEW op SEW
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
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VWMACCUS: begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase
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
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end

          VWRXUNARY0: begin
            if(vs2_opcode==VMV_S_X) begin
              emul_vd     = EMUL1;
              emul_max    = EMUL1;
            end
          `ifdef ZVT_ON
            else if(vs2_opcode==VTMVVT) begin
              case(csr_lmul)
                LMUL1_4,
                LMUL1_2,
                LMUL1: begin
                  // Drain a single tile row into one v register; no
                  // stripmining. Added so vtmv.v.t can be issued without
                  // running into the LMUL>=2 uop-stripmine + isMv2Rvv-only-
                  // acks-uop[0] wedge in zvt_ctrl.
                  if(csr_sew==SEW8) begin
                    emul_vd       = EMUL1;
                    emul_max      = EMUL1;
                  end
                end
                LMUL2: begin
                  if(csr_sew==SEW16) begin
                    emul_vd       = EMUL2;
                    emul_max      = EMUL2;
                    uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  end
                end
                LMUL4: begin
                  if(csr_sew==SEW32) begin
                    emul_vd       = EMUL4;
                    emul_max      = EMUL4;
                    uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  end
                end
              endcase
            end
            else if(vs2_opcode==VTZERO) begin
              case(1'b1)
                ((csr_sew==SEW8 )&&(csr_lmul==LMUL1)),
                ((csr_sew==SEW16)&&(csr_lmul==LMUL2)),
                ((csr_sew==SEW32)&&(csr_lmul==LMUL4)): begin
                  emul_max      = EMUL1;
                end
              endcase
            end
          `endif
          end

          VSLIDE1UP,
          VSLIDE1DOWN: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

        `ifdef ZVT_ON
          VCOMPRESS_VTMVTV: begin
            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                if(csr_sew==SEW8) begin
                  emul_vs2      = EMUL1;
                  emul_max      = EMUL1;
                end
              end
              LMUL2: begin
                if(csr_sew==SEW16) begin
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  emul_vs2      = EMUL2;
                  emul_max      = EMUL2;
                end
              end
              LMUL4: begin
                if(csr_sew==SEW32) begin
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  emul_vs2      = EMUL4;
                  emul_max      = EMUL4;
                end
              end          
            endcase
          end
        `endif              
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
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
          VFSGNJX: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VFUNARY1: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(vs1_opcode)
              VFSQRT,
              VFRSQRT7,
              VFREC7,
              VFCLASS: begin
                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end

          VMFEQ,           
          VMFNE,           
          VMFLT,           
          VMFLE: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16: begin
                case(reduced_lmul)
                  LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase 
              end
              VFWCVTBF16: begin
                case(reduced_lmul)
                  LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL1: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL4;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL8;
                  end
                endcase 
              end
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV: begin
                case(reduced_lmul)
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2,
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL8: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase
              end
              VFWCVTFXU,
              VFWCVTFX: begin
                case(reduced_lmul)
                  LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL1: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL2;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL4;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL8;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL8;
                  end
                endcase
              end
              VFNCVTXUF,
              VFNCVTXF,
              VFNCVTRTZXUF,
              VFNCVTRTZXF: begin
                case(reduced_lmul)
                  LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                  LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                  LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                endcase

                case(csr_lmul)
                  LMUL1_4,
                  LMUL1_2: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL1;
                    emul_max    = EMUL1;
                  end
                  LMUL1: begin
                    emul_vd     = EMUL1;
                    emul_vs2    = EMUL2;
                    emul_max    = EMUL2;
                  end
                  LMUL2: begin
                    emul_vd     = EMUL2;
                    emul_vs2    = EMUL4;
                    emul_max    = EMUL4;
                  end
                  LMUL4: begin
                    emul_vd     = EMUL4;
                    emul_vs2    = EMUL8;
                    emul_max    = EMUL8;
                  end
                endcase
              end
            endcase
          end

          VFREDOSUM,       
          VFREDUSUM,       
          VFREDMAX,       
          VFREDMIN: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL1;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_vs1    = EMUL1;
                emul_max    = EMUL8;
              end
            endcase
          end

          VWRFUNARY0: begin
            if(vs1_opcode==VFMV_F_S) begin
              emul_vs2      = EMUL1;
              emul_max      = EMUL1;
            end
          end

          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

             case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_vs1    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_vs1    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_vs1    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase           
          end
          `endif

          `ifdef ZVT_ON
          VTXMMXTVV: begin
            case(1'b1)
              ((csr_sew==SEW8 )&&(csr_lmul==LMUL1)),
              ((csr_sew==SEW16)&&(csr_lmul==LMUL2)),
              ((csr_sew==SEW32)&&(csr_lmul==LMUL4)): begin
                uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                emul_vs2      = EMUL4;
                emul_vs1      = EMUL4;
                emul_max      = EMUL4;
              end
            endcase
          end
          `endif
        endcase
      end

      OPFVF: begin
        case(inst_funct6)
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
          VFSLIDE1UP,      
          VFSLIDE1DOWN: begin  
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VMFEQ,           
          VMFNE,           
          VMFLT,           
          VMFLE,           
          VMFGT,           
          VMFGE: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL8;
                emul_max    = EMUL8;
              end
            endcase
          end

          VFMERGE_VFMV: begin
            case(reduced_lmul)
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL8: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2,
              LMUL1: begin
                emul_vd     = EMUL1;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL2: begin
                emul_vd     = EMUL2;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL2;
                emul_max    = EMUL2;
              end
              LMUL4: begin
                emul_vd     = EMUL4;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL4;
                emul_max    = EMUL4;
              end
              LMUL8: begin
                emul_vd     = EMUL8;
                if(inst_vm=='b0)
                  emul_vs2  = EMUL8;
                emul_max    = EMUL8;
              end
            endcase            
          end

          VWRFUNARY0: begin
            if(vs2_opcode==VFMV_S_F) begin
              emul_vd       = EMUL1;
              emul_max      = EMUL1;
            end
          end

          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            case(reduced_lmul)
              LMUL1: uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
              LMUL2: uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
              LMUL4: uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
            endcase

            case(csr_lmul)
              LMUL1_4,
              LMUL1_2: begin
                emul_vd     = EMUL1;
                emul_vs2    = EMUL1;
                emul_max    = EMUL1;
              end
              LMUL1: begin
                emul_vd     = EMUL2;
                emul_vs2    = EMUL1;
                emul_max    = EMUL2;
              end
              LMUL2: begin
                emul_vd     = EMUL4;
                emul_vs2    = EMUL2;
                emul_max    = EMUL4;
              end
              LMUL4: begin
                emul_vd     = EMUL8;
                emul_vs2    = EMUL4;
                emul_max    = EMUL8;
              end
            endcase           
          end
          `endif
        endcase
      end
      `endif
    endcase
  end
 
// get EEW 
  always_comb begin
    // initial
  `ifdef ZVT_ON
    eew_mt  = EEW_NONE;
  `endif
    eew_vd  = EEW_NONE;
    eew_vs2 = EEW_NONE;
    eew_vs1 = EEW_NONE;
    eew_max = EEW_NONE;

    case(1'b1)
      valid_opi: begin
        // OPI* instruction
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
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSLIDEDOWN,
          VRGATHER: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                eew_vs2     = EEW8;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
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
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW8;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                eew_vs2     = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
          end

          VMERGE_VMV: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                if (inst_vm=='b0)
                  eew_vs2   = EEW8;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW16;
                if (inst_vm=='b0)
                  eew_vs2   = EEW16;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW32;
                if (inst_vm=='b0)
                  eew_vs2   = EEW32;
                if(inst_funct3==OPIVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VWREDSUMU,
          VWREDSUM: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW8;
                eew_vs1     = EEW16;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                eew_vs1     = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end
          
          VSLIDEUP_RGATHEREI16: begin
            case(inst_funct3)
              // VRGATHEREI16
              OPIVV: begin
                case(csr_sew)
                  SEW8: begin
                    eew_vd      = EEW8;
                    eew_vs2     = EEW8;
                    eew_vs1     = EEW16;
                    eew_max     = EEW16;
                  end
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW16;
                    eew_vs1     = EEW16;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_vs1     = EEW16;
                    eew_max     = EEW32;
                  end
                endcase
              end
              // VSLIDEUP
              OPIVX,
              OPIVI: begin
                case(csr_sew)
                  SEW8: begin
                    eew_vd      = EEW8;
                    eew_vs2     = EEW8;
                    eew_max     = EEW8;
                  end
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW16;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end

        `ifdef ZVT_ON
          VTXMMXTVV: begin
            case(inst_funct3)
              OPIVV: begin
                case({csr_sew, csr_mtwiden})
                  {SEW8, 2'd3}: begin
                    eew_mt      = EEW32;
                    eew_vs2     = EEW8;
                    eew_vs1     = EEW8;
                    eew_max     = EEW32;
                  end
                `ifdef ZVTI16I32_ON
                  {SEW16, 2'd2}: begin
                    eew_mt      = EEW32;
                    eew_vs2     = EEW16;
                    eew_vs1     = EEW16;
                    eew_max     = EEW32;
                  end
                `endif
                endcase
              end
            endcase 
          end
        `endif
        endcase
      end

      valid_opm: begin
        // OPM* instruction
        case(inst_funct6)
          // widening instructions: 2SEW = SEW op SEW
          VWADDU,
          VWSUBU,
          VWADD,
          VWSUB,
          VWMUL,
          VWMULU,
          VWMULSU,
          VWMACCU,
          VWMACC,
          VWMACCSU: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW8;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
          end
         
          // widening instructions: 2SEW = 2SEW op SEW
          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW16;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
          end

          // SEW = extend 1/2SEW or 1/4SEW
          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW8;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW16;
                    eew_max     = EEW32;
                  end
                endcase
              end
              VZEXT_VF4,
              VSEXT_VF4: begin
                case(csr_sew)
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW8;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end

          // SEW = SEW op SEW
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
          // reduction
          VREDSUM,
          VREDMAXU,
          VREDMAX,
          VREDMINU,
          VREDMIN,
          VREDAND,
          VREDOR,
          VREDXOR,
          VSLIDE1UP,
          VSLIDE1DOWN: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW8;
                eew_vs2     = EEW8;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW8;
                eew_max     = EEW8;
              end
              SEW16: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW16;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW16;
              end
              SEW32: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPMVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end
          
          VWMACCUS: begin
            case(csr_sew)
              SEW8: begin
                eew_vd      = EEW16;
                eew_vs2     = EEW8;
                eew_max     = EEW16;
              end
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                eew_max     = EEW32;
              end
            endcase
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
            case(csr_sew)
              SEW8,
              SEW16,
              SEW32: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW1;
                eew_vs1     = EEW1;
                eew_max     = EEW1;
              end
            endcase
          end

          VWRXUNARY0: begin
            case(inst_funct3)
              OPMVV: begin
                case(vs1_opcode)
                  VCPOP,
                  VFIRST,
                  VMV_X_S: begin
                    case(csr_sew)
                      SEW8: begin
                        eew_vs2     = EEW8;
                        eew_max     = EEW8;
                      end
                      SEW16: begin
                        eew_vs2     = EEW16;
                        eew_max     = EEW16;
                      end
                      SEW32: begin
                        eew_vs2     = EEW32;
                        eew_max     = EEW32;
                      end
                    endcase
                  end
                endcase
              end
              OPMVX: begin
                if(vs2_opcode==VMV_S_X) begin
                  case(csr_sew)
                    SEW8: begin
                      eew_vd      = EEW8;
                      eew_max     = EEW8;
                    end
                    SEW16: begin
                      eew_vd      = EEW16;
                      eew_max     = EEW16;
                    end
                    SEW32: begin
                      eew_vd      = EEW32;
                      eew_max     = EEW32;
                    end
                  endcase
                end
              `ifdef ZVT_ON
                else if(vs2_opcode==VTMVVT) begin
                  case(csr_sew)
                    SEW8: begin
                      eew_mt      = EEW8;
                      eew_vd      = EEW8;
                      eew_max     = EEW8;
                    end
                    SEW16: begin
                      eew_mt      = EEW16;
                      eew_vd      = EEW16;
                      eew_max     = EEW16;
                    end
                    SEW32: begin
                      eew_mt      = EEW32;
                      eew_vd      = EEW32;
                      eew_max     = EEW32;
                    end
                  endcase
                end
                else if(vs2_opcode==VTZERO) begin
                  case(csr_sew)
                    SEW8: begin
                      eew_mt      = EEW8;
                      eew_max     = EEW8;
                    end
                    SEW16: begin
                      eew_mt      = EEW16;
                      eew_max     = EEW16;
                    end
                    SEW32: begin
                      eew_mt      = EEW32;
                      eew_max     = EEW32;
                    end
                  //case({csr_sew, csr_mtwiden})
                  //`ifdef ZVTI16I32_ON
                  //  {SEW16, 2'd2}: begin
                  //    eew_mt      = EEW32;
                  //    eew_max     = EEW32;
                  //  end
                  //`endif
                  //  {SEW8, 2'd3}: begin
                  //    eew_mt      = EEW32;
                  //    eew_max     = EEW32;
                  //  end
                  endcase
                end
              `endif
              end
            endcase
          end

          VMUNARY0: begin
            case(inst_funct3)
              OPMVV: begin
                case(vs1_opcode)
                  VMSBF,
                  VMSIF,
                  VMSOF: begin
                    case(csr_sew)
                      SEW8,
                      SEW16,
                      SEW32: begin
                        eew_vd      = EEW1;
                        eew_vs2     = EEW1;
                        eew_max     = EEW1;
                      end
                    endcase
                  end
                  VIOTA:begin
                    case(csr_sew)
                      SEW8: begin
                        eew_vd      = EEW8;
                        eew_vs2     = EEW1;
                        eew_max     = EEW8;
                      end
                      SEW16: begin
                        eew_vd      = EEW16;
                        eew_vs2     = EEW1;
                        eew_max     = EEW16;
                      end
                      SEW32: begin
                        eew_vd      = EEW32;
                        eew_vs2     = EEW1;
                        eew_max     = EEW32;
                      end
                    endcase
                  end
                  VID: begin
                    case(csr_sew)
                      SEW8: begin
                        eew_vd      = EEW8;
                        eew_max     = EEW8;
                      end
                      SEW16: begin
                        eew_vd      = EEW16;
                        eew_max     = EEW16;
                      end
                      SEW32: begin
                        eew_vd      = EEW32;
                        eew_max     = EEW32;
                      end
                    endcase
                  end
                endcase
              end
            endcase
          end

          VCOMPRESS_VTMVTV: begin
            case(inst_funct3)
              OPMVV: begin
                case(csr_sew)
                  SEW8: begin
                    eew_vd      = EEW8;
                    eew_vs2     = EEW8;
                    eew_vs1     = EEW1;
                    eew_max     = EEW8;
                  end
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW16;
                    eew_vs1     = EEW1;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_vs1     = EEW1;
                    eew_max     = EEW32;
                  end
                endcase
              end
            `ifdef ZVT_ON
              // vtmv.t.v
              OPMVX: begin
                case(csr_sew)
                  SEW8: begin
                    eew_mt      = EEW8;
                    eew_vs2     = EEW8;
                    eew_max     = EEW8;
                  end
                  SEW16: begin
                    eew_mt      = EEW16;
                    eew_vs2     = EEW16;
                    eew_max     = EEW16;
                  end
                  SEW32: begin
                    eew_mt      = EEW32;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            `endif
            endcase
          end
        endcase
      end

      `ifdef ZVE32F_ON
      valid_opf: begin
        // OPF* instruction
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            case(csr_sew)
              SEW16: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW16;
                if(inst_funct3==OPFVV)
                  eew_vs1   = EEW16;
                eew_max     = EEW32;
              end
            endcase
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
          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX,
          VFREDOSUM,
          VFREDUSUM,
          VFREDMAX,
          VFREDMIN,
          VFSLIDE1UP,
          VFSLIDE1DOWN: begin
            case(csr_sew)
              SEW32: begin
                eew_vd      = EEW32;
                eew_vs2     = EEW32;
                if(inst_funct3==OPFVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VFUNARY1: begin
            case(vs1_opcode)
              VFSQRT,
              VFRSQRT7,
              VFREC7,
              VFCLASS: begin
                case(csr_sew)
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE: begin
            case(csr_sew)
              SEW32: begin
                eew_vd      = EEW1;
                eew_vs2     = EEW32;
                if(inst_funct3==OPFVV)
                  eew_vs1   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VFMERGE_VFMV: begin
            case(csr_sew)
              SEW32: begin
                eew_vd      = EEW32;
                if(inst_vm=='b0)
                  eew_vs2   = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
              VFWCVTBF16: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW16;
                    eew_max     = EEW32;
                  end
                endcase
              end
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV: begin
                case(csr_sew)
                  SEW32: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
              VFWCVTFXU,
              VFWCVTFX: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW32;
                    eew_vs2     = EEW16;
                    eew_max     = EEW32;
                  end
                endcase
              end
              VFNCVTXUF,
              VFNCVTXF,
              VFNCVTRTZXUF,
              VFNCVTRTZXF: begin
                case(csr_sew)
                  SEW16: begin
                    eew_vd      = EEW16;
                    eew_vs2     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase
          end

          VWRFUNARY0: begin
            case(csr_sew)
              SEW32: begin
                if(inst_funct3==OPFVV)
                  eew_vs2   = EEW32;
                else
                  eew_vd    = EEW32;
                eew_max     = EEW32;
              end
            endcase
          end

        `ifdef ZVT_ON
          VTXMMXTVV: begin
            case(inst_funct3)
              OPFVV: begin
                case({csr_sew, csr_mtwiden, csr_altfmt})
                  {SEW16, 2'd2, 1'b1}: begin
                    eew_mt      = EEW32;
                    eew_vs2     = EEW16;
                    eew_vs1     = EEW16;
                    eew_max     = EEW32;
                  end
                  {SEW32, 2'd1, 1'b0}: begin
                    eew_mt      = EEW32;
                    eew_vs2     = EEW32;
                    eew_vs1     = EEW32;
                    eew_max     = EEW32;
                  end
                endcase
              end
            endcase 
          end
        `endif
        endcase
      end
      `endif
    endcase
  end

//  
// instruction encoding error check
//
  assign inst_encoding_correct = check_special&check_common&inst_valid;

  // check whether vd overlaps v0 when vm=0
  // check_vd_overlap_v0=1 means check pass (vd does NOT overlap v0)
  assign check_vd_overlap_v0 = (((inst_vm==1'b0)&(inst_vd!='b0)) | (inst_vm==1'b1));

  // check whether vd partially overlaps vs2 with EEW_vd<EEW_vs2
  // check_vd_part_overlap_vs2=1 means that check pass (vd group does NOT overlap vs2 group partially)
  always_comb begin
    check_vd_part_overlap_vs2 = 'b0;          
    
    case(emul_vs2)
      EMUL1: begin
        check_vd_part_overlap_vs2 = 1'b1;          
      end
      EMUL2: begin
        check_vd_part_overlap_vs2 = !((inst_vd[0]!='b0) & ((inst_vd[`REGIDX_WIDTH-1:1]==inst_vs2[`REGIDX_WIDTH-1:1])));
      end
      EMUL4: begin
        check_vd_part_overlap_vs2 = !((inst_vd[1:0]!='b0) & ((inst_vd[`REGIDX_WIDTH-1:2]==inst_vs2[`REGIDX_WIDTH-1:2])));
      end
      EMUL8 : begin
        check_vd_part_overlap_vs2 = !((inst_vd[2:0]!='b0) & ((inst_vd[`REGIDX_WIDTH-1:3]==inst_vs2[`REGIDX_WIDTH-1:3])));
      end
    endcase
  end

  // check whether vd partially overlaps vs1 with EEW_vd<EEW_vs1
  // check_vd_part_overlap_vs1=1 means that check pass (vd group does NOT overlap vs1 group partially)
  always_comb begin
    check_vd_part_overlap_vs1     = 'b0;          
    
    case(emul_vs1)
      EMUL1: begin
        check_vd_part_overlap_vs1 = 1'b1;          
      end
      EMUL2: begin
        check_vd_part_overlap_vs1 = !((inst_vd[0]!='b0) & ((inst_vd[`REGIDX_WIDTH-1:1]==inst_vs1[`REGIDX_WIDTH-1:1])));
      end
      EMUL4: begin
        check_vd_part_overlap_vs1 = !((inst_vd[1:0]!='b0) & ((inst_vd[`REGIDX_WIDTH-1:2]==inst_vs1[`REGIDX_WIDTH-1:2])));
      end
      EMUL8 : begin
        check_vd_part_overlap_vs1 = !((inst_vd[2:0]!='b0) & ((inst_vd[`REGIDX_WIDTH-1:3]==inst_vs1[`REGIDX_WIDTH-1:3])));
      end
    endcase
  end

  // vd cannot overlap vs2
  // check_vd_overlap_vs2=1 means that check pass (vd group does NOT overlap vs2 group fully)
  always_comb begin
    if((emul_vd==EMUL8)|(emul_vs2==EMUL8)) 
      check_vd_overlap_vs2 = !(inst_vd[`REGIDX_WIDTH-1:3]==inst_vs2[`REGIDX_WIDTH-1:3]);
    else if((emul_vd==EMUL4)|(emul_vs2==EMUL4)) 
      check_vd_overlap_vs2 = !(inst_vd[`REGIDX_WIDTH-1:2]==inst_vs2[`REGIDX_WIDTH-1:2]);
    else if((emul_vd==EMUL2)|(emul_vs2==EMUL2)) 
      check_vd_overlap_vs2 = !(inst_vd[`REGIDX_WIDTH-1:1]==inst_vs2[`REGIDX_WIDTH-1:1]);
    else if((emul_vd==EMUL1)|(emul_vs2==EMUL1)) 
      check_vd_overlap_vs2 = (inst_vd!=inst_vs2);
    else 
      check_vd_overlap_vs2 = 'b0;
  end
  
  // vd cannot overlap vs1
  // check_vd_overlap_vs1=1 means that check pass (vd group does NOT overlap vs1 group fully)
  always_comb begin
    if((emul_vd==EMUL8)|(emul_vs1==EMUL8)) 
      check_vd_overlap_vs1 = !(inst_vd[`REGIDX_WIDTH-1:3]==inst_vs1[`REGIDX_WIDTH-1:3]);
    else if((emul_vd==EMUL4)|(emul_vs1==EMUL4)) 
      check_vd_overlap_vs1 = !(inst_vd[`REGIDX_WIDTH-1:2]==inst_vs1[`REGIDX_WIDTH-1:2]);
    else if((emul_vd==EMUL2)|(emul_vs1==EMUL2)) 
      check_vd_overlap_vs1 = !(inst_vd[`REGIDX_WIDTH-1:1]==inst_vs1[`REGIDX_WIDTH-1:1]);
    else if((emul_vd==EMUL1)|(emul_vs1==EMUL1)) 
      check_vd_overlap_vs1 = (inst_vd!=inst_vs1);
    else 
      check_vd_overlap_vs1 = 'b0;
  end

  // check whether vs2 group partially overlaps vd group for EEW_vd:EEW_vs2=2:1
  always_comb begin
    check_vs2_part_overlap_vd_2_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs2_part_overlap_vd_2_1 = 1'b1;
      end
      EMUL2: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGIDX_WIDTH-1:1]==inst_vs2[`REGIDX_WIDTH-1:1])&(inst_vs2[0]!=1'b1));
      end
      EMUL4: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGIDX_WIDTH-1:2]==inst_vs2[`REGIDX_WIDTH-1:2])&(inst_vs2[1:0]!=2'b10));
      end
      EMUL8: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGIDX_WIDTH-1:3]==inst_vs2[`REGIDX_WIDTH-1:3])&(inst_vs2[2:0]!=3'b100));
      end
    endcase
  end
  
  // check whether vs1 group partially overlaps vd group for EEW_vd:EEW_vs1=2:1
  always_comb begin
    check_vs1_part_overlap_vd_2_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs1_part_overlap_vd_2_1 = 1'b1;
      end
      EMUL2: begin
        check_vs1_part_overlap_vd_2_1 = !((inst_vd[`REGIDX_WIDTH-1:1]==inst_vs1[`REGIDX_WIDTH-1:1])&(inst_vs1[0]!=1'b1));
      end
      EMUL4: begin
        check_vs1_part_overlap_vd_2_1 = !((inst_vd[`REGIDX_WIDTH-1:2]==inst_vs1[`REGIDX_WIDTH-1:2])&(inst_vs1[1:0]!=2'b10));
      end
      EMUL8: begin
        check_vs1_part_overlap_vd_2_1 = !((inst_vd[`REGIDX_WIDTH-1:3]==inst_vs1[`REGIDX_WIDTH-1:3])&(inst_vs1[2:0]!=3'b100));
      end
    endcase
  end

  // check whether vs2 group partially overlaps vd group for EEW_vd:EEW_vs2=4:1
  always_comb begin
    check_vs2_part_overlap_vd_4_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs2_part_overlap_vd_4_1 = 1'b1;
      end
      EMUL2: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGIDX_WIDTH-1:1]==inst_vs2[`REGIDX_WIDTH-1:1])&(inst_vs2[0]!=1'b1));
      end
      EMUL4: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGIDX_WIDTH-1:2]==inst_vs2[`REGIDX_WIDTH-1:2])&(inst_vs2[1:0]!=2'b11));
      end
      EMUL8: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGIDX_WIDTH-1:3]==inst_vs2[`REGIDX_WIDTH-1:3])&(inst_vs2[2:0]!=3'b110));
      end
    endcase
  end

`ifdef ZVT_ON
  always_comb begin
    case(eew_mt)
      EEW16:   check_mtd_align = inst_vd[1]=='b0;
      EEW32:   check_mtd_align = inst_vd[2:1]=='b0;
      default: check_mtd_align = 1'b1;
    endcase
  end

  always_comb begin
    check_vme_vs1_align = 'b0;
    check_vme_vs2_align = 'b0;
    
    case(eew_vs1)
      EEW16:   check_vme_vs1_align = (inst_vs1[2]=='b0) && (inst_vs1[0]=='b0);
      EEW32:   check_vme_vs1_align = (inst_vs1[1:0]=='b0);
      default: check_vme_vs1_align = (inst_vs1[2:1]=='b0);
    endcase

    case(eew_vs2)
      EEW16:   check_vme_vs2_align = (inst_vs2[2]=='b0) && (inst_vs2[0]=='b0);
      EEW32:   check_vme_vs2_align = (inst_vs2[1:0]=='b0);
      default: check_vme_vs2_align = (inst_vs2[2:1]=='b0);
    endcase
  end

  assign check_tm = (|csr_tm) && (csr_tm<=`TE);  // 0<tm<=`TE
  assign check_tn = (|csr_tn) && (csr_tn<=`TE);  // 0<tm<=`TE

  always_comb begin
    case(csr_sew)
      SEW8 :   check_tk = (|csr_tk) && (csr_tk<=3'd4);  // 0<tk<=4
      SEW16:   check_tk = (|csr_tk) && (csr_tk<=3'd2);  // 0<tk<=2
      SEW32:   check_tk = csr_tk==3'd1;
      default: check_tk = 'b0;
    endcase
  end
`endif

  // start to check special requirements for every instructions
  always_comb begin 
    check_special = 'b0;
    
    case(inst_funct3)
      OPIVV: begin
        case(inst_funct6)
          VADD,
          VSUB,
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
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSSRL,
          VSSRA,
          VSLIDEDOWN: begin
            check_special = check_vd_overlap_v0;
          end
        
          VADC,
          VSBC: begin
            check_special = (inst_vm==1'b0)&(inst_vd!='b0);
          end

          VMADC,
          VMSBC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSLTU,
          VMSLT: begin
            check_special = check_vd_part_overlap_vs2&check_vd_part_overlap_vs1;
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
          end
          
          VMERGE_VMV: begin
            // when vm=1, it is vmv instruction and vs2_index must be 5'b0.
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(inst_vs2=='b0));
          end
               
          VWREDSUMU,
          VWREDSUM: begin
            check_special = (csr_vstart=='b0);
          end

          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2&check_vd_overlap_vs1;                
          end

         `ifdef ZVT_ON
          VTXMMXTVV: begin
            check_special = inst_vm&check_tm&check_tn&check_tk&check_mtd_align&(csr_vstart=='b0);
          end
        `endif
        endcase
      end
      OPIVX: begin
        case(inst_funct6)
          VADD,
          VSUB,
          VRSUB,
          VAND,
          VOR,
          VXOR,
          VMINU,
          VMIN,
          VMAXU,
          VMAX,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSUBU,
          VSSUB,
          VSMUL_VMVNRR,
          VSSRL,
          VSSRA,
          VSLIDEDOWN: begin
            check_special = check_vd_overlap_v0;
          end
        
          VADC,
          VSBC: begin
            check_special = (inst_vm==1'b0)&(inst_vd!='b0);
          end

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
            check_special = check_vd_part_overlap_vs2;
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
          end
          
          VMERGE_VMV: begin
            // when vm=1, it is vmv instruction and vs2_index must be 5'b0.
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(inst_vs2=='b0));
          end
               
          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;
          end
        endcase
      end
      OPIVI: begin
        case(inst_funct6)
          VADD,
          VRSUB,
          VAND,
          VOR,
          VXOR,
          VSLL,
          VSRL,
          VSRA,
          VSADDU,
          VSADD,
          VSSRL,
          VSSRA,
          VSLIDEDOWN: begin
            check_special = check_vd_overlap_v0;
          end

          VADC: begin
            check_special = (inst_vm==1'b0)&(inst_vd!='b0);
          end

          VMADC,
          VMSEQ,
          VMSNE,
          VMSLEU,
          VMSLE,
          VMSGTU,
          VMSGT: begin
            check_special = check_vd_part_overlap_vs2;
          end

          VNSRL,
          VNSRA,
          VNCLIPU,
          VNCLIP: begin
            check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
          end
          
          VMERGE_VMV: begin
            // when vm=1, it is vmv instruction and vs2_index must be 5'b0.
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(inst_vs2=='b0));
          end
               
          VSMUL_VMVNRR: begin
            check_special = (inst_vm == 1'b1)&(inst_vs1[4:3]==2'b0)&
                            ((inst_nr==NREG1)|(inst_nr==NREG2)|(inst_nr==NREG4)|(inst_nr==NREG8));
          end

          VSLIDEUP_RGATHEREI16,
          VRGATHER: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;
          end
        endcase
      end

      OPMVV: begin
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
          VWMACCSU: begin
            // overlap constraint
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1&check_vs1_part_overlap_vd_2_1;                
          end

          VWADDU_W,
          VWSUBU_W,
          VWADD_W,
          VWSUB_W: begin
            // overlap constraint
            check_special = check_vd_overlap_v0&check_vs1_part_overlap_vd_2_1;                
          end
          
          VXUNARY0: begin
            case(vs1_opcode) 
              VZEXT_VF2,
              VSEXT_VF2: begin
                // overlap constraint
                check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;                
              end
              VZEXT_VF4,
              VSEXT_VF4: begin
                // overlap constraint
                check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_4_1;                
              end
            endcase
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
            check_special = check_vd_overlap_v0;          
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
            check_special = (csr_vstart=='b0);
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
            check_special = inst_vm;
          end
          
          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST: begin
                check_special = (csr_vstart=='b0);
              end
              VMV_X_S: begin
                check_special = (inst_vm==1'b1);
              end
            endcase
          end

          VMUNARY0: begin
            case(vs1_opcode)
              VMSBF,
              VMSIF,
              VMSOF,
              VIOTA: begin
                check_special = (csr_vstart=='b0)&check_vd_overlap_v0&check_vd_overlap_vs2;
              end
              VID: begin
                check_special = (inst_vs2=='b0)&check_vd_overlap_v0;
              end
            endcase
          end

          VCOMPRESS_VTMVTV: begin
            // destination register group cannot overlap the source register group
            check_special = (csr_vstart=='b0)&inst_vm&check_vd_overlap_vs2&check_vd_overlap_vs1;
          end
        endcase
      end
      OPMVX: begin
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
            // overlap constraint
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;                
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
          VSLIDE1DOWN: begin
            check_special = check_vd_overlap_v0;          
          end

          VWRXUNARY0: begin
            case(vs2_opcode)
              VMV_S_X: check_special = inst_vm&(inst_vs2=='b0)&(csr_vstart=='b0);
            `ifdef ZVT_ON
              VTMVVT:  check_special = inst_vm;
              VTZERO:  check_special = inst_vm&(inst_vs1==5'b00000)&(inst_vd[0]=='b0)&check_mtd_align&check_tm&check_tn;
            `endif
            endcase
          end

          VSLIDE1UP: begin
            // destination register group cannot overlap the source register group
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;
          end

        `ifdef ZVT_ON
          VCOMPRESS_VTMVTV: begin
            check_special = inst_vm&(inst_vd==5'b00000)&check_tn&(csr_vstart<=(`VSTART_WIDTH)'(tss.index));
          end
        `endif
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1&check_vs1_part_overlap_vd_2_1;
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
          VFSGNJX: begin
            check_special = check_vd_overlap_v0;          
          end

          VFUNARY1: begin
            case(vs1_opcode)
              VFSQRT,
              VFRSQRT7,
              VFREC7,
              VFCLASS: begin          
                check_special = check_vd_overlap_v0;          
              end
            endcase
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE: begin
            check_special = check_vd_part_overlap_vs2&check_vd_part_overlap_vs1;
          end

          VFUNARY0: begin
            case(vs1_opcode)
              `ifdef ZVFBFWMA_ON
              VFNCVTBF16: begin
                check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;
              end
              VFWCVTBF16: begin
                check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;
              end
              `endif
              VFCVT_XUFV, 
              VFCVT_XFV,
              VFCVT_RTZXUFV,
              VFCVT_RTZXFV,
              VFCVT_FXUV,
              VFCVT_FXV: begin
                check_special = check_vd_overlap_v0;          
              end
              VFWCVTFXU,
              VFWCVTFX: begin
                check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;          
              end
              VFNCVTXUF,
              VFNCVTXF,
              VFNCVTRTZXUF,
              VFNCVTRTZXF: begin
                check_special = check_vd_overlap_v0&check_vd_part_overlap_vs2;          
              end
            endcase
          end

          VFREDOSUM,
          VFREDUSUM,
          VFREDMAX,
          VFREDMIN: begin
            check_special = (csr_vstart=='b0);
          end

          VWRFUNARY0: begin
            check_special = inst_vm&(vs1_opcode==VFMV_F_S);
          end

        `ifdef ZVT_ON
          VTXMMXTVV: begin
            // Per Zvt §15.1.1.8 matrix arith traps on non-zero vstart.
            // Mirrors the OPIVV arm at line 3147-3151 which already gates on
            // (csr_vstart=='b0).
            check_special = inst_vm&check_tm&check_tn&check_tk&check_mtd_align&(csr_vstart=='b0);
          end
        `endif
        endcase
      end

      OPFVF: begin
        case(inst_funct6)
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            check_special = check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1;
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
          VFMIN,
          VFMAX,
          VFSGNJ,
          VFSGNJN,
          VFSGNJX,
          VFSLIDE1DOWN: begin
            check_special = check_vd_overlap_v0;          
          end

          VMFEQ,
          VMFNE,
          VMFLT,
          VMFLE,
          VMFGT,
          VMFGE: begin
            check_special = check_vd_part_overlap_vs2;
          end

          VFMERGE_VFMV: begin
            check_special = ((inst_vm=='b0)&(inst_vd!='b0)) | ((inst_vm==1'b1)&(vs2_opcode=='b0));
          end

          VWRFUNARY0: begin
            check_special = inst_vm&(vs2_opcode==VFMV_S_F)&(csr_vstart=='b0);
          end

          VFSLIDE1UP: begin
            check_special = check_vd_overlap_v0&check_vd_overlap_vs2;          
          end
        endcase
      end
      `endif
    endcase
  end

  //check common requirements for all instructions
  assign check_common = (!csr_vill)&check_vd_align&check_sew&check_lmul&(check_vs2_align&check_vs1_align
                      `ifdef ZVT_ON
                        || isVmeAlu
                      `endif
                        )&
                      `ifdef ZVE32F_ON
                        check_frm&
                      `endif
                        check_vl_not_0&check_vstart_sle_vl;

  // check whether vd is aligned to emul_vd
  always_comb begin
    check_vd_align = 'b0; 

    case(emul_vd)
      EMUL_NONE,
      EMUL1: begin
        check_vd_align = 1'b1; 
      end
      EMUL2: begin
        check_vd_align = (inst_vd[0]==1'b0); 
      end
      EMUL4: begin
        check_vd_align = (inst_vd[1:0]==2'b0); 
      end
      EMUL8: begin
        check_vd_align = (inst_vd[2:0]==3'b0); 
      end
    endcase
  end

`ifdef ZVT_ON
  // VME arithmetic instructions use special case to check vs2 and vs1
  always_comb begin
    case(inst_funct3)
      OPFVV,
      OPIVV:   isVmeAlu = inst_funct6==VTXMMXTVV;
      default: isVmeAlu = 'b0;
    endcase
  end
`endif

  // check whether vs2 is aligned to emul_vs2
  always_comb begin
    check_vs2_align = 'b0; 

    case(emul_vs2)
      EMUL_NONE,
      EMUL1: begin
        check_vs2_align = 1'b1; 
      end
      EMUL2: begin
        check_vs2_align = (inst_vs2[0]==1'b0); 
      end
      EMUL4: begin
        check_vs2_align = (inst_vs2[1:0]==2'b0); 
      end
      EMUL8: begin
        check_vs2_align = (inst_vs2[2:0]==3'b0); 
      end
    endcase
  end
    
  // check whether vs1 is aligned to emul_vs1
  always_comb begin
    check_vs1_align = 'b0; 
    
    case(emul_vs1)
      EMUL_NONE,
      EMUL1: begin
        check_vs1_align = 1'b1; 
      end
      EMUL2: begin
        check_vs1_align = (inst_vs1[0]==1'b0); 
      end
      EMUL4: begin
        check_vs1_align = (inst_vs1[1:0]==2'b0); 
      end
      EMUL8: begin
        check_vs1_align = (inst_vs1[2:0]==3'b0); 
      end
    endcase
  end
 
  // check the validation of EEW
  assign check_sew = (eew_max != EEW_NONE);
    
  // check the validation of EMUL
  assign check_lmul = (emul_max != EMUL_NONE);

  // effect vstart
  assign offset = inst_funct3==OPIVI ? `XLEN'(inst_imm) : rs1;

  always_comb begin
    evstart = {1'b0, csr_vstart};
    
    case(inst_funct3)
      OPIVX,
      OPIVI: begin
        case(inst_funct6)
          VSLIDEUP_RGATHEREI16: begin 
            case(csr_sew)
              SEW8 : begin
                if (|offset[`XLEN-1:`VSTART_WIDTH])
                  evstart = (`VL_WIDTH)'('1);
                else if (csr_vstart < offset[`VSTART_WIDTH-1:0])
                  evstart = {1'b0, offset[`VSTART_WIDTH-1:0]};
              end
              SEW16: begin
                if ((|offset[`XLEN-1:`VSTART_WIDTH-1]) || csr_vstart[`VSTART_WIDTH-1])
                  evstart = (`VL_WIDTH)'('1);
                else if (csr_vstart[`VSTART_WIDTH-2:0] < offset[`VSTART_WIDTH-2:0])
                  evstart = {2'b0, offset[`VSTART_WIDTH-2:0]};
              end
              default: begin // SEW32
                if ((|offset[`XLEN-1:`VSTART_WIDTH-2]) || (|csr_vstart[`VSTART_WIDTH-2]))
                  evstart = (`VL_WIDTH)'('1);
                else if (csr_vstart[`VSTART_WIDTH-3:0] < offset[`VSTART_WIDTH-3:0])
                  evstart = {3'b0, offset[`VSTART_WIDTH-3:0]};
              end
            endcase
          end
        endcase
      end

      `ifdef ZVT_ON
      OPMVX: begin
        if((inst_funct6==VWRXUNARY0)&&(vs2_opcode==VTZERO)) evstart = 'b0;
      end
      `endif
    endcase
  end

  // get evl
  always_comb begin
    evl = csr_vl;
  
    case(inst_funct3)
      OPIVI: begin
        case(inst_funct6)
          VSMUL_VMVNRR: begin
            // vmv<nr>r.v
            case(emul_max)
              EMUL1: begin
                case(eew_max)
                  EEW8: begin
                    evl = 1*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 1*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 1*`VLEN/32;
                  end
                endcase
              end
              EMUL2: begin
                case(eew_max)
                  EEW8: begin
                    evl = 2*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 2*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 2*`VLEN/32;
                  end
                endcase
              end
              EMUL4: begin
                case(eew_max)
                  EEW8: begin
                    evl = 4*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 4*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 4*`VLEN/32;
                  end
                endcase
              end
              EMUL8: begin
                case(eew_max)
                  EEW8: begin
                    evl = 8*`VLEN/8;
                  end
                  EEW16: begin
                    evl = 8*`VLEN/16;
                  end
                  EEW32: begin
                    evl = 8*`VLEN/32;
                  end
                endcase
              end
            endcase
          end
        endcase
      end

      OPMVX: begin
        case(inst_funct6)
          VWRXUNARY0: begin
            if(vs2_opcode==VMV_S_X) begin
              evl = 'b1;
            end
          end
        endcase
      end

      `ifdef ZVE32F_ON
      OPFVF: begin
        case(inst_funct6)
          VWRFUNARY0: begin
            if(vs2_opcode==VFMV_S_F) begin
              evl = 'b1;
            end
          end
        endcase
      end
      `endif      
    endcase
  end

  // check vl is not 0
  // check vstart < vl
  always_comb begin
    check_vl_not_0      = csr_vl!='b0;
    check_vstart_sle_vl = {1'b0, csr_vstart} < csr_vl;
    
    // Instructions that write an x register or f register do so even when vstart >= vl, including when vl=0.
    case(inst_funct3) 

      OPIVI: begin
        case(inst_funct6)
          VSMUL_VMVNRR: begin
            check_vl_not_0      = evl!='b0;
            check_vstart_sle_vl = {1'b0,csr_vstart} < evl;
          end
        endcase
      end

      OPMVV: begin
        case(inst_funct6)
          VWRXUNARY0: begin
            case(vs1_opcode)
              VCPOP,
              VFIRST,
              VMV_X_S: begin
                check_vl_not_0      = 'b1;
                check_vstart_sle_vl = 'b1;
              end
            endcase
          end
        endcase
      end
      `ifdef ZVE32F_ON
      OPFVV: begin
        case(inst_funct6)
          VWRFUNARY0: begin
            if(vs1_opcode==VFMV_F_S) begin
              check_vl_not_0      = 'b1;
              check_vstart_sle_vl = 'b1;
            end
          end
        endcase
      end
      `endif      
    endcase
  end

`ifdef ZVE32F_ON
  // check FP rounding mode is legal
  assign check_frm = (inst.arch_state.frm < 3'd5) && valid_opf || !valid_opf;
`endif

  `ifdef ASSERT_ON
    `ifdef TB_SUPPORT
      `rvv_forbid((inst_valid==1'b1)&(inst_encoding_correct==1'b0))
      else $warning("pc(0x%h) instruction will be discarded directly.\n",$sampled(inst.inst_pc));
    `else
      `rvv_forbid((inst_valid==1'b1)&(inst_encoding_correct==1'b0))
      else $warning("This instruction will be discarded directly.\n");
    `endif
  `endif

// get the start number of uop_index
  always_comb begin
    if((inst_funct6==VWRXUNARY0)&(inst_funct3==OPMVV)&(vs1_opcode==VMV_X_S)) begin
      uop_vstart = 'b0;
    end
   `ifdef ZVE32F_ON
    else if((inst_funct6==VWRFUNARY0)&(inst_funct3==OPFVV)&(vs1_opcode==VFMV_F_S)) begin
      uop_vstart = 'b0;
    end
    `endif
    else begin
      case(eew_max)
        EEW8: begin
          uop_vstart = (`UOP_INDEX_WIDTH)'(evstart[$clog2(`VLENB) +: `UOP_INDEX_WIDTH_ALU]);
        end
        EEW16: begin
          uop_vstart = (`UOP_INDEX_WIDTH)'(evstart[$clog2(`VLENH) +: `UOP_INDEX_WIDTH_ALU]);
        end
        EEW32: begin
          uop_vstart = (`UOP_INDEX_WIDTH)'(evstart[$clog2(`VLENW) +: `UOP_INDEX_WIDTH_ALU]);
        end
        default: begin
          uop_vstart = 'b0;
        end
      endcase
    end
  end

  // update force_vma_agnostic
  //When source and destination registers overlap and have different EEW, the instruction is mask- and tail-agnostic.
  assign force_vma_agnostic = ((check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE)) |
                              ((check_vd_overlap_vs1==1'b0)&(eew_vd!=eew_vs1)&(eew_vd!=EEW_NONE)&(eew_vs1!=EEW_NONE));

  // update force_vta_agnostic
  assign force_vta_agnostic = (eew_vd==EEW1) |   // Mask destination tail elements are always treated as tail-agnostic
         //When source and destination registers overlap and have different EEW, the instruction is mask- and tail-agnostic.
                              ((check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE)) |
                              ((check_vd_overlap_vs1==1'b0)&(eew_vd!=eew_vs1)&(eew_vd!=EEW_NONE)&(eew_vs1!=EEW_NONE));

  // result
  always_comb begin
    lcmd.cmd                     = inst;
    lcmd.cmd.arch_state.vstart   = evstart;
  end

  assign lcmd_valid              = inst_encoding_correct;
  assign lcmd.eew_vs1            = eew_vs1;
  assign lcmd.eew_vs2            = eew_vs2;
  assign lcmd.eew_vd             = eew_vd;
`ifdef ZVT_ON
  assign lcmd.eew_mt             = eew_mt;
`endif
  assign lcmd.eew_max            = eew_max;
  assign lcmd.emul_vs1           = emul_vs1;
  assign lcmd.emul_vs2           = emul_vs2;
  assign lcmd.emul_vd            = emul_vd;
  assign lcmd.emul_max           = emul_max;
  assign lcmd.uop_vstart         = uop_vstart;
  assign lcmd.uop_index_max      = uop_index_max;
  assign lcmd.evl                = evl;
  assign lcmd.force_vma_agnostic = force_vma_agnostic;
  assign lcmd.force_vta_agnostic = force_vta_agnostic;


endmodule
