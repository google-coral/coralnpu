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

module coralnpu_soc
    #(parameter MemInitFile = "",
      parameter int ClockFrequencyMhz = 50,
      parameter int IspClockFrequencyMhz = 10,
      parameter int SpimClockFrequencyMhz = 100,
      parameter int EnableAutoboot = 0,
      parameter int ItcmSizeKBytes = 8,
      parameter int DtcmSizeKBytes = 32
      ) (

input clk_i,
     input clk_isp_i,
     input rst_ni,
     input spi_clk_i,
     input spi_csb_i,
     input spi_mosi_i,
     output logic spi_miso_o,
     output logic spim_sclk_o,
     output logic spim_csb_o,
     output logic spim_mosi_o,
     input spim_miso_i,
     input spim_clk_i,
     input [31:0] boot_addr_i,  // PC reset value (0x0 for ITCM, 0x10000000 for ROM)
     output logic spim_flash_sclk_o,
     output logic spim_flash_csb_o,
     output logic spim_flash_mosi_o,
     input spim_flash_miso_i,
     input spim_flash_clk_i,
     output logic spim_flash_rst_no,
     output [7:0] gpio_o,
     output [7:0] gpio_en_o,
     input [7:0] gpio_i,
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
     input prim_mubi_pkg::mubi4_t scanmode_i,
     input top_pkg::uart_sideband_i_t[1 : 0] uart_sideband_i,
     output top_pkg::uart_sideband_o_t[1 : 0] uart_sideband_o,
     input scl_i,
     output logic scl_o,
     output logic scl_en_o,
     input sda_i,
     output logic sda_o,
     output logic sda_en_o,
     output logic io_halted,
     output logic io_fault,
     input ddr_clk_i,
     input ddr_rst,
     output        io_ddr_ctrl_axi_aw_valid,
     input         io_ddr_ctrl_axi_aw_ready,
     output [31:0] io_ddr_ctrl_axi_aw_bits_addr,
     output [2:0]  io_ddr_ctrl_axi_aw_bits_prot,
     output [5:0]  io_ddr_ctrl_axi_aw_bits_id,
     output [7:0]  io_ddr_ctrl_axi_aw_bits_len,
     output [2:0]  io_ddr_ctrl_axi_aw_bits_size,
     output [1:0]  io_ddr_ctrl_axi_aw_bits_burst,
     output        io_ddr_ctrl_axi_aw_bits_lock,
     output [3:0]  io_ddr_ctrl_axi_aw_bits_cache,
                   io_ddr_ctrl_axi_aw_bits_qos,
                   io_ddr_ctrl_axi_aw_bits_region,
     output        io_ddr_ctrl_axi_w_valid,
     input         io_ddr_ctrl_axi_w_ready,
     output [31:0] io_ddr_ctrl_axi_w_bits_data,
     output        io_ddr_ctrl_axi_w_bits_last,
     output [3:0]  io_ddr_ctrl_axi_w_bits_strb,
     input         io_ddr_ctrl_axi_b_valid,
     output        io_ddr_ctrl_axi_b_ready,
     input  [5:0]  io_ddr_ctrl_axi_b_bits_id,
     input  [1:0]  io_ddr_ctrl_axi_b_bits_resp,
     output        io_ddr_ctrl_axi_ar_valid,
     input         io_ddr_ctrl_axi_ar_ready,
     output [31:0] io_ddr_ctrl_axi_ar_bits_addr,
     output [2:0]  io_ddr_ctrl_axi_ar_bits_prot,
     output [5:0]  io_ddr_ctrl_axi_ar_bits_id,
     output [7:0]  io_ddr_ctrl_axi_ar_bits_len,
     output [2:0]  io_ddr_ctrl_axi_ar_bits_size,
     output [1:0]  io_ddr_ctrl_axi_ar_bits_burst,
     output        io_ddr_ctrl_axi_ar_bits_lock,
     output [3:0]  io_ddr_ctrl_axi_ar_bits_cache,
                   io_ddr_ctrl_axi_ar_bits_qos,
                   io_ddr_ctrl_axi_ar_bits_region,
     input         io_ddr_ctrl_axi_r_valid,
     output        io_ddr_ctrl_axi_r_ready,
     input  [31:0] io_ddr_ctrl_axi_r_bits_data,
     input  [5:0]  io_ddr_ctrl_axi_r_bits_id,
     input  [1:0]  io_ddr_ctrl_axi_r_bits_resp,
     input         io_ddr_ctrl_axi_r_bits_last,
     output        io_ddr_mem_axi_aw_valid,
     input         io_ddr_mem_axi_aw_ready,
     output [31:0] io_ddr_mem_axi_aw_bits_addr,
     output [2:0]  io_ddr_mem_axi_aw_bits_prot,
     output [0:0]  io_ddr_mem_axi_aw_bits_id,
     output [7:0]  io_ddr_mem_axi_aw_bits_len,
     output [2:0]  io_ddr_mem_axi_aw_bits_size,
     output [1:0]  io_ddr_mem_axi_aw_bits_burst,
     output        io_ddr_mem_axi_aw_bits_lock,
     output [3:0]  io_ddr_mem_axi_aw_bits_cache,
                   io_ddr_mem_axi_aw_bits_qos,
                   io_ddr_mem_axi_aw_bits_region,
     output        io_ddr_mem_axi_w_valid,
     input         io_ddr_mem_axi_w_ready,
     output [255:0] io_ddr_mem_axi_w_bits_data,
     output        io_ddr_mem_axi_w_bits_last,
     output [31:0]  io_ddr_mem_axi_w_bits_strb,
     input         io_ddr_mem_axi_b_valid,
     output        io_ddr_mem_axi_b_ready,
     input  [0:0]  io_ddr_mem_axi_b_bits_id,
     input  [1:0]  io_ddr_mem_axi_b_bits_resp,
     output        io_ddr_mem_axi_ar_valid,
     input         io_ddr_mem_axi_ar_ready,
     output [31:0] io_ddr_mem_axi_ar_bits_addr,
     output [2:0]  io_ddr_mem_axi_ar_bits_prot,
     output [0:0]  io_ddr_mem_axi_ar_bits_id,
     output [7:0]  io_ddr_mem_axi_ar_bits_len,
     output [2:0]  io_ddr_mem_axi_ar_bits_size,
     output [1:0]  io_ddr_mem_axi_ar_bits_burst,
     output        io_ddr_mem_axi_ar_bits_lock,
     output [3:0]  io_ddr_mem_axi_ar_bits_cache,
                   io_ddr_mem_axi_ar_bits_qos,
                   io_ddr_mem_axi_ar_bits_region,
     input         io_ddr_mem_axi_r_valid,
     output        io_ddr_mem_axi_r_ready,
     input  [255:0] io_ddr_mem_axi_r_bits_data,
     input  [0:0]  io_ddr_mem_axi_r_bits_id,
     input  [1:0]  io_ddr_mem_axi_r_bits_resp,
     input         io_ddr_mem_axi_r_bits_last,
     // RV-DM request
     input io_dm_req_valid,
     input [31:0] io_dm_req_bits_address,
     input [31:0] io_dm_req_bits_data,
     input [1:0] io_dm_req_bits_op,
     output io_dm_req_ready,
     // RV-DM response
     input io_dm_rsp_ready,
     output io_dm_rsp_valid,
     output [31:0] io_dm_rsp_bits_data,
     output [1:0] io_dm_rsp_bits_op
     );

  assign spim_flash_rst_no = gpio_o[4];
  // Camera trigger tie off. Use as alternative to I2C trigger.
  assign CAM_TRIG = 1'b0;

  import tlul_pkg::*;
  import top_pkg::*;

  coralnpu_tlul_pkg_128::tl_h2d_t tl_coralnpu_core_i;
  coralnpu_tlul_pkg_128::tl_d2h_t tl_coralnpu_core_o;
  coralnpu_tlul_pkg_128::tl_h2d_t tl_coralnpu_device_o;
  coralnpu_tlul_pkg_128::tl_d2h_t tl_coralnpu_device_i;

  coralnpu_tlul_pkg_32::tl_h2d_t tl_rom_o_32;
  coralnpu_tlul_pkg_32::tl_d2h_t tl_rom_i_32;

  coralnpu_tlul_pkg_128::tl_h2d_t tl_sram_o;
  coralnpu_tlul_pkg_128::tl_d2h_t tl_sram_i;

  tl_h2d_t tl_uart0_o;
  tl_d2h_t tl_uart0_i;

  tl_h2d_t tl_uart1_o;
  tl_d2h_t tl_uart1_i;

  coralnpu_tlul_pkg_32::tl_h2d_t tl_i2c_h2d;
  coralnpu_tlul_pkg_32::tl_d2h_t tl_i2c_d2h;

  coralnpu_tlul_pkg_32::tl_h2d_t tl_clk_table_h2d;
  coralnpu_tlul_pkg_32::tl_d2h_t tl_clk_table_d2h;

  coralnpu_tlul_pkg_32::tl_h2d_t tl_autoboot_h2d;
  coralnpu_tlul_pkg_32::tl_d2h_t tl_autoboot_d2h;

  localparam logic [31:0] CsrBaseAddr = (ItcmSizeKBytes == 8 && DtcmSizeKBytes == 32) ? 32'h00030000 : 32'h00200000;

  if (EnableAutoboot) begin : gen_autoboot
    autoboot #(
      .CsrBaseAddr(CsrBaseAddr)
    ) i_autoboot (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .tl_o(tl_autoboot_h2d),
      .tl_i(tl_autoboot_d2h)
    );
  end else begin : gen_no_autoboot
    assign tl_autoboot_h2d = '0;
  end

  clk_table #(.MainFreqMhz(ClockFrequencyMhz),
              .IspFreqMhz(IspClockFrequencyMhz),
              .SpimFreqMhz(SpimClockFrequencyMhz))
  i_clk_table(
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .tl_i(tl_clk_table_h2d),
    .tl_o(tl_clk_table_d2h),
    .intg_error_o()
  );

  i2c_master_top i_i2c_master (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .tl_i(tl_i2c_h2d),
    .tl_o(tl_i2c_d2h),
    .scl_i(scl_i),
    .scl_o(scl_o),
    .scl_en_o(scl_en_o),
    .sda_i(sda_i),
    .sda_o(sda_o),
    .sda_en_o(sda_en_o)
  );

  uart i_uart0(.clk_i(clk_i),
               .rst_ni(rst_ni),
               .tl_i(tl_uart0_o),
               .tl_o(tl_uart0_i),
               .alert_rx_i(1'b0),
               .alert_tx_o(),
               .racl_policies_i(1'b0),
               .racl_error_o(),
               .cio_rx_i(uart_sideband_i[0].cio_rx),
               .cio_tx_o(uart_sideband_o[0].cio_tx),
               .cio_tx_en_o(uart_sideband_o[0].cio_tx_en),
               .intr_tx_watermark_o(uart_sideband_o[0].intr_tx_watermark),
               .intr_tx_empty_o(uart_sideband_o[0].intr_tx_empty),
               .intr_rx_watermark_o(uart_sideband_o[0].intr_rx_watermark),
               .intr_tx_done_o(uart_sideband_o[0].intr_tx_done),
               .intr_rx_overflow_o(uart_sideband_o[0].intr_rx_overflow),
               .intr_rx_frame_err_o(uart_sideband_o[0].intr_rx_frame_err),
               .intr_rx_break_err_o(uart_sideband_o[0].intr_rx_break_err),
               .intr_rx_timeout_o(uart_sideband_o[0].intr_rx_timeout),
               .intr_rx_parity_err_o(uart_sideband_o[0].intr_rx_parity_err),
               .lsio_trigger_o(uart_sideband_o[0].lsio_trigger));

  uart i_uart1(.clk_i(clk_i),
               .rst_ni(rst_ni),
               .tl_i(tl_uart1_o),
               .tl_o(tl_uart1_i),
               .alert_rx_i(1'b0),
               .alert_tx_o(),
               .racl_policies_i(1'b0),
               .racl_error_o(),
               .cio_rx_i(uart_sideband_i[1].cio_rx),
               .cio_tx_o(uart_sideband_o[1].cio_tx),
               .cio_tx_en_o(uart_sideband_o[1].cio_tx_en),
               .intr_tx_watermark_o(uart_sideband_o[1].intr_tx_watermark),
               .intr_tx_empty_o(uart_sideband_o[1].intr_tx_empty),
               .intr_rx_watermark_o(uart_sideband_o[1].intr_rx_watermark),
               .intr_tx_done_o(uart_sideband_o[1].intr_tx_done),
               .intr_rx_overflow_o(uart_sideband_o[1].intr_rx_overflow),
               .intr_rx_frame_err_o(uart_sideband_o[1].intr_rx_frame_err),
               .intr_rx_break_err_o(uart_sideband_o[1].intr_rx_break_err),
               .intr_rx_timeout_o(uart_sideband_o[1].intr_rx_timeout),
               .intr_rx_parity_err_o(uart_sideband_o[1].intr_rx_parity_err),
               .lsio_trigger_o(uart_sideband_o[1].lsio_trigger));

  logic rom_req;
  logic [12 : 0] rom_addr;
  logic [31 : 0] rom_rdata;
  logic rom_we;
  logic [31 : 0] rom_wdata;
  logic [3 : 0] rom_wmask;
  logic rom_rvalid;

  tlul_adapter_sram #(.SramAw(13),
                      .SramDw(32),
                      .ErrOnWrite(1),
                      .CmdIntgCheck(1'b1),
                      .EnableRspIntgGen(1'b1),
                      .EnableDataIntgGen(1'b1))
      i_rom_adapter(.clk_i(clk_i),
                    .rst_ni(rst_ni),
                    .tl_i(tl_rom_o_32),
                    .tl_o(tl_rom_i_32),
                    .req_o(rom_req),
                    .we_o(rom_we),
                    .addr_o(rom_addr),
                    .wdata_o(rom_wdata),
                    .wmask_o(rom_wmask),
                    .rdata_i(rom_rdata),
                    .gnt_i(1'b1),
                    .rvalid_i(rom_rvalid),
                    .en_ifetch_i(prim_mubi_pkg::MuBi4True),
                    .req_type_o(),
                    .intg_error_o(),
                    .user_rsvd_o(),
                    .rerror_i(2'b0),
                    .compound_txn_in_progress_o(),
                    .readback_en_i(4'b0),
                    .readback_error_o(),
                    .wr_collision_i(1'b0),
                    .write_pending_i(1'b0));

  prim_rom_adv #(.Width(32),
                 .Depth(8192),
                 .MemInitFile(MemInitFile))
      i_rom(.clk_i(clk_i),
            .rst_ni(rst_ni),
            .req_i(rom_req),
            .addr_i(rom_addr),
            .rvalid_o(rom_rvalid),
            .rdata_o(rom_rdata),
            .cfg_i('0));

  // --- ISP Wires ---
  // Control (TLUL)
  coralnpu_tlul_pkg_32::tl_h2d_t isp_tl_h2d;
  coralnpu_tlul_pkg_32::tl_d2h_t isp_tl_d2h;

  // AXI M1 (isp main path)
  logic isp_m1_awvalid, isp_m1_awready;
  logic [31:0] isp_m1_awaddr;
  logic [3:0] isp_m1_awid, isp_m1_awlen, isp_m1_awcache, isp_m1_awqos, isp_m1_awregion;
  logic [2:0] isp_m1_awsize, isp_m1_awprot;
  logic [1:0] isp_m1_awburst, isp_m1_awlock;
  logic isp_m1_wvalid, isp_m1_wready, isp_m1_wlast;
  logic [63:0] isp_m1_wdata;
  logic [7:0] isp_m1_wstrb;
  logic [3:0] isp_m1_wid;
  logic isp_m1_bvalid, isp_m1_bready;
  logic [1:0] isp_m1_bresp;
  logic [3:0] isp_m1_bid;
  logic isp_m1_arvalid, isp_m1_arready;
  logic [31:0] isp_m1_araddr;
  logic [3:0] isp_m1_arid, isp_m1_arlen, isp_m1_arcache, isp_m1_arqos, isp_m1_arregion;
  logic [2:0] isp_m1_arsize, isp_m1_arprot;
  logic [1:0] isp_m1_arburst, isp_m1_arlock;
  logic isp_m1_rvalid, isp_m1_rready, isp_m1_rlast;
  logic [63:0] isp_m1_rdata;
  logic [1:0] isp_m1_rresp;
  logic [3:0] isp_m1_rid;

  // AXI M2 (isp self path)
  logic isp_m2_awvalid, isp_m2_awready;
  logic [31:0] isp_m2_awaddr;
  logic [3:0] isp_m2_awid, isp_m2_awlen, isp_m2_awcache, isp_m2_awqos, isp_m2_awregion;
  logic [2:0] isp_m2_awsize, isp_m2_awprot;
  logic [1:0] isp_m2_awburst, isp_m2_awlock;
  logic isp_m2_wvalid, isp_m2_wready, isp_m2_wlast;
  logic [63:0] isp_m2_wdata;
  logic [7:0] isp_m2_wstrb;
  logic [3:0] isp_m2_wid;
  logic isp_m2_bvalid, isp_m2_bready;
  logic [1:0] isp_m2_bresp;
  logic [3:0] isp_m2_bid;

  logic intr_mi, intr_isp;

  isp_wrapper u_isp (
    .clk_i          (clk_isp_i),
    .clk_core_i     (clk_isp_i),
    .clk_axi_i      (clk_isp_i),
    .rst_ni         (rst_ni),

    // TLUL Control (TLUL Control Slave (AHB internally))
    .tl_i           (isp_tl_h2d),
    .tl_o           (isp_tl_d2h),

    // AXI M1 (Master isp main path)
    .axi_m1_awvalid (isp_m1_awvalid),
    .axi_m1_awready (isp_m1_awready),
    .axi_m1_awaddr  (isp_m1_awaddr),
    .axi_m1_awid    (isp_m1_awid),
    .axi_m1_awlen   (isp_m1_awlen),
    .axi_m1_awsize  (isp_m1_awsize),
    .axi_m1_awburst (isp_m1_awburst),
    .axi_m1_awlock  (isp_m1_awlock),
    .axi_m1_awcache (isp_m1_awcache),
    .axi_m1_awprot  (isp_m1_awprot),
    .axi_m1_awqos   (isp_m1_awqos),
    .axi_m1_awregion(isp_m1_awregion),
    .axi_m1_wvalid  (isp_m1_wvalid),
    .axi_m1_wready  (isp_m1_wready),
    .axi_m1_wdata   (isp_m1_wdata),
    .axi_m1_wstrb   (isp_m1_wstrb),
    .axi_m1_wlast   (isp_m1_wlast),
    .axi_m1_wid     (isp_m1_wid),
    .axi_m1_bvalid  (isp_m1_bvalid),
    .axi_m1_bready  (isp_m1_bready),
    .axi_m1_bresp   (isp_m1_bresp),
    .axi_m1_bid     (isp_m1_bid),
    .axi_m1_arready (isp_m1_arready),
    .axi_m1_arvalid (isp_m1_arvalid),
    .axi_m1_araddr  (isp_m1_araddr),
    .axi_m1_arid    (isp_m1_arid),
    .axi_m1_arlen   (isp_m1_arlen),
    .axi_m1_arsize  (isp_m1_arsize),
    .axi_m1_arburst (isp_m1_arburst),
    .axi_m1_arlock  (isp_m1_arlock),
    .axi_m1_arcache (isp_m1_arcache),
    .axi_m1_arprot  (isp_m1_arprot),
    .axi_m1_arqos   (isp_m1_arqos),
    .axi_m1_arregion(isp_m1_arregion),
    .axi_m1_rvalid  (isp_m1_rvalid),
    .axi_m1_rready  (isp_m1_rready),
    .axi_m1_rdata   (isp_m1_rdata),
    .axi_m1_rresp   (isp_m1_rresp),
    .axi_m1_rid     (isp_m1_rid),
    .axi_m1_rlast   (isp_m1_rlast),

    // AXI M2 (Master isp self path)
    .axi_m2_awvalid (isp_m2_awvalid),
    .axi_m2_awready (isp_m2_awready),
    .axi_m2_awaddr  (isp_m2_awaddr),
    .axi_m2_awid    (isp_m2_awid),
    .axi_m2_awlen   (isp_m2_awlen),
    .axi_m2_awsize  (isp_m2_awsize),
    .axi_m2_awburst (isp_m2_awburst),
    .axi_m2_awlock  (isp_m2_awlock),
    .axi_m2_awcache (isp_m2_awcache),
    .axi_m2_awprot  (isp_m2_awprot),
    .axi_m2_awqos   (isp_m2_awqos),
    .axi_m2_awregion(isp_m2_awregion),
    .axi_m2_wvalid  (isp_m2_wvalid),
    .axi_m2_wready  (isp_m2_wready),
    .axi_m2_wdata   (isp_m2_wdata),
    .axi_m2_wstrb   (isp_m2_wstrb),
    .axi_m2_wlast   (isp_m2_wlast),
    .axi_m2_wid     (isp_m2_wid),
    .axi_m2_bvalid  (isp_m2_bvalid),
    .axi_m2_bready  (isp_m2_bready),
    .axi_m2_bresp   (isp_m2_bresp),
    .axi_m2_bid     (isp_m2_bid),
    .axi_m2_arready (1'b1), // Unused by ISP wrapper
    .axi_m2_arvalid (),
    .axi_m2_araddr  (),
    .axi_m2_arid    (),
    .axi_m2_arlen   (),
    .axi_m2_arsize  (),
    .axi_m2_arburst (),
    .axi_m2_arlock  (),
    .axi_m2_arcache (),
    .axi_m2_arprot  (),
    .axi_m2_arqos   (),
    .axi_m2_arregion(),
    .axi_m2_rvalid  (1'b0),
    .axi_m2_rready  (),
    .axi_m2_rdata   (64'b0),
    .axi_m2_rresp   (2'b0),
    .axi_m2_rid     (4'b0),
    .axi_m2_rlast   (1'b0),

    // Sensor Interface
    .cio_s_pclk_i   (ISP_DVP_PCLK),
    .cio_s_data_i   ({ISP_DVP_D7, ISP_DVP_D6, ISP_DVP_D5, ISP_DVP_D4, ISP_DVP_D3, ISP_DVP_D2, ISP_DVP_D1, ISP_DVP_D0}),
    .cio_s_hsync_i  (ISP_DVP_HSYNC),
    .cio_s_vsync_i  (ISP_DVP_VSYNC),

    // Interrupts
    .intr_mi_o      (intr_mi),
    .intr_isp_o     (intr_isp),

    .disable_isp_i  (1'b0),
    .scanmode_i     (1'b0)
  );

  logic rst_isp_nq, rst_isp_nqq;
  always_ff @(posedge clk_isp_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rst_isp_nq  <= 1'b0;
      rst_isp_nqq <= 1'b0;
    end else begin
      rst_isp_nq  <= 1'b1;
      rst_isp_nqq <= rst_isp_nq;
    end
  end

  CoralNPUChiselSubsystem i_chisel_subsystem (
    .io_clk_i(clk_i),
    .io_rst_ni(rst_ni),

    // External Device Port: rom
    .io_external_devices_rom_a_valid(tl_rom_o_32.a_valid),
    .io_external_devices_rom_a_bits_opcode(tl_rom_o_32.a_opcode),
    .io_external_devices_rom_a_bits_param(tl_rom_o_32.a_param),
    .io_external_devices_rom_a_bits_size(tl_rom_o_32.a_size),
    .io_external_devices_rom_a_bits_source(tl_rom_o_32.a_source),
    .io_external_devices_rom_a_bits_address(tl_rom_o_32.a_address),
    .io_external_devices_rom_a_bits_mask(tl_rom_o_32.a_mask),
    .io_external_devices_rom_a_bits_data(tl_rom_o_32.a_data),
    .io_external_devices_rom_a_bits_user_rsvd(tl_rom_o_32.a_user.rsvd),
    .io_external_devices_rom_a_bits_user_instr_type(tl_rom_o_32.a_user.instr_type),
    .io_external_devices_rom_a_bits_user_cmd_intg(tl_rom_o_32.a_user.cmd_intg),
    .io_external_devices_rom_a_bits_user_data_intg(tl_rom_o_32.a_user.data_intg),
    .io_external_devices_rom_d_ready(tl_rom_o_32.d_ready),
    .io_external_devices_rom_a_ready(tl_rom_i_32.a_ready),
    .io_external_devices_rom_d_valid(tl_rom_i_32.d_valid),
    .io_external_devices_rom_d_bits_opcode(tl_rom_i_32.d_opcode),
    .io_external_devices_rom_d_bits_param(tl_rom_i_32.d_param),
    .io_external_devices_rom_d_bits_size(tl_rom_i_32.d_size),
    .io_external_devices_rom_d_bits_source(tl_rom_i_32.d_source),
    .io_external_devices_rom_d_bits_sink(tl_rom_i_32.d_sink),
    .io_external_devices_rom_d_bits_data(tl_rom_i_32.d_data),
    .io_external_devices_rom_d_bits_error(tl_rom_i_32.d_error),
    .io_external_devices_rom_d_bits_user_rsp_intg(tl_rom_i_32.d_user.rsp_intg),
    .io_external_devices_rom_d_bits_user_data_intg(tl_rom_i_32.d_user.data_intg),

    // External Device Port: uart0
    .io_external_devices_uart0_a_valid(tl_uart0_o.a_valid),
    .io_external_devices_uart0_a_bits_opcode(tl_uart0_o.a_opcode),
    .io_external_devices_uart0_a_bits_param(tl_uart0_o.a_param),
    .io_external_devices_uart0_a_bits_size(tl_uart0_o.a_size),
    .io_external_devices_uart0_a_bits_source(tl_uart0_o.a_source),
    .io_external_devices_uart0_a_bits_address(tl_uart0_o.a_address),
    .io_external_devices_uart0_a_bits_mask(tl_uart0_o.a_mask),
    .io_external_devices_uart0_a_bits_data(tl_uart0_o.a_data),
    .io_external_devices_uart0_a_bits_user_rsvd(tl_uart0_o.a_user.rsvd),
    .io_external_devices_uart0_a_bits_user_instr_type(tl_uart0_o.a_user.instr_type),
    .io_external_devices_uart0_a_bits_user_cmd_intg(tl_uart0_o.a_user.cmd_intg),
    .io_external_devices_uart0_a_bits_user_data_intg(tl_uart0_o.a_user.data_intg),
    .io_external_devices_uart0_d_ready(tl_uart0_o.d_ready),
    .io_external_devices_uart0_a_ready(tl_uart0_i.a_ready),
    .io_external_devices_uart0_d_valid(tl_uart0_i.d_valid),
    .io_external_devices_uart0_d_bits_opcode(tl_uart0_i.d_opcode),
    .io_external_devices_uart0_d_bits_param(tl_uart0_i.d_param),
    .io_external_devices_uart0_d_bits_size(tl_uart0_i.d_size),
    .io_external_devices_uart0_d_bits_source(tl_uart0_i.d_source),
    .io_external_devices_uart0_d_bits_sink(tl_uart0_i.d_sink),
    .io_external_devices_uart0_d_bits_data(tl_uart0_i.d_data),
    .io_external_devices_uart0_d_bits_error(tl_uart0_i.d_error),
    .io_external_devices_uart0_d_bits_user_rsp_intg(tl_uart0_i.d_user.rsp_intg),
    .io_external_devices_uart0_d_bits_user_data_intg(tl_uart0_i.d_user.data_intg),

    // External Device Port: uart1
    .io_external_devices_uart1_a_valid(tl_uart1_o.a_valid),
    .io_external_devices_uart1_a_bits_opcode(tl_uart1_o.a_opcode),
    .io_external_devices_uart1_a_bits_param(tl_uart1_o.a_param),
    .io_external_devices_uart1_a_bits_size(tl_uart1_o.a_size),
    .io_external_devices_uart1_a_bits_source(tl_uart1_o.a_source),
    .io_external_devices_uart1_a_bits_address(tl_uart1_o.a_address),
    .io_external_devices_uart1_a_bits_mask(tl_uart1_o.a_mask),
    .io_external_devices_uart1_a_bits_data(tl_uart1_o.a_data),
    .io_external_devices_uart1_a_bits_user_rsvd(tl_uart1_o.a_user.rsvd),
    .io_external_devices_uart1_a_bits_user_instr_type(tl_uart1_o.a_user.instr_type),
    .io_external_devices_uart1_a_bits_user_cmd_intg(tl_uart1_o.a_user.cmd_intg),
    .io_external_devices_uart1_a_bits_user_data_intg(tl_uart1_o.a_user.data_intg),
    .io_external_devices_uart1_d_ready(tl_uart1_o.d_ready),
    .io_external_devices_uart1_a_ready(tl_uart1_i.a_ready),
    .io_external_devices_uart1_d_valid(tl_uart1_i.d_valid),
    .io_external_devices_uart1_d_bits_opcode(tl_uart1_i.d_opcode),
    .io_external_devices_uart1_d_bits_param(tl_uart1_i.d_param),
    .io_external_devices_uart1_d_bits_size(tl_uart1_i.d_size),
    .io_external_devices_uart1_d_bits_source(tl_uart1_i.d_source),
    .io_external_devices_uart1_d_bits_sink(tl_uart1_i.d_sink),
    .io_external_devices_uart1_d_bits_data(tl_uart1_i.d_data),
    .io_external_devices_uart1_d_bits_error(tl_uart1_i.d_error),
    .io_external_devices_uart1_d_bits_user_rsp_intg(tl_uart1_i.d_user.rsp_intg),
    .io_external_devices_uart1_d_bits_user_data_intg(tl_uart1_i.d_user.data_intg),

    // External Device Port: i2c_master
    .io_external_devices_i2c_master_a_valid(tl_i2c_h2d.a_valid),
    .io_external_devices_i2c_master_a_bits_opcode(tl_i2c_h2d.a_opcode),
    .io_external_devices_i2c_master_a_bits_param(tl_i2c_h2d.a_param),
    .io_external_devices_i2c_master_a_bits_size(tl_i2c_h2d.a_size),
    .io_external_devices_i2c_master_a_bits_source(tl_i2c_h2d.a_source),
    .io_external_devices_i2c_master_a_bits_address(tl_i2c_h2d.a_address),
    .io_external_devices_i2c_master_a_bits_mask(tl_i2c_h2d.a_mask),
    .io_external_devices_i2c_master_a_bits_data(tl_i2c_h2d.a_data),
    .io_external_devices_i2c_master_a_bits_user_rsvd(tl_i2c_h2d.a_user.rsvd),
    .io_external_devices_i2c_master_a_bits_user_instr_type(tl_i2c_h2d.a_user.instr_type),
    .io_external_devices_i2c_master_a_bits_user_cmd_intg(tl_i2c_h2d.a_user.cmd_intg),
    .io_external_devices_i2c_master_a_bits_user_data_intg(tl_i2c_h2d.a_user.data_intg),
    .io_external_devices_i2c_master_d_ready(tl_i2c_h2d.d_ready),
    .io_external_devices_i2c_master_a_ready(tl_i2c_d2h.a_ready),
    .io_external_devices_i2c_master_d_valid(tl_i2c_d2h.d_valid),
    .io_external_devices_i2c_master_d_bits_opcode(tl_i2c_d2h.d_opcode),
    .io_external_devices_i2c_master_d_bits_param(tl_i2c_d2h.d_param),
    .io_external_devices_i2c_master_d_bits_size(tl_i2c_d2h.d_size),
    .io_external_devices_i2c_master_d_bits_source(tl_i2c_d2h.d_source),
    .io_external_devices_i2c_master_d_bits_sink(tl_i2c_d2h.d_sink),
    .io_external_devices_i2c_master_d_bits_data(tl_i2c_d2h.d_data),
    .io_external_devices_i2c_master_d_bits_error(tl_i2c_d2h.d_error),
    .io_external_devices_i2c_master_d_bits_user_rsp_intg(tl_i2c_d2h.d_user.rsp_intg),
    .io_external_devices_i2c_master_d_bits_user_data_intg(tl_i2c_d2h.d_user.data_intg),

    // External Device Port: clk_table
    .io_external_devices_clk_table_a_valid(tl_clk_table_h2d.a_valid),
    .io_external_devices_clk_table_a_bits_opcode(tl_clk_table_h2d.a_opcode),
    .io_external_devices_clk_table_a_bits_param(tl_clk_table_h2d.a_param),
    .io_external_devices_clk_table_a_bits_size(tl_clk_table_h2d.a_size),
    .io_external_devices_clk_table_a_bits_source(tl_clk_table_h2d.a_source),
    .io_external_devices_clk_table_a_bits_address(tl_clk_table_h2d.a_address),
    .io_external_devices_clk_table_a_bits_mask(tl_clk_table_h2d.a_mask),
    .io_external_devices_clk_table_a_bits_data(tl_clk_table_h2d.a_data),
    .io_external_devices_clk_table_a_bits_user_rsvd(tl_clk_table_h2d.a_user.rsvd),
    .io_external_devices_clk_table_a_bits_user_instr_type(tl_clk_table_h2d.a_user.instr_type),
    .io_external_devices_clk_table_a_bits_user_cmd_intg(tl_clk_table_h2d.a_user.cmd_intg),
    .io_external_devices_clk_table_a_bits_user_data_intg(tl_clk_table_h2d.a_user.data_intg),
    .io_external_devices_clk_table_d_ready(tl_clk_table_h2d.d_ready),
    .io_external_devices_clk_table_a_ready(tl_clk_table_d2h.a_ready),
    .io_external_devices_clk_table_d_valid(tl_clk_table_d2h.d_valid),
    .io_external_devices_clk_table_d_bits_opcode(tl_clk_table_d2h.d_opcode),
    .io_external_devices_clk_table_d_bits_param(tl_clk_table_d2h.d_param),
    .io_external_devices_clk_table_d_bits_size(tl_clk_table_d2h.d_size),
    .io_external_devices_clk_table_d_bits_source(tl_clk_table_d2h.d_source),
    .io_external_devices_clk_table_d_bits_sink(tl_clk_table_d2h.d_sink),
    .io_external_devices_clk_table_d_bits_data(tl_clk_table_d2h.d_data),
    .io_external_devices_clk_table_d_bits_error(tl_clk_table_d2h.d_error),
    .io_external_devices_clk_table_d_bits_user_rsp_intg(tl_clk_table_d2h.d_user.rsp_intg),
    .io_external_devices_clk_table_d_bits_user_data_intg(tl_clk_table_d2h.d_user.data_intg),

    // Peripheral Ports
    .io_external_ports_halted(io_halted),      // halted
    .io_external_ports_fault(io_fault),       // fault
    .io_external_ports_wfi(),               // wfi (unused)
    .io_external_ports_ext_intrs(31'b0),    // ext_intrs (tied off)
    .io_external_ports_te(1'b0),           // te (tied off)
    .io_external_ports_boot_addr(boot_addr_i),
    .io_external_ports_dm_req_valid(io_dm_req_valid),
    .io_external_ports_dm_req_ready(io_dm_req_ready),
    .io_external_ports_dm_req_bits_address(io_dm_req_bits_address),
    .io_external_ports_dm_req_bits_data(io_dm_req_bits_data),
    .io_external_ports_dm_req_bits_op(io_dm_req_bits_op),
    .io_external_ports_dm_rsp_valid(io_dm_rsp_valid),
    .io_external_ports_dm_rsp_ready(io_dm_rsp_ready),
    .io_external_ports_dm_rsp_bits_data(io_dm_rsp_bits_data),
    .io_external_ports_dm_rsp_bits_op(io_dm_rsp_bits_op),
    .io_external_ports_spi_clk(spi_clk_i),      // spi_clk
    .io_external_ports_spi_csb(spi_csb_i),      // spi_csb
    .io_external_ports_spi_mosi(spi_mosi_i),     // spi_mosi
    .io_external_ports_spi_miso(spi_miso_o),     // spi_miso
    .io_external_ports_spim_sclk(spim_sclk_o),
    .io_external_ports_spim_csb(spim_csb_o),
    .io_external_ports_spim_mosi(spim_mosi_o),
    .io_external_ports_spim_miso(spim_miso_i),
    .io_external_ports_spim_clk_i(spim_clk_i),
    .io_external_ports_gpio_o(gpio_o),
    .io_external_ports_gpio_en_o(gpio_en_o),
    .io_external_ports_gpio_i(gpio_i),
    .io_external_ports_spim_flash_sclk(spim_flash_sclk_o),
    .io_external_ports_spim_flash_csb(spim_flash_csb_o),
    .io_external_ports_spim_flash_mosi(spim_flash_mosi_o),
    .io_external_ports_spim_flash_miso(spim_flash_miso_i),
    .io_external_ports_spim_flash_clk_i(spim_flash_clk_i),

    .io_async_ports_devices_ddr_clock(ddr_clk_i),
    .io_async_ports_devices_ddr_reset(ddr_rst),
    .io_async_ports_devices_isp_axi_clk_clock(clk_isp_i),
    .io_async_ports_devices_isp_axi_clk_reset(~rst_isp_nqq),

    // ISP Control Interface (TLUL)
    .io_ispyocto_ctrl_a_valid(isp_tl_h2d.a_valid),
    .io_ispyocto_ctrl_a_ready(isp_tl_d2h.a_ready),
    .io_ispyocto_ctrl_a_bits_opcode(isp_tl_h2d.a_opcode),
    .io_ispyocto_ctrl_a_bits_param(isp_tl_h2d.a_param),
    .io_ispyocto_ctrl_a_bits_size(isp_tl_h2d.a_size),
    .io_ispyocto_ctrl_a_bits_source(isp_tl_h2d.a_source[5:0]), // Map to 6-bit port
    .io_ispyocto_ctrl_a_bits_address(isp_tl_h2d.a_address),
    .io_ispyocto_ctrl_a_bits_mask(isp_tl_h2d.a_mask),
    .io_ispyocto_ctrl_a_bits_data(isp_tl_h2d.a_data),
    .io_ispyocto_ctrl_a_bits_user_rsvd(isp_tl_h2d.a_user.rsvd),
    .io_ispyocto_ctrl_a_bits_user_instr_type(isp_tl_h2d.a_user.instr_type),
    .io_ispyocto_ctrl_a_bits_user_cmd_intg(isp_tl_h2d.a_user.cmd_intg),
    .io_ispyocto_ctrl_a_bits_user_data_intg(isp_tl_h2d.a_user.data_intg),
    .io_ispyocto_ctrl_d_ready(isp_tl_h2d.d_ready),
    .io_ispyocto_ctrl_d_valid(isp_tl_d2h.d_valid),
    .io_ispyocto_ctrl_d_bits_opcode(isp_tl_d2h.d_opcode),
    .io_ispyocto_ctrl_d_bits_param(isp_tl_d2h.d_param),
    .io_ispyocto_ctrl_d_bits_size(isp_tl_d2h.d_size),
    .io_ispyocto_ctrl_d_bits_source(isp_tl_d2h.d_source[5:0]),
    .io_ispyocto_ctrl_d_bits_sink(isp_tl_d2h.d_sink),
    .io_ispyocto_ctrl_d_bits_data(isp_tl_d2h.d_data),
    .io_ispyocto_ctrl_d_bits_error(isp_tl_d2h.d_error),
    .io_ispyocto_ctrl_d_bits_user_rsp_intg(isp_tl_d2h.d_user.rsp_intg),
    .io_ispyocto_ctrl_d_bits_user_data_intg(isp_tl_d2h.d_user.data_intg),

    // ISP AXI M1
    .io_ispyocto_m1_axi_write_addr_valid(isp_m1_awvalid),
    .io_ispyocto_m1_axi_write_addr_ready(isp_m1_awready),
    .io_ispyocto_m1_axi_write_addr_bits_addr(isp_m1_awaddr),
    .io_ispyocto_m1_axi_write_addr_bits_prot(isp_m1_awprot),
    .io_ispyocto_m1_axi_write_addr_bits_id(isp_m1_awid),
    .io_ispyocto_m1_axi_write_addr_bits_len(isp_m1_awlen),
    .io_ispyocto_m1_axi_write_addr_bits_size(isp_m1_awsize),
    .io_ispyocto_m1_axi_write_addr_bits_burst(isp_m1_awburst),
    .io_ispyocto_m1_axi_write_addr_bits_lock(isp_m1_awlock),
    .io_ispyocto_m1_axi_write_addr_bits_cache(isp_m1_awcache),
    .io_ispyocto_m1_axi_write_addr_bits_qos(isp_m1_awqos),
    .io_ispyocto_m1_axi_write_addr_bits_region(isp_m1_awregion),
    .io_ispyocto_m1_axi_write_data_valid(isp_m1_wvalid),
    .io_ispyocto_m1_axi_write_data_ready(isp_m1_wready),
    .io_ispyocto_m1_axi_write_data_bits_data(isp_m1_wdata),
    .io_ispyocto_m1_axi_write_data_bits_last(isp_m1_wlast),
    .io_ispyocto_m1_axi_write_data_bits_strb(isp_m1_wstrb),
    .io_ispyocto_m1_axi_write_resp_valid(isp_m1_bvalid),
    .io_ispyocto_m1_axi_write_resp_ready(isp_m1_bready),
    .io_ispyocto_m1_axi_write_resp_bits_id(isp_m1_bid),
    .io_ispyocto_m1_axi_write_resp_bits_resp(isp_m1_bresp),
    .io_ispyocto_m1_axi_read_addr_valid(isp_m1_arvalid),
    .io_ispyocto_m1_axi_read_addr_ready(isp_m1_arready),
    .io_ispyocto_m1_axi_read_addr_bits_addr(isp_m1_araddr),
    .io_ispyocto_m1_axi_read_addr_bits_prot(isp_m1_arprot),
    .io_ispyocto_m1_axi_read_addr_bits_id(isp_m1_arid),
    .io_ispyocto_m1_axi_read_addr_bits_len(isp_m1_arlen),
    .io_ispyocto_m1_axi_read_addr_bits_size(isp_m1_arsize),
    .io_ispyocto_m1_axi_read_addr_bits_burst(isp_m1_arburst),
    .io_ispyocto_m1_axi_read_addr_bits_lock(isp_m1_arlock),
    .io_ispyocto_m1_axi_read_addr_bits_cache(isp_m1_arcache),
    .io_ispyocto_m1_axi_read_addr_bits_qos(isp_m1_arqos),
    .io_ispyocto_m1_axi_read_addr_bits_region(isp_m1_arregion),
    .io_ispyocto_m1_axi_read_data_valid(isp_m1_rvalid),
    .io_ispyocto_m1_axi_read_data_ready(isp_m1_rready),
    .io_ispyocto_m1_axi_read_data_bits_data(isp_m1_rdata),
    .io_ispyocto_m1_axi_read_data_bits_id(isp_m1_rid),
    .io_ispyocto_m1_axi_read_data_bits_resp(isp_m1_rresp),
    .io_ispyocto_m1_axi_read_data_bits_last(isp_m1_rlast),

    // ISP AXI M2
    .io_ispyocto_m2_axi_write_addr_valid(isp_m2_awvalid),
    .io_ispyocto_m2_axi_write_addr_ready(isp_m2_awready),
    .io_ispyocto_m2_axi_write_addr_bits_addr(isp_m2_awaddr),
    .io_ispyocto_m2_axi_write_addr_bits_prot(isp_m2_awprot),
    .io_ispyocto_m2_axi_write_addr_bits_id(isp_m2_awid),
    .io_ispyocto_m2_axi_write_addr_bits_len(isp_m2_awlen),
    .io_ispyocto_m2_axi_write_addr_bits_size(isp_m2_awsize),
    .io_ispyocto_m2_axi_write_addr_bits_burst(isp_m2_awburst),
    .io_ispyocto_m2_axi_write_addr_bits_lock(isp_m2_awlock),
    .io_ispyocto_m2_axi_write_addr_bits_cache(isp_m2_awcache),
    .io_ispyocto_m2_axi_write_addr_bits_qos(isp_m2_awqos),
    .io_ispyocto_m2_axi_write_addr_bits_region(isp_m2_awregion),
    .io_ispyocto_m2_axi_write_data_valid(isp_m2_wvalid),
    .io_ispyocto_m2_axi_write_data_ready(isp_m2_wready),
    .io_ispyocto_m2_axi_write_data_bits_data(isp_m2_wdata),
    .io_ispyocto_m2_axi_write_data_bits_last(isp_m2_wlast),
    .io_ispyocto_m2_axi_write_data_bits_strb(isp_m2_wstrb),
    .io_ispyocto_m2_axi_write_resp_valid(isp_m2_bvalid),
    .io_ispyocto_m2_axi_write_resp_ready(isp_m2_bready),
    .io_ispyocto_m2_axi_write_resp_bits_id(isp_m2_bid),
    .io_ispyocto_m2_axi_write_resp_bits_resp(isp_m2_bresp),

    // External Host: autoboot
    .io_external_hosts_autoboot_a_ready(tl_autoboot_d2h.a_ready),
    .io_external_hosts_autoboot_a_valid(tl_autoboot_h2d.a_valid),
    .io_external_hosts_autoboot_a_bits_opcode(tl_autoboot_h2d.a_opcode),
    .io_external_hosts_autoboot_a_bits_param(tl_autoboot_h2d.a_param),
    .io_external_hosts_autoboot_a_bits_size(tl_autoboot_h2d.a_size),
    .io_external_hosts_autoboot_a_bits_source(tl_autoboot_h2d.a_source),
    .io_external_hosts_autoboot_a_bits_address(tl_autoboot_h2d.a_address),
    .io_external_hosts_autoboot_a_bits_mask(tl_autoboot_h2d.a_mask),
    .io_external_hosts_autoboot_a_bits_data(tl_autoboot_h2d.a_data),
    .io_external_hosts_autoboot_a_bits_user_rsvd(tl_autoboot_h2d.a_user.rsvd),
    .io_external_hosts_autoboot_a_bits_user_instr_type(tl_autoboot_h2d.a_user.instr_type),
    .io_external_hosts_autoboot_a_bits_user_cmd_intg(tl_autoboot_h2d.a_user.cmd_intg),
    .io_external_hosts_autoboot_a_bits_user_data_intg(tl_autoboot_h2d.a_user.data_intg),
    .io_external_hosts_autoboot_d_ready(tl_autoboot_h2d.d_ready),
    .io_external_hosts_autoboot_d_valid(tl_autoboot_d2h.d_valid),
    .io_external_hosts_autoboot_d_bits_opcode(tl_autoboot_d2h.d_opcode),
    .io_external_hosts_autoboot_d_bits_param(tl_autoboot_d2h.d_param),
    .io_external_hosts_autoboot_d_bits_size(tl_autoboot_d2h.d_size),
    .io_external_hosts_autoboot_d_bits_source(tl_autoboot_d2h.d_source),
    .io_external_hosts_autoboot_d_bits_sink(tl_autoboot_d2h.d_sink),
    .io_external_hosts_autoboot_d_bits_data(tl_autoboot_d2h.d_data),
    .io_external_hosts_autoboot_d_bits_error(tl_autoboot_d2h.d_error),
    .io_external_hosts_autoboot_d_bits_user_rsp_intg(tl_autoboot_d2h.d_user.rsp_intg),
    .io_external_hosts_autoboot_d_bits_user_data_intg(tl_autoboot_d2h.d_user.data_intg),

    .io_ispyocto_m2_axi_read_addr_valid(1'b0),
    .io_ispyocto_m2_axi_read_addr_ready(),
    .io_ispyocto_m2_axi_read_addr_bits_addr('0),
    .io_ispyocto_m2_axi_read_addr_bits_prot('0),
    .io_ispyocto_m2_axi_read_addr_bits_id('0),
    .io_ispyocto_m2_axi_read_addr_bits_len('0),
    .io_ispyocto_m2_axi_read_addr_bits_size('0),
    .io_ispyocto_m2_axi_read_addr_bits_burst('0),
    .io_ispyocto_m2_axi_read_addr_bits_lock('0),
    .io_ispyocto_m2_axi_read_addr_bits_cache('0),
    .io_ispyocto_m2_axi_read_addr_bits_qos('0),
    .io_ispyocto_m2_axi_read_addr_bits_region('0),
    .io_ispyocto_m2_axi_read_data_valid(),
    .io_ispyocto_m2_axi_read_data_ready(1'b0),
    .io_ispyocto_m2_axi_read_data_bits_data(),
    .io_ispyocto_m2_axi_read_data_bits_id(),
    .io_ispyocto_m2_axi_read_data_bits_resp(),
    .io_ispyocto_m2_axi_read_data_bits_last(),

    .io_async_ports_hosts_isp_axi_clk_clock(clk_isp_i),
    .io_async_ports_hosts_isp_axi_clk_reset(~rst_isp_nqq),

    .io_ddr_ctrl_axi_write_addr_valid(io_ddr_ctrl_axi_aw_valid),
    .io_ddr_ctrl_axi_write_addr_ready(io_ddr_ctrl_axi_aw_ready),
    .io_ddr_ctrl_axi_write_addr_bits_addr(io_ddr_ctrl_axi_aw_bits_addr),
    .io_ddr_ctrl_axi_write_addr_bits_prot(io_ddr_ctrl_axi_aw_bits_prot),
    .io_ddr_ctrl_axi_write_addr_bits_id(io_ddr_ctrl_axi_aw_bits_id),
    .io_ddr_ctrl_axi_write_addr_bits_len(io_ddr_ctrl_axi_aw_bits_len),
    .io_ddr_ctrl_axi_write_addr_bits_size(io_ddr_ctrl_axi_aw_bits_size),
    .io_ddr_ctrl_axi_write_addr_bits_burst(io_ddr_ctrl_axi_aw_bits_burst),
    .io_ddr_ctrl_axi_write_addr_bits_lock(io_ddr_ctrl_axi_aw_bits_lock),
    .io_ddr_ctrl_axi_write_addr_bits_cache(io_ddr_ctrl_axi_aw_bits_cache),
    .io_ddr_ctrl_axi_write_addr_bits_qos(io_ddr_ctrl_axi_aw_bits_qos),
    .io_ddr_ctrl_axi_write_addr_bits_region(io_ddr_ctrl_axi_aw_bits_region),
    .io_ddr_ctrl_axi_write_data_valid(io_ddr_ctrl_axi_w_valid),
    .io_ddr_ctrl_axi_write_data_ready(io_ddr_ctrl_axi_w_ready),
    .io_ddr_ctrl_axi_write_data_bits_data(io_ddr_ctrl_axi_w_bits_data),
    .io_ddr_ctrl_axi_write_data_bits_last(io_ddr_ctrl_axi_w_bits_last),
    .io_ddr_ctrl_axi_write_data_bits_strb(io_ddr_ctrl_axi_w_bits_strb),
    .io_ddr_ctrl_axi_write_resp_valid(io_ddr_ctrl_axi_b_valid),
    .io_ddr_ctrl_axi_write_resp_ready(io_ddr_ctrl_axi_b_ready),
    .io_ddr_ctrl_axi_write_resp_bits_id(io_ddr_ctrl_axi_b_bits_id),
    .io_ddr_ctrl_axi_write_resp_bits_resp(io_ddr_ctrl_axi_b_bits_resp),
    .io_ddr_ctrl_axi_read_addr_valid(io_ddr_ctrl_axi_ar_valid),
    .io_ddr_ctrl_axi_read_addr_ready(io_ddr_ctrl_axi_ar_ready),
    .io_ddr_ctrl_axi_read_addr_bits_addr(io_ddr_ctrl_axi_ar_bits_addr),
    .io_ddr_ctrl_axi_read_addr_bits_prot(io_ddr_ctrl_axi_ar_bits_prot),
    .io_ddr_ctrl_axi_read_addr_bits_id(io_ddr_ctrl_axi_ar_bits_id),
    .io_ddr_ctrl_axi_read_addr_bits_len(io_ddr_ctrl_axi_ar_bits_len),
    .io_ddr_ctrl_axi_read_addr_bits_size(io_ddr_ctrl_axi_ar_bits_size),
    .io_ddr_ctrl_axi_read_addr_bits_burst(io_ddr_ctrl_axi_ar_bits_burst),
    .io_ddr_ctrl_axi_read_addr_bits_lock(io_ddr_ctrl_axi_ar_bits_lock),
    .io_ddr_ctrl_axi_read_addr_bits_cache(io_ddr_ctrl_axi_ar_bits_cache),
    .io_ddr_ctrl_axi_read_addr_bits_qos(io_ddr_ctrl_axi_ar_bits_qos),
    .io_ddr_ctrl_axi_read_addr_bits_region(io_ddr_ctrl_axi_ar_bits_region),
    .io_ddr_ctrl_axi_read_data_valid(io_ddr_ctrl_axi_r_valid),
    .io_ddr_ctrl_axi_read_data_ready(io_ddr_ctrl_axi_r_ready),
    .io_ddr_ctrl_axi_read_data_bits_data(io_ddr_ctrl_axi_r_bits_data),
    .io_ddr_ctrl_axi_read_data_bits_id(io_ddr_ctrl_axi_r_bits_id),
    .io_ddr_ctrl_axi_read_data_bits_resp(io_ddr_ctrl_axi_r_bits_resp),
    .io_ddr_ctrl_axi_read_data_bits_last(io_ddr_ctrl_axi_r_bits_last),
    .io_ddr_mem_axi_write_addr_valid(io_ddr_mem_axi_aw_valid),
    .io_ddr_mem_axi_write_addr_ready(io_ddr_mem_axi_aw_ready),
    .io_ddr_mem_axi_write_addr_bits_addr(io_ddr_mem_axi_aw_bits_addr),
    .io_ddr_mem_axi_write_addr_bits_prot(io_ddr_mem_axi_aw_bits_prot),
    .io_ddr_mem_axi_write_addr_bits_id(io_ddr_mem_axi_aw_bits_id),
    .io_ddr_mem_axi_write_addr_bits_len(io_ddr_mem_axi_aw_bits_len),
    .io_ddr_mem_axi_write_addr_bits_size(io_ddr_mem_axi_aw_bits_size),
    .io_ddr_mem_axi_write_addr_bits_burst(io_ddr_mem_axi_aw_bits_burst),
    .io_ddr_mem_axi_write_addr_bits_lock(io_ddr_mem_axi_aw_bits_lock),
    .io_ddr_mem_axi_write_addr_bits_cache(io_ddr_mem_axi_aw_bits_cache),
    .io_ddr_mem_axi_write_addr_bits_qos(io_ddr_mem_axi_aw_bits_qos),
    .io_ddr_mem_axi_write_addr_bits_region(io_ddr_mem_axi_aw_bits_region),
    .io_ddr_mem_axi_write_data_valid(io_ddr_mem_axi_w_valid),
    .io_ddr_mem_axi_write_data_ready(io_ddr_mem_axi_w_ready),
    .io_ddr_mem_axi_write_data_bits_data(io_ddr_mem_axi_w_bits_data),
    .io_ddr_mem_axi_write_data_bits_last(io_ddr_mem_axi_w_bits_last),
    .io_ddr_mem_axi_write_data_bits_strb(io_ddr_mem_axi_w_bits_strb),
    .io_ddr_mem_axi_write_resp_valid(io_ddr_mem_axi_b_valid),
    .io_ddr_mem_axi_write_resp_ready(io_ddr_mem_axi_b_ready),
    .io_ddr_mem_axi_write_resp_bits_id(io_ddr_mem_axi_b_bits_id),
    .io_ddr_mem_axi_write_resp_bits_resp(io_ddr_mem_axi_b_bits_resp),
    .io_ddr_mem_axi_read_addr_valid(io_ddr_mem_axi_ar_valid),
    .io_ddr_mem_axi_read_addr_ready(io_ddr_mem_axi_ar_ready),
    .io_ddr_mem_axi_read_addr_bits_addr(io_ddr_mem_axi_ar_bits_addr),
    .io_ddr_mem_axi_read_addr_bits_prot(io_ddr_mem_axi_ar_bits_prot),
    .io_ddr_mem_axi_read_addr_bits_id(io_ddr_mem_axi_ar_bits_id),
    .io_ddr_mem_axi_read_addr_bits_len(io_ddr_mem_axi_ar_bits_len),
    .io_ddr_mem_axi_read_addr_bits_size(io_ddr_mem_axi_ar_bits_size),
    .io_ddr_mem_axi_read_addr_bits_burst(io_ddr_mem_axi_ar_bits_burst),
    .io_ddr_mem_axi_read_addr_bits_lock(io_ddr_mem_axi_ar_bits_lock),
    .io_ddr_mem_axi_read_addr_bits_cache(io_ddr_mem_axi_ar_bits_cache),
    .io_ddr_mem_axi_read_addr_bits_qos(io_ddr_mem_axi_ar_bits_qos),
    .io_ddr_mem_axi_read_addr_bits_region(io_ddr_mem_axi_ar_bits_region),
    .io_ddr_mem_axi_read_data_valid(io_ddr_mem_axi_r_valid),
    .io_ddr_mem_axi_read_data_ready(io_ddr_mem_axi_r_ready),
    .io_ddr_mem_axi_read_data_bits_data(io_ddr_mem_axi_r_bits_data),
    .io_ddr_mem_axi_read_data_bits_id(io_ddr_mem_axi_r_bits_id),
    .io_ddr_mem_axi_read_data_bits_resp(io_ddr_mem_axi_r_bits_resp),
    .io_ddr_mem_axi_read_data_bits_last(io_ddr_mem_axi_r_bits_last)
  );
endmodule
