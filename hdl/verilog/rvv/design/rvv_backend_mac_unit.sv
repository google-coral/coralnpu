// description: 
// 1. It will get uops from mac Reservation station and execute this uop.
//
// feature list:
// 1. 

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_mac_unit (
  // Outputs
  mac2rob_uop_valid, 
  mac2rob_uop_data,
  // Inputs
  clk, 
  rst_n, 
  rs2mac_uop_valid, 
  rs2mac_uop_data,
  mac_pipe_vld_en,
  mac_pipe_data_en,
  trap_flush_rvv
);

input                                 clk;
input                                 rst_n;
input                                 rs2mac_uop_valid;
input   MUL_RS_t                      rs2mac_uop_data;
input                                 mac_pipe_vld_en;
input                                 mac_pipe_data_en;
input                                 trap_flush_rvv;
output                                mac2rob_uop_valid;
output  PU2ROB_t                      mac2rob_uop_data;

// Wires & Regs
logic [`ROB_DEPTH_WIDTH-1:0]          mac_uop_rob_entry;
logic [`FUNCT6_WIDTH-1:0]             mac_uop_funct6;
logic [`FUNCT3_WIDTH-1:0]             mac_uop_funct3;
RVVXRM                                mac_uop_xrm;
EEW_e                                 mac_top_vs_eew;
logic [`VLEN-1:0]                     mac_uop_vs1_data;
logic [`VLEN-1:0]                     mac_uop_vs2_data;
logic [`XLEN-1:0]                     mac_uop_rs1_data;
logic [`VLEN-1:0]                     mac_uop_vs3_data;
logic                                 mac_uop_index;

logic                                 is_vv; //1:op*vv; 0:op*vx
logic [`VLEN-1:0]                     mac_src2;
logic [`VLEN-1:0]                     mac_src1;
logic [`VLEN-1:0]                     mac_addsrc;
logic                                 mac_src2_is_signed;
logic                                 mac_src1_is_signed;
logic                                 mac_is_widen;
logic                                 mac_keep_low_bits;
logic                                 mac_mul_reverse;
logic                                 is_vsmul;
logic                                 is_vmac;

logic [`VLEN-1:0]                     mac_src2_mux;
logic [`VLEN-1:0]                     mac_src1_mux;
logic [`VLENB-1:0]                    mac_src2_is_signed_extend;
logic [`VLENB-1:0]                    mac_src1_is_signed_extend;

logic [`VLENB-1:0][`BYTE_WIDTH-1:0]   mac8_in0;
logic [`VLENB-1:0]                    mac8_in0_is_signed;
logic [`VLENB-1:0][`BYTE_WIDTH-1:0]   mac8_in1;
logic [`VLENB-1:0]                    mac8_in1_is_signed;
logic [`VLEN/2-1:0][`HWORD_WIDTH-1:0] mac8_out;  // `VLEN/`WORD_WIDTH tiles, each tile has 4*4 elements. Total: VLEN/2 elements

logic [`VLEN/2-1:0]                   mac8_en;
// EX2 stage
logic [`VLEN/2-1:0][`HWORD_WIDTH-1:0] mac8_out_d1;  
logic [`VLEN-1:0]                     mac_addsrc_d1;
logic [2*`VLEN-1:0]                   mac_addsrc_widen_d1;

logic                                 rs2mac_uop_valid_d1;
logic                                 mac_src2_is_signed_d1;
logic                                 mac_src1_is_signed_d1;
logic                                 mac_is_widen_d1;
logic                                 mac_keep_low_bits_d1;
logic                                 mac_mul_reverse_d1;
logic                                 is_vsmul_d1;
logic                                 is_vmac_d1;
RVVXRM                                mac_uop_xrm_d1;
EEW_e                                 mac_top_vs_eew_d1;
logic [`ROB_DEPTH_WIDTH-1:0]          mac_uop_rob_entry_d1;

logic [`VLENB-1:0][`HWORD_WIDTH-1:0]  mac_rslt_full_eew8_d1;
logic [2*`VLEN-1:0]                   mac_rslt_eew8_widen_d1;
logic [`VLEN-1:0]                     mac_rslt_eew8_no_widen_d1;
logic [`VLENB-1:0]                    vsmul_round_incr_eew8_d1;
logic [`VLEN-1:0]                     vsmul_rslt_eew8_d1;
logic [`VLENB-1:0]                    vsmul_sat_eew8_d1;
logic [`VLEN-1:0]                     mac_rslt_eew8_d1;
logic [`VLENB-1:0]                    update_vxsat_eew8_d1;
logic [`VLENB-1:0][`BYTE_WIDTH:0]     vmac_mul_add_eew8_no_widen_d1;
logic [`VLENB-1:0][`BYTE_WIDTH:0]     vmac_mul_sub_eew8_no_widen_d1;
logic [`VLEN-1:0]                     vmac_rslt_eew8_no_widen_d1;
logic [`VLENB-1:0][`HWORD_WIDTH:0]    vmac_mul_add_eew8_widen_d1;
logic [`VLENB-1:0][`HWORD_WIDTH:0]    vmac_mul_sub_eew8_widen_d1;
logic [2*`VLEN-1:0]                   vmac_rslt_eew8_widen_d1;

logic [`VLENH-1:0][17:0]              mac_rslt_part16_eew16_d1;
logic [`VLENH-1:0][`WORD_WIDTH-1:0]   mac_rslt_full_eew16_d1;
logic [2*`VLEN-1:0]                   mac_rslt_eew16_widen_d1;
logic [`VLEN-1:0]                     mac_rslt_eew16_no_widen_d1;
logic [`VLENH-1:0]                    vsmul_round_incr_eew16_d1;
logic [`VLEN-1:0]                     vsmul_rslt_eew16_d1;
logic [`VLENH-1:0]                    vsmul_sat_eew16_d1;
logic [`VLEN-1:0]                     mac_rslt_eew16_d1;
logic [`VLENB-1:0]                    update_vxsat_eew16_d1;
logic [`VLENH-1:0][`HWORD_WIDTH:0]    vmac_mul_add_eew16_no_widen_d1;
logic [`VLENH-1:0][`HWORD_WIDTH:0]    vmac_mul_sub_eew16_no_widen_d1;
logic [`VLEN-1:0]                     vmac_rslt_eew16_no_widen_d1;
logic [`VLENH-1:0][`WORD_WIDTH:0]     vmac_mul_add_eew16_widen_d1;
logic [`VLENH-1:0][`WORD_WIDTH:0]     vmac_mul_sub_eew16_widen_d1;
logic [2*`VLEN-1:0]                   vmac_rslt_eew16_widen_d1;

`ifndef CORALNPU_STRUCTURAL_DATAPATH
logic [`VLENW-1:0][17:0]              mac_rslt_part16_eew32_d1;
logic [`VLENW-1:0][33:0]              mac_rslt_part32_eew32_d1;
logic [`VLENW-1:0][49:0]              mac_rslt_part48_eew32_d1;
logic [`VLENW-1:0][2*`WORD_WIDTH-1:0] mac_rslt_full_eew32_d1;
`endif
logic [2*`VLEN-1:0]                   mac_rslt_eew32_widen_d1;
logic [`VLEN-1:0]                     mac_rslt_eew32_no_widen_d1;
`ifndef CORALNPU_STRUCTURAL_DATAPATH
logic [`VLENW-1:0]                    vsmul_round_incr_eew32_d1;
logic [`VLEN-1:0]                     vsmul_rslt_eew32_d1;
`endif
logic [`VLENW-1:0]                    vsmul_sat_eew32_d1;
logic [`VLEN-1:0]                     mac_rslt_eew32_d1;
logic [`VLENB-1:0]                    update_vxsat_eew32_d1;
`ifndef CORALNPU_STRUCTURAL_DATAPATH
logic [`VLENW-1:0][`WORD_WIDTH:0]     vmac_mul_add_eew32_no_widen_d1;
logic [`VLENW-1:0][`WORD_WIDTH:0]     vmac_mul_sub_eew32_no_widen_d1;
logic [`VLEN-1:0]                     vmac_rslt_eew32_no_widen_d1;
logic [`VLENW-1:0][2*`WORD_WIDTH:0]   vmac_mul_add_eew32_widen_d1;
logic [`VLENW-1:0][2*`WORD_WIDTH:0]   vmac_mul_sub_eew32_widen_d1;
logic [2*`VLEN-1:0]                   vmac_rslt_eew32_widen_d1;
`endif

logic [`VLENB-1:0]                    update_vxsat;

`ifdef TB_SUPPORT
logic [`PC_WIDTH-1:0]                 mac_uop_pc;
logic [`PC_WIDTH-1:0]                 mac_uop_pc_d1;
`endif

//Int & Genvar
integer i,j;
genvar z,x,y;

// Input struct decode
assign mac_uop_rob_entry = rs2mac_uop_data.rob_entry;
assign mac_uop_funct6    = rs2mac_uop_data.uop_funct6.ari_funct6;
assign mac_uop_funct3    = rs2mac_uop_data.uop_funct3;
assign mac_uop_xrm       = rs2mac_uop_data.vxrm;
assign mac_top_vs_eew    = rs2mac_uop_data.vs2_eew;
assign mac_uop_vs1_data  = rs2mac_uop_data.vs1_data;
assign mac_uop_vs2_data  = rs2mac_uop_data.vs2_data;
assign mac_uop_vs3_data  = rs2mac_uop_data.vs3_data;
assign mac_uop_rs1_data  = rs2mac_uop_data.vs1_data[`XLEN-1:0];
assign mac_uop_index     = rs2mac_uop_data.uop_index;
`ifdef TB_SUPPORT
assign mac_uop_pc        = rs2mac_uop_data.uop_pc;
`endif

// Global EU control
always@(*) begin
  case ({rs2mac_uop_valid,mac_uop_funct3}) 
    {1'b1,OPMVV} : begin
      is_vv = 1'b1;
      case (mac_uop_funct6) 
        VMACC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VNMSAC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMADD : begin
          mac_src2           = mac_uop_vs3_data; //vd
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VNMSUB : begin
          mac_src2           = mac_uop_vs3_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACC : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMUL: begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULH : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHSU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMUL : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = (`VLEN)'(mac_uop_vs1_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        default : begin 
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;
        end//end default
      endcase//end funct6
    end//end OPMVV
    {1'b1,OPMVX} : begin
      is_vv = 1'b0;
      case (mac_uop_funct6) 
        VMACC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VNMSAC : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMADD : begin
          mac_src2           = mac_uop_vs3_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VNMSUB : begin
          mac_src2           = mac_uop_vs3_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs2_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b1;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACC : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VWMACCUS : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = mac_uop_vs3_data;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b1;
        end
        VMUL : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b1;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULH : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VMULHSU : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMUL : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b0;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        VWMULSU : begin
          mac_src2           = (`VLEN)'(mac_uop_vs2_data[mac_uop_index*(`VLEN/2) +: `VLEN/2]);
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b0;
          mac_is_widen       = 1'b1;
          mac_keep_low_bits  = 1'b0;//if widen, keep_low doesnt matter
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b0;
          is_vmac            = 1'b0;
        end
        default : begin 
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;        
        end//end default
      endcase
    end//end OPMVX
    {1'b1,OPIVV} : begin
      is_vv = 1'b1;
      case (mac_uop_funct6) 
        VSMUL_VMVNRR : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = mac_uop_vs1_data;
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b1;
          is_vmac            = 1'b0;
        end
        default : begin 
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;  
        end//end default
      endcase//end funct6
    end//end OPIVV
    {1'b1,OPIVX} : begin
      is_vv = 1'b0;
      case (mac_uop_funct6) 
        VSMUL_VMVNRR : begin
          mac_src2           = mac_uop_vs2_data;
          mac_src1           = {(`VLEN-`XLEN)'('b0),mac_uop_rs1_data}; //use rs1
          mac_addsrc         = `VLEN'b0;
          mac_src2_is_signed = 1'b1;
          mac_src1_is_signed = 1'b1;
          mac_is_widen       = 1'b0;
          mac_keep_low_bits  = 1'b0;
          mac_mul_reverse    = 1'b0;
          is_vsmul           = 1'b1;
          is_vmac            = 1'b0;
        end
        default : begin //currently put default the same as VSMUL_VMVNRR
          mac_src2           = 'b0;
          mac_src1           = 'b0;
          mac_addsrc         = 'b0;
          mac_src2_is_signed = 'b0;
          mac_src1_is_signed = 'b0;
          mac_is_widen       = 'b0;
          mac_keep_low_bits  = 'b0;
          mac_mul_reverse    = 'b0;
          is_vsmul           = 'b0;
          is_vmac            = 'b0;          
        end//end default
      endcase//end funct6
    end//end OPIVX
    default : begin
      is_vv              = 1'b1;
      mac_src2           = `VLEN'b0;
      mac_src1           = `VLEN'b0;
      mac_addsrc         = `VLEN'b0;
      mac_src2_is_signed = 1'b0;
      mac_src1_is_signed = 1'b0;
      mac_is_widen       = 1'b0;
      mac_keep_low_bits  = 1'b0;
      mac_mul_reverse    = 1'b0;
      is_vsmul           = 1'b0;
      is_vmac            = 1'b0;
    end//end default
  endcase//end funct3
end

// Before using mac alu, 
//  1.group sub-elements' sign bit
always@(*) begin
  mac_src2_mux                  = mac_src2;
  
  case (mac_top_vs_eew) 
    EEW16 : begin
      mac_src1_mux              = is_vv ? mac_src1 : {(`VLENH){mac_src1[`HWORD_WIDTH-1:0]}};
      mac_src2_is_signed_extend = {(`VLENH){mac_src2_is_signed,1'b0}};
      mac_src1_is_signed_extend = {(`VLENH){mac_src1_is_signed,1'b0}};
    end//end eew16
    EEW32 : begin
      mac_src1_mux              = is_vv ? mac_src1 : {(`VLENW){mac_src1[`WORD_WIDTH-1:0]}};
      mac_src2_is_signed_extend = {(`VLENW){mac_src2_is_signed,3'b0}};
      mac_src1_is_signed_extend = {(`VLENW){mac_src1_is_signed,3'b0}};
    end//end eew32
    default : begin //default use eew8
      mac_src1_mux              = is_vv ? mac_src1 : {`VLENB{mac_src1[`BYTE_WIDTH-1:0]}};
      mac_src2_is_signed_extend = {`VLENB{mac_src2_is_signed}};
      mac_src1_is_signed_extend = {`VLENB{mac_src1_is_signed}};
    end//end default
  endcase
end

// Before mac, always depart 128 bits into 16x8 sub-elements
always@(*) begin
  for (i=0; i<`VLENB; i=i+1) begin
      mac8_in0[i]           = mac_src2_mux[i*`BYTE_WIDTH +: `BYTE_WIDTH];
      mac8_in1[i]           = mac_src1_mux[i*`BYTE_WIDTH +: `BYTE_WIDTH];
      mac8_in0_is_signed[i] = mac_src2_is_signed_extend[i];
      mac8_in1_is_signed[i] = mac_src1_is_signed_extend[i];
  end
end

// enable for mac unit pipe
always_comb begin
  mac8_en = 'b0;

  case (mac_top_vs_eew) 
    EEW8: begin
      for(int i=0;i<`VLENW;i++) begin
        mac8_en[16*i]    = mac_pipe_data_en;
        mac8_en[16*i+5]  = mac_pipe_data_en;
        mac8_en[16*i+10] = mac_pipe_data_en;
        mac8_en[16*i+15] = mac_pipe_data_en;
      end
    end
    EEW16: begin
      for(int i=0;i<`VLENW;i++) begin
        mac8_en[16*i]    = mac_pipe_data_en;
        mac8_en[16*i+1]  = mac_pipe_data_en;
        mac8_en[16*i+4]  = mac_pipe_data_en;
        mac8_en[16*i+5]  = mac_pipe_data_en;
        mac8_en[16*i+10] = mac_pipe_data_en;
        mac8_en[16*i+11] = mac_pipe_data_en;
        mac8_en[16*i+14] = mac_pipe_data_en;
        mac8_en[16*i+15] = mac_pipe_data_en;
      end
    end
    EEW32: mac8_en = {(`VLEN/2){mac_pipe_data_en}};
  endcase
end

// mul alus with d1_reg
// `VLEN/32 tiles
generate 
  for (z=0; z<`VLENW; z=z+1) begin: cnt_tiles
    for (x=0; x<`WORD_WIDTH/`BYTE_WIDTH; x=x+1) begin: cnt_src0_axis
      for (y=0; y<`WORD_WIDTH/`BYTE_WIDTH; y=y+1) begin: cnt_src1_axis
        rvv_backend_mul_unit_mul8 
        u_mul8 (
          .res            (mac8_out[z*16+y*4+x]     ), //16bit out
          .src0           (mac8_in0[z*4+x]          ), 
          .src0_is_signed (mac8_in0_is_signed[z*4+x]),
          .src1           (mac8_in1[z*4+y]          ), 
          .src1_is_signed (mac8_in1_is_signed[z*4+y])
        );

        edff #(
          .T              (logic [`HWORD_WIDTH-1:0])
        ) 
        u_mul8_delay (
          .q              (mac8_out_d1[z*16+y*4+x]  ), 
          .clk            (clk                      ), 
          .rst_n          (rst_n                    ), 
          .e              (mac8_en[z*16+y*4+x]      ),     
          .d              (mac8_out[z*16+y*4+x]     )
        );
      end
    end
  end
endgenerate

cdffr #(.T(logic))              u_valid_delay (
  .clk(clk), .rst_n(rst_n), .c(trap_flush_rvv), .e(mac_pipe_vld_en), .d(rs2mac_uop_valid), .q(rs2mac_uop_valid_d1));
edff  #(.T(logic [`VLEN-1:0]))  u_addsrc_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_addsrc), .q(mac_addsrc_d1));
edff #(.T(logic))               u_src2_is_signed_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_src2_is_signed), .q(mac_src2_is_signed_d1));
edff #(.T(logic))               u_src1_is_signed_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_src1_is_signed), .q(mac_src1_is_signed_d1));
edff #(.T(logic))               u_is_widen_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_is_widen), .q(mac_is_widen_d1));
edff #(.T(logic))               u_keep_low_bits_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_keep_low_bits), .q(mac_keep_low_bits_d1));
edff #(.T(logic))               u_is_vsmul_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(is_vsmul), .q(is_vsmul_d1));
edff #(.T(logic))               u_mul_reverse_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_mul_reverse), .q(mac_mul_reverse_d1));
edff #(.T(logic))               u_is_vmac_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(is_vmac), .q(is_vmac_d1));
edff #(.T(RVVXRM))              u_xrm_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_uop_xrm), .q(mac_uop_xrm_d1));
edff #(.T(EEW_e))               u_eew_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_top_vs_eew), .q(mac_top_vs_eew_d1));
edff #(.T(logic [`ROB_DEPTH_WIDTH-1:0]))  u_rob_entry_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_uop_rob_entry), .q(mac_uop_rob_entry_d1));
`ifdef TB_SUPPORT
edff #(.T(logic [`PC_WIDTH-1:0]))         u_PC_delay (
  .clk(clk), .rst_n(rst_n), .e(!trap_flush_rvv&mac_pipe_data_en), .d(mac_uop_pc), .q(mac_uop_pc_d1));
`endif

/////////////////////////////////////////////////
///////Enter EX2_stage ///////////////////////////
/////////////////////////////////////////////////

//when widen, copy low half to high, for widen add
assign mac_addsrc_widen_d1 = {2{mac_addsrc_d1}}; 

// After mac, calculte eew8, eew16, eew32 results
//eew8
//full rslt is 16bit
always@(*) begin
  for (i=0; i<`VLENW; i=i+1) begin: tiles_eew8
    for (j=0; j<`WORD_WIDTH/`BYTE_WIDTH; j=j+1) begin // 
      mac_rslt_full_eew8_d1[i*4+j]                                   = mac8_out_d1[i*16+j*5];
      mac_rslt_eew8_widen_d1[2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH] = mac_rslt_full_eew8_d1[i*4+j];//widen, and convert to [255:0]
      mac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]  = mac_keep_low_bits_d1 ? 
                                                                       mac_rslt_full_eew8_d1[i*4+j][0          +:`BYTE_WIDTH] : 
                                                                       mac_rslt_full_eew8_d1[i*4+j][`BYTE_WIDTH+:`BYTE_WIDTH];
      //Below are for rounding mul (vsmul.vv, vsmul.vx)
      //right shift bit is 7 not 8 !
      case(mac_uop_xrm_d1)
        ROD: vsmul_round_incr_eew8_d1[i*4+j] = !mac_rslt_full_eew8_d1[i*4+j][7] && (|mac_rslt_full_eew8_d1[i*4+j][6:0]);
        RDN: vsmul_round_incr_eew8_d1[i*4+j] = 'b0; 
        RNE: begin 
             vsmul_round_incr_eew8_d1[i*4+j] = mac_rslt_full_eew8_d1[i*4+j][6] && 
                                               ( (|mac_rslt_full_eew8_d1[i*4+j][5:0]) || mac_rslt_full_eew8_d1[i*4+j][7] );
        end
        //RNU
        default: vsmul_round_incr_eew8_d1[i*4+j] = mac_rslt_full_eew8_d1[i*4+j][6];
      endcase
      
      // saturating
      vsmul_sat_eew8_d1[i*4+j] = mac_rslt_full_eew8_d1[i*4+j][15:14] == 2'b01;
      vsmul_rslt_eew8_d1[`BYTE_WIDTH*(i*4+j)+:`BYTE_WIDTH] = vsmul_sat_eew8_d1[i*4+j] ? 8'h7f : //saturate 
                                   //right shift 7bit then +"1"
                                   mac_rslt_full_eew8_d1[i*4+j][(`BYTE_WIDTH-1)+:`BYTE_WIDTH] + {7'b0,vsmul_round_incr_eew8_d1[i*4+j]};

      //Below are for vmac related instructions
      vmac_mul_add_eew8_no_widen_d1[i*4+j] = {1'b0,mac_addsrc_d1[            `BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} + 
                                             {1'b0,mac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} ; //9bit
      vmac_mul_sub_eew8_no_widen_d1[i*4+j] = {1'b0,mac_addsrc_d1[            `BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} - 
                                             {1'b0,mac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH]} ;
      vmac_rslt_eew8_no_widen_d1[`BYTE_WIDTH*(i*4+j) +: `BYTE_WIDTH] = mac_mul_reverse_d1 ? 
                                                                         vmac_mul_sub_eew8_no_widen_d1[i*4+j][`BYTE_WIDTH-1:0] :
                                                                         vmac_mul_add_eew8_no_widen_d1[i*4+j][`BYTE_WIDTH-1:0] ;

      vmac_mul_add_eew8_widen_d1[i*4+j] = {1'b0,mac_addsrc_widen_d1[   2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} + 
                                          {1'b0,mac_rslt_eew8_widen_d1[2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} ; //17bit
      vmac_mul_sub_eew8_widen_d1[i*4+j] = {1'b0,mac_addsrc_widen_d1[   2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} - 
                                          {1'b0,mac_rslt_eew8_widen_d1[2*`BYTE_WIDTH*(i*4+j) +: 2*`BYTE_WIDTH]} ;
      vmac_rslt_eew8_widen_d1[`HWORD_WIDTH*(i*4+j) +: `HWORD_WIDTH] = mac_mul_reverse_d1 ? 
                                                                        vmac_mul_sub_eew8_widen_d1[i*4+j][2*`BYTE_WIDTH-1:0] :
                                                                        vmac_mul_add_eew8_widen_d1[i*4+j][2*`BYTE_WIDTH-1:0] ;
    end
  end
end

always_comb begin
  casex({is_vmac_d1,mac_is_widen_d1,is_vsmul_d1,mac_is_widen_d1})
    4'b11?? : mac_rslt_eew8_d1 = vmac_rslt_eew8_widen_d1[`VLEN-1:0];  //mac widen 
    4'b10?? : mac_rslt_eew8_d1 = vmac_rslt_eew8_no_widen_d1;          //mac normal
    4'b0?1? : mac_rslt_eew8_d1 = vsmul_rslt_eew8_d1;                  //vsmul
    4'b0?01 : mac_rslt_eew8_d1 = mac_rslt_eew8_widen_d1[`VLEN-1:0];   //mul widen
    4'b0?00 : mac_rslt_eew8_d1 = mac_rslt_eew8_no_widen_d1;           //mul normal
    default : mac_rslt_eew8_d1 = 'b0;
  endcase
end

assign update_vxsat_eew8_d1 = vsmul_sat_eew8_d1;

//eew16
//full rslt is 32bit
always@(*) begin
  for (i=0; i<`VLENW; i=i+1) begin: tiles_eew16
    for (j=0; j<`WORD_WIDTH/`HWORD_WIDTH; j=j+1) begin // 
      mac_rslt_part16_eew16_d1[2*i+j] = {{2{mac8_out_d1[i*16+j*10+4][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+j*10+4]} + 
                                        {{2{mac8_out_d1[i*16+j*10+1][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+j*10+1]} ;

      mac_rslt_full_eew16_d1[2*i+j] = {mac8_out_d1[i*16+j*10+5],mac8_out_d1[i*16+j*10]} + 
                                      {{6{mac_rslt_part16_eew16_d1[2*i+j][17]}},mac_rslt_part16_eew16_d1[2*i+j],8'b0};

      mac_rslt_eew16_widen_d1[2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH] = mac_rslt_full_eew16_d1[i*2+j];  //widen, and convert to [255:0]
      mac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]  = mac_keep_low_bits_d1 ? 
                                                                            mac_rslt_full_eew16_d1[i*2+j][0           +:`HWORD_WIDTH] : 
                                                                            mac_rslt_full_eew16_d1[i*2+j][`HWORD_WIDTH+:`HWORD_WIDTH];
      //Below are for rounding mac (vsmul.vv, vsmul.vx)
      //right shift bit is 16-1=15 not 16 !
      case(mac_uop_xrm_d1)
        ROD: vsmul_round_incr_eew16_d1[i*2+j] = !mac_rslt_full_eew16_d1[i*2+j][15] && (|mac_rslt_full_eew16_d1[i*2+j][14:0]);
        RDN: vsmul_round_incr_eew16_d1[i*2+j] = 'b0; 
        RNE: begin 
             vsmul_round_incr_eew16_d1[i*2+j] = mac_rslt_full_eew16_d1[i*2+j][14] && 
                                                ( (|mac_rslt_full_eew16_d1[i*2+j][13:0]) || mac_rslt_full_eew16_d1[i*2+j][15]);
             
        end
        //RNU
        default: vsmul_round_incr_eew16_d1[i*2+j] = mac_rslt_full_eew16_d1[i*2+j][14];
      endcase

      // saturating
      vsmul_sat_eew16_d1[i*2+j] = mac_rslt_full_eew16_d1[i*2+j][31:30] == 2'b01;

      vsmul_rslt_eew16_d1[16*(i*2+j) +:16]= vsmul_sat_eew16_d1[i*2+j] ? 16'h7fff :        //saturate
                                              //right shift 15bit then +"1"
                                              mac_rslt_full_eew16_d1[i*2+j][(`HWORD_WIDTH-1)+:`HWORD_WIDTH] + 
                                              {15'b0,vsmul_round_incr_eew16_d1[i*2+j]} ;  

      //Below are for vmac related instructions
      vmac_mul_add_eew16_no_widen_d1[i*2+j] = {1'b0,mac_addsrc_d1[             `HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} + 
                                              {1'b0,mac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} ; //17bit
      vmac_mul_sub_eew16_no_widen_d1[i*2+j] = {1'b0,mac_addsrc_d1[             `HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} - 
                                              {1'b0,mac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +: `HWORD_WIDTH]} ;
      vmac_rslt_eew16_no_widen_d1[`HWORD_WIDTH*(i*2+j) +:`HWORD_WIDTH] = mac_mul_reverse_d1 ? 
                                                                           vmac_mul_sub_eew16_no_widen_d1[i*2+j][`HWORD_WIDTH-1:0] :
                                                                           vmac_mul_add_eew16_no_widen_d1[i*2+j][`HWORD_WIDTH-1:0] ;
                                                                           
      vmac_mul_add_eew16_widen_d1[i*2+j] = {1'b0,mac_addsrc_widen_d1[    2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} + 
                                           {1'b0,mac_rslt_eew16_widen_d1[2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} ; //33bit
      vmac_mul_sub_eew16_widen_d1[i*2+j] = {1'b0,mac_addsrc_widen_d1[    2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} - 
                                           {1'b0,mac_rslt_eew16_widen_d1[2*`HWORD_WIDTH*(i*2+j) +: 2*`HWORD_WIDTH]} ;
      vmac_rslt_eew16_widen_d1[`WORD_WIDTH*(i*2+j) +: `WORD_WIDTH] = mac_mul_reverse_d1 ? 
                                                                       vmac_mul_sub_eew16_widen_d1[i*2+j][2*`HWORD_WIDTH-1:0] :
                                                                       vmac_mul_add_eew16_widen_d1[i*2+j][2*`HWORD_WIDTH-1:0];
    end
  end
end

always_comb begin
  casex({is_vmac_d1,mac_is_widen_d1,is_vsmul_d1,mac_is_widen_d1})
    4'b11?? : mac_rslt_eew16_d1 = vmac_rslt_eew16_widen_d1[`VLEN-1:0];  //mac widen 
    4'b10?? : mac_rslt_eew16_d1 = vmac_rslt_eew16_no_widen_d1;          //mac normal
    4'b0?1? : mac_rslt_eew16_d1 = vsmul_rslt_eew16_d1;                  //vsmul
    4'b0?01 : mac_rslt_eew16_d1 = mac_rslt_eew16_widen_d1[`VLEN-1:0];   //mul widen
    4'b0?00 : mac_rslt_eew16_d1 = mac_rslt_eew16_no_widen_d1;           //mul normal
    default : mac_rslt_eew16_d1 = 'b0;
  endcase
end

always_comb begin
  for(int i=0;i<`VLENH;i++) begin
    update_vxsat_eew16_d1[2*i +: 2] = {vsmul_sat_eew16_d1[i],1'b0}; 
  end
end

//eew32
`ifdef CORALNPU_STRUCTURAL_DATAPATH
generate
  for (genvar mac_i = 0; mac_i < `VLENW; mac_i = mac_i + 1) begin : gen_mac_eew32_lane
    rvv_backend_mac_eew32_datapath u_mac_eew32_lane (
      .mac8_out       (mac8_out_d1[mac_i*16 +: 16]),
      .src1_is_signed (mac_src1_is_signed_d1),
      .src2_is_signed (mac_src2_is_signed_d1),
      .keep_low_bits  (mac_keep_low_bits_d1),
      .xrm            (mac_uop_xrm_d1),
      .is_vsmul       (is_vsmul_d1),
      .is_vmac        (is_vmac_d1),
      .mul_reverse    (mac_mul_reverse_d1),
      .addsrc_no_widen(mac_addsrc_d1[`WORD_WIDTH*mac_i +: `WORD_WIDTH]),
      .addsrc_widen   (mac_addsrc_widen_d1[2*`WORD_WIDTH*mac_i +: 2*`WORD_WIDTH]),
      .result_narrow  (mac_rslt_eew32_no_widen_d1[`WORD_WIDTH*mac_i +: `WORD_WIDTH]),
      .result_widen   (mac_rslt_eew32_widen_d1[2*`WORD_WIDTH*mac_i +: 2*`WORD_WIDTH]),
      .vxsat          (vsmul_sat_eew32_d1[mac_i])
    );
  end
endgenerate

assign mac_rslt_eew32_d1 = mac_is_widen_d1 ? mac_rslt_eew32_widen_d1[`VLEN-1:0] :
                                             mac_rslt_eew32_no_widen_d1;
`else
//full rslt is 64bit
always@(*) begin
  for (i=0; i<`VLENW; i=i+1) begin //z
    mac_rslt_part16_eew32_d1[i] = {{2{mac8_out_d1[i*16+12][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+12]} +
                                  {{2{mac8_out_d1[i*16+3 ][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+3 ]} ;    
    mac_rslt_part32_eew32_d1[i] = {{2{mac8_out_d1[i*16+13][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+13],mac8_out_d1[i*16+5]} +
                                  {{2{mac8_out_d1[i*16+7 ][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+7 ],mac8_out_d1[i*16+8]} ;
    mac_rslt_part48_eew32_d1[i] = {{2{mac8_out_d1[i*16+14][15]&&mac_src1_is_signed_d1}},mac8_out_d1[i*16+14],mac8_out_d1[i*16+6],mac8_out_d1[i*16+4]} +
                                  {{2{mac8_out_d1[i*16+11][15]&&mac_src2_is_signed_d1}},mac8_out_d1[i*16+11],mac8_out_d1[i*16+9],mac8_out_d1[i*16+1]} ;

    mac_rslt_full_eew32_d1[i] = 
      {mac8_out_d1[i*16+15],mac8_out_d1[i*16+10],mac8_out_d1[i*16+2],mac8_out_d1[i*16]} + 
      {{22{mac_rslt_part16_eew32_d1[i][17]}},mac_rslt_part16_eew32_d1[i],24'b0} +
      {{14{mac_rslt_part32_eew32_d1[i][33]}},mac_rslt_part32_eew32_d1[i],16'b0} +
      {{6{mac_rslt_part48_eew32_d1[i][49]}},mac_rslt_part48_eew32_d1[i],8'b0} ;

    mac_rslt_eew32_widen_d1[2*`WORD_WIDTH*i +: 2*`WORD_WIDTH] = mac_rslt_full_eew32_d1[i];//widen, and convert to [255:0]
    mac_rslt_eew32_no_widen_d1[`WORD_WIDTH*i +: `WORD_WIDTH]  = mac_keep_low_bits_d1 ?
                                                                  mac_rslt_full_eew32_d1[i][0           +: `WORD_WIDTH] : 
                                                                  mac_rslt_full_eew32_d1[i][`WORD_WIDTH +: `WORD_WIDTH] ; 
    //Below are for rounding mac (vsmul.vv, vsmul.vx)
    //right shift bit is 32-1=31 not 32 !
    case(mac_uop_xrm_d1)
      ROD: vsmul_round_incr_eew32_d1[i] = !mac_rslt_full_eew32_d1[i][31] && (|mac_rslt_full_eew32_d1[i][30:0]);
      RDN: vsmul_round_incr_eew32_d1[i] = 'b0; 
      RNE: begin 
           vsmul_round_incr_eew32_d1[i] = mac_rslt_full_eew32_d1[i][30] && 
                                          ((|mac_rslt_full_eew32_d1[i][29:0]) || mac_rslt_full_eew32_d1[i][31]);
      end
      //RNU
      default: vsmul_round_incr_eew32_d1[i] = mac_rslt_full_eew32_d1[i][30];
    endcase

    // saturating  
    vsmul_sat_eew32_d1[i] = mac_rslt_full_eew32_d1[i][63:62] == 2'b01;
    vsmul_rslt_eew32_d1[`WORD_WIDTH*i +: `WORD_WIDTH] = vsmul_sat_eew32_d1[i] ? 32'h7fff_ffff : //saturate
                                                          //right shift 31bit then +"1"
                                                          mac_rslt_full_eew32_d1[i][(`WORD_WIDTH-1)+:`WORD_WIDTH] + 
                                                          {31'b0,vsmul_round_incr_eew32_d1[i]};

    //Below are for vmac related instructions
    vmac_mul_add_eew32_no_widen_d1[i] = {1'b0,mac_addsrc_d1[             `WORD_WIDTH*i +: `WORD_WIDTH]} + 
                                        {1'b0,mac_rslt_eew32_no_widen_d1[`WORD_WIDTH*i +: `WORD_WIDTH]} ;  //33bit
    vmac_mul_sub_eew32_no_widen_d1[i] = {1'b0,mac_addsrc_d1[             `WORD_WIDTH*i +: `WORD_WIDTH]} - 
                                        {1'b0,mac_rslt_eew32_no_widen_d1[`WORD_WIDTH*i +: `WORD_WIDTH]} ;
    vmac_rslt_eew32_no_widen_d1[32*i +:32] = mac_mul_reverse_d1 ? vmac_mul_sub_eew32_no_widen_d1[i][`WORD_WIDTH-1:0] :
                                                                  vmac_mul_add_eew32_no_widen_d1[i][`WORD_WIDTH-1:0] ;

    vmac_mul_add_eew32_widen_d1[i] = {1'b0,mac_addsrc_widen_d1[    2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} + 
                                     {1'b0,mac_rslt_eew32_widen_d1[2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} ; //65bit
    vmac_mul_sub_eew32_widen_d1[i] = {1'b0,mac_addsrc_widen_d1[    2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} - 
                                     {1'b0,mac_rslt_eew32_widen_d1[2*`WORD_WIDTH*i +: 2*`WORD_WIDTH]} ;
    vmac_rslt_eew32_widen_d1[64*i +: 64] = mac_mul_reverse_d1 ? vmac_mul_sub_eew32_widen_d1[i][2*`WORD_WIDTH-1:0] :
                                                                vmac_mul_add_eew32_widen_d1[i][2*`WORD_WIDTH-1:0] ;
  end
end

always_comb begin
  casex({is_vmac_d1,mac_is_widen_d1,is_vsmul_d1,mac_is_widen_d1})
    4'b11?? : mac_rslt_eew32_d1 = vmac_rslt_eew32_widen_d1[`VLEN-1:0];  //mac widen 
    4'b10?? : mac_rslt_eew32_d1 = vmac_rslt_eew32_no_widen_d1;          //mac normal
    4'b0?1? : mac_rslt_eew32_d1 = vsmul_rslt_eew32_d1;                  //vsmul
    4'b0?01 : mac_rslt_eew32_d1 = mac_rslt_eew32_widen_d1[`VLEN-1:0];   //mul widen
    4'b0?00 : mac_rslt_eew32_d1 = mac_rslt_eew32_no_widen_d1;           //mul normal
    default : mac_rslt_eew32_d1 = 'b0;
  endcase
end

`endif
always_comb begin
  for(int i=0;i<`VLENW;i++) begin
    update_vxsat_eew32_d1[4*i +: 4] = {vsmul_sat_eew32_d1[i],3'b0}; 
  end
end

//Output pack
`ifdef TB_SUPPORT
  assign mac2rob_uop_data.uop_pc    = mac_uop_pc_d1;
`endif
  assign mac2rob_uop_valid          = rs2mac_uop_valid_d1;
  assign mac2rob_uop_data.rob_entry = mac_uop_rob_entry_d1;
  assign mac2rob_uop_data.w_valid   = rs2mac_uop_valid_d1;
  assign mac2rob_uop_data.vsaturate = is_vsmul_d1 ? update_vxsat : 'b0;
`ifdef ZVE32F_ON
  assign mac2rob_uop_data.fpexp     = 'b0;
`endif

always_comb begin
  case(mac_top_vs_eew_d1)
    EEW32: begin
      mac2rob_uop_data.w_data = mac_rslt_eew32_d1; 
      update_vxsat            = update_vxsat_eew32_d1;
    end
    EEW16: begin
      mac2rob_uop_data.w_data = mac_rslt_eew16_d1; 
      update_vxsat            = update_vxsat_eew16_d1;
    end
    default: begin  // EEW8
      mac2rob_uop_data.w_data = mac_rslt_eew8_d1; 
      update_vxsat            = update_vxsat_eew8_d1;
    end
  endcase
end


endmodule
