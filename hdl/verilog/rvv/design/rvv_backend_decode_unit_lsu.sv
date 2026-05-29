
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_decode_unit_lsu
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
  logic   [`FUNCT6_WIDTH-1:0]         inst_funct6;      // inst original encoding[31:26]
  logic   [`NFIELD_WIDTH-1:0]         inst_nf;          // inst original encoding[31:29]
  logic   [`VM_WIDTH-1:0]             inst_vm;          // inst original encoding[25]
  logic   [`REGFILE_INDEX_WIDTH-1:0]  inst_vs2;         // inst original encoding[24:20]
  logic   [`UMOP_WIDTH-1:0]           inst_umop;        // inst original encoding[24:20]
  logic   [`FUNCT3_WIDTH-1:0]         inst_funct3;      // inst original encoding[14:12]
  logic   [`REGFILE_INDEX_WIDTH-1:0]  inst_vd;          // inst original encoding[11:7]
  RVVOpCode                           inst_opcode;      // inst original encoding[6:0]

  logic   [`VSTART_WIDTH-1:0]         csr_vstart;
  logic   [`VL_WIDTH-1:0]             csr_vl;
  logic   [`VL_WIDTH-1:0]             evl;
  RVVConfigState                      vector_csr_lsu;
  RVVSEW                              csr_sew;
  RVVLMUL                             csr_lmul;
  EMUL_e                              emul_vd;
  EMUL_e                              emul_vs2;
  EMUL_e                              emul_vd_nf;
  EMUL_e                              emul_max;
  logic   [`UOP_INDEX_WIDTH-1:0]      uop_index_max;
  EEW_e                               eew_vd;
  EEW_e                               eew_vs2;
  EEW_e                               eew_max;
  logic                               valid_lsu;
  logic                               valid_lsu_opcode;
  logic                               valid_lsu_mop;
  logic                               inst_encoding_correct;
  logic                               check_special;
  logic                               check_vd_overlap_v0;
  logic                               check_vd_part_overlap_vs2;
  logic   [`REGFILE_INDEX_WIDTH:0]    vd_index_start;
  logic   [`REGFILE_INDEX_WIDTH:0]    vd_index_end;
  logic   [`REGFILE_INDEX_WIDTH-1:0]  vd_index_offset;
  logic                               check_vd_overlap_vs2;
  logic                               check_vs2_part_overlap_vd_2_1;
  logic                               check_vs2_part_overlap_vd_4_1;
  logic                               check_common;
  logic                               check_vd_align;
  logic                               check_vs2_align;
  logic                               check_vd_in_range;
  logic   [`REGFILE_INDEX_WIDTH-1:0]  check_vd_cmp;
  logic                               check_sew;
  logic                               check_lmul;
  logic                               check_evl_not_0;
  logic                               inst_is_nop;
  logic                               check_vstart_sle_evl;
  logic                               check_frm;
  FUNCT6_u                            funct6_lsu;
  logic                               force_vma_agnostic;
  logic                               force_vta_agnostic;
  genvar                              j;

  // local parameter for SEW in original endocing[14:12]
  localparam  SEW_8     = 3'b000;
  localparam  SEW_16    = 3'b101;
  localparam  SEW_32    = 3'b110;

//
// decode
//
  assign inst_funct6    = inst_valid ? inst.bits[24:19] : 'b0;
  assign inst_nf        = inst_valid ? inst.bits[24:22] : 'b0;
  assign inst_vm        = inst_valid ? inst.bits[18] : 'b0;
  assign inst_vs2       = inst_valid ? inst.bits[17:13] : 'b0;
  assign inst_umop      = inst_valid ? inst.bits[17:13] : 'b0;
  assign inst_funct3    = inst_valid ? inst.bits[7:5] : 'b0;
  assign inst_vd        = inst_valid ? inst.bits[4:0] : 'b0;
  assign inst_opcode    = inst_valid ? inst.opcode : LOAD;
  assign vector_csr_lsu = inst_valid ? inst.arch_state : RVVConfigState'('0);
  assign csr_vstart     = inst_valid ? inst.arch_state.vstart : 'b0;
  assign csr_vl         = inst_valid ? inst.arch_state.vl : 'b0;
  assign csr_sew        = inst_valid ? inst.arch_state.sew : SEW8;
  assign csr_lmul       = inst_valid ? inst.arch_state.lmul : LMULRESERVED;

// decode funct6
  // valid signal
  assign valid_lsu = valid_lsu_opcode&valid_lsu_mop&inst_valid;

  // identify load or store
  always_comb begin
    funct6_lsu.lsu_funct6.lsu_is_store = IS_LOAD;
    valid_lsu_opcode                   = 'b0;

    case(inst_opcode)
      LOAD: begin
        funct6_lsu.lsu_funct6.lsu_is_store = IS_LOAD;
        valid_lsu_opcode                   = 1'b1;
      end
      STORE: begin
        funct6_lsu.lsu_funct6.lsu_is_store = IS_STORE;
        valid_lsu_opcode                   = 1'b1;
      end
    endcase

  // lsu_mop distinguishes unit-stride, constant-stride, unordered index, ordered index
  // lsu_umop identifies what unit-stride instruction belong to when lsu_mop=US
    // initial
    funct6_lsu.lsu_funct6.lsu_mop    = US;
    funct6_lsu.lsu_funct6.lsu_umop   = US_US;
    funct6_lsu.lsu_funct6.lsu_is_seg = NONE;
    valid_lsu_mop                    = 'b0;

    case(inst_funct6[2:0])
      UNIT_STRIDE: begin
        case(inst_umop)
          US_REGULAR: begin
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_US;
            valid_lsu_mop                    = 1'b1;
            funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
          end
          US_WHOLE_REGISTER: begin
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_WR;
            valid_lsu_mop                    = 1'b1;
          end
          US_MASK: begin
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_MK;
            valid_lsu_mop                    = 1'b1;
          end
          US_FAULT_FIRST: begin
            funct6_lsu.lsu_funct6.lsu_mop    = US;
            funct6_lsu.lsu_funct6.lsu_umop   = US_FF;
            valid_lsu_mop                    = 1'b1;
            funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
          end
        endcase
      end
      UNORDERED_INDEX: begin
        funct6_lsu.lsu_funct6.lsu_mop    = IU;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
      CONSTANT_STRIDE: begin
        funct6_lsu.lsu_funct6.lsu_mop    = CS;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
      ORDERED_INDEX: begin
        funct6_lsu.lsu_funct6.lsu_mop    = IO;
        valid_lsu_mop                    = 1'b1;
        funct6_lsu.lsu_funct6.lsu_is_seg = (inst_nf!=NF1) ? IS_SEGMENT : NONE;
      end
    endcase
  end

// get EMUL
  always_comb begin
    // initial
    emul_vd         = EMUL_NONE;
    emul_vs2        = EMUL_NONE;
    emul_vd_nf      = EMUL_NONE;
    emul_max        = EMUL_NONE;
    uop_index_max   = 'd0;

    if (valid_lsu) begin
      case(funct6_lsu.lsu_funct6.lsu_mop)
        US: begin
          case(funct6_lsu.lsu_funct6.lsu_umop)
            US_US,
            US_FF: begin
              case(inst_nf)
                // emul_vd = ceil(inst_funct3/csr_sew*csr_lmul)
                // emul_vd_nf = NF*emul_vd
                // emul_vs2: no emul_vs2 for unit
                // emul_max = max(emul_vd_nf,emul_vs2) = emul_vd_nf
                // uop_index_max = NF*max(emul_vd,emul_vs2) = emul_vd_nf
                NF1: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL_e'(csr_lmul);
                          emul_max      = EMUL_e'(csr_lmul);
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL_e'(csr_lmul);
                          emul_max      = EMUL_e'(csr_lmul);
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL_e'(csr_lmul);
                          emul_max      = EMUL_e'(csr_lmul);
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL8;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL1_2: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL8;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL1;
                          emul_max      = EMUL1;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                      endcase
                    end
                  endcase
                end
                NF2: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL1_2: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL4;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL2;
                          emul_max      = EMUL2;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                      endcase
                    end
                  endcase
                end
                NF3: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL1_2: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL3;
                          emul_max      = EMUL3;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                  endcase
                end
                NF4: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL2: begin
                          emul_vd       = EMUL_e'(csr_lmul);
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL1: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL1_2: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL4: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL4;
                          emul_max      = EMUL4;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                        end
                        LMUL8: begin
                          emul_vd       = EMUL2;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                  endcase
                end
                NF5: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL5;
                          emul_max      = EMUL5;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                        end
                      endcase
                    end
                  endcase
                end
                NF6: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL6;
                          emul_max      = EMUL6;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                        end
                      endcase
                    end
                  endcase
                end
                NF7: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL7;
                          emul_max      = EMUL7;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                        end
                      endcase
                    end
                  endcase
                end
                NF8: begin
                  case({inst_funct3,csr_sew})
                    // 1:1
                    {SEW_8,SEW8},
                    {SEW_16,SEW16},
                    {SEW_32,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2,
                        LMUL1: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 2:1
                    {SEW_16,SEW8},
                    {SEW_32,SEW16}: begin
                      case(csr_lmul)
                        LMUL1_4,
                        LMUL1_2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 4:1
                    {SEW_32,SEW8}: begin
                      case(csr_lmul)
                        LMUL1_4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:2
                    {SEW_8,SEW16},
                    {SEW_16,SEW32}: begin
                      case(csr_lmul)
                        LMUL1_2,
                        LMUL1,
                        LMUL2: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                    // 1:4
                    {SEW_8,SEW32}: begin
                      case(csr_lmul)
                        LMUL1,
                        LMUL2,
                        LMUL4: begin
                          emul_vd       = EMUL1;
                          emul_vd_nf    = EMUL8;
                          emul_max      = EMUL8;
                          uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                        end
                      endcase
                    end
                  endcase
                end
              endcase
            end
            US_WR: begin
              case(inst_nf)
                NF1: begin
                  emul_vd       = EMUL1;
                  emul_vd_nf    = EMUL1;
                  emul_max      = EMUL1;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                end
                NF2: begin
                  emul_vd       = EMUL2;
                  emul_vd_nf    = EMUL2;
                  emul_max      = EMUL2;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                end
                NF4: begin
                  emul_vd       = EMUL4;
                  emul_vd_nf    = EMUL4;
                  emul_max      = EMUL4;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                end
                NF8: begin
                  emul_vd       = EMUL8;
                  emul_vd_nf    = EMUL8;
                  emul_max      = EMUL8;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                end
              endcase
            end
            US_MK: begin
              case(csr_lmul)
                LMUL1_4,
                LMUL1_2,
                LMUL1,
                LMUL2,
                LMUL4,
                LMUL8: begin
                  emul_vd       = EMUL1;
                  emul_vd_nf    = EMUL1;
                  emul_max      = EMUL1;
                  uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                end
              endcase
            end
          endcase
        end

        CS: begin
          case(inst_nf)
            // emul_vd = ceil(inst_funct3/csr_sew*csr_lmul)
            // emul_vs2: no emul_vs2 for unit
            // emul_vd_nf = NF*emul_vd
            // emul_max = max(emul_vd_nf,emul_vs2) = emul_vd_nf
            // uop_index_max = NF*max(emul_vd,emul_vs2) = emul_vd_nf
            NF1: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL8;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL8;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                  endcase
                end
              endcase
            end
            NF2: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                  endcase
                end
              endcase
            end
            NF3: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF4: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            NF5: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
              endcase
            end
            NF6: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF7: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
              endcase
            end
            NF8: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1,
                    LMUL2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1,
                    LMUL2,
                    LMUL4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
          endcase
        end

        IU,
        IO: begin
          case(inst_nf)
            // emul_vd = ceil(csr_lmul)
            // emul_vd_nf = NF*emul_vd
            // emul_vs2 = ceil(inst_funct3/csr_sew*csr_lmul)
            // emul_max = max(emul_vd_nf,emul_vs2)
            // uop_index_max = NF*max(emul_vd,emul_vs2)
            NF1: begin
              case({inst_funct3,csr_sew})
                // 1:1
                // {vs2,vd}
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL1;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL1;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d0);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL8: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL_e'(csr_lmul);
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL_e'(csr_lmul);
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            NF2: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL2;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL4;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL2;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL2;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d1);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL4: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            NF3: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d23);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL3;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL3;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d2);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF4: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2       = EMUL_e'(csr_lmul);
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL8;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d31);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL4;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL4;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d3);
                    end
                    LMUL2: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
            NF5: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d9);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d9);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d19);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL5;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL5;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d4);
                    end
                  endcase
                end
              endcase
            end
            NF6: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d11);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d23);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL6;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL6;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d5);
                    end
                  endcase
                end
              endcase
            end
            NF7: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d13);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d13);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d27);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL7;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL7;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d6);
                    end
                  endcase
                end
              endcase
            end
            NF8: begin
              case({inst_funct3,csr_sew})
                // 1:1
                {SEW_8,SEW8},
                {SEW_16,SEW16},
                {SEW_32,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 2:1
                {SEW_16,SEW8},
                {SEW_32,SEW16}: begin
                  case(csr_lmul)
                    LMUL1_4,
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                  endcase
                end
                // 4:1
                {SEW_32,SEW8}: begin
                  case(csr_lmul)
                    LMUL1_4: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                    LMUL1_2: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL2;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d15);
                    end
                    LMUL1: begin
                      emul_vd       = EMUL_e'(csr_lmul);
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL4;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d31);
                    end
                  endcase
                end
                // 1:2
                {SEW_8,SEW16},
                {SEW_16,SEW32}: begin
                  case(csr_lmul)
                    LMUL1_2,
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
                // 1:4
                {SEW_8,SEW32}: begin
                  case(csr_lmul)
                    LMUL1: begin
                      emul_vd       = EMUL1;
                      emul_vd_nf    = EMUL8;
                      emul_vs2      = EMUL1;
                      emul_max      = EMUL8;
                      uop_index_max = (`UOP_INDEX_WIDTH)'('d7);
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
      endcase
    end
  end

// get EEW
  always_comb begin
    // initial
    eew_vd  = EEW_NONE;
    eew_vs2 = EEW_NONE;
    eew_max = EEW_NONE;

    if (valid_lsu) begin
      case(funct6_lsu.lsu_funct6.lsu_mop)
        US: begin
          case(funct6_lsu.lsu_funct6.lsu_umop)
            US_US,
            US_WR,
            US_FF: begin
              case(inst_funct3)
                SEW_8: begin
                  eew_vd          = EEW8;
                  eew_max         = EEW8;
                end
                SEW_16: begin
                  eew_vd          = EEW16;
                  eew_max         = EEW16;
                end
                SEW_32: begin
                  eew_vd          = EEW32;
                  eew_max         = EEW32;
                end
              endcase
            end
            US_MK: begin
              case(inst_funct3)
                SEW_8: begin
                  eew_vd          = EEW1;
                  eew_max         = EEW1;
                end
              endcase
            end
          endcase
        end
        CS: begin
          case(inst_funct3)
            SEW_8: begin
              eew_vd          = EEW8;
              eew_max         = EEW8;
            end
            SEW_16: begin
              eew_vd          = EEW16;
              eew_max         = EEW16;
            end
            SEW_32: begin
              eew_vd          = EEW32;
              eew_max         = EEW32;
            end
          endcase
        end
        IU,
        IO: begin
          case({inst_funct3,csr_sew})
            {SEW_8,SEW8}: begin
              eew_vd          = EEW8;
              eew_vs2         = EEW8;
              eew_max         = EEW8;
            end
            {SEW_8,SEW16}: begin
              eew_vd          = EEW16;
              eew_vs2         = EEW8;
              eew_max         = EEW16;
            end
            {SEW_8,SEW32}: begin
              eew_vd          = EEW32;
              eew_vs2         = EEW8;
              eew_max         = EEW32;
            end
            {SEW_16,SEW8}: begin
              eew_vd          = EEW8;
              eew_vs2         = EEW16;
              eew_max         = EEW16;
            end
            {SEW_16,SEW16}: begin
              eew_vd          = EEW16;
              eew_vs2         = EEW16;
              eew_max         = EEW16;
            end
            {SEW_16,SEW32}: begin
              eew_vd          = EEW32;
              eew_vs2         = EEW16;
              eew_max         = EEW32;
            end
            {SEW_32,SEW8}: begin
              eew_vd          = EEW8;
              eew_vs2         = EEW32;
              eew_max         = EEW32;
            end
            {SEW_32,SEW16}: begin
              eew_vd          = EEW16;
              eew_vs2         = EEW32;
              eew_max         = EEW32;
            end
            {SEW_32,SEW32}: begin
              eew_vd          = EEW32;
              eew_vs2         = EEW32;
              eew_max         = EEW32;
            end
          endcase
        end
      endcase
    end
  end

//
// instruction encoding error check
//
  assign inst_encoding_correct = check_special&check_common&valid_lsu;

  // check whether vd overlaps v0 when vm=0
  // check_vd_overlap_v0=1 means that vd does NOT overlap v0
  assign check_vd_overlap_v0 = (((inst_vm==1'b0)&(inst_vd!='b0)) | (inst_vm==1'b1));

  // check whether vd partially overlaps vs2 with EEW_vd<EEW_vs2
  // check_vd_part_overlap_vs2=1 means that vd group does NOT overlap vs2 group partially
  // used in regular index load/store
  always_comb begin
    check_vd_part_overlap_vs2     = 'b0;

    case(emul_vs2)
      EMUL1: begin
        check_vd_part_overlap_vs2 = 1'b1;
      end
      EMUL2: begin
        check_vd_part_overlap_vs2 = !((inst_vd[0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs2[`REGFILE_INDEX_WIDTH-1:1])));
      end
      EMUL4: begin
        check_vd_part_overlap_vs2 = !((inst_vd[1:0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs2[`REGFILE_INDEX_WIDTH-1:2])));
      end
      EMUL8 : begin
        check_vd_part_overlap_vs2 = !((inst_vd[2:0]!='b0) & ((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs2[`REGFILE_INDEX_WIDTH-1:3])));
      end
    endcase
  end

  // vd cannot overlap vs2
  // check_vd_overlap_vs2=1 means that vd group does NOT overlap vs2 group fully
  // used in segment index load/store
  assign vd_index_start = {1'b0,inst_vd};

  always_comb begin
    case(emul_vd_nf)
      EMUL2:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d1);
      EMUL3:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d2);
      EMUL4:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d3);
      EMUL5:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d4);
      EMUL6:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d5);
      EMUL7:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d6);
      EMUL8:   vd_index_offset = (`REGFILE_INDEX_WIDTH)'('d7);
      default: vd_index_offset = 'b0;
    endcase
  end
  assign vd_index_end = {1'b0, inst_vd+vd_index_offset};

  always_comb begin
    check_vd_overlap_vs2 = 'b0;

    case(emul_vs2)
      EMUL1: begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2}<vd_index_start) ||
                               ({1'b0,inst_vs2}>vd_index_end);
      end
      EMUL2: begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:1]}<vd_index_start[`REGFILE_INDEX_WIDTH:1]) ||
                               ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:1]}>vd_index_end[`REGFILE_INDEX_WIDTH:1]);
      end
      EMUL4: begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:2]}<vd_index_start[`REGFILE_INDEX_WIDTH:2]) ||
                               ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:2]}>vd_index_end[`REGFILE_INDEX_WIDTH:2]);
      end
      EMUL8 : begin
        check_vd_overlap_vs2 = ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:3]}<vd_index_start[`REGFILE_INDEX_WIDTH:3]) ||
                               ({1'b0,inst_vs2[`REGFILE_INDEX_WIDTH-1:3]}>vd_index_end[`REGFILE_INDEX_WIDTH:3]);
      end
    endcase
  end

  // check whether vs2 partially overlaps vd for EEW_vd:EEW_vs2=2:1
  // used in regular index load/store
  always_comb begin
    check_vs2_part_overlap_vd_2_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs2_part_overlap_vd_2_1 = 1'b1;
      end
      EMUL2: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs2[`REGFILE_INDEX_WIDTH-1:1])&(inst_vs2[0]!=1'b1));
      end
      EMUL4: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs2[`REGFILE_INDEX_WIDTH-1:2])&(inst_vs2[1:0]!=2'b10));
      end
      EMUL8: begin
        check_vs2_part_overlap_vd_2_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs2[`REGFILE_INDEX_WIDTH-1:3])&(inst_vs2[2:0]!=3'b100));
      end
    endcase
  end

  // check whether vs2 partially overlaps vd for EEW_vd:EEW_vs2=4:1
  // used in regular index load/store
  always_comb begin
    check_vs2_part_overlap_vd_4_1 = 'b0;

    case(emul_vd)
      EMUL1: begin
        check_vs2_part_overlap_vd_4_1 = 1'b1;
      end
      EMUL2: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:1]==inst_vs2[`REGFILE_INDEX_WIDTH-1:1])&(inst_vs2[0]!=1'b1));
      end
      EMUL4: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:2]==inst_vs2[`REGFILE_INDEX_WIDTH-1:2])&(inst_vs2[1:0]!=2'b11));
      end
      EMUL8: begin
        check_vs2_part_overlap_vd_4_1 = !((inst_vd[`REGFILE_INDEX_WIDTH-1:3]==inst_vs2[`REGFILE_INDEX_WIDTH-1:3])&(inst_vs2[2:0]!=3'b110));
      end
    endcase
  end

  // start to check special requirements for every instructions
  always_comb begin
    check_special = 'b0;

    case(inst_funct6[2:0])
      UNIT_STRIDE: begin
        case(inst_umop)
          US_REGULAR: begin
            check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0 : 1'b1;
          end
          US_WHOLE_REGISTER: begin
            check_special = inst_vm&((inst_opcode==LOAD)||((inst_opcode==STORE)&(inst_funct3==SEW_8)));
          end
          US_MASK: begin
            check_special = inst_vm&(inst_funct3==SEW_8)&(inst_funct6[5:3]=='b0);
          end
          US_FAULT_FIRST: begin
            check_special = check_vd_overlap_v0&(inst_opcode==LOAD);
          end
        endcase
      end

      CONSTANT_STRIDE: begin
        check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0 : 1'b1;
      end

      UNORDERED_INDEX,
      ORDERED_INDEX: begin
        if (inst_nf==NF1) begin
          case({inst_funct3,csr_sew})
            // EEW_vs2:EEW_vd = 1:1
            {SEW_8,SEW8},
            {SEW_16,SEW16},
            {SEW_32,SEW32}: begin
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0 : 1'b1;
            end
            // 2:1
            {SEW_16,SEW8},
            {SEW_32,SEW16},
            // 4:1
            {SEW_32,SEW8}: begin
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vd_part_overlap_vs2 : 1'b1;
            end
            // 1:2
            {SEW_8,SEW16},
            {SEW_16,SEW32}: begin
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vs2_part_overlap_vd_2_1 : 1'b1;
            end
            // 1:4
            {SEW_8,SEW32}: begin
              check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vs2_part_overlap_vd_4_1 : 1'b1;
            end
          endcase
        end
        else begin
          // segment indexed ld, vd group cannot overlap vs2 group fully
          check_special = (inst_opcode==LOAD) ? check_vd_overlap_v0&check_vd_overlap_vs2 : 1'b1;
        end
      end
    endcase
  end

  //check common requirements for all instructions
  assign check_common = check_vd_align&check_vs2_align&check_vd_in_range&check_sew&check_lmul
                      `ifdef ZVE32F_ON
                        `ifdef CHECK_FRM
                        &check_frm
                        `endif
                      `endif
                        &check_evl_not_0&check_vstart_sle_evl;

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

  // check vd/vs3 is in 0-31 for segment load/store
  always_comb begin
    case(emul_vd_nf)
      EMUL1:   check_vd_cmp = 'd31;
      EMUL2:   check_vd_cmp = 'd30;
      EMUL3:   check_vd_cmp = 'd29;
      EMUL4:   check_vd_cmp = 'd28;
      EMUL5:   check_vd_cmp = 'd27;
      EMUL6:   check_vd_cmp = 'd26;
      EMUL7:   check_vd_cmp = 'd25;
      EMUL8:   check_vd_cmp = 'd24;
      default: check_vd_cmp = 'b0;
    endcase
  end
  assign check_vd_in_range = (emul_vd_nf!=EMUL_NONE) ? inst_vd <= check_vd_cmp : 'b0;

  // check the validation of EEW
  assign check_sew = (eew_max != EEW_NONE);

  // check the validation of EMUL
  assign check_lmul = (emul_max != EMUL_NONE);

  // get evl
  always_comb begin
    evl = csr_vl;

    case(inst_funct6[2:0])
      UNIT_STRIDE: begin
        case(inst_umop)
          US_WHOLE_REGISTER: begin
            // evl = NFIELD*VLEN/EEW
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
          US_MASK: begin
            // evl = ceil(vl/8)
            evl = {3'b0,csr_vl[`VL_WIDTH-1:3]} + (csr_vl[2:0]!='b0);
          end
        endcase
      end
    endcase
  end

  // check evl is not 0
  assign check_evl_not_0 = evl!='b0;

  // check vstart < evl
  assign check_vstart_sle_evl = {1'b0,csr_vstart} < evl;

  // Per RISC-V V spec, vl=0 or vstart>=evl means the instruction is a no-op
  // regardless of encoding validity. This bypasses all encoding checks to
  // prevent pipeline deadlock, and is compatible with PR #71's trap mechanism.
  assign inst_is_nop = valid_lsu & (~check_evl_not_0 | ~check_vstart_sle_evl);

`ifdef ZVE32F_ON
  // check FP rounding mode is legal
  assign check_frm = inst.arch_state.frm < 3'd5;
`endif

`ifdef ASSERT_ON
  `ifdef TB_SUPPORT
    `rvv_forbid((inst_valid==1'b1)&(inst_encoding_correct==1'b0)&(inst_is_nop==1'b0))
    else $warning("pc(0x%h) instruction will be discarded directly.\n",$sampled(inst.inst_pc));
  `else
    `rvv_forbid((inst_valid==1'b1)&(inst_encoding_correct==1'b0)&(inst_is_nop==1'b0))
    else $warning("This instruction will be discarded directly.\n");
  `endif
`endif

  // update force_vma_agnostic
    //When source and destination registers overlap and have different EEW, the instruction is mask- and tail-agnostic.
  assign force_vma_agnostic = (check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE);

  // update force_vta_agnostic
  assign force_vta_agnostic = (eew_vd==EEW1) |   // Mask destination tail elements are always treated as tail-agnostic
    //When source and destination registers overlap and have different EEW, the instruction is mask- and tail-agnostic.
                              ((check_vd_overlap_vs2==1'b0)&(eew_vd!=eew_vs2)&(eew_vd!=EEW_NONE)&(eew_vs2!=EEW_NONE));

  // result
  assign lcmd_valid              = inst_encoding_correct | inst_is_nop;
  assign lcmd.cmd                = inst;
  assign lcmd.eew_vs1            = EEW_NONE;
  assign lcmd.eew_vs2            = eew_vs2;
  assign lcmd.eew_vd             = eew_vd;
  assign lcmd.eew_max            = eew_max;
  assign lcmd.emul_vs1           = EMUL_NONE;
  assign lcmd.emul_vs2           = emul_vs2;
  assign lcmd.emul_vd            = emul_vd;
  assign lcmd.emul_max           = emul_max;
  assign lcmd.uop_vstart         = 'b0;
  assign lcmd.uop_index_max      = inst_is_nop ? '0 : uop_index_max;
  assign lcmd.evl                = evl;
  assign lcmd.force_vma_agnostic = force_vma_agnostic;
  assign lcmd.force_vta_agnostic = force_vta_agnostic;

endmodule
