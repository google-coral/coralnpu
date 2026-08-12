// description

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`ifndef PMTRDT_DEFINE_SVH
`include "rvv_backend_pmtrdt.svh"
`endif

module rvv_backend_pmtrdt_unit_permutation
(
  clk,
  rst_n,

  pmt_uop_valid,
  pmt_uop,
  pmt_uop_ready,

  pmt_res_valid,
  pmt_res,
  pmt_res_ready,

  rd_index_pmt2vrf,
  rd_data_vrf2pmt,

  rob_rptr,
  trap_flush_rvv
);

// ---port definition-------------------------------------------------
// global signal
  input logic       clk;
  input logic       rst_n;

// the uop
  input             pmt_uop_valid;
  input PMT_RDT_RS_t pmt_uop;
  output logic      pmt_uop_ready;

// the result
  output logic      pmt_res_valid;
  output PU2ROB_t   pmt_res;
  input             pmt_res_ready;

// vrf read
  output logic [`REGIDX_WIDTH-1:0]            rd_index_pmt2vrf;
  input  logic [`VLENB-1:0][`BYTE_WIDTH-1:0]  rd_data_vrf2pmt;

// MISC
  input  logic [`ROB_DEPTH_WIDTH-1:0]         rob_rptr;
// trap-flush
  input             trap_flush_rvv;

// ---parameter definition--------------------------------------------
  localparam VLENB_WIDTH = $clog2(`VLENB);

// ---internal signal definition--------------------------------------
  PMT_CTRL_t                pmt_ctrl_t0, pmt_ctrl_t1, pmt_ctrl_t2;
  PMT_INFO_t  [`VLENB-1:0]  pmt_info_t0, pmt_info_t1;
  logic [`VLENB-1:0]        pmt_info_valid;
  logic                     pmt_info_ready;
  PMT_DATA_t  [`VLENB-1:0]  pmt_data_t1, pmt_data_t2;
  logic       [`VLENB-1:0]  pmt_t0_valid, pmt_t1_valid, pmt_t2_valid;
  logic       [`VLENB-1:0]  pmt_t0_ready, pmt_t1_ready, pmt_t2_ready;
  logic                     pmt_go;

  PMT_INFO_t  [`VLENB-1:0]  slideup_info_t0;
  PMT_INFO_t  [`VLENB-1:0]  slidedown_info_t0;
  PMT_INFO_t  [`VLENB-1:0]  rgather_info_t0;
  PMT_INFO_t  [`VLENB-1:0]  compress_info_t0;

  logic [`VLENB-1:0][`XLEN+1:0] slideup_offset;
  logic [`VLENB-1:0]            slideup_overflow;
  logic [`VLENB-1:0]            slideup_scalar_valid;
  logic [`VLENB-1:0][`XLEN+2:0] slidedown_offset;
  logic [`VLENB-1:0]            slidedown_overflow;
  logic [`VLENB-1:0]            slidedown_scalar_valid;
  logic [`VLENB-1:0][`XLEN-1:0] rgather_vs1;
  logic [2*`VLEN-1:0]           double_vs1_data;
  logic [`VLENB-1:0][`XLEN+2:0] rgather_offset;
  logic [`VLENB-1:0]            rgather_overflow;
  logic [`VLEN-1:0]             compress_vs1;
  logic [`VLEN-1:0]             compress_vs1_d, compress_vs1_q;
  logic [`VLEN-1:0]             compress_vmsof;
  logic [`VL_WIDTH-1:0]         compress_vfirst;
  logic                         compress_overflow;
  logic [`VLENB-1:0][`VSTART_WIDTH-1:0]   compress_offset;
  logic [`VLENB-1:0]            compress_info_enable;
  logic [VLENB_WIDTH-1:0]       compress_cnt_d, compress_cnt_q;
  logic                         compress_cnt_en;

  logic [`VSTART_WIDTH-1:0]     last_element_index;

  logic [`VLENB-1:0]            data_valid;
  logic [`VLENB-1:0]            data_valid_zsof; //zero set-only first
  logic [VLENB_WIDTH-1:0]       data_valid_zfirst;
  logic [`VLENB-1:0]            data_write_enable;
  logic                         data_clear; // clear data slots when all data are ready.

  genvar i;

// ---code start------------------------------------------------------
  // pmt_info_t0
  generate
    always_comb begin
    `ifdef ZVE32F_ON
      if (pmt_uop.first_uop_valid & (pmt_uop.uop_funct3==OPMVX || pmt_uop.uop_funct3==OPFVF)) // only vslide1up/vfslide1up
    `else
      if (pmt_uop.first_uop_valid & (pmt_uop.uop_funct3==OPMVX)) // only slide1up
    `endif
        case (pmt_uop.vs2_eew)
          EEW32:  slideup_scalar_valid = {{(`VLENB-4){1'h0}}, 4'hF};
          EEW16:  slideup_scalar_valid = {{(`VLENB-2){1'h0}}, 2'h3};
          default: slideup_scalar_valid = {{(`VLENB-1){1'h0}}, 1'h1}; // EEW8
        endcase
      else
        slideup_scalar_valid = '0;
    end
    for (i=0; i<`VLENB; i++) begin: gen_slideup_info_t0 
      always_comb begin
      `ifdef ZVE32F_ON
        if (pmt_uop.uop_funct3 == OPMVX || pmt_uop.uop_funct3 == OPFVF) begin
      `else
        if (pmt_uop.uop_funct3 == OPMVX) begin
      `endif
          case (pmt_uop.vs2_eew)
            EEW32: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({{(`XLEN+1){1'b0}}, 1'b1} << 2) + i;
            EEW16: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({{(`XLEN+1){1'b0}}, 1'b1} << 1) + i;
            default: //EEW8
                   slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({{(`XLEN+1){1'b0}}, 1'b1}) + i;
          endcase
        end else begin
          case (pmt_uop.vs2_eew)
            EEW32: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({2'h0, pmt_uop.rs1_data} << 2)  + i;
            EEW16: slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({2'h0, pmt_uop.rs1_data} << 1)  + i;
            default: //EEW8
                   slideup_offset[i] = (`VLENB * pmt_uop.uop_index) - ({2'h0, pmt_uop.rs1_data})  + i;
          endcase
        end
      end
      always_comb begin
        case (pmt_uop.vs2_eew)
          EEW32: slideup_overflow[i] = (|slideup_offset[i][`XLEN+1:`VL_WIDTH+2]) | (slideup_offset[i][`VL_WIDTH+1:0] >= ({2'h0, pmt_uop.vlmax} << 2));
          EEW16: slideup_overflow[i] = (|slideup_offset[i][`XLEN+1:`VL_WIDTH+1]) | (slideup_offset[i][`VL_WIDTH:0] >= ({1'b0, pmt_uop.vlmax} << 1));
          default: slideup_overflow[i] = (|slideup_offset[i][`XLEN+1:`VL_WIDTH]) | (slideup_offset[i][`VL_WIDTH-1:0] >= pmt_uop.vlmax); //EEW8
        endcase
      end
      always_comb begin
        slideup_info_t0[i].zero_valid = '0;
        slideup_info_t0[i].rs_valid = slideup_scalar_valid[i];
        slideup_info_t0[i].index = slideup_overflow[i] ? pmt_uop.dst_index : pmt_uop.vs2_index + slideup_offset[i][VLENB_WIDTH+:3];
        slideup_info_t0[i].offset = slideup_overflow[i] ? i[0+:VLENB_WIDTH] : slideup_offset[i][0+:VLENB_WIDTH];
        slideup_info_t0[i].vs_valid = ~slideup_info_t0[i].rs_valid & ((pmt_uop.uop_funct6 == VSLIDEUP_RGATHEREI16) | (pmt_uop.uop_funct6 == VSLIDE1UP));
      end
    end

    assign last_element_index = pmt_uop.vl - 'h1;
    always_comb begin
    `ifdef ZVE32F_ON
      if (pmt_uop.uop_funct3==OPMVX || pmt_uop.uop_funct3==OPFVF) // vslide1down/vfslide1down
    `else
      if (pmt_uop.uop_funct3==OPMVX) // vslide1down
    `endif
        case (pmt_uop.vs2_eew)
          EEW32: slidedown_scalar_valid = last_element_index[`VSTART_WIDTH-3:VLENB_WIDTH-2] == pmt_uop.uop_index ? {{(`VLENB-4){1'b0}}, 4'hF} << 4*last_element_index[VLENB_WIDTH-3:0] : '0;
          EEW16: slidedown_scalar_valid = last_element_index[`VSTART_WIDTH-2:VLENB_WIDTH-1] == pmt_uop.uop_index ? {{(`VLENB-2){1'b0}}, 2'h3} << 2*last_element_index[VLENB_WIDTH-2:0] : '0;
          default: slidedown_scalar_valid = last_element_index[`VSTART_WIDTH-1:VLENB_WIDTH] == pmt_uop.uop_index ? {{(`VLENB-1){1'b0}}, 1'h1} << last_element_index[VLENB_WIDTH-1:0] : '0;// EEW8
        endcase
      else
        slidedown_scalar_valid = '0;
    end
    for (i=0; i<`VLENB; i++) begin : gen_slidedown_info_t0
      always_comb begin
      `ifdef ZVE32F_ON
        if (pmt_uop.uop_funct3 == OPMVX || pmt_uop.uop_funct3 == OPFVF) begin
      `else
        if (pmt_uop.uop_funct3 == OPMVX) begin
      `endif
          case (pmt_uop.vs2_eew)
            EEW32: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({{(`XLEN+2){1'b0}}, 1'b1} << 2) + i;
            EEW16: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({{(`XLEN+2){1'b0}}, 1'b1} << 1) + i;
            default: //EEW8
                   slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({{(`XLEN+2){1'b0}}, 1'b1}) + i;
          endcase
        end else begin
          case (pmt_uop.vs2_eew)
            EEW32: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({3'h0, pmt_uop.rs1_data} << 2)  + i;
            EEW16: slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({3'h0, pmt_uop.rs1_data} << 1)  + i;
            default: //EEW8
                   slidedown_offset[i] = (`VLENB * pmt_uop.uop_index) + ({3'h0, pmt_uop.rs1_data})  + i;
          endcase
        end
      end
      always_comb begin
        case (pmt_uop.vs2_eew)
          EEW32: slidedown_overflow[i] = (|slidedown_offset[i][`XLEN+2:`VL_WIDTH+2]) | (slidedown_offset[i][`VL_WIDTH+1:0] >= ({2'h0, pmt_uop.vlmax} << 2));
          EEW16: slidedown_overflow[i] = (|slidedown_offset[i][`XLEN+2:`VL_WIDTH+1]) | (slidedown_offset[i][`VL_WIDTH:0] >= ({1'b0, pmt_uop.vlmax} << 1));
          default: slidedown_overflow[i] = (|slidedown_offset[i][`XLEN+2:`VL_WIDTH]) | (slidedown_offset[i][`VL_WIDTH-1:0] >= pmt_uop.vlmax);
        endcase
      end
      always_comb begin
        slidedown_info_t0[i].zero_valid = slidedown_overflow[i];
        slidedown_info_t0[i].rs_valid = slidedown_scalar_valid[i];
        slidedown_info_t0[i].index = pmt_uop.vs2_index + slidedown_offset[i][VLENB_WIDTH+:3];
        slidedown_info_t0[i].offset = slidedown_offset[i][0+:VLENB_WIDTH];
        slidedown_info_t0[i].vs_valid = ~slidedown_scalar_valid[i] & ~slidedown_overflow[i] & 
                                   ((pmt_uop.uop_funct6 == VSLIDEDOWN) | (pmt_uop.uop_funct6 == VSLIDE1DOWN));
      end
    end

    assign double_vs1_data = {2{pmt_uop.vs1_data}};
    for (i=0; i<`VLENB; i++) begin : gen_rgather_info_t0
      //rgather_vs1
      always_comb begin
        if (pmt_uop.uop_funct6 == VSLIDEUP_RGATHEREI16) begin //vs1_eew = 16b
          case(pmt_uop.vs2_eew)
            EEW32: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, pmt_uop.uop_index[0] ? pmt_uop.vs1_data[(i/4+`VLENW)*16+:16] : pmt_uop.vs1_data[(i/4)*16+:16]};
            EEW16: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, pmt_uop.vs1_data[(i/2)*16+:16]};
            default: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, double_vs1_data[i*16+:16]}; //EEW8
                                                                                       // uop_index[0] ? high part : low part; // based on valid
          endcase
        end else begin
          case(pmt_uop.vs2_eew)
            EEW32: rgather_vs1[i] = {{(`XLEN-32){1'b0}}, pmt_uop.vs1_data[(i/4)*32+:32]};
            EEW16: rgather_vs1[i] = {{(`XLEN-16){1'b0}}, pmt_uop.vs1_data[(i/2)*16+:16]};
            default: rgather_vs1[i] = {{(`XLEN-8){1'b0}}, pmt_uop.vs1_data[i*8+:8]};// EEW8
          endcase
        end
      end

      always_comb begin
        case (pmt_uop.uop_funct3)
          OPIVX,
          OPIVI:begin // vrgather.vx and vrgather.vi instructions
            case (pmt_uop.vs2_eew)
              EEW32: rgather_offset[i] = ({3'b0, pmt_uop.rs1_data} << 2) + (i%4);
              EEW16: rgather_offset[i] = ({3'b0, pmt_uop.rs1_data} << 1) + (i%2);
              default: rgather_offset[i] = ({3'b0, pmt_uop.rs1_data}) + (i%1); // EEW8
            endcase
          end
          default: begin // vrgather.vv and vrgatheri16.vv instructions
            case (pmt_uop.vs2_eew)
              EEW32: rgather_offset[i] = ({3'b0, rgather_vs1[i]} << 2) + (i%4); 
              EEW16: rgather_offset[i] = ({3'b0, rgather_vs1[i]} << 1) + (i%2);
              default: rgather_offset[i] = ({3'b0, rgather_vs1[i]}) + (i%1); // EEW8
            endcase
          end
        endcase
      end
      always_comb begin
        case (pmt_uop.vs2_eew)
          EEW32: rgather_overflow[i] = (|rgather_offset[i][`XLEN+2:`VL_WIDTH+2]) | (rgather_offset[i][`VL_WIDTH+1:0] >= ({2'h0, pmt_uop.vlmax} << 2));
          EEW16: rgather_overflow[i] = (|rgather_offset[i][`XLEN+2:`VL_WIDTH+1]) | (rgather_offset[i][`VL_WIDTH:0] >= ({1'b0, pmt_uop.vlmax} << 1));
          default: rgather_overflow[i] = (|rgather_offset[i][`XLEN+2:`VL_WIDTH]) | (rgather_offset[i][`VL_WIDTH-1:0] >= pmt_uop.vlmax);
        endcase
      end
      always_comb begin
        rgather_info_t0[i].zero_valid = rgather_overflow[i];
        rgather_info_t0[i].rs_valid = '0;
        rgather_info_t0[i].index = pmt_uop.vs2_index + rgather_offset[i][VLENB_WIDTH+:3];
        rgather_info_t0[i].offset = rgather_offset[i][0+:VLENB_WIDTH];
        rgather_info_t0[i].vs_valid = ~rgather_overflow[i];
      end
    end

    //gen_compress_info_t0
    assign compress_vs1 = pmt_uop.first_uop_valid&(compress_cnt_q=='0) ? pmt_uop.vs1_data : compress_vs1_q;
    assign compress_vmsof = compress_vs1 & ~(compress_vs1 - 'b1);
    always_comb begin
      compress_vfirst = `VLMAX_MAX;
      for (int j=0; j<`VLEN; j++)
        if (compress_vmsof[j]==1'b1) compress_vfirst = j[0+:`VL_WIDTH];
    end
    assign compress_overflow = compress_vfirst >= pmt_uop.vl;
    assign compress_vs1_d = compress_vs1 & ~compress_vmsof;
    edff #(.T(logic[`VLEN-1:0])) compress_vs1_reg (.q(compress_vs1_q), .d(compress_vs1_d), .e((pmt_uop.uop_funct6==VCOMPRESS_VTMVTV) & |(pmt_t0_valid&pmt_t0_ready)), .clk(clk), .rst_n(rst_n));
    always_comb begin
      if (compress_overflow)
        compress_cnt_d = '0;
      else
        case (pmt_uop.vs2_eew)
          EEW32: compress_cnt_d = compress_cnt_q + 'h4;
          EEW16: compress_cnt_d = compress_cnt_q + 'h2;
          default: compress_cnt_d = compress_cnt_q + 'b1; // EEW8
        endcase
    end
    assign compress_cnt_en = compress_overflow | 
                             ((pmt_uop.uop_funct6==VCOMPRESS_VTMVTV) & |(pmt_t0_valid&pmt_t0_ready));
    edff #(.T(logic[VLENB_WIDTH-1:0])) compress_cnt_reg (.q(compress_cnt_q), .d(compress_cnt_d), .e(compress_cnt_en), .clk(clk), .rst_n(rst_n));
    for (i=0; i<`VLENB; i++) begin : gen_compress_info_t0
      always_comb begin
        if (compress_overflow)
          compress_info_enable[i] = i>=compress_cnt_q;
        else begin
          case(pmt_uop.vs2_eew)
            EEW32: compress_info_enable[i] = i[VLENB_WIDTH-1:2]==compress_cnt_q[VLENB_WIDTH-1:2];
            EEW16: compress_info_enable[i] = i[VLENB_WIDTH-1:1]==compress_cnt_q[VLENB_WIDTH-1:1];
            default: compress_info_enable[i] = i[VLENB_WIDTH-1:0]==compress_cnt_q[VLENB_WIDTH-1:0]; //EEW8
          endcase
        end
      end
      always_comb begin
        case (pmt_uop.vs2_eew)
          EEW32: compress_offset[i] = (compress_vfirst[`VSTART_WIDTH-1:0] << 2) + i%4;
          EEW16: compress_offset[i] = (compress_vfirst[`VSTART_WIDTH-1:0] << 1) + i%2;
          default: compress_offset[i] = compress_vfirst[`VSTART_WIDTH-1:0] + i%1; //EEW8
        endcase
      end
      always_comb begin
        compress_info_t0[i].zero_valid = '0;
        compress_info_t0[i].rs_valid = '0;
        compress_info_t0[i].index = compress_overflow ? pmt_uop.dst_index : pmt_uop.vs2_index + compress_offset[i][VLENB_WIDTH+:3];
        compress_info_t0[i].offset = compress_overflow ? i[0+:VLENB_WIDTH] : compress_offset[i][0+:VLENB_WIDTH];
        compress_info_t0[i].vs_valid = (pmt_uop.uop_funct6 == VCOMPRESS_VTMVTV);
      end
    end

    assign pmt_info_ready = (&(data_write_enable|data_valid))&(~(&data_valid));
    for (i=0; i<`VLENB; i++) begin : gen_pmt_info
      always_comb begin
        case (pmt_uop.uop_funct6)
          //VSLIDE1UP == VSLIDEUP_RGATHEREI16
          VSLIDEUP_RGATHEREI16: pmt_info_t0[i] = pmt_uop.uop_funct3 == OPIVV ? rgather_info_t0[i] : slideup_info_t0[i];
          //VSLIDE1DOWN == VSLIDEDOWN
          VSLIDEDOWN: pmt_info_t0[i] = slidedown_info_t0[i];
          VRGATHER: pmt_info_t0[i] = rgather_info_t0[i];
          default: pmt_info_t0[i] = compress_info_t0[i]; // VCOMPRESS
        endcase
      end
      always_comb begin
        case (pmt_uop.uop_funct6)
          VCOMPRESS_VTMVTV: pmt_info_valid[i] =  compress_info_enable[i] & pmt_go;
          //VSLIDE1UP, 
          //VSLIDE1DOWN,
          //VSLIDEDOWN,
          //VSLIDEUP_RGATHEREI16,
          //VRGATHER,
          default: pmt_info_valid[i] = pmt_go;
        endcase
      end
      assign pmt_t0_valid[i] = pmt_uop_valid & pmt_info_valid[i];

      handshake_ff #(.T(PMT_INFO_t)) pmt_info_reg (.outdata(pmt_info_t1[i]), .outvalid(pmt_t1_valid[i]), .outready(pmt_info_ready), 
                                                   .indata(pmt_info_t0[i]),  .invalid(pmt_t0_valid[i]),  .inready(pmt_t0_ready[i]),
                                                   .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));
    end
  endgenerate

  // pmt_ctrl
`ifdef TB_SUPPORT
  assign pmt_ctrl_t0.uop_pc = pmt_uop.uop_pc;
`endif
  assign pmt_ctrl_t0.rob_entry = pmt_uop.rob_entry;
  assign pmt_ctrl_t0.rs1_data = pmt_uop.rs1_data;
  assign pmt_ctrl_t0.vs2_eew = pmt_uop.vs2_eew;
  edff #(.T(PMT_CTRL_t)) pmt_ctrl_t0_reg (.q(pmt_ctrl_t1), .d(pmt_ctrl_t0), .e(pmt_t0_valid[0]&pmt_t0_ready[0]), .clk(clk), .rst_n(rst_n));

  // vrd read
  generate
    for (i=0; i<`VLENB; i++) assign data_valid[i] = pmt_data_t2[i].valid;
  endgenerate
  assign data_valid_zsof = ~data_valid & ~(~data_valid - 'b1);
  always_comb begin
    data_valid_zfirst = '0;
    for (int j=0; j<`VLENB; j++)
      if (data_valid_zsof[j]==1'b1) data_valid_zfirst = j;
  end
  assign rd_index_pmt2vrf = pmt_info_t1[data_valid_zfirst].index;

  generate
    for (i=0; i<`VLENB; i++) assign data_write_enable[i] = ~pmt_data_t2[i].valid & 
                                                           (pmt_info_t1[i].zero_valid | pmt_info_t1[i].rs_valid | (pmt_info_t1[i].vs_valid & (pmt_info_t1[i].index == rd_index_pmt2vrf)));
  endgenerate

  assign data_clear = pmt_res_valid & pmt_res_ready; 
  generate
    for (i=0; i<`VLENB; i++) begin : gen_pmt_data
      always_comb begin
        if (pmt_info_t1[i].rs_valid)
          case (pmt_ctrl_t1.vs2_eew)
            EEW32: pmt_data_t1[i].data = pmt_ctrl_t1.rs1_data[(i%4)*8+:8];
            EEW16: pmt_data_t1[i].data = pmt_ctrl_t1.rs1_data[(i%2)*8+:8];
            default: pmt_data_t1[i].data = pmt_ctrl_t1.rs1_data[(i%1)*8+:8]; // EEW8
          endcase
        else if (pmt_info_t1[i].vs_valid)
          pmt_data_t1[i].data = rd_data_vrf2pmt[pmt_info_t1[i].offset];
        else
          pmt_data_t1[i].data = '0;
        
        if (data_clear) pmt_data_t1[i].valid = 1'b0;
        else pmt_data_t1[i].valid = pmt_info_t1[i].rs_valid | pmt_info_t1[i].vs_valid | pmt_info_t1[i].zero_valid;
      end

      handshake_ff #(.T(logic[`BYTE_WIDTH-1:0])) pmt_data_value_reg (.outdata(pmt_data_t2[i].data), .outvalid(pmt_t2_valid[i]),                      .outready(pmt_t2_ready[i]), 
                                                                    .indata(pmt_data_t1[i].data),   .invalid(pmt_t1_valid[i]&data_write_enable[i]),  .inready(pmt_t1_ready[i]),
                                                                    .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));
      edff #(.T(logic)) pmt_data_valid_reg (.q(pmt_data_t2[i].valid), .d(pmt_data_t1[i].valid), .e(data_clear|(pmt_t1_valid[i]&data_write_enable[i]&pmt_t1_ready[i])), .clk(clk), .rst_n(rst_n));
      assign pmt_t2_ready[i] = pmt_res_ready; 
    end
  endgenerate

  edff #(.T(PMT_CTRL_t)) pmt_ctrl_t1_reg (.q(pmt_ctrl_t2), .d(pmt_ctrl_t1), .e(pmt_t1_valid[0]&pmt_t1_ready[0]), .clk(clk), .rst_n(rst_n));

// pmt_uop_ready
  assign pmt_go = ((rob_rptr==pmt_uop.rob_entry) | ~pmt_uop.first_uop_valid);
  assign pmt_uop_ready = pmt_uop.uop_funct6 == VCOMPRESS_VTMVTV ? (compress_cnt_d == '0) & pmt_t0_ready[`VLENB-1] & pmt_go
                                                                : (&pmt_t0_ready) & pmt_go;

// pmt_res
  always_comb begin
  `ifdef TB_SUPPORT
    pmt_res.uop_pc = pmt_ctrl_t2.uop_pc;
  `endif
    pmt_res.rob_entry = pmt_ctrl_t2.rob_entry;
    for (int j=0; j<`VLENB; j++) pmt_res.w_data[j*8+:8] = pmt_data_t2[j].data; 
    pmt_res.w_valid = &data_valid;
    pmt_res.vsaturate = '0;
  `ifdef ZVE32F_ON
    pmt_res.fpexp = '0;
  `endif
  end

// pmt_res_valid
  assign pmt_res_valid = &pmt_t2_valid;

// ---function--------------------------------------------------------

endmodule
