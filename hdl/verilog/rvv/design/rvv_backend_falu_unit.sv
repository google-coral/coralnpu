
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef HDL_VERILOG_RVV_INC_FALU_SVH
`include "rvv_backend_falu.svh"
`endif

// description
//to FMA
//VFADD, VFSUB, VFMUL, VFRSUB, VFMAC, VFNMAC, VFMSAC, VFNMSAC, VFMADD, VFNMADD, VFMSUB, VFNMSUB
//to CMOP
//VMIN, VMAX, VFSGNJ, VFSGNJN, VFSGNJX, VFCLASS, VFFEQ, VFFLE, VFFLT, VFFNE, VFFGT, VFFGE     
//to CVT
//VFCVT_F2I, VFCVT_F2I, VFCVT_F2IT, VFCVT_F2IT, VFCVT_I2F, VFCVT_I2F

module rvv_backend_falu_unit(
  //global
  clk,
  rst_n,
  //rs in
  falu_uop_vld,
  falu_uop,
  //dec tye
  falu_type,
  //rdy to rs
  falu_uop_addmul_rdy,
  falu_uop_cmp_rdy,
  falu_uop_cvt_rdy,
  falu_uop_tbl_rdy,
  //flush
  trap_flush_rvv,
  //result to rob
  falu_result_vld,
  falu_result,
  //rob ready 2 unit
  falu_result_rdy
);
  parameter PIPEREGS  = 3; 
  //global
  input   logic         clk;
  input   logic         rst_n;
  //rs in
  input   logic         falu_uop_vld;
  input   FALU_RS_t     falu_uop;
  //dec tye
  input   logic [3:0]   falu_type;
  //rdy to rs
  output  logic         falu_uop_addmul_rdy;
  output  logic         falu_uop_cmp_rdy;
  output  logic         falu_uop_cvt_rdy;
  output  logic         falu_uop_tbl_rdy;
  //flush
  input   logic         trap_flush_rvv;
  //result to rob
  output  logic         falu_result_vld;
  output  PU2ROB_t      falu_result;
  //rob ready 
  input   logic         falu_result_rdy;

//
// internal signals
//
  //sub unit 
  //input of sub unit
  logic                                     addmul_vld;
  logic                                     allcmp_vld;
  logic                                     cvt_vld;
  logic                                     tbl_vld;
  // operand
  logic [`VLEN-1:0]                         src1;
  logic [`VLEN-1:0]                         src2;
  logic [`VLEN-1:0]                         src3;
  logic [`VLENW-1:0][2:0][`WORD_WIDTH-1:0]  op_i;
  EEW_e                                     vd_eew;
  fpnew_pkg::roundmode_e                    rnd_mod_i;    // also opcode
  fpnew_pkg::operation_e                    op_type;
  logic                                     op_mod;
  fpnew_pkg::fp_format_e                    src_fmt;
  fpnew_pkg::fp_format_e                    src2_fmt;
  fpnew_pkg::fp_format_e                    dst_fmt;
  fpnew_pkg::int_format_e                   int_fmt;
  // tage
  TAG_t                                     tag_fma;
  FCMP_TAG_t                                tag_fcmp;
  FCVT_TAG_t                                tag_fcvt;
  TAG_t                                     tag_ftbl;
  // result & arb
  logic     [3:0]                           result_vld;
  logic     [3:0]                           arb_rdy;
  // fma
  logic                                     addmul_result_vld;
  logic     [`VLEN-1:0]                     addmul_result;
  fpnew_pkg::status_t [`VLENW-1:0]          addmul_status_o;
  TAG_t                                     addmul_tag_o;
  logic                                     addmul_result_rdy;
  // fcvt
  logic                                     cvt_result_vld;
  logic     [`VLEN-1:0]                     cvt_result;
  fpnew_pkg::status_t [`VLENW-1:0]          cvt_status_o;
  FCVT_TAG_t                                cvt_tag_o;
  logic                                     cvt_result_rdy;
  // ftbl
  logic                                     tbl_result_vld;
  logic     [`VLEN-1:0]                     tbl_result;
  RVFEXP_t  [`VLENW-1:0]                    tbl_status_o;
  TAG_t                                     tbl_tag_o;
  logic                                     tbl_result_rdy;
  // fcmp&fncmp
  logic                                     allcmp_result_vld_tmp;
  logic                                     allcmp_result_vld;
  logic                                     is_class_o;
  logic     [`VLEN-1:0]                     allcmp_unit_res;
  fpnew_pkg::classmask_e  [`VLENW-1:0]      class_result;
  logic     [`VLEN-1:0]                     allcmp_result;
  fpnew_pkg::status_t [`VLENW-1:0]          allcmp_status_o;
  FCMP_TAG_t                                allcmp_tag_o;
  logic                                     allcmp_result_rdy_tmp;
  logic                                     allcmp_result_rdy;
  // fcmp info
  logic         [PIPEREGS:0][1:0]           info_vld;
  logic         [PIPEREGS:0]                info_rdy;
  FCMP_INFO_t   [PIPEREGS:0]                cmp_info;
  logic   [`VLEN-1:0]                       v0;
  logic   [`VLEN-1:0]                       vstart_elements_tmp;
  logic   [`VLEN-1:0]                       vstart_elements;
  logic   [`VLEN-1:0]                       tail_elements_tmp;
  logic   [`VLEN-1:0]                       tail_elements;
  logic   [6:0]                             cmp_en;
  logic   [8*`VLENW-1:0]                    cmp;
  logic   [7*`VLENW-1:0]                    cmp_d1;
  logic   [`VLEN-1:0]                       cmp_res_tmp;
  logic   [`VLEN-1:0]                       cmp_res;
  RVFEXP_t  [8*`VLENW-1:0]                  cmp_status;
  RVFEXP_t  [7*`VLENW-1:0]                  cmp_status_d1;
  RVFEXP_t  [`VLEN-1:0]                     cmp_fexp_tmp;
  RVFEXP_t  [`VLEN-1:0]                     cmp_fexp_per1;
  RVFEXP_t  [`VLENB-1:0]                    cmp_fexp;
  RVFEXP_t  [`VLENB-1:0]                    allcmp_fexp;
  
  genvar                                    i;

//
// code start
//
  // valid uop
  assign addmul_vld = falu_uop_vld & falu_type[0];
  assign allcmp_vld = falu_uop_vld & falu_type[1];
  assign cvt_vld    = falu_uop_vld & falu_type[2];
  assign tbl_vld    = falu_uop_vld & falu_type[3];

  always_comb begin
    vd_eew = EEW32;

    if(falu_uop.uop_funct6.ari_funct6 == VFUNARY0) begin
      case(falu_uop.vs1)
      `ifdef ZVFBFWMA_ON
        VFNCVTBF16,
      `endif
        VFNCVTXUF,
        VFNCVTXF,
        VFNCVTRTZXUF,
        VFNCVTRTZXF: vd_eew = EEW16;
      endcase
    end
  end

  // prepare source data
  always_comb begin
    src1 = falu_uop.vs1_data;
    src2 = falu_uop.vs2_data;
    src3 = falu_uop.vs3_data;
    
    case(falu_uop.uop_funct3)
      OPFVF: begin
        src1 = {`VLENW{falu_uop.rs1_data}};
      `ifdef ZVFBFWMA_ON
        if(falu_uop.uop_funct6.ari_funct6==VFWMACCBF16) begin
          for(int i=0;i<`VLENW;i++) begin
            if(falu_uop.uop_index[0]) begin
              src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs2_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
            end
            else begin
              src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
            end
          end
        end
      `endif
      end
      OPFVV: begin
        case(falu_uop.uop_funct6.ari_funct6)
          VFUNARY0: begin 
            case(falu_uop.vs1)
            `ifdef ZVFBFWMA_ON
              VFWCVTBF16,
            `endif
              VFWCVTFXU,
              VFWCVTFX: begin
                for(int i=0;i<`VLENW;i++) begin
                  if(falu_uop.uop_index[0])
                    src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs2_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                  else
                    src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                end
              end
            endcase
          end
          `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            for(int i=0;i<`VLENW;i++) begin
              if(falu_uop.uop_index[0]) begin
                src1[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs1_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs2_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
              end
              else begin
                src1[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs1_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
                src2[i*`WORD_WIDTH+:`WORD_WIDTH] = {(`HWORD_WIDTH'('1)), falu_uop.vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};    
              end
            end
          end
          `endif
        endcase
      end
    endcase
  end

  //decode for instruction
  always_comb begin
    // default
    for(int i=0;i<`VLENW;i++) begin
      op_i[i] = {src3[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]};
    end
    rnd_mod_i = fpnew_pkg::roundmode_e'(falu_uop.frm);
    op_type   = fpnew_pkg::FMADD;
    op_mod    = 1'b0;
    src_fmt   = fpnew_pkg::FP32;
    src2_fmt  = fpnew_pkg::FP32;
    dst_fmt   = fpnew_pkg::FP32;
    int_fmt   = fpnew_pkg::INT32;
    
    case(1'b1)
      addmul_vld: begin//ADDMUL
        case(falu_uop.uop_funct6.ari_funct6)
          VFADD: begin
            op_type   = fpnew_pkg::ADD;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH], `WORD_WIDTH'b0}; 
            end
          end
          VFSUB: begin
            op_type = fpnew_pkg::ADD;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH], `WORD_WIDTH'b0}; 
            end
          end
          VFRSUB: begin
            op_type = fpnew_pkg::ADD;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH], `WORD_WIDTH'b0}; 
            end
          end
          VFMUL: begin
            op_type = fpnew_pkg::MUL;
          end
          VFMACC: begin
            op_type = fpnew_pkg::FMADD;
          end
          VFNMACC: begin
            op_type = fpnew_pkg::FNMSUB;
            op_mod  = 1'b1;
          end
          VFMSAC: begin
            op_type = fpnew_pkg::FMADD;
            op_mod  = 1'b1;
          end
          VFNMSAC: begin
            op_type = fpnew_pkg::FNMSUB;
          end
          VFMADD: begin
            op_type = fpnew_pkg::FMADD;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
          VFNMADD: begin
            op_type = fpnew_pkg::FNMSUB;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
          VFMSUB: begin
            op_type = fpnew_pkg::FMADD;
            op_mod  = 1'b1;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
          VFNMSUB: begin
            op_type = fpnew_pkg::FNMSUB;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {src2[i*`WORD_WIDTH+:`WORD_WIDTH], src3[i*`WORD_WIDTH+:`WORD_WIDTH], src1[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
        `ifdef ZVFBFWMA_ON
          VFWMACCBF16: begin
            op_type = fpnew_pkg::FMADD;
            src_fmt = fpnew_pkg::FP16ALT;
            src2_fmt= fpnew_pkg::FP32;
            dst_fmt = fpnew_pkg::FP32;
          end
        `endif
        endcase
      end
      allcmp_vld: begin//CMP
        case(falu_uop.uop_funct6.ari_funct6)
          VMFEQ: begin
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RDN;
          end
          VMFNE:begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RDN; 
            op_mod    = 1'b1;
          end
          VMFLT: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RNE; 
            op_mod    = 1'b1;
          end
          VMFLE: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RTZ; 
            op_mod    = 1'b1;
          end
          VMFGT: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RTZ; 
          end
          VMFGE: begin 
            op_type   = fpnew_pkg::CMP;
            rnd_mod_i = fpnew_pkg::RNE; 
          end
          VFSGNJ: begin
            op_type   = fpnew_pkg::SGNJ;
            rnd_mod_i = fpnew_pkg::RNE;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]};
            end
          end
          VFSGNJN: begin
            op_type   = fpnew_pkg::SGNJ;
            rnd_mod_i = fpnew_pkg::RTZ;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]};
            end
          end
          VFSGNJX: begin
            op_type   = fpnew_pkg::SGNJ;
            rnd_mod_i = fpnew_pkg::RDN;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, src1[i*`WORD_WIDTH+:`WORD_WIDTH], src2[i*`WORD_WIDTH+:`WORD_WIDTH]};
            end
          end
          VFMIN: begin
            op_type   = fpnew_pkg::MINMAX;
            rnd_mod_i = fpnew_pkg::RNE;
          end
          VFMAX: begin
            op_type   = fpnew_pkg::MINMAX;
            rnd_mod_i = fpnew_pkg::RTZ;
          end
          VFUNARY1: begin
            op_type   = fpnew_pkg::CLASSIFY;
            for(int i=0;i<`VLENW;i++) begin
              op_i[i] = {`WORD_WIDTH'b0, `WORD_WIDTH'b0, src2[i*`WORD_WIDTH+:`WORD_WIDTH]}; 
            end
          end
        endcase
      end
      cvt_vld: begin//CVT
        case(falu_uop.vs1)
          VFCVT_XUFV: begin
            op_type   = fpnew_pkg::F2I; 
            op_mod    = 1'b1;
          end
          VFCVT_XFV: begin
            op_type   = fpnew_pkg::F2I; 
          end
          VFCVT_FXUV: begin
            op_type   = fpnew_pkg::I2F;
            op_mod    = 1'b1;
          end
          VFCVT_FXV: begin 
            op_type   = fpnew_pkg::I2F; 
          end
          VFCVT_RTZXUFV: begin
            op_type   = fpnew_pkg::F2I; 
            rnd_mod_i = fpnew_pkg::RTZ;
            op_mod    = 1'b1;
          end
          VFCVT_RTZXFV: begin
            op_type   = fpnew_pkg::F2I; 
            rnd_mod_i = fpnew_pkg::RTZ; 
          end
          VFWCVTFXU: begin
            op_type   = fpnew_pkg::I2F;
            op_mod    = 1'b1;
            int_fmt   = fpnew_pkg::INT16;
          end
          VFWCVTFX: begin
            op_type   = fpnew_pkg::I2F;
            int_fmt   = fpnew_pkg::INT16;
          end
          VFNCVTXUF: begin
            op_type   = fpnew_pkg::F2I;
            op_mod    = 1'b1;
            int_fmt   = fpnew_pkg::INT16;
          end
          VFNCVTXF: begin
            op_type   = fpnew_pkg::F2I;
            int_fmt   = fpnew_pkg::INT16;
          end
          VFNCVTRTZXUF: begin
            op_type   = fpnew_pkg::F2I;
            op_mod    = 1'b1;
            int_fmt   = fpnew_pkg::INT16;
            rnd_mod_i = fpnew_pkg::RTZ;
          end
          VFNCVTRTZXF: begin
            op_type   = fpnew_pkg::F2I;
            int_fmt   = fpnew_pkg::INT16;
            rnd_mod_i = fpnew_pkg::RTZ;
          end
        `ifdef ZVFBFWMA_ON
          VFNCVTBF16: begin
            op_type   = fpnew_pkg::F2F;
            src2_fmt  = fpnew_pkg::FP32;
            dst_fmt   = fpnew_pkg::FP16ALT;
          end
          VFWCVTBF16: begin
            op_type   = fpnew_pkg::F2F;
            src2_fmt  = fpnew_pkg::FP16ALT;
            dst_fmt   = fpnew_pkg::FP32;
          end
        `endif
        endcase
      end
    endcase
  end

  // tag
`ifdef TB_SUPPORT
  assign tag_fma.uop_pc             = falu_uop.uop_pc;
  assign tag_fcmp.com_tag.uop_pc    = falu_uop.uop_pc;
  assign tag_fcvt.com_tag.uop_pc    = falu_uop.uop_pc;
  assign tag_ftbl.uop_pc            = falu_uop.uop_pc;
`endif
  assign tag_fma.rob_entry          = falu_uop.rob_entry;
  assign tag_fcmp.com_tag.rob_entry = falu_uop.rob_entry;
  assign tag_fcmp.is_fcmp           = falu_uop.uop_exe_unit==FCMP;
  assign tag_fcmp.uop_index         = falu_uop.uop_index;
  assign tag_fcmp.last_uop_valid    = falu_uop.last_uop_valid;
  assign tag_fcvt.com_tag.rob_entry = falu_uop.rob_entry;
  assign tag_fcvt.eew_vd            = vd_eew;
  assign tag_fcvt.uop_index         = falu_uop.uop_index[0];
  assign tag_ftbl.rob_entry         = falu_uop.rob_entry;

  // execution units
  generate
    // sub unit 0
    fpnew_fma_multi #(
      `ifdef ZVFBFWMA_ON
      .FpFmtConfig        (5'b10001),
      `else
      .FpFmtConfig        (5'b10000),
      `endif
      .NumPipeRegs        (PIPEREGS),
      .PipeConfig         (fpnew_pkg::DISTRIBUTED),
      .TagType            (TAG_t)
      )
    addmul (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      // Input signals
      .operands_i         (op_i[0]), // 3 operands
      .is_boxed_i         ('1), // 3 operands
      .rnd_mode_i         (rnd_mod_i),
      .op_i               (op_type),
      .op_mod_i           (op_mod),
      .src_fmt_i          (src_fmt),
      .src2_fmt_i         (src2_fmt),
      .dst_fmt_i          (dst_fmt),
      .tag_i              (tag_fma),
      .mask_i             ('0),
      .aux_i              ('0),
      // Input Handshake
      .in_valid_i         (addmul_vld),
      .in_ready_o         (falu_uop_addmul_rdy),
      .flush_i            (trap_flush_rvv),
      // Output signals
      .result_o           (addmul_result[0+:`WORD_WIDTH]), 
      .status_o           (addmul_status_o[0]),          
      .extension_bit_o    (),
      .tag_o              (addmul_tag_o),
      .mask_o             (),
      .aux_o              (),
      // Output handshake
      .out_valid_o        (addmul_result_vld),    
      .out_ready_i        (addmul_result_rdy),    
      // Indication of valid data in flight
      .busy_o             (),
      // External register enable override
      .reg_ena_i          ('0),
      // Early valid for external structural hazard generation
      .early_out_valid_o  ()
    );
  
    fpnew_noncomp #(
      .FpFormat           (fpnew_pkg::FP32),
      .NumPipeRegs        (PIPEREGS),
      .PipeConfig         (fpnew_pkg::DISTRIBUTED),
      .TagType            (FCMP_TAG_t)
    )
    allcmp (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      // Input signals
      .operands_i         ({op_i[0][1], op_i[0][0]}), // 2 operands
      .is_boxed_i         ('1), // 2 operands
      .rnd_mode_i         (rnd_mod_i),
      .op_i               (op_type),
      .op_mod_i           (op_mod),
      .tag_i              (tag_fcmp),
      .mask_i             ('0),
      .aux_i              ('0),
      // Input Handshake
      .in_valid_i         (allcmp_vld),
      .in_ready_o         (falu_uop_cmp_rdy),
      .flush_i            (trap_flush_rvv),
      // Output signals
      .result_o           (allcmp_unit_res[0+:`WORD_WIDTH]),
      .status_o           (allcmp_status_o[0]),
      .extension_bit_o    (),
      .class_mask_o       (class_result[0]),
      .is_class_o         (is_class_o),
      .tag_o              (allcmp_tag_o),
      .mask_o             (),
      .aux_o              (),
      // Output handshake
      .out_valid_o        (allcmp_result_vld_tmp),
      .out_ready_i        (allcmp_result_rdy_tmp),
      // Indication of valid data in flight
      .busy_o             (),
      // External register enable override
      .reg_ena_i          ('0),
      // Early valid for external structural hazard generation
      .early_out_valid_o  ()
    );
  
    fpnew_cast_multi #(
      `ifdef ZVFBFWMA_ON
      .FpFmtConfig        (5'b10001),
      `else
      .FpFmtConfig        (5'b10000),
      `endif
      .IntFmtConfig       (4'b1110),
      .NumPipeRegs        (PIPEREGS),
      .PipeConfig         (fpnew_pkg::DISTRIBUTED),
      .TagType            (FCVT_TAG_t)
    )
    cvt (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      // Input signals
      .operands_i         (src2[0+:`WORD_WIDTH]), // 1 operand
      .is_boxed_i         ('1), // 1 operand
      .rnd_mode_i         (rnd_mod_i),
      .op_i               (op_type),
      .op_mod_i           (op_mod),
      .src_fmt_i          (src2_fmt),
      .dst_fmt_i          (dst_fmt),
      .int_fmt_i          (int_fmt),
      .tag_i              (tag_fcvt),
      .mask_i             ('0),
      .aux_i              ('0),
      // Input Handshake
      .in_valid_i         (cvt_vld),
      .in_ready_o         (falu_uop_cvt_rdy),
      .flush_i            (trap_flush_rvv),
      // Output signals
      .result_o           (cvt_result[0+:`WORD_WIDTH]),
      .status_o           (cvt_status_o[0]),
      .extension_bit_o    (),
      .tag_o              (cvt_tag_o),
      .mask_o             (),
      .aux_o              (),
      // Output handshake
      .out_valid_o        (cvt_result_vld),
      .out_ready_i        (cvt_result_rdy),
      // Indication of valid data in flight
      .busy_o             (),
      // External register enable override
      .reg_ena_i          ('0),
      // Early valid for external structural hazard generation
      .early_out_valid_o  ()
    );
  
    rvv_backend_sqrt7_rec7 #(
      .TagType            (TAG_t)
    )
    tbl (
      .clk                (clk),
      .rst_n              (rst_n),
      // Input signals
      .operand_i          (src2[0+:`WORD_WIDTH]), // 1 operand
      .vs1_i              (falu_uop.vs1),
      .rnd_mode_i         (falu_uop.frm),
      .tag_i              (tag_ftbl),         
      // Input Handshake
      .in_valid_i         (tbl_vld),
      .in_ready_o         (falu_uop_tbl_rdy),
      .flush_i            (trap_flush_rvv),
      // Output signals
      .result_o           (tbl_result[0+:`WORD_WIDTH]),   
      .tbl_status_o       (tbl_status_o[0]),
      .tag_o              (tbl_tag_o),
      // Output handshake
      .out_valid_o        (tbl_result_vld),
      .out_ready_i        (tbl_result_rdy)
    );

    for(i=1;i<`VLENW;i++) begin:sub_unit      
      fpnew_fma_multi #(
        `ifdef ZVFBFWMA_ON
        .FpFmtConfig        (5'b10001),
        `else
        .FpFmtConfig        (5'b10000),
        `endif
        .NumPipeRegs        (PIPEREGS),
        .PipeConfig         (fpnew_pkg::DISTRIBUTED)
        )
      addmul (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        // Input signals
        .operands_i         (op_i[i]), // 3 operands
        .is_boxed_i         ('1), // 3 operands
        .rnd_mode_i         (rnd_mod_i),
        .op_i               (op_type),
        .op_mod_i           (op_mod),
        .src_fmt_i          (src_fmt),
        .src2_fmt_i         (src2_fmt),
        .dst_fmt_i          (dst_fmt),
        .tag_i              ('0),
        .mask_i             ('0),
        .aux_i              ('0),
        // Input Handshake
        .in_valid_i         (addmul_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // Output signals
        .result_o           (addmul_result[i*`WORD_WIDTH+:`WORD_WIDTH]), 
        .status_o           (addmul_status_o[i]),          
        .extension_bit_o    (),
        .tag_o              (),
        .mask_o             (),
        .aux_o              (),
        // Output handshake
        .out_valid_o        (),    
        .out_ready_i        (addmul_result_rdy),    
        // Indication of valid data in flight
        .busy_o             (),
        // External register enable override
        .reg_ena_i          ('0),
        // Early valid for external structural hazard generation
        .early_out_valid_o  ()
      );
  
      fpnew_noncomp #(
        .FpFormat           (fpnew_pkg::FP32),
        .NumPipeRegs        (PIPEREGS),
        .PipeConfig         (fpnew_pkg::DISTRIBUTED)
      )
      allcmp (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        // Input signals
        .operands_i         ({op_i[i][1], op_i[i][0]}), // 2 operands
        .is_boxed_i         ('1), // 2 operands
        .rnd_mode_i         (rnd_mod_i),
        .op_i               (op_type),
        .op_mod_i           (op_mod),
        .tag_i              ('0),
        .mask_i             ('0),
        .aux_i              ('0),
        // Input Handshake
        .in_valid_i         (allcmp_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // Output signals
        .result_o           (allcmp_unit_res[i*`WORD_WIDTH+:`WORD_WIDTH]),
        .status_o           (allcmp_status_o[i]),
        .extension_bit_o    (),
        .class_mask_o       (class_result[i]),
        .is_class_o         (),
        .tag_o              (),
        .mask_o             (),
        .aux_o              (),
        // Output handshake
        .out_valid_o        (),
        .out_ready_i        (allcmp_result_rdy_tmp),
        // Indication of valid data in flight
        .busy_o             (),
        // External register enable override
        .reg_ena_i          ('0),
        // Early valid for external structural hazard generation
        .early_out_valid_o  ()
      );
  
      fpnew_cast_multi #(
        `ifdef ZVFBFWMA_ON
        .FpFmtConfig        (5'b10001),
        `else
        .FpFmtConfig        (5'b10000),
        `endif
        .IntFmtConfig       (4'b1110),
        .NumPipeRegs        (PIPEREGS),
        .PipeConfig         (fpnew_pkg::DISTRIBUTED),
        .TagType            (FCVT_TAG_t)
      )
      cvt (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        // Input signals
        .operands_i         (src2[i*`WORD_WIDTH+:`WORD_WIDTH]), // 1 operand
        .is_boxed_i         ('1), // 1 operand
        .rnd_mode_i         (rnd_mod_i),
        .op_i               (op_type),
        .op_mod_i           (op_mod),
        .src_fmt_i          (src2_fmt),
        .dst_fmt_i          (dst_fmt),
        .int_fmt_i          (int_fmt),
        .tag_i              ('0),
        .mask_i             ('0),
        .aux_i              ('0),
        // Input Handshake
        .in_valid_i         (cvt_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // Output signals
        .result_o           (cvt_result[i*`WORD_WIDTH+:`WORD_WIDTH]),
        .status_o           (cvt_status_o[i]),
        .extension_bit_o    (),
        .tag_o              (),
        .mask_o             (),
        .aux_o              (),
        // Output handshake
        .out_valid_o        (),
        .out_ready_i        (cvt_result_rdy),
        // Indication of valid data in flight
        .busy_o             (),
        // External register enable override
        .reg_ena_i          ('0),
        // Early valid for external structural hazard generation
        .early_out_valid_o  ()
      );
  
      rvv_backend_sqrt7_rec7 #(
      )
      tbl (
        .clk                (clk),
        .rst_n              (rst_n),
        // Input signals
        .operand_i          (src2[i*`WORD_WIDTH+:`WORD_WIDTH]), // 1 operand
        .vs1_i              (falu_uop.vs1),
        .rnd_mode_i         (falu_uop.frm),
        .tag_i              ('0),
        // Input Handshake
        .in_valid_i         (tbl_vld),
        .in_ready_o         (),
        .flush_i            (trap_flush_rvv),
        // Output signals
        .result_o           (tbl_result[i*`WORD_WIDTH+:`WORD_WIDTH]),   
        .tbl_status_o       (tbl_status_o[i]),
        .tag_o              (),
        // Output handshake
        .out_valid_o        (),
        .out_ready_i        (tbl_result_rdy)
      );
    end
  endgenerate

  // register some extra information for FCMP instructions.
  assign info_vld[0][0]     = falu_uop_vld&(falu_uop.uop_exe_unit==FCMP);
  assign info_vld[0][1]     = falu_uop_vld&(falu_uop.uop_exe_unit==FNCMP);
  assign info_rdy[PIPEREGS] = allcmp_result_rdy_tmp; 
  assign cmp_info[0].vstart = falu_uop.vstart;
  assign cmp_info[0].vl     = falu_uop.vl;   
  assign cmp_info[0].vm     = falu_uop.vm;
  assign cmp_info[0].v0     = falu_uop.v0_data_valid ? falu_uop.v0_data : '1;
  assign cmp_info[0].vd     = falu_uop.vs3_data;
  
  // info pipeline
  generate
    for(i=0;i<PIPEREGS;i++) begin
      assign info_rdy[i] = !(|info_vld[i+1]) || info_rdy[i+1];
      
      // vld
      cdffr #(
        .T            (logic [1:0])
      ) fcmp_vld_pipe ( 
        .q            (info_vld[i+1]), 
        .clk          (clk), 
        .rst_n        (rst_n),  
        .c            (trap_flush_rvv), 
        .e            (info_rdy[i]), 
        .d            (info_vld[i]) 
      );
      // info for FCMP
      edff # (
        .T            (FCMP_INFO_t)
      ) fcmp_info_pipe ( 
        .q            (cmp_info[i+1]), 
        .clk          (clk), 
        .rst_n        (rst_n),  
        .e            (info_vld[i][0]&info_rdy[i]), 
        .d            (cmp_info[i]) 
      );
    end
    
    always_comb begin
      for(int i=0;i<8;i++) begin
        if(allcmp_tag_o.uop_index==i) begin 
          for(int j=0;j<`VLENW;j++) begin
            cmp[i*`VLENW+j]         = allcmp_unit_res[j*`WORD_WIDTH];
            cmp_status[i*`VLENW+j]  = allcmp_status_o[j];
          end
        end
        else begin
          cmp[i*`VLENW+:`VLENW]         = 'b0;
          cmp_status[i*`VLENW+:`VLENW]  = 'b0;
        end
      end
    end
  
    for(i=0;i<7;i++) begin
      assign cmp_en[i] = allcmp_result_vld_tmp&allcmp_tag_o.is_fcmp&(!allcmp_tag_o.last_uop_valid)&(allcmp_tag_o.uop_index==i);

      cdffr # (
        .T            (logic [`VLENW-1:0])
      ) fcmp_res ( 
        .q            (cmp_d1[i*`VLENW+:`VLENW]), 
        .clk          (clk), 
        .rst_n        (rst_n),  
        .c            (allcmp_result_vld_tmp&allcmp_tag_o.is_fcmp&allcmp_tag_o.last_uop_valid&allcmp_result_rdy_tmp | trap_flush_rvv), 
        .e            (cmp_en[i]), 
        .d            (cmp[i*`VLENW+:`VLENW]) 
      );

      cdffr # (
        .T            (RVFEXP_t[`VLENW-1:0])
      ) fcmp_exp ( 
        .q            (cmp_status_d1[i*`VLENW+:`VLENW]),
        .clk          (clk), 
        .rst_n        (rst_n),  
        .c            (allcmp_result_vld_tmp&allcmp_tag_o.is_fcmp&allcmp_tag_o.last_uop_valid&allcmp_result_rdy_tmp | trap_flush_rvv), 
        .e            (cmp_en[i]), 
        .d            (cmp_status[i*`VLENW+:`VLENW]) 
      );
    end

    assign cmp_res_tmp      = {(`VLEN-8*`VLENW)'(0), cmp[8*`VLENW-1:7*`VLENW], (cmp[7*`VLENW-1:0]|cmp_d1)};
    assign cmp_fexp_tmp     = {((`VLEN-8*`VLENW)*5)'(0), cmp_status[8*`VLENW-1:7*`VLENW], (cmp_status[7*`VLENW-1:0]|cmp_status_d1)};

    barrel_shifter #(.DATA_WIDTH(`VLEN)) 
    u_prestart (.din((`VLEN)'('1)), .shift_amount(cmp_info[PIPEREGS].vstart[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vstart_elements_tmp));
    barrel_shifter #(.DATA_WIDTH(`VLEN)) 
    u_tail (.din((`VLEN)'('1)), .shift_amount(cmp_info[PIPEREGS].vl[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(tail_elements_tmp));
    
    assign vstart_elements  = ~vstart_elements_tmp;
    assign tail_elements    = cmp_info[PIPEREGS].vl[$clog2(`VLEN)] ? 'b0 : tail_elements_tmp;

    assign v0               = {(`VLEN-8*`VLENW)'(0), cmp_info[PIPEREGS].v0};

    for(i=0;i<`VLEN;i++) begin: FCMP_MERGE
      always_comb begin
        if(!(vstart_elements[i]|tail_elements[i]) & (cmp_info[PIPEREGS].vm|v0[i])) begin
          cmp_res[i]        = cmp_res_tmp[i];
          cmp_fexp_per1[i]  = cmp_fexp_tmp[i];
        end
        else begin
          cmp_res[i]        = cmp_info[PIPEREGS].vd[i];
          cmp_fexp_per1[i]  = 'b0;
        end
      end
    end

    for(i=0;i<`VLENB;i++) begin
      always_comb begin
        cmp_fexp[i]   = 'b0;
        for(int j=0;j<8;j++) begin
          cmp_fexp[i] = cmp_fexp[i] | cmp_fexp_per1[i*8+j];
        end
      end
    end
  endgenerate

  // final result of allCMP
  always_comb begin
    allcmp_result_vld     = 'b0;
    allcmp_result         = allcmp_unit_res;
    allcmp_result_rdy_tmp = 'b1;
    allcmp_fexp           = 'b0;

    if(allcmp_result_vld_tmp) begin
      if(is_class_o) begin
        allcmp_result_vld     = 'b1;
        allcmp_result_rdy_tmp = allcmp_result_rdy;
        for(int i=0;i<`VLENW;i++) begin
          allcmp_result[i*`WORD_WIDTH+:`WORD_WIDTH] = {22'b0, class_result[i]};
          allcmp_fexp[4*i+:4]                       = {4{allcmp_status_o[i]}};
        end
      end
      else if(!allcmp_tag_o.is_fcmp) begin
        allcmp_result_vld     = 'b1;
        allcmp_result         = allcmp_unit_res;
        allcmp_result_rdy_tmp = allcmp_result_rdy;
        for(int i=0;i<`VLENW;i++) begin
          allcmp_fexp[4*i+:4] = {4{allcmp_status_o[i]}};
        end
      end
      else if(allcmp_tag_o.last_uop_valid) begin
        allcmp_result_vld     = 'b1;
        allcmp_result         = cmp_res;
        allcmp_result_rdy_tmp = allcmp_result_rdy;
        allcmp_fexp           = cmp_fexp;
      end
    end
  end

  // commit result
  arb_round_robin #(.REQ_NUM(4)) arb2rob (.clk(clk), .rst_n(rst_n), .req(result_vld), .grant(arb_rdy));
  assign result_vld         = falu_result_rdy ? {tbl_result_vld, cvt_result_vld, allcmp_result_vld, addmul_result_vld} : 'b0;
  assign falu_result_vld     = |result_vld;
  assign addmul_result_rdy  = arb_rdy[0];
  assign allcmp_result_rdy  = arb_rdy[1];
  assign cvt_result_rdy     = arb_rdy[2];
  assign tbl_result_rdy     = arb_rdy[3];

  always_comb begin
    falu_result = 'b0;

    case(1'b1)
      arb_rdy[3]: begin//choose look-up table results
      `ifdef TB_SUPPORT
        falu_result.uop_pc     = tbl_tag_o.uop_pc;
      `endif
        falu_result.rob_entry  = tbl_tag_o.rob_entry;
        falu_result.w_valid    = 'b1;
        falu_result.vsaturate  = 'b0;
        falu_result.w_data     = tbl_result;
        for(int i=0;i<`VLENW;i++) begin
          falu_result.fpexp[4*i+:4]  = {4{tbl_status_o[i]}};
        end
      end
      arb_rdy[2]: begin//choose cvt results
      `ifdef TB_SUPPORT
        falu_result.uop_pc     = cvt_tag_o.com_tag.uop_pc;
      `endif
        falu_result.rob_entry  = cvt_tag_o.com_tag.rob_entry;
        falu_result.w_valid    = 'b1;
        falu_result.vsaturate  = 'b0;
        for(int i=0;i<`VLENW;i++) begin
          case(cvt_tag_o.eew_vd) 
            EEW16: begin
              if(cvt_tag_o.uop_index) begin  
                falu_result.w_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH] = cvt_result[i*`WORD_WIDTH+:`HWORD_WIDTH];
                falu_result.w_data[        i*`HWORD_WIDTH+:`HWORD_WIDTH] = 'b0;
                falu_result.fpexp[`VLENB/2+2*i+:2]                       = {2{cvt_status_o[i]}};
                falu_result.fpexp[         2*i+:2]                       = 'b0;
              end
              else begin
                falu_result.w_data[`VLEN/2+i*`HWORD_WIDTH+:`HWORD_WIDTH] = 'b0;
                falu_result.w_data[        i*`HWORD_WIDTH+:`HWORD_WIDTH] = cvt_result[i*`WORD_WIDTH+:`HWORD_WIDTH];
                falu_result.fpexp[`VLENB/2+2*i+:2]                       = 'b0;
                falu_result.fpexp[         2*i+:2]                       = {2{cvt_status_o[i]}};
              end
            end
            default: begin //EEW32
              falu_result.w_data[i*`WORD_WIDTH+:`WORD_WIDTH] = cvt_result[i*`WORD_WIDTH+:`WORD_WIDTH];
              falu_result.fpexp[4*i+:4]                      = {4{cvt_status_o[i]}};
            end
          endcase
        end
      end
      arb_rdy[1]: begin //choose allcmp results
      `ifdef TB_SUPPORT
        falu_result.uop_pc     = allcmp_tag_o.com_tag.uop_pc;
      `endif
        falu_result.rob_entry  = allcmp_tag_o.com_tag.rob_entry;
        falu_result.w_valid    = 'b1;
        falu_result.vsaturate  = 'b0;
        falu_result.w_data     = allcmp_result;
        falu_result.fpexp      = allcmp_fexp;
      end
      arb_rdy[0]: begin // addmul results
      `ifdef TB_SUPPORT
        falu_result.uop_pc     = addmul_tag_o.uop_pc;
      `endif
        falu_result.rob_entry  = addmul_tag_o.rob_entry;
        falu_result.w_valid    = 'b1;
        falu_result.vsaturate  = 'b0;
        falu_result.w_data     = addmul_result;
        for(int i=0;i<`VLENW;i++) begin
          falu_result.fpexp[4*i+:4]  = {4{addmul_status_o[i]}};
        end
      end
    endcase
  end

endmodule
