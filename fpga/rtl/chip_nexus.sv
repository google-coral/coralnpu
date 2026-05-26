// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

module chip_nexus
    #(parameter MemInitFile = "",
      parameter int ClockFrequencyMhz = 50,
      parameter int IspClockFrequencyMhz = 10,
      parameter int SpimClockFrequencyMhz = 100,
      parameter int BootAddr = 0,
      parameter int EnableAutoboot = 0,
      parameter int ItcmSizeKBytes = 8,
      parameter int DtcmSizeKBytes = 32
) (
     input clk_p_i,
     input clk_n_i,
     input rst_ni,
     input spi_clk_i,
     input spi_csb_i,
     input spi_mosi_i,
     output logic spi_miso_o,
     output logic spim_sclk_o,
     output logic spim_csb_o,
     output logic spim_mosi_o,
     input spim_miso_i,
     output logic spim_flash_sclk_o,
     output logic spim_flash_csb_o,
     output logic spim_flash_mosi_o,
     input spim_flash_miso_i,
     output logic spim_flash_rst_no,
     inout wire [3:0] gpio,
     output [1 : 0] uart_tx_o,
     input [1 : 0] uart_rx_i,
     inout wire i2c_scl,
     inout wire i2c_sda,
     output logic io_halted,
     output logic io_fault,
     output logic io_ddr_mem_axi_aw_ready,
     output logic io_ddr_mem_axi_ar_ready,
     input ISP_DVP_D0,
     input ISP_DVP_D1,
     input ISP_DVP_D2,
     input ISP_DVP_D3,
     input ISP_DVP_D4,
     input ISP_DVP_D5,
     input ISP_DVP_D6,
     input ISP_DVP_D7,
     input ISP_DVP_PCLK,
     input ISP_DVP_HSYNC,
     input ISP_DVP_VSYNC,
     input CAM_INT,           // Unused
     output logic CAM_TRIG,   // Tied low, route to GPIO or logic to use as alternative to I2C trigger
     output logic c0_ddr4_act_n,
     output logic [16:0] c0_ddr4_adr,
     output logic [1:0] c0_ddr4_ba,
     output logic [1:0] c0_ddr4_bg,
     output logic [1:0] c0_ddr4_cke,
     output logic [1:0] c0_ddr4_odt,
     output logic [1:0] c0_ddr4_cs_n,
     output logic [0:0] c0_ddr4_ck_t,
     output logic [0:0] c0_ddr4_ck_c,
     output logic c0_ddr4_reset_n,
     output logic c0_ddr4_parity,
     inout wire [71:0] c0_ddr4_dq,
     inout wire [17:0] c0_ddr4_dqs_c,
     inout wire [17:0] c0_ddr4_dqs_t,
     input logic c0_sys_clk_p,
     input logic c0_sys_clk_n,
     output logic ddr_cal_complete_o,
     output ddr_ui_clk,
     output ddr_ui_clk_sync_rst,
     input tck_i,
     input tms_i,
     input trst_ni,
     input td_i,
     output td_o
    );

  logic clk;
  logic rst_n;
  logic clk_isp;
  logic clk_spim;
  logic locked;
  logic eos;
  logic mig_sys_rst;
  logic c0_init_calib_complete;
  logic c0_ddr4_ui_clk;
  logic c0_ddr4_ui_clk_sync_rst;

  assign ddr_ui_clk = c0_ddr4_ui_clk;
  assign ddr_ui_clk_sync_rst = c0_ddr4_ui_clk_sync_rst;

  //================================================================
  //== STARTUPE3 Primitive for reliable FPGA startup
  //================================================================
  STARTUPE3 i_startupe3 (
      .EOS(eos),
      // --- Unused ports, connect to dummy wires or tie off ---
      .CFGCLK(),
      .CFGMCLK(),
      .PREQ(),
      // --- Tie off unused inputs ---
      .GSR(1'b0),
      .GTS(1'b0),
      .KEYCLEARB(1'b0),
      .PACK(1'b0),
      .USRCCLKO(1'b0),
      .USRCCLKTS(1'b0),
      .USRDONEO(1'b0),
      .USRDONETS(1'b0)
  );

  //================================================================
  //== Combined Reset Logic for DDR4 MIG
  //================================================================
  assign mig_sys_rst = (~locked) | (~eos) | (~rst_ni);

  top_pkg::uart_sideband_i_t[1 : 0] uart_sideband_i;
  top_pkg::uart_sideband_o_t[1 : 0] uart_sideband_o;

  assign uart_sideband_i[0].cio_rx = uart_rx_i[0];
  assign uart_sideband_i[1].cio_rx = uart_rx_i[1];
  assign uart_tx_o[0] = uart_sideband_o[0].cio_tx;
  assign uart_tx_o[1] = uart_sideband_o[1].cio_tx;

  wire [7:0] gpio_out;
  wire [7:0] gpio_en;
  wire [7:0] gpio_in;

  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : gen_gpio_iobuf
      IOBUF i_iobuf (
        .O(gpio_in[i]),
        .IO(gpio[i]),
        .I(gpio_out[i]),
        .T(~gpio_en[i]) // T is active low enable (Tristate)
      );
    end
  endgenerate
  assign gpio_in[7:4] = 4'b0;

  logic scl_in, scl_out, scl_en;
  logic sda_in, sda_out, sda_en;

  IOBUF i_scl_iobuf (.O(scl_in), .IO(i2c_scl), .I(scl_out), .T(~scl_en));
  IOBUF i_sda_iobuf (.O(sda_in), .IO(i2c_sda), .I(sda_out), .T(~sda_en));

  assign ddr_cal_complete_o = c0_init_calib_complete;
  logic dbg_clk;
  logic [63:0] dbg_rd_data_cmp;
  logic [63:0] dbg_expected_data;
  logic [2:0] dbg_cal_seq;
  logic [31:0] dbg_cal_seq_cnt;
  logic [7:0] dbg_cal_seq_rd_cnt;
  logic dbg_rd_valid;
  logic [5:0] dbg_cmp_byte;
  logic [63:0] dbg_rd_data;
  logic [15:0] dbg_cplx_config;
  logic [1:0] dbg_cplx_status;
  logic [27:0] dbg_io_address;
  logic dbg_pllGate;
  logic [19:0] dbg_phy2clb_fixdly_rdy_low;
  logic [19:0] dbg_phy2clb_fixdly_rdy_upp;
  logic [19:0] dbg_phy2clb_phy_rdy_low;
  logic [19:0] dbg_phy2clb_phy_rdy_upp;
  logic [127:0] cal_r0_status;
  logic [8:0] cal_post_status;
  logic c0_ddr4_s_axi_ctrl_awvalid;
  logic c0_ddr4_s_axi_ctrl_awready;
  logic [31:0] c0_ddr4_s_axi_ctrl_awaddr;
  logic c0_ddr4_s_axi_ctrl_wvalid;
  logic c0_ddr4_s_axi_ctrl_wready;
  logic [31:0] c0_ddr4_s_axi_ctrl_wdata;
  logic c0_ddr4_s_axi_ctrl_bvalid;
  logic c0_ddr4_s_axi_ctrl_bready;
  logic [1:0] c0_ddr4_s_axi_ctrl_bresp;
  logic c0_ddr4_s_axi_ctrl_arvalid;
  logic c0_ddr4_s_axi_ctrl_arready;
  logic [31:0] c0_ddr4_s_axi_ctrl_araddr;
  logic c0_ddr4_s_axi_ctrl_rvalid;
  logic c0_ddr4_s_axi_ctrl_rready;
  logic [31:0] c0_ddr4_s_axi_ctrl_rdata;
  logic [1:0] c0_ddr4_s_axi_ctrl_rresp;
  logic c0_ddr4_interrupt;
  logic c0_ddr4_aresetn;
  logic [0:0] c0_ddr4_s_axi_awid;
  logic [33:0] c0_ddr4_s_axi_awaddr;
  logic [7:0] c0_ddr4_s_axi_awlen;
  logic [2:0] c0_ddr4_s_axi_awsize;
  logic [1:0] c0_ddr4_s_axi_awburst;
  logic [0:0] c0_ddr4_s_axi_awlock;
  logic [3:0] c0_ddr4_s_axi_awcache;
  logic [2:0] c0_ddr4_s_axi_awprot;
  logic [3:0] c0_ddr4_s_axi_awqos;
  logic c0_ddr4_s_axi_awvalid;
  logic c0_ddr4_s_axi_awready;
  logic [255:0] c0_ddr4_s_axi_wdata;
  logic [31:0] c0_ddr4_s_axi_wstrb;
  logic c0_ddr4_s_axi_wlast;
  logic c0_ddr4_s_axi_wvalid;
  logic c0_ddr4_s_axi_wready;
  logic c0_ddr4_s_axi_bready;
  logic [0:0] c0_ddr4_s_axi_bid;
  logic [1:0] c0_ddr4_s_axi_bresp;
  logic c0_ddr4_s_axi_bvalid;
  logic [0:0] c0_ddr4_s_axi_arid;
  logic [33:0] c0_ddr4_s_axi_araddr;
  logic [7:0] c0_ddr4_s_axi_arlen;
  logic [2:0] c0_ddr4_s_axi_arsize;
  logic [1:0] c0_ddr4_s_axi_arburst;
  logic [0:0] c0_ddr4_s_axi_arlock;
  logic [3:0] c0_ddr4_s_axi_arcache;
  logic [2:0] c0_ddr4_s_axi_arprot;
  logic [3:0] c0_ddr4_s_axi_arqos;
  logic c0_ddr4_s_axi_arvalid;
  logic c0_ddr4_s_axi_arready;
  logic c0_ddr4_s_axi_rready;
  logic [0:0] c0_ddr4_s_axi_rid;
  logic [255:0] c0_ddr4_s_axi_rdata;
  logic [1:0] c0_ddr4_s_axi_rresp;
  logic c0_ddr4_s_axi_rlast;
  logic c0_ddr4_s_axi_rvalid;
  logic [511:0] dbg_bus;
  assign io_ddr_mem_axi_aw_ready = c0_ddr4_s_axi_awready;
  assign io_ddr_mem_axi_ar_ready = c0_ddr4_s_axi_arready;
  assign c0_ddr4_aresetn = ~c0_ddr4_ui_clk_sync_rst;

  ddr_system_bd_ddr4_0_0 i_ddr4(
    .sys_rst(mig_sys_rst),
    .c0_sys_clk_p(c0_sys_clk_p),
    .c0_sys_clk_n(c0_sys_clk_n),
    .c0_ddr4_act_n(c0_ddr4_act_n),
    .c0_ddr4_adr(c0_ddr4_adr),
    .c0_ddr4_ba(c0_ddr4_ba),
    .c0_ddr4_bg(c0_ddr4_bg),
    .c0_ddr4_cke(c0_ddr4_cke),
    .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_cs_n(c0_ddr4_cs_n),
    .c0_ddr4_ck_t(c0_ddr4_ck_t),
    .c0_ddr4_ck_c(c0_ddr4_ck_c),
    .c0_ddr4_reset_n(c0_ddr4_reset_n),
    .c0_ddr4_parity(c0_ddr4_parity),
    .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
    .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
    .c0_init_calib_complete(c0_init_calib_complete),
    .c0_ddr4_ui_clk(c0_ddr4_ui_clk),
    .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),
    .dbg_clk(dbg_clk),
    .dbg_rd_data_cmp(dbg_rd_data_cmp),
    .dbg_expected_data(dbg_expected_data),
    .dbg_cal_seq(dbg_cal_seq),
    .dbg_cal_seq_cnt(dbg_cal_seq_cnt),
    .dbg_cal_seq_rd_cnt(dbg_cal_seq_rd_cnt),
    .dbg_rd_valid(dbg_rd_valid),
    .dbg_cmp_byte(dbg_cmp_byte),
    .dbg_rd_data(dbg_rd_data),
    .dbg_cplx_config(dbg_cplx_config),
    .dbg_cplx_status(dbg_cplx_status),
    .dbg_io_address(dbg_io_address),
    .dbg_pllGate(dbg_pllGate),
    .dbg_phy2clb_fixdly_rdy_low(dbg_phy2clb_fixdly_rdy_low),
    .dbg_phy2clb_fixdly_rdy_upp(dbg_phy2clb_fixdly_rdy_upp),
    .dbg_phy2clb_phy_rdy_low(dbg_phy2clb_phy_rdy_low),
    .dbg_phy2clb_phy_rdy_upp(dbg_phy2clb_phy_rdy_upp),
    .cal_r0_status(cal_r0_status),
    .cal_post_status(cal_post_status),
    .c0_ddr4_s_axi_ctrl_awvalid(c0_ddr4_s_axi_ctrl_awvalid),
    .c0_ddr4_s_axi_ctrl_awready(c0_ddr4_s_axi_ctrl_awready),
    .c0_ddr4_s_axi_ctrl_awaddr(c0_ddr4_s_axi_ctrl_awaddr),
    .c0_ddr4_s_axi_ctrl_wvalid(c0_ddr4_s_axi_ctrl_wvalid),
    .c0_ddr4_s_axi_ctrl_wready(c0_ddr4_s_axi_ctrl_wready),
    .c0_ddr4_s_axi_ctrl_wdata(c0_ddr4_s_axi_ctrl_wdata),
    .c0_ddr4_s_axi_ctrl_bvalid(c0_ddr4_s_axi_ctrl_bvalid),
    .c0_ddr4_s_axi_ctrl_bready(c0_ddr4_s_axi_ctrl_bready),
    .c0_ddr4_s_axi_ctrl_bresp(c0_ddr4_s_axi_ctrl_bresp),
    .c0_ddr4_s_axi_ctrl_arvalid(c0_ddr4_s_axi_ctrl_arvalid),
    .c0_ddr4_s_axi_ctrl_arready(c0_ddr4_s_axi_ctrl_arready),
    .c0_ddr4_s_axi_ctrl_araddr(c0_ddr4_s_axi_ctrl_araddr),
    .c0_ddr4_s_axi_ctrl_rvalid(c0_ddr4_s_axi_ctrl_rvalid),
    .c0_ddr4_s_axi_ctrl_rready(c0_ddr4_s_axi_ctrl_rready),
    .c0_ddr4_s_axi_ctrl_rdata(c0_ddr4_s_axi_ctrl_rdata),
    .c0_ddr4_s_axi_ctrl_rresp(c0_ddr4_s_axi_ctrl_rresp),
    .c0_ddr4_interrupt(c0_ddr4_interrupt),
    .c0_ddr4_aresetn(c0_ddr4_aresetn),
    .c0_ddr4_s_axi_awid(c0_ddr4_s_axi_awid),
    .c0_ddr4_s_axi_awaddr(c0_ddr4_s_axi_awaddr),
    .c0_ddr4_s_axi_awlen(c0_ddr4_s_axi_awlen),
    .c0_ddr4_s_axi_awsize(c0_ddr4_s_axi_awsize),
    .c0_ddr4_s_axi_awburst(c0_ddr4_s_axi_awburst),
    .c0_ddr4_s_axi_awlock(c0_ddr4_s_axi_awlock),
    .c0_ddr4_s_axi_awcache(c0_ddr4_s_axi_awcache),
    .c0_ddr4_s_axi_awprot(c0_ddr4_s_axi_awprot),
    .c0_ddr4_s_axi_awqos(c0_ddr4_s_axi_awqos),
    .c0_ddr4_s_axi_awvalid(c0_ddr4_s_axi_awvalid),
    .c0_ddr4_s_axi_awready(c0_ddr4_s_axi_awready),
    .c0_ddr4_s_axi_wdata(c0_ddr4_s_axi_wdata),
    .c0_ddr4_s_axi_wstrb(c0_ddr4_s_axi_wstrb),
    .c0_ddr4_s_axi_wlast(c0_ddr4_s_axi_wlast),
    .c0_ddr4_s_axi_wvalid(c0_ddr4_s_axi_wvalid),
    .c0_ddr4_s_axi_wready(c0_ddr4_s_axi_wready),
    .c0_ddr4_s_axi_bready(c0_ddr4_s_axi_bready),
    .c0_ddr4_s_axi_bid(c0_ddr4_s_axi_bid),
    .c0_ddr4_s_axi_bresp(c0_ddr4_s_axi_bresp),
    .c0_ddr4_s_axi_bvalid(c0_ddr4_s_axi_bvalid),
    .c0_ddr4_s_axi_arid(c0_ddr4_s_axi_arid),
    .c0_ddr4_s_axi_araddr(c0_ddr4_s_axi_araddr),
    .c0_ddr4_s_axi_arlen(c0_ddr4_s_axi_arlen),
    .c0_ddr4_s_axi_arsize(c0_ddr4_s_axi_arsize),
    .c0_ddr4_s_axi_arburst(c0_ddr4_s_axi_arburst),
    .c0_ddr4_s_axi_arlock(c0_ddr4_s_axi_arlock),
    .c0_ddr4_s_axi_arcache(c0_ddr4_s_axi_arcache),
    .c0_ddr4_s_axi_arprot(c0_ddr4_s_axi_arprot),
    .c0_ddr4_s_axi_arqos(c0_ddr4_s_axi_arqos),
    .c0_ddr4_s_axi_arvalid(c0_ddr4_s_axi_arvalid),
    .c0_ddr4_s_axi_arready(c0_ddr4_s_axi_arready),
    .c0_ddr4_s_axi_rready(c0_ddr4_s_axi_rready),
    .c0_ddr4_s_axi_rid(c0_ddr4_s_axi_rid),
    .c0_ddr4_s_axi_rdata(c0_ddr4_s_axi_rdata),
    .c0_ddr4_s_axi_rresp(c0_ddr4_s_axi_rresp),
    .c0_ddr4_s_axi_rlast(c0_ddr4_s_axi_rlast),
    .c0_ddr4_s_axi_rvalid(c0_ddr4_s_axi_rvalid),
    .dbg_bus(dbg_bus)
  );

  clkgen_wrapper #(.ClockFrequencyMhz(ClockFrequencyMhz))
      i_clkgen(.clk_p_i(clk_p_i),
               .clk_n_i(clk_n_i),
               .rst_ni(rst_ni),
               .srst_ni(rst_ni),
               .clk_main_o(clk),
               .clk_isp_o(clk_isp),
               .clk_spim_o(clk_spim),
               .rst_no(rst_n),
               .locked_o(locked));

  logic dm_req_valid, dm_req_ready;
  dm::dmi_req_t dm_req;
  logic dm_rsp_valid, dm_rsp_ready;
  dm::dmi_resp_t dm_rsp;
  logic dmi_rst_n;

  dmi_jtag #(.IdcodeValue(32'h04f5484d)) i_jtag (
    .clk_i(clk),
    .rst_ni(rst_n),
    .testmode_i(1'b0),
    .test_rst_ni(1'b1),
    .dmi_rst_no(dmi_rst_n),
    .dmi_req_o(dm_req),
    .dmi_req_valid_o(dm_req_valid),
    .dmi_req_ready_i(dm_req_ready),
    .dmi_resp_i(dm_rsp),
    .dmi_resp_ready_o(dm_rsp_ready),
    .dmi_resp_valid_i(dm_rsp_valid),
    .tck_i(tck_i),
    .tms_i(tms_i),
    .trst_ni(trst_ni),
    .td_i(td_i),
    .td_o(td_o),
    .tdo_oe_o(/*tdo_oe_o*/)
  );

  coralnpu_soc #(.MemInitFile(MemInitFile),
                 .ClockFrequencyMhz(ClockFrequencyMhz),
                 .IspClockFrequencyMhz(IspClockFrequencyMhz),
                 .SpimClockFrequencyMhz(SpimClockFrequencyMhz),
                 .EnableAutoboot(EnableAutoboot),
                 .ItcmSizeKBytes(ItcmSizeKBytes),
                 .DtcmSizeKBytes(DtcmSizeKBytes))
  i_coralnpu_soc(
    .clk_i(clk),
    .clk_isp_i(clk_isp),
    .rst_ni(rst_n),
    .spi_clk_i(spi_clk_i),
    .spi_csb_i(spi_csb_i),
    .spi_mosi_i(spi_mosi_i),
    .spi_miso_o(spi_miso_o),
    .spim_sclk_o(spim_sclk_o),
    .spim_csb_o(spim_csb_o),
    .spim_mosi_o(spim_mosi_o),
    .spim_miso_i(spim_miso_i),
    .spim_clk_i(clk_spim),
    .boot_addr_i(BootAddr),
    .spim_flash_sclk_o(spim_flash_sclk_o),
    .spim_flash_csb_o(spim_flash_csb_o),
    .spim_flash_mosi_o(spim_flash_mosi_o),
    .spim_flash_miso_i(spim_flash_miso_i),
    .spim_flash_clk_i(clk_spim),
    .spim_flash_rst_no(spim_flash_rst_no),
    .gpio_o(gpio_out),
    .gpio_en_o(gpio_en),
    .gpio_i(gpio_in),
    .ISP_DVP_D0(ISP_DVP_D0),
    .ISP_DVP_D1(ISP_DVP_D1),
    .ISP_DVP_D2(ISP_DVP_D2),
    .ISP_DVP_D3(ISP_DVP_D3),
    .ISP_DVP_D4(ISP_DVP_D4),
    .ISP_DVP_D5(ISP_DVP_D5),
    .ISP_DVP_D6(ISP_DVP_D6),
    .ISP_DVP_D7(ISP_DVP_D7),
    .ISP_DVP_PCLK(ISP_DVP_PCLK),
    .ISP_DVP_HSYNC(ISP_DVP_HSYNC),
    .ISP_DVP_VSYNC(ISP_DVP_VSYNC),
    .CAM_INT(CAM_INT),
    .CAM_TRIG(CAM_TRIG),
    .scanmode_i('0),
    .uart_sideband_i(uart_sideband_i),
    .uart_sideband_o(uart_sideband_o),
    .scl_i(scl_in),
    .scl_o(scl_out),
    .scl_en_o(scl_en),
    .sda_i(sda_in),
    .sda_o(sda_out),
    .sda_en_o(sda_en),
    .io_halted(io_halted),
    .io_fault(io_fault),
    .ddr_clk_i(c0_ddr4_ui_clk),
    .ddr_rst(c0_ddr4_ui_clk_sync_rst),
    .io_ddr_ctrl_axi_aw_valid(c0_ddr4_s_axi_ctrl_awvalid),
    .io_ddr_ctrl_axi_aw_ready(c0_ddr4_s_axi_ctrl_awready),
    .io_ddr_ctrl_axi_aw_bits_addr(c0_ddr4_s_axi_ctrl_awaddr),
    .io_ddr_ctrl_axi_w_valid(c0_ddr4_s_axi_ctrl_wvalid),
    .io_ddr_ctrl_axi_w_ready(c0_ddr4_s_axi_ctrl_wready),
    .io_ddr_ctrl_axi_w_bits_data(c0_ddr4_s_axi_ctrl_wdata),
    .io_ddr_ctrl_axi_b_valid(c0_ddr4_s_axi_ctrl_bvalid),
    .io_ddr_ctrl_axi_b_ready(c0_ddr4_s_axi_ctrl_bready),
    .io_ddr_ctrl_axi_b_bits_resp(c0_ddr4_s_axi_ctrl_bresp),
    .io_ddr_ctrl_axi_ar_valid(c0_ddr4_s_axi_ctrl_arvalid),
    .io_ddr_ctrl_axi_ar_ready(c0_ddr4_s_axi_ctrl_arready),
    .io_ddr_ctrl_axi_ar_bits_addr(c0_ddr4_s_axi_ctrl_araddr),
    .io_ddr_ctrl_axi_r_valid(c0_ddr4_s_axi_ctrl_rvalid),
    .io_ddr_ctrl_axi_r_ready(c0_ddr4_s_axi_ctrl_rready),
    .io_ddr_ctrl_axi_r_bits_data(c0_ddr4_s_axi_ctrl_rdata),
    .io_ddr_ctrl_axi_r_bits_resp(c0_ddr4_s_axi_ctrl_rresp),
    .io_ddr_mem_axi_aw_valid(c0_ddr4_s_axi_awvalid),
    .io_ddr_mem_axi_aw_ready(c0_ddr4_s_axi_awready),
    .io_ddr_mem_axi_aw_bits_addr(c0_ddr4_s_axi_awaddr[31:0]),
    .io_ddr_mem_axi_aw_bits_prot(c0_ddr4_s_axi_awprot),
    .io_ddr_mem_axi_aw_bits_id(c0_ddr4_s_axi_awid),
    .io_ddr_mem_axi_aw_bits_len(c0_ddr4_s_axi_awlen),
    .io_ddr_mem_axi_aw_bits_size(c0_ddr4_s_axi_awsize),
    .io_ddr_mem_axi_aw_bits_burst(c0_ddr4_s_axi_awburst),
    .io_ddr_mem_axi_aw_bits_lock(c0_ddr4_s_axi_awlock),
    .io_ddr_mem_axi_aw_bits_cache(c0_ddr4_s_axi_awcache),
    .io_ddr_mem_axi_aw_bits_qos(c0_ddr4_s_axi_awqos),
    .io_ddr_mem_axi_w_valid(c0_ddr4_s_axi_wvalid),
    .io_ddr_mem_axi_w_ready(c0_ddr4_s_axi_wready),
    .io_ddr_mem_axi_w_bits_data(c0_ddr4_s_axi_wdata),
    .io_ddr_mem_axi_w_bits_last(c0_ddr4_s_axi_wlast),
    .io_ddr_mem_axi_w_bits_strb(c0_ddr4_s_axi_wstrb),
    .io_ddr_mem_axi_b_valid(c0_ddr4_s_axi_bvalid),
    .io_ddr_mem_axi_b_ready(c0_ddr4_s_axi_bready),
    .io_ddr_mem_axi_b_bits_id(c0_ddr4_s_axi_bid),
    .io_ddr_mem_axi_b_bits_resp(c0_ddr4_s_axi_bresp),
    .io_ddr_mem_axi_ar_valid(c0_ddr4_s_axi_arvalid),
    .io_ddr_mem_axi_ar_ready(c0_ddr4_s_axi_arready),
    .io_ddr_mem_axi_ar_bits_addr(c0_ddr4_s_axi_araddr[31:0]),
    .io_ddr_mem_axi_ar_bits_prot(c0_ddr4_s_axi_arprot),
    .io_ddr_mem_axi_ar_bits_id(c0_ddr4_s_axi_arid),
    .io_ddr_mem_axi_ar_bits_len(c0_ddr4_s_axi_arlen),
    .io_ddr_mem_axi_ar_bits_size(c0_ddr4_s_axi_arsize),
    .io_ddr_mem_axi_ar_bits_burst(c0_ddr4_s_axi_arburst),
    .io_ddr_mem_axi_ar_bits_lock(c0_ddr4_s_axi_arlock),
    .io_ddr_mem_axi_ar_bits_cache(c0_ddr4_s_axi_arcache),
    .io_ddr_mem_axi_ar_bits_qos(c0_ddr4_s_axi_arqos),
    .io_ddr_mem_axi_r_valid(c0_ddr4_s_axi_rvalid),
    .io_ddr_mem_axi_r_ready(c0_ddr4_s_axi_rready),
    .io_ddr_mem_axi_r_bits_data(c0_ddr4_s_axi_rdata),
    .io_ddr_mem_axi_r_bits_id(c0_ddr4_s_axi_rid),
    .io_ddr_mem_axi_r_bits_resp(c0_ddr4_s_axi_rresp),
    .io_ddr_mem_axi_r_bits_last(c0_ddr4_s_axi_rlast),
    .io_dm_req_valid(dm_req_valid),
    .io_dm_req_ready(dm_req_ready),
    .io_dm_req_bits_address(dm_req.addr),
    .io_dm_req_bits_data(dm_req.data),
    .io_dm_req_bits_op(dm_req.op),
    .io_dm_rsp_ready(dm_rsp_ready),
    .io_dm_rsp_valid(dm_rsp_valid),
    .io_dm_rsp_bits_data(dm_rsp.data),
    .io_dm_rsp_bits_op(dm_rsp.resp)
  );

endmodule
