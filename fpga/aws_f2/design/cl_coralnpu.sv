// Copyright 2026
// SPDX-License-Identifier: Apache-2.0
//
// AWS F2 shell wrapper for Coral NPU's production RvvCoreMiniAxi target.
// This bootstrap CL exposes Coral ITCM, DTCM and control CSRs through OCL.
// The NPU runs at the shell-provided 100 MHz HBM reference clock.
//
// External-memory traffic is intentionally not enabled in this bootstrap CL.
// The Gemma CL must connect io_axi_master_* to HBM; see fpga/aws_f2/README.md.

module cl_coralnpu (
  `include "cl_ports.vh"
);

`include "cl_id_defines.vh"
`include "unused_flr_template.inc"
`include "unused_ddr_template.inc"
`include "unused_cl_sda_template.inc"
`include "unused_apppf_irq_template.inc"
`include "unused_dma_pcis_template.inc"
`include "unused_pcim_template.inc"

  logic rst_main_n_sync;
  logic rst_coral_n;
  logic coral_halted, coral_fault, coral_wfi;

  xpm_cdc_async_rst #(
    .DEST_SYNC_FF(4),
    .INIT_SYNC_FF(0),
    .RST_ACTIVE_HIGH(0)
  ) MAIN_RESET_SYNC (
    .src_arst(rst_main_n),
    .dest_clk(clk_main_a0),
    .dest_arst(rst_main_n_sync)
  );

  xpm_cdc_async_rst #(
    .DEST_SYNC_FF(4),
    .INIT_SYNC_FF(0),
    .RST_ACTIVE_HIGH(0)
  ) CORAL_RESET_SYNC (
    .src_arst(rst_main_n),
    .dest_clk(clk_hbm_ref),
    .dest_arst(rst_coral_n)
  );

  assign cl_sh_id0 = `CL_SH_ID0;
  assign cl_sh_id1 = `CL_SH_ID1;
  assign cl_sh_status0 = 32'b0;
  assign cl_sh_status1 = 32'b0;
  assign cl_sh_status2 = 32'b0;
  assign cl_sh_status_vled = {13'b0, coral_wfi, coral_fault, coral_halted};
  assign tdo = 1'b0;

  assign hbm_apb_paddr_1   = '0;
  assign hbm_apb_pprot_1   = '0;
  assign hbm_apb_psel_1    = '0;
  assign hbm_apb_penable_1 = '0;
  assign hbm_apb_pwrite_1  = '0;
  assign hbm_apb_pwdata_1  = '0;
  assign hbm_apb_pstrb_1   = '0;
  assign hbm_apb_pready_1  = '0;
  assign hbm_apb_prdata_1  = '0;
  assign hbm_apb_pslverr_1 = '0;
  assign hbm_apb_paddr_0   = '0;
  assign hbm_apb_pprot_0   = '0;
  assign hbm_apb_psel_0    = '0;
  assign hbm_apb_penable_0 = '0;
  assign hbm_apb_pwrite_0  = '0;
  assign hbm_apb_pwdata_0  = '0;
  assign hbm_apb_pstrb_0   = '0;
  assign hbm_apb_pready_0  = '0;
  assign hbm_apb_prdata_0  = '0;
  assign hbm_apb_pslverr_0 = '0;

  assign PCIE_EP_TXP    = '0;
  assign PCIE_EP_TXN    = '0;
  assign PCIE_RP_PERSTN = '0;
  assign PCIE_RP_TXP    = '0;
  assign PCIE_RP_TXN    = '0;

  // OCL in clk_main_a0 -> AXI-Lite in the Coral 100 MHz clock domain.
  logic [31:0] axil_awaddr, axil_wdata, axil_araddr, axil_rdata;
  logic [2:0]  axil_awprot, axil_arprot;
  logic [3:0]  axil_wstrb;
  logic [1:0]  axil_bresp, axil_rresp;
  logic axil_awvalid, axil_awready, axil_wvalid, axil_wready;
  logic axil_bvalid, axil_bready, axil_arvalid, axil_arready;
  logic axil_rvalid, axil_rready;

  cl_axi_clock_converter_light OCL_CLOCK_CONVERTER (
    .s_axi_aclk(clk_main_a0),
    .s_axi_aresetn(rst_main_n_sync),
    .s_axi_awaddr(ocl_cl_awaddr),
    .s_axi_awprot(3'b0),
    .s_axi_awvalid(ocl_cl_awvalid),
    .s_axi_awready(cl_ocl_awready),
    .s_axi_wdata(ocl_cl_wdata),
    .s_axi_wstrb(ocl_cl_wstrb),
    .s_axi_wvalid(ocl_cl_wvalid),
    .s_axi_wready(cl_ocl_wready),
    .s_axi_bresp(cl_ocl_bresp),
    .s_axi_bvalid(cl_ocl_bvalid),
    .s_axi_bready(ocl_cl_bready),
    .s_axi_araddr(ocl_cl_araddr),
    .s_axi_arprot(3'b0),
    .s_axi_arvalid(ocl_cl_arvalid),
    .s_axi_arready(cl_ocl_arready),
    .s_axi_rdata(cl_ocl_rdata),
    .s_axi_rresp(cl_ocl_rresp),
    .s_axi_rvalid(cl_ocl_rvalid),
    .s_axi_rready(ocl_cl_rready),
    .m_axi_aclk(clk_hbm_ref),
    .m_axi_aresetn(rst_coral_n),
    .m_axi_awaddr(axil_awaddr),
    .m_axi_awprot(axil_awprot),
    .m_axi_awvalid(axil_awvalid),
    .m_axi_awready(axil_awready),
    .m_axi_wdata(axil_wdata),
    .m_axi_wstrb(axil_wstrb),
    .m_axi_wvalid(axil_wvalid),
    .m_axi_wready(axil_wready),
    .m_axi_bresp(axil_bresp),
    .m_axi_bvalid(axil_bvalid),
    .m_axi_bready(axil_bready),
    .m_axi_araddr(axil_araddr),
    .m_axi_arprot(axil_arprot),
    .m_axi_arvalid(axil_arvalid),
    .m_axi_arready(axil_arready),
    .m_axi_rdata(axil_rdata),
    .m_axi_rresp(axil_rresp),
    .m_axi_rvalid(axil_rvalid),
    .m_axi_rready(axil_rready)
  );

  logic         npu_awvalid, npu_awready, npu_wvalid, npu_wready;
  logic [31:0]  npu_awaddr;
  logic [2:0]   npu_awprot, npu_awsize;
  logic [5:0]   npu_awid;
  logic [7:0]   npu_awlen;
  logic [1:0]   npu_awburst;
  logic         npu_awlock;
  logic [3:0]   npu_awcache, npu_awqos, npu_awregion;
  logic [127:0] npu_wdata;
  logic         npu_wlast;
  logic [15:0]  npu_wstrb;
  logic         npu_bvalid, npu_bready;
  logic [1:0]   npu_bresp;
  logic         npu_arvalid, npu_arready;
  logic [31:0]  npu_araddr;
  logic [2:0]   npu_arprot, npu_arsize;
  logic [5:0]   npu_arid;
  logic [7:0]   npu_arlen;
  logic [1:0]   npu_arburst;
  logic         npu_arlock;
  logic [3:0]   npu_arcache, npu_arqos, npu_arregion;
  logic         npu_rvalid, npu_rready, npu_rlast;
  logic [127:0] npu_rdata;
  logic [1:0]   npu_rresp;

  coralnpu_axil_to_axi OCL_TO_CORAL (
    .clk(clk_hbm_ref), .reset_n(rst_coral_n),
    .s_awaddr(axil_awaddr), .s_awprot(axil_awprot),
    .s_awvalid(axil_awvalid), .s_awready(axil_awready),
    .s_wdata(axil_wdata), .s_wstrb(axil_wstrb),
    .s_wvalid(axil_wvalid), .s_wready(axil_wready),
    .s_bresp(axil_bresp), .s_bvalid(axil_bvalid), .s_bready(axil_bready),
    .s_araddr(axil_araddr), .s_arprot(axil_arprot),
    .s_arvalid(axil_arvalid), .s_arready(axil_arready),
    .s_rdata(axil_rdata), .s_rresp(axil_rresp),
    .s_rvalid(axil_rvalid), .s_rready(axil_rready),
    .m_awvalid(npu_awvalid), .m_awready(npu_awready),
    .m_awaddr(npu_awaddr), .m_awprot(npu_awprot), .m_awid(npu_awid),
    .m_awlen(npu_awlen), .m_awsize(npu_awsize), .m_awburst(npu_awburst),
    .m_awlock(npu_awlock), .m_awcache(npu_awcache), .m_awqos(npu_awqos),
    .m_awregion(npu_awregion), .m_wvalid(npu_wvalid), .m_wready(npu_wready),
    .m_wdata(npu_wdata), .m_wlast(npu_wlast), .m_wstrb(npu_wstrb),
    .m_bvalid(npu_bvalid), .m_bready(npu_bready), .m_bresp(npu_bresp),
    .m_arvalid(npu_arvalid), .m_arready(npu_arready),
    .m_araddr(npu_araddr), .m_arprot(npu_arprot), .m_arid(npu_arid),
    .m_arlen(npu_arlen), .m_arsize(npu_arsize), .m_arburst(npu_arburst),
    .m_arlock(npu_arlock), .m_arcache(npu_arcache), .m_arqos(npu_arqos),
    .m_arregion(npu_arregion), .m_rvalid(npu_rvalid), .m_rready(npu_rready),
    .m_rdata(npu_rdata), .m_rresp(npu_rresp), .m_rlast(npu_rlast)
  );

  RvvCoreMiniAxi CORAL_NPU (
    .io_aclk(clk_hbm_ref),
    .io_aresetn(rst_coral_n),
    .io_axi_slave_write_addr_ready(npu_awready),
    .io_axi_slave_write_addr_valid(npu_awvalid),
    .io_axi_slave_write_addr_bits_addr(npu_awaddr),
    .io_axi_slave_write_addr_bits_prot(npu_awprot),
    .io_axi_slave_write_addr_bits_id(npu_awid),
    .io_axi_slave_write_addr_bits_len(npu_awlen),
    .io_axi_slave_write_addr_bits_size(npu_awsize),
    .io_axi_slave_write_addr_bits_burst(npu_awburst),
    .io_axi_slave_write_addr_bits_lock(npu_awlock),
    .io_axi_slave_write_addr_bits_cache(npu_awcache),
    .io_axi_slave_write_addr_bits_qos(npu_awqos),
    .io_axi_slave_write_addr_bits_region(npu_awregion),
    .io_axi_slave_write_data_ready(npu_wready),
    .io_axi_slave_write_data_valid(npu_wvalid),
    .io_axi_slave_write_data_bits_data(npu_wdata),
    .io_axi_slave_write_data_bits_last(npu_wlast),
    .io_axi_slave_write_data_bits_strb(npu_wstrb),
    .io_axi_slave_write_resp_ready(npu_bready),
    .io_axi_slave_write_resp_valid(npu_bvalid),
    .io_axi_slave_write_resp_bits_id(),
    .io_axi_slave_write_resp_bits_resp(npu_bresp),
    .io_axi_slave_read_addr_ready(npu_arready),
    .io_axi_slave_read_addr_valid(npu_arvalid),
    .io_axi_slave_read_addr_bits_addr(npu_araddr),
    .io_axi_slave_read_addr_bits_prot(npu_arprot),
    .io_axi_slave_read_addr_bits_id(npu_arid),
    .io_axi_slave_read_addr_bits_len(npu_arlen),
    .io_axi_slave_read_addr_bits_size(npu_arsize),
    .io_axi_slave_read_addr_bits_burst(npu_arburst),
    .io_axi_slave_read_addr_bits_lock(npu_arlock),
    .io_axi_slave_read_addr_bits_cache(npu_arcache),
    .io_axi_slave_read_addr_bits_qos(npu_arqos),
    .io_axi_slave_read_addr_bits_region(npu_arregion),
    .io_axi_slave_read_data_ready(npu_rready),
    .io_axi_slave_read_data_valid(npu_rvalid),
    .io_axi_slave_read_data_bits_data(npu_rdata),
    .io_axi_slave_read_data_bits_id(),
    .io_axi_slave_read_data_bits_resp(npu_rresp),
    .io_axi_slave_read_data_bits_last(npu_rlast),

    // Bootstrap CL: reject/hold external-memory requests. Tutorial programs
    // are entirely resident in ITCM/DTCM and never use this interface.
    .io_axi_master_write_addr_ready(1'b0),
    .io_axi_master_write_data_ready(1'b0),
    .io_axi_master_write_resp_valid(1'b0),
    .io_axi_master_write_resp_bits_id(6'b0),
    .io_axi_master_write_resp_bits_resp(2'b11),
    .io_axi_master_read_addr_ready(1'b0),
    .io_axi_master_read_data_valid(1'b0),
    .io_axi_master_read_data_bits_data(128'b0),
    .io_axi_master_read_data_bits_id(6'b0),
    .io_axi_master_read_data_bits_resp(2'b11),
    .io_axi_master_read_data_bits_last(1'b1),

    .io_halted(coral_halted), .io_fault(coral_fault), .io_wfi(coral_wfi),
    .io_irq(1'b0), .io_boot_addr(32'b0), .io_timer_irq(1'b0),
    .io_software_irq(1'b0),
    .io_dm_req_valid(1'b0), .io_dm_req_bits_address(32'b0),
    .io_dm_req_bits_data(32'b0), .io_dm_req_bits_op(2'b0),
    .io_dm_rsp_ready(1'b1), .io_te(1'b0)
  );

endmodule
