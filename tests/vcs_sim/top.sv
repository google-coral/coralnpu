// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`timescale 1ns / 1ps

module top;
  reg clk = 0;
  reg resetn = 0;
  wire [31:0] boot_addr = 32'h0;
  wire te = 1'b0;
  wire irq = 1'b0;
  wire timer_irq = 1'b0;
  wire software_irq = 1'b0;

  wire halted;
  wire fault;
  wire wfi;

  // AXI Slave Interface (tied off)
  wire slave_awready;
  wire slave_wready;
  wire slave_bvalid;
  wire [5:0] slave_bid;
  wire [1:0] slave_bresp;
  wire slave_arready;
  wire slave_rvalid;
  wire [127:0] slave_rdata;
  wire [5:0] slave_rid;
  wire [1:0] slave_rresp;
  wire slave_rlast;

  // AXI Master Interface (Mailbox Loopback!)
  wire master_awvalid;
  wire [31:0] master_awaddr;
  wire [5:0] master_awid;
  wire [7:0] master_awlen;
  wire [2:0] master_awsize;
  wire [2:0] master_awprot;
  wire [1:0] master_awburst;
  wire master_awlock;
  wire [3:0] master_awcache;
  wire [3:0] master_awqos;
  wire [3:0] master_awregion;
  wire master_awready;

  wire master_wvalid;
  wire [127:0] master_wdata;
  wire master_wlast;
  wire [15:0] master_wstrb;
  wire master_wready;

  wire master_bvalid;
  wire [5:0] master_bid;
  wire [1:0] master_bresp;
  wire master_bready;

  wire master_arvalid;
  wire [31:0] master_araddr;
  wire [5:0] master_arid;
  wire [7:0] master_arlen;
  wire [2:0] master_arsize;
  wire [2:0] master_arprot;
  wire [1:0] master_arburst;
  wire master_arlock;
  wire [3:0] master_arcache;
  wire [3:0] master_arqos;
  wire [3:0] master_arregion;
  wire master_arready;

  wire master_rvalid;
  wire [127:0] master_rdata;
  wire [5:0] master_rid;
  wire [1:0] master_rresp;
  wire master_rlast;
  wire master_rready;

  // Instantiation of the DUT
  `DUT_MODULE dut (
      .io_aclk(clk),
      .io_aresetn(resetn),
      .io_boot_addr(boot_addr),
      .io_te(te),
      .io_irq(irq),
      .io_timer_irq(timer_irq),
      .io_software_irq(software_irq),
      .io_halted(halted),
      .io_fault(fault),
      .io_wfi(wfi),

      // Slave AXI (tied off)
      .io_axi_slave_write_addr_ready(slave_awready),
      .io_axi_slave_write_addr_valid(1'b0),
      .io_axi_slave_write_addr_bits_addr(32'h0),
      .io_axi_slave_write_addr_bits_prot(3'h0),
      .io_axi_slave_write_addr_bits_id(6'h0),
      .io_axi_slave_write_addr_bits_len(8'h0),
      .io_axi_slave_write_addr_bits_size(3'h0),
      .io_axi_slave_write_addr_bits_burst(2'h0),
      .io_axi_slave_write_addr_bits_lock(1'b0),
      .io_axi_slave_write_addr_bits_cache(4'h0),
      .io_axi_slave_write_addr_bits_qos(4'h0),
      .io_axi_slave_write_addr_bits_region(4'h0),
      .io_axi_slave_write_data_ready(slave_wready),
      .io_axi_slave_write_data_valid(1'b0),
      .io_axi_slave_write_data_bits_data(128'h0),
      .io_axi_slave_write_data_bits_last(1'b0),
      .io_axi_slave_write_data_bits_strb(16'h0),
      .io_axi_slave_write_resp_ready(1'b0),
      .io_axi_slave_write_resp_valid(slave_bvalid),
      .io_axi_slave_write_resp_bits_id(slave_bid),
      .io_axi_slave_write_resp_bits_resp(slave_bresp),
      .io_axi_slave_read_addr_ready(slave_arready),
      .io_axi_slave_read_addr_valid(1'b0),
      .io_axi_slave_read_addr_bits_addr(32'h0),
      .io_axi_slave_read_addr_bits_prot(3'h0),
      .io_axi_slave_read_addr_bits_id(6'h0),
      .io_axi_slave_read_addr_bits_len(8'h0),
      .io_axi_slave_read_addr_bits_size(3'h0),
      .io_axi_slave_read_addr_bits_burst(2'h0),
      .io_axi_slave_read_addr_bits_lock(1'b0),
      .io_axi_slave_read_addr_bits_cache(4'h0),
      .io_axi_slave_read_addr_bits_qos(4'h0),
      .io_axi_slave_read_addr_bits_region(4'h0),
      .io_axi_slave_read_data_ready(1'b0),
      .io_axi_slave_read_data_valid(slave_rvalid),
      .io_axi_slave_read_data_bits_data(slave_rdata),
      .io_axi_slave_read_data_bits_id(slave_rid),
      .io_axi_slave_read_data_bits_resp(slave_rresp),
      .io_axi_slave_read_data_bits_last(slave_rlast),

      // Master AXI
      .io_axi_master_write_addr_ready(master_awready),
      .io_axi_master_write_addr_valid(master_awvalid),
      .io_axi_master_write_addr_bits_addr(master_awaddr),
      .io_axi_master_write_addr_bits_prot(master_awprot),
      .io_axi_master_write_addr_bits_id(master_awid),
      .io_axi_master_write_addr_bits_len(master_awlen),
      .io_axi_master_write_addr_bits_size(master_awsize),
      .io_axi_master_write_addr_bits_burst(master_awburst),
      .io_axi_master_write_addr_bits_lock(master_awlock),
      .io_axi_master_write_addr_bits_cache(master_awcache),
      .io_axi_master_write_addr_bits_qos(master_awqos),
      .io_axi_master_write_addr_bits_region(master_awregion),
      .io_axi_master_write_data_ready(master_wready),
      .io_axi_master_write_data_valid(master_wvalid),
      .io_axi_master_write_data_bits_data(master_wdata),
      .io_axi_master_write_data_bits_last(master_wlast),
      .io_axi_master_write_data_bits_strb(master_wstrb),
      .io_axi_master_write_resp_ready(master_bready),
      .io_axi_master_write_resp_valid(master_bvalid),
      .io_axi_master_write_resp_bits_id(master_bid),
      .io_axi_master_write_resp_bits_resp(master_bresp),
      .io_axi_master_read_addr_ready(master_arready),
      .io_axi_master_read_addr_valid(master_arvalid),
      .io_axi_master_read_addr_bits_addr(master_araddr),
      .io_axi_master_read_addr_bits_prot(master_arprot),
      .io_axi_master_read_addr_bits_id(master_arid),
      .io_axi_master_read_addr_bits_len(master_arlen),
      .io_axi_master_read_addr_bits_size(master_arsize),
      .io_axi_master_read_addr_bits_burst(master_arburst),
      .io_axi_master_read_addr_bits_lock(master_arlock),
      .io_axi_master_read_addr_bits_cache(master_arcache),
      .io_axi_master_read_addr_bits_qos(master_arqos),
      .io_axi_master_read_addr_bits_region(master_arregion),
      .io_axi_master_read_data_ready(master_rready),
      .io_axi_master_read_data_valid(master_rvalid),
      .io_axi_master_read_data_bits_data(master_rdata),
      .io_axi_master_read_data_bits_id(master_rid),
      .io_axi_master_read_data_bits_resp(master_rresp),
      .io_axi_master_read_data_bits_last(master_rlast),

      // Debug module (tied off)
      .io_dm_req_ready(),
      .io_dm_req_valid(1'b0),
      .io_dm_req_bits_address(32'h0),
      .io_dm_req_bits_data(32'h0),
      .io_dm_req_bits_op(2'b0),
      .io_dm_rsp_ready(1'b0),
      .io_dm_rsp_valid(),
      .io_dm_rsp_bits_data(),
      .io_dm_rsp_bits_op()
  );

  // Clock generator
  always #5 clk = ~clk;

  // Dynamic Mailbox Loopback logic!
  reg [127:0] mailbox = 128'h0;

  // Write channel handling
  assign master_awready = 1'b1;
  assign master_wready  = 1'b1;

  reg bvalid_reg = 0;
  reg [5:0] bid_reg = 0;
  assign master_bvalid = bvalid_reg;
  assign master_bid = bid_reg;
  assign master_bresp = 2'b00;

  always @(posedge clk) begin
    if (master_awvalid && master_wvalid) begin
      for (int i = 0; i < 16; i++) begin
        if (master_wstrb[i]) begin
          mailbox[i*8+:8] <= master_wdata[i*8+:8];
        end
      end
      bvalid_reg <= 1'b1;
      bid_reg <= master_awid;
    end else if (master_bready) begin
      bvalid_reg <= 1'b0;
    end
  end

  // Read channel handling
  reg rvalid_reg = 0;
  reg [5:0] rid_reg = 0;
  assign master_arready = 1'b1;
  assign master_rvalid = rvalid_reg;
  assign master_rdata = mailbox;
  assign master_rid = rid_reg;
  assign master_rresp = 2'b00;
  assign master_rlast = 1'b1;

  always @(posedge clk) begin
    if (master_arvalid) begin
      rvalid_reg <= 1'b1;
      rid_reg <= master_arid;
    end else if (master_rready) begin
      rvalid_reg <= 1'b0;
    end
  end

  // DPI-C ELF loader declaration!
  import "DPI-C" function void sram_load_elf(input string filepath);

  string binary_path;
  int fd_check;

  initial begin
    if ($value$plusargs("binary=%s", binary_path)) begin
      // Proceed
    end else begin
      $display("Error: Must specify +binary=<elf_file>");
      $finish;
    end

    // Verify ELF file exists and is readable!
    fd_check = $fopen(binary_path, "r");
    if (fd_check == 0) begin
      $display("Error: Failed to open ELF file: %s", binary_path);
      $finish;
    end
    $fclose(fd_check);

    // Hold reset active
    resetn = 0;
    #100;

    // Backdoor load ELF
    sram_load_elf(binary_path);

    // Release reset
    #20;
    dut.csr.resetReg = 32'h0;  // Backdoor release internal CSR reset and un-gate clock!
    resetn = 1;
  end

  int cycles_limit = 100000000;  // Default limit is 100M cycles!
  initial begin
    if ($value$plusargs("cycles=%d", cycles_limit)) begin
      // Override dynamically!
    end
  end

  int clk_ticks = 0;
  always @(posedge clk) begin
    clk_ticks <= clk_ticks + 1;
  end

  // Completion evaluation
  always @(posedge clk) begin
    if (halted || wfi) begin
      $display("Simulator halted successfully.");
      $finish;
    end
    if (fault) begin
      $display("Error: Simulator hit a fault condition.");
      $finish;
    end
    // Infinite loop / hang protection timeout
    if (cycles_limit >= 0 && clk_ticks >= cycles_limit) begin
      $display("Error: Simulation timed out / exceeded cycles limit of %0d.", cycles_limit);
      $finish;
    end
  end
endmodule
