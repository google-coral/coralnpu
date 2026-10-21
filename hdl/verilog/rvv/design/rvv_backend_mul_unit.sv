// description: 
// 1. It will get uops from MUL Reservation station and execute this uop.
//
// feature list:
// 1. 

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_mul_unit (
  // Outputs
  mul2rob_uop_valid, mul2rob_uop_data,
  // Inputs
  clk, rst_n, rs2mul_uop_valid, rs2mul_uop_data,
  mul_stg0_vld_en, mul_stg0_data_en
  );

input             clk;
input             rst_n;

input             rs2mul_uop_valid;
input MUL_RS_t    rs2mul_uop_data;

input             mul_stg0_vld_en;
input             mul_stg0_data_en;

output            mul2rob_uop_valid;
output PU2ROB_t   mul2rob_uop_data;

// Wires & Regs
logic [`ROB_DEPTH_WIDTH-1:0]   mul_uop_rob_entry;
logic [`FUNCT6_WIDTH-1:0]      mul_uop_funct6;
logic [`FUNCT3_WIDTH-1:0]      mul_uop_funct3;
logic [1:0]                    mul_uop_xrm;
logic [2:0]                    mul_top_vs_eew;
logic [`VLEN-1:0]              mul_uop_vs1_data;
logic [`VLEN-1:0]              mul_uop_vs2_data;
logic [`XLEN-1:0]              mul_uop_rs1_data;
logic                          mul_uop_index;

logic                          is_vv; //1:op*vv; 0:op*vx
logic [`VLEN-1:0]              mul_src2;
logic [`VLEN-1:0]              mul_src1;
logic                          mul_src2_is_signed;
logic                          mul_src1_is_signed;
logic                          mul_is_widen;
logic                          mul_keep_low_bits;
logic                          is_vsmul;

logic [`VLEN-1:0]              mul_src2_mux;
logic [`VLEN-1:0]              mul_src1_mux;
logic [15:0]                   mul_src2_is_signed_extend;
logic [15:0]                   mul_src1_is_signed_extend;

logic [7:0]                    mul8_in0[15:0];
logic [15:0]                   mul8_in0_is_signed;
logic [7:0]                    mul8_in1[15:0];
logic [15:0]                   mul8_in1_is_signed;
logic [15:0]                   mul8_out[63:0];

`ifdef CORALNPU_STRUCTURAL_DATAPATH
logic [63:0][15:0]             mul8_out_d1;
`else
logic [15:0]                   mul8_out_d1[63:0];
`endif

logic                          rs2mul_uop_valid_d1;
logic                          mul_src2_is_signed_d1;
logic                          mul_src1_is_signed_d1;
logic                          mul_is_widen_d1;
logic                          mul_keep_low_bits_d1;
logic                          is_vsmul_d1;
logic [1:0]                    mul_uop_xrm_d1;
logic [2:0]                    mul_top_vs_eew_d1;
logic [`ROB_DEPTH_WIDTH-1:0]   mul_uop_rob_entry_d1;

logic [15:0]                   mul_rslt_full_eew8_d1[15:0];
logic [2*`VLEN-1:0]            mul_rslt_eew8_widen_d1;
logic [`VLEN-1:0]              mul_rslt_eew8_no_widen_d1;
logic [15:0]                   vsmul_round_incr_eew8_d1;
logic [`VLEN-1:0]              vsmul_rslt_eew8_d1;
logic [15:0]                   vsmul_sat_eew8_d1;
logic [`VLEN-1:0]              mul_rslt_eew8_d1;
logic [`VLENB-1:0]             update_vxsat_eew8_d1;

logic [31:0]                   mul_rslt_full_eew16_d1[7:0];
logic [2*`VLEN-1:0]            mul_rslt_eew16_widen_d1;
logic [`VLEN-1:0]              mul_rslt_eew16_no_widen_d1;
logic [7:0]                    vsmul_round_incr_eew16_d1;
logic [`VLEN-1:0]              vsmul_rslt_eew16_d1;
logic [7:0]                    vsmul_sat_eew16_d1;
logic [`VLEN-1:0]              mul_rslt_eew16_d1;
logic [`VLENB-1:0]             update_vxsat_eew16_d1;

`ifndef CORALNPU_STRUCTURAL_DATAPATH
logic [63:0]                   mul_rslt_full_eew32_d1[3:0];
`endif
logic [2*`VLEN-1:0]            mul_rslt_eew32_widen_d1;
logic [`VLEN-1:0]              mul_rslt_eew32_no_widen_d1;
`ifndef CORALNPU_STRUCTURAL_DATAPATH
logic [3:0]                    vsmul_round_incr_eew32_d1;
logic [`VLEN-1:0]              vsmul_rslt_eew32_d1;
`endif
logic [3:0]                    vsmul_sat_eew32_d1;
logic [`VLEN-1:0]              mul_rslt_eew32_d1;
logic [`VLENB-1:0]             update_vxsat_eew32_d1;

`ifdef TB_SUPPORT
logic [`PC_WIDTH-1:0]          mul_uop_pc;
logic [`PC_WIDTH-1:0]          mul_uop_pc_d1;
`endif

//Int & Genvar
integer i,j;
genvar z,x,y;

// Input struct decode
assign mul_uop_rob_entry = rs2mul_uop_data.rob_entry;
assign mul_uop_funct6 = rs2mul_uop_data.uop_funct6.ari_funct6;
assign mul_uop_funct3 = rs2mul_uop_data.uop_funct3;
assign mul_uop_xrm = rs2mul_uop_data.vxrm;
assign mul_top_vs_eew = rs2mul_uop_data.vs2_eew;

assign mul_uop_vs1_data = rs2mul_uop_data.vs1_data;

assign mul_uop_vs2_data = rs2mul_uop_data.vs2_data;

assign mul_uop_rs1_data = rs2mul_uop_data.rs1_data;

assign mul_uop_index = rs2mul_uop_data.uop_index[0];

`ifdef TB_SUPPORT
assign mul_uop_pc = rs2mul_uop_data.uop_pc;
`endif

// Global EU control
always@(*) begin
  case ({rs2mul_uop_valid,mul_uop_funct3}) 
    {1'b1,OPMVV} : begin
      is_vv = 1'b1;
      case (mul_uop_funct6) 
        VMUL: begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = mul_uop_vs1_data;
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b1;
          is_vsmul = 1'b0;
        end
        VMULH : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = mul_uop_vs1_data;
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b0;
        end
        VMULHU : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = mul_uop_vs1_data;
          mul_src2_is_signed = 1'b0;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b0;
        end
        VMULHSU : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = mul_uop_vs1_data;
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b0;
        end
        VWMUL : begin
          mul_src2 = {64'b0,mul_uop_vs2_data[mul_uop_index*64 +: 64]};
          mul_src1 = {64'b0,mul_uop_vs1_data[mul_uop_index*64 +: 64]};
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b1;
          mul_keep_low_bits = 1'b0;//if widen, keep_low doesnt matter
          is_vsmul = 1'b0;
        end
        VWMULU : begin
          mul_src2 = {64'b0,mul_uop_vs2_data[mul_uop_index*64 +: 64]};
          mul_src1 = {64'b0,mul_uop_vs1_data[mul_uop_index*64 +: 64]};
          mul_src2_is_signed = 1'b0;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b1;
          mul_keep_low_bits = 1'b0;//if widen, keep_low doesnt matter
          is_vsmul = 1'b0;
        end
        VWMULSU : begin
          mul_src2 = {64'b0,mul_uop_vs2_data[mul_uop_index*64 +: 64]};
          mul_src1 = {64'b0,mul_uop_vs1_data[mul_uop_index*64 +: 64]};
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b1;
          mul_keep_low_bits = 1'b0;//if widen, keep_low doesnt matter
          is_vsmul = 1'b0;
        end
        default : begin //default use VMUL
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = mul_uop_vs1_data;
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b1;
          is_vsmul = 1'b0;
        end//end default
      endcase//end funct6
    end//end OPMVV
    {1'b1,OPMVX} : begin
      is_vv = 1'b0;
      case (mul_uop_funct6) 
        VMUL : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b1;
          is_vsmul = 1'b0;
        end
        VMULH : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b0;
        end
        VMULHU : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b0;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b0;
        end
        VMULHSU : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b0;
        end
        VWMUL : begin
          mul_src2 = {64'b0,mul_uop_vs2_data[mul_uop_index*64 +: 64]};
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b1;
          mul_keep_low_bits = 1'b0;//if widen, keep_low doesnt matter
          is_vsmul = 1'b0;
        end
        VWMULU : begin
          mul_src2 = {64'b0,mul_uop_vs2_data[mul_uop_index*64 +: 64]};
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b0;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b1;
          mul_keep_low_bits = 1'b0;//if widen, keep_low doesnt matter
          is_vsmul = 1'b0;
        end
        VWMULSU : begin
          mul_src2 = {64'b0,mul_uop_vs2_data[mul_uop_index*64 +: 64]};
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b0;
          mul_is_widen = 1'b1;
          mul_keep_low_bits = 1'b0;//if widen, keep_low doesnt matter
          is_vsmul = 1'b0;
        end
        default : begin //default use VMUL
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b1;
          is_vsmul = 1'b0;
        end//end default
      endcase
    end//end OPMVX
    {1'b1,OPIVV} : begin
      is_vv = 1'b1;
      case (mul_uop_funct6) 
        VSMUL_VMVNRR : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = mul_uop_vs1_data;
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b1;
        end
        default : begin //currently put default the same as vsmul
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = mul_uop_vs1_data;
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b1;
        end//end default
      endcase//end funct6
    end//end OPIVV
    {1'b1,OPIVX} : begin
      is_vv = 1'b0;
      case (mul_uop_funct6) 
        VSMUL_VMVNRR : begin
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b1;
        end
        default : begin //currently put default the same as vsmul
          mul_src2 = mul_uop_vs2_data;
          mul_src1 = {{(`VLEN-`XLEN){mul_uop_rs1_data[`XLEN-1]&&mul_src1_is_signed}},mul_uop_rs1_data}; //use rs1
          mul_src2_is_signed = 1'b1;
          mul_src1_is_signed = 1'b1;
          mul_is_widen = 1'b0;
          mul_keep_low_bits = 1'b0;
          is_vsmul = 1'b1;
        end//end default
      endcase//end funct6
    end//end OPIVX
    default : begin
      is_vv = 1'b1;
      mul_src2 = `VLEN'b0;
      mul_src1 = `VLEN'b0;
      mul_src2_is_signed = 1'b0;
      mul_src1_is_signed = 1'b0;
      mul_is_widen = 1'b0;
      mul_keep_low_bits = 1'b0;
      is_vsmul = 1'b0;
    end//end default
  endcase//end funct3
end

// Before using MUL alu, 
//  1.group sub-elements' sign bit
// (TODO) let input is 0 when not use that EU
always@(*) begin
  case (mul_top_vs_eew) 
    EEW8 : begin
      mul_src2_mux = mul_src2;
      mul_src1_mux = is_vv ? mul_src1 : {16{mul_src1[7:0]}};
      mul_src2_is_signed_extend = {16{mul_src2_is_signed}};
      mul_src1_is_signed_extend = {16{mul_src1_is_signed}};
    end//end eew8
    EEW16 : begin
      mul_src2_mux = mul_src2;
      mul_src1_mux = is_vv ? mul_src1 : {8{mul_src1[15:0]}};
      mul_src2_is_signed_extend = {8{mul_src2_is_signed,1'b0}};
      mul_src1_is_signed_extend = {8{mul_src1_is_signed,1'b0}};
    end//end eew16
    EEW32 : begin
      mul_src2_mux = mul_src2;
      mul_src1_mux = is_vv ? mul_src1 : {4{mul_src1[31:0]}};
      mul_src2_is_signed_extend = {4{mul_src2_is_signed,3'b0}};
      mul_src1_is_signed_extend = {4{mul_src1_is_signed,3'b0}};
    end//end eew32
    default : begin //default use eew8
      mul_src2_mux = mul_src2;
      mul_src1_mux = is_vv ? mul_src1 : {16{mul_src1[7:0]}};
      mul_src2_is_signed_extend = {16{mul_src2_is_signed}};
      mul_src1_is_signed_extend = {16{mul_src1_is_signed}};
    end//end default
  endcase
end

// Before MUL, always depart 128 bits into 16x8 sub-elements
always@(*) begin
  for (i=0; i<16; i=i+1) begin
      mul8_in0[i] = mul_src2_mux[i*8 +: 8];
      mul8_in1[i] = mul_src1_mux[i*8 +: 8];
      mul8_in0_is_signed[i] = mul_src2_is_signed_extend[i];
      mul8_in1_is_signed[i] = mul_src1_is_signed_extend[i];
  end
end

// MUL alus with d1_reg
//  in a 4 of 4x4 tiled way for instantiation
generate 
  for (z=0; z<4; z=z+1) begin 
    for (x=0; x<4; x=x+1) begin
      for (y=0; y<4; y=y+1) begin
        rvv_backend_mul_unit_mul8 u_mul8 (
          .res(mul8_out[z*16+y*4+x]), //16bit out
          .src0(mul8_in0[z*4+x]), 
          .src0_is_signed(mul8_in0_is_signed[z*4+x]),
          .src1(mul8_in1[z*4+y]), 
          .src1_is_signed(mul8_in1_is_signed[z*4+y]));

        edff #(.T(logic [16-1:0])) u_mul8_delay (
          .q(mul8_out_d1[z*16+y*4+x]), 
          .clk(clk), 
          .rst_n(rst_n), 
          .e(mul_stg0_data_en),
          .d(mul8_out[z*16+y*4+x]));
      end
    end
  end
endgenerate

edff #(.T(logic)) u_valid_delay (.q(rs2mul_uop_valid_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_vld_en), .d(rs2mul_uop_valid));
edff #(.T(logic)) u_src2_is_signed_delay (.q(mul_src2_is_signed_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_src2_is_signed));
edff #(.T(logic)) u_src1_is_signed_delay (.q(mul_src1_is_signed_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_src1_is_signed));
edff #(.T(logic)) u_is_widen_delay (.q(mul_is_widen_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_is_widen));
edff #(.T(logic)) u_keep_low_bits_delay (.q(mul_keep_low_bits_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_keep_low_bits));
edff #(.T(logic)) u_is_vsmul_delay (.q(is_vsmul_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(is_vsmul));
edff #(.T(logic [2-1:0])) u_xrm_delay (.q(mul_uop_xrm_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_uop_xrm));
edff #(.T(logic [3-1:0])) u_eew_delay (.q(mul_top_vs_eew_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_top_vs_eew));

edff #(.T(logic [`ROB_DEPTH_WIDTH-1:0])) u_rob_entry_delay (.q(mul_uop_rob_entry_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_uop_rob_entry));

`ifdef TB_SUPPORT
edff #(.T(logic [`PC_WIDTH-1:0])) u_PC_delay (.q(mul_uop_pc_d1), .clk(clk), .rst_n(rst_n), .e(mul_stg0_data_en), .d(mul_uop_pc));
`endif

/////////////////////////////////////////////////
///////Enter d1_stage ///////////////////////////
/////////////////////////////////////////////////

// After MUL, calculte eew8, eew16, eew32 results
// Here we have a ([15:0] [63:0] mul8_out_d1)
//eew8
//full rslt is 16bit
always@(*) begin
  for (i=0; i<4; i=i+1) begin //z
    for (j=0; j<4; j=j+1) begin //x
        mul_rslt_full_eew8_d1[i*4+j] = mul8_out_d1[i*16+j*5];
        mul_rslt_eew8_widen_d1[16*(i*4+j) +: 16] = mul_rslt_full_eew8_d1[i*4+j];//widen, and convert to [255:0]
        mul_rslt_eew8_no_widen_d1[8*(i*4+j) +: 8] = mul_keep_low_bits_d1 ? mul_rslt_full_eew8_d1[i*4+j][7:0] : mul_rslt_full_eew8_d1[i*4+j][15:8];
        //Below are for rounding mul (vsmul.vv, vsmul.vx)
        //right shift bit is 7 not 8 !
        //(TODO) Improve to make this readable
        vsmul_round_incr_eew8_d1[i*4+j] = mul_uop_xrm_d1==2'd3 ? !mul_rslt_full_eew8_d1[i*4+j][7] && (|mul_rslt_full_eew8_d1[i*4+j][6:0]) : //ROD
                                          mul_uop_xrm_d1==2'd2 ? 1'b0  : //RDN
                                          mul_uop_xrm_d1==2'd1 ? mul_rslt_full_eew8_d1[i*4+j][6] && (|(mul_rslt_full_eew8_d1[i*4+j][5:0]) || mul_rslt_full_eew8_d1[i*4+j][7]) : //RNE
                                                                 mul_rslt_full_eew8_d1[i*4+j][6]; //RNU
        vsmul_rslt_eew8_d1[8*(i*4+j) +:8]= mul_rslt_full_eew8_d1[i*4+j][15:14] == 2'b01 ? 8'h7f : //saturate
                                                                                      mul_rslt_full_eew8_d1[i*4+j][7+:8] + {7'b0,vsmul_round_incr_eew8_d1[i*4+j]};//right shift 7bit then +"1"
        vsmul_sat_eew8_d1[i*4+j] = mul_rslt_full_eew8_d1[i*4+j][15:14] == 2'b01;
    end
  end
end
assign mul_rslt_eew8_d1 = is_vsmul_d1     ? vsmul_rslt_eew8_d1 : //vsmul
                          mul_is_widen_d1 ? mul_rslt_eew8_widen_d1[`VLEN-1:0] : //widen
                                            mul_rslt_eew8_no_widen_d1; //normal
assign update_vxsat_eew8_d1 = vsmul_sat_eew8_d1;
//eew16
//full rslt is 32bit
always@(*) begin
  for (i=0; i<4; i=i+1) begin //z
    for (j=0; j<2; j=j+1) begin //x
      mul_rslt_full_eew16_d1[i*2+j] = {mul8_out_d1[i*16+j*10+5],16'b0} + 
                                   {{8{mul8_out_d1[i*16+j*10+4][15]&&mul_src1_is_signed_d1}},mul8_out_d1[i*16+j*10+4],8'b0} + 
                                   {{8{mul8_out_d1[i*16+j*10+1][15]&&mul_src2_is_signed_d1}},mul8_out_d1[i*16+j*10+1],8'b0} + 
                                   {16'b0,mul8_out_d1[i*16+j*10]};
      mul_rslt_eew16_widen_d1[32*(i*2+j) +: 32] = mul_rslt_full_eew16_d1[i*2+j];//widen, and convert to [255:0]
      mul_rslt_eew16_no_widen_d1[16*(i*2+j) +: 16] = mul_keep_low_bits_d1 ? mul_rslt_full_eew16_d1[i*2+j][15:0] : mul_rslt_full_eew16_d1[i*2+j][31:16];
      //Below are for rounding mul (vsmul.vv, vsmul.vx)
      //right shift bit is 16-1=15 not 16 !
      //(TODO) Improve to make this readable
      vsmul_round_incr_eew16_d1[i*2+j] = mul_uop_xrm_d1==2'd3 ? !mul_rslt_full_eew16_d1[i*2+j][15] && (|mul_rslt_full_eew16_d1[i*2+j][14:0]) : //ROD
                                         mul_uop_xrm_d1==2'd2 ? 1'b0  : //RDN
                                         mul_uop_xrm_d1==2'd1 ? mul_rslt_full_eew16_d1[i*2+j][14] && (|(mul_rslt_full_eew16_d1[i*2+j][13:0]) || mul_rslt_full_eew16_d1[i*2+j][15]) : //RNE
                                                                mul_rslt_full_eew16_d1[i*2+j][14]; //RNU
      vsmul_rslt_eew16_d1[16*(i*2+j) +:16]= mul_rslt_full_eew16_d1[i*2+j][31:30] == 2'b01 ? 16'h7fff : //saturate
                                                                                       mul_rslt_full_eew16_d1[i*2+j][15+:16] + {15'b0,vsmul_round_incr_eew16_d1[i*2+j]};//right shift 15bit then +"1"
      vsmul_sat_eew16_d1[i*2+j] = mul_rslt_full_eew16_d1[i*2+j][31:30] == 2'b01;
    end
  end
end
assign mul_rslt_eew16_d1 = is_vsmul_d1     ? vsmul_rslt_eew16_d1 : //vsmul
                           mul_is_widen_d1 ? mul_rslt_eew16_widen_d1[`VLEN-1:0] : //widen
                                             mul_rslt_eew16_no_widen_d1; //normal
assign update_vxsat_eew16_d1 = {vsmul_sat_eew16_d1[7],1'b0,
                                vsmul_sat_eew16_d1[6],1'b0,
                                vsmul_sat_eew16_d1[5],1'b0,
                                vsmul_sat_eew16_d1[4],1'b0,
                                vsmul_sat_eew16_d1[3],1'b0,
                                vsmul_sat_eew16_d1[2],1'b0,
                                vsmul_sat_eew16_d1[1],1'b0,
                                vsmul_sat_eew16_d1[0],1'b0};
//eew32
`ifdef CORALNPU_STRUCTURAL_DATAPATH
generate
  for (genvar mul_i = 0; mul_i < 4; mul_i = mul_i + 1) begin : gen_mul_eew32_lane
    rvv_backend_mul_eew32_datapath u_mul_eew32_lane (
      .mul8_out       (mul8_out_d1[mul_i*16 +: 16]),
      .src1_is_signed (mul_src1_is_signed_d1),
      .src2_is_signed (mul_src2_is_signed_d1),
      .keep_low_bits  (mul_keep_low_bits_d1),
      .xrm            (mul_uop_xrm_d1),
      .is_vsmul       (is_vsmul_d1),
      .result_narrow  (mul_rslt_eew32_no_widen_d1[32*mul_i +: 32]),
      .result_widen   (mul_rslt_eew32_widen_d1[64*mul_i +: 64]),
      .vxsat          (vsmul_sat_eew32_d1[mul_i])
    );
  end
endgenerate
assign mul_rslt_eew32_d1 = mul_is_widen_d1 ? mul_rslt_eew32_widen_d1[`VLEN-1:0] :
                                             mul_rslt_eew32_no_widen_d1;
`else
//full rslt is 64bit
always@(*) begin
  for (i=0; i<4; i=i+1) begin //z
    mul_rslt_full_eew32_d1[i] = {mul8_out_d1[i*16+15],48'b0} + 
                             {{8{mul8_out_d1[i*16+14][15]&&mul_src1_is_signed_d1}},mul8_out_d1[i*16+14],40'b0} + 
                             {{8{mul8_out_d1[i*16+11][15]&&mul_src2_is_signed_d1}},mul8_out_d1[i*16+11],40'b0} + 
                             {{16{mul8_out_d1[i*16+13][15]&&mul_src1_is_signed_d1}},mul8_out_d1[i*16+13],32'b0} + 
                             {16'b0,mul8_out_d1[i*16+10],32'b0} + 
                             {{16{mul8_out_d1[i*16+7][15]&&mul_src2_is_signed_d1}},mul8_out_d1[i*16+7],32'b0} + 
                             {{24{mul8_out_d1[i*16+12][15]&&mul_src1_is_signed_d1}},mul8_out_d1[i*16+12],24'b0} + 
                             {24'b0,mul8_out_d1[i*16+9],24'b0} +
                             {24'b0,mul8_out_d1[i*16+6],24'b0} + 
                             {{24{mul8_out_d1[i*16+3][15]&&mul_src2_is_signed_d1}},mul8_out_d1[i*16+3],24'b0} + 
                             {32'b0,mul8_out_d1[i*16+8],16'b0} + 
                             {32'b0,mul8_out_d1[i*16+5],16'b0} +
                             {32'b0,mul8_out_d1[i*16+2],16'b0} + 
                             {40'b0,mul8_out_d1[i*16+4],8'b0} + 
                             {40'b0,mul8_out_d1[i*16+1],8'b0} + 
                             {48'b0,mul8_out_d1[i*16]};
    mul_rslt_eew32_widen_d1[64*i +: 64] = mul_rslt_full_eew32_d1[i];//widen, and convert to [255:0]
    mul_rslt_eew32_no_widen_d1[32*i +: 32] = mul_keep_low_bits_d1 ? mul_rslt_full_eew32_d1[i][31:0] : mul_rslt_full_eew32_d1[i][63:32];
    //Below are for rounding mul (vsmul.vv, vsmul.vx)
    //right shift bit is 32-1=31 not 32 !
    //(TODO) Improve to make this readable
    vsmul_round_incr_eew32_d1[i] = mul_uop_xrm_d1==2'd3 ? !mul_rslt_full_eew32_d1[i][31] && (|mul_rslt_full_eew32_d1[i][30:0]) : //ROD
                                   mul_uop_xrm_d1==2'd2 ? 1'b0  : //RDN
                                   mul_uop_xrm_d1==2'd1 ? mul_rslt_full_eew32_d1[i][30] && (|(mul_rslt_full_eew32_d1[i][29:0]) || mul_rslt_full_eew32_d1[i][31]) : //RNE
                                                          mul_rslt_full_eew32_d1[i][30]; //RNU      
    vsmul_rslt_eew32_d1[32*i +:32]= mul_rslt_full_eew32_d1[i][63:62] == 2'b01 ? 32'h7fff_ffff : //saturate
                                                                             mul_rslt_full_eew32_d1[i][31+:32] + {31'b0,vsmul_round_incr_eew32_d1[i]};//right shift 31bit then +"1"
    vsmul_sat_eew32_d1[i] = mul_rslt_full_eew32_d1[i][63:62] == 2'b01;
  end
end
assign mul_rslt_eew32_d1 = is_vsmul_d1     ? vsmul_rslt_eew32_d1 : //vsmul
                           mul_is_widen_d1 ? mul_rslt_eew32_widen_d1[`VLEN-1:0] : //widen
                                             mul_rslt_eew32_no_widen_d1; //normal
`endif
assign update_vxsat_eew32_d1 = {vsmul_sat_eew32_d1[3],3'b0,
                                vsmul_sat_eew32_d1[2],3'b0,
                                vsmul_sat_eew32_d1[1],3'b0,
                                vsmul_sat_eew32_d1[0],3'b0};

//Output pack
assign mul2rob_uop_valid = rs2mul_uop_valid_d1;

assign mul2rob_uop_data.rob_entry = mul_uop_rob_entry_d1;
assign mul2rob_uop_data.w_data = mul_top_vs_eew_d1==EEW32 ? mul_rslt_eew32_d1 : 
                                 mul_top_vs_eew_d1==EEW16 ? mul_rslt_eew16_d1 :
                                                            mul_rslt_eew8_d1; //all possible cases are 8/16/32
assign mul2rob_uop_data.w_valid = rs2mul_uop_valid_d1;
assign mul2rob_uop_data.vsaturate = is_vsmul_d1 ? mul_top_vs_eew_d1==EEW32 ? update_vxsat_eew32_d1 :
                                                  mul_top_vs_eew_d1==EEW16 ? update_vxsat_eew16_d1 :
                                                                             update_vxsat_eew8_d1  :
                                                                             {`VLENB{1'b0}};

`ifdef TB_SUPPORT
assign mul2rob_uop_data.uop_pc = mul_uop_pc_d1;
`endif
endmodule
