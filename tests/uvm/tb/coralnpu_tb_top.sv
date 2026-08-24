// Copyright 2025 Google LLC
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

//----------------------------------------------------------------------------
// Module: coralnpu_tb_top
// Description: Top-level testbench module for the CoralNPU DUT.
//              Instantiates the DUT, interfaces, and starts the UVM simulation.
//----------------------------------------------------------------------------
module coralnpu_tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Import all necessary UVM packages
  import coralnpu_test_pkg::*;
  import coralnpu_env_pkg::*;
  import transaction_item_pkg::*;
  import coralnpu_axi_master_agent_pkg::*;
  import coralnpu_axi_slave_agent_pkg::*;
  import coralnpu_irq_agent_pkg::*;
  import coralnpu_rvvi_agent_pkg::*;
  import coralnpu_cosim_checker_pkg::*;

  //--------------------------------------------------------------------------
  // Parameters
  //--------------------------------------------------------------------------
  localparam int unsigned AxiAddrWidth = 32;
  localparam int unsigned AxiDataWidth = 128;
  localparam int unsigned AxiIdWidth = 6;
  localparam time ClkPeriod = 10ns;

  //--------------------------------------------------------------------------
  // Clock and Reset Signals
  //--------------------------------------------------------------------------
  bit clk;
  bit resetn;

  //--------------------------------------------------------------------------
  // Interface Instantiations
  //--------------------------------------------------------------------------
  coralnpu_axi_master_if #(
      .AWIDTH (AxiAddrWidth),
      .DWIDTH (AxiDataWidth),
      .IDWIDTH(AxiIdWidth)
  ) master_axi_if (
      .clk(clk),
      .resetn(resetn)
  );

  coralnpu_axi_slave_if #(
      .AWIDTH (AxiAddrWidth),
      .DWIDTH (AxiDataWidth),
      .IDWIDTH(AxiIdWidth)
  ) slave_axi_if (
      .clk(clk),
      .resetn(resetn)
  );

  coralnpu_irq_if irq_if (
      .clk(clk),
      .resetn(resetn)
  );

  typedef virtual rvviTrace #(
      .ILEN  (32),
      .XLEN  (32),
      .FLEN  (32),
      .VLEN  (128),
      .NHART (1),
      .RETIRE(8)
  ) rvvi_trace_vif_t;

  rvvi_trace_vif_t rvvi_vif;


  //--------------------------------------------------------------------------
  // Debug Port Binding Macros for RvvCoreMiniVerificationAxi
  // Collapses ~300 lines of repetitive unconnected debug ports
  //--------------------------------------------------------------------------
  `define DEBUG_RB_VEC_WRITE(lane, vw) \
      .io_debug_rb_inst_``lane``_bits_vecWrites_``vw``_valid(), \
      .io_debug_rb_inst_``lane``_bits_vecWrites_``vw``_bits_data(), \
      .io_debug_rb_inst_``lane``_bits_vecWrites_``vw``_bits_idx()

  `define DEBUG_RB_VEC_WRITES(lane) \
      `DEBUG_RB_VEC_WRITE(lane, 0), \
      `DEBUG_RB_VEC_WRITE(lane, 1), \
      `DEBUG_RB_VEC_WRITE(lane, 2), \
      `DEBUG_RB_VEC_WRITE(lane, 3), \
      `DEBUG_RB_VEC_WRITE(lane, 4), \
      `DEBUG_RB_VEC_WRITE(lane, 5), \
      `DEBUG_RB_VEC_WRITE(lane, 6), \
      `DEBUG_RB_VEC_WRITE(lane, 7)

  `define DEBUG_RB_LANE(lane) \
      .io_debug_rb_inst_``lane``_valid(), \
      .io_debug_rb_inst_``lane``_bits_pc(), \
      .io_debug_rb_inst_``lane``_bits_inst(), \
      .io_debug_rb_inst_``lane``_bits_idx(), \
      .io_debug_rb_inst_``lane``_bits_data(), \
      `DEBUG_RB_VEC_WRITES(lane), \
      .io_debug_rb_inst_``lane``_bits_trap()

  `define DEBUG_RB_ALL_LANES \
      `DEBUG_RB_LANE(0), \
      `DEBUG_RB_LANE(1), \
      `DEBUG_RB_LANE(2), \
      `DEBUG_RB_LANE(3), \
      `DEBUG_RB_LANE(4), \
      `DEBUG_RB_LANE(5), \
      `DEBUG_RB_LANE(6), \
      `DEBUG_RB_LANE(7)

  `define DEBUG_DISPATCH_LANE(n) \
      .io_debug_dispatch_``n``_instFire(), \
      .io_debug_dispatch_``n``_instAddr(), \
      .io_debug_dispatch_``n``_instInst()

  `define DEBUG_REGFILE_WRITE_ADDR(n) \
      .io_debug_regfile_writeAddr_``n``_valid(), \
      .io_debug_regfile_writeAddr_``n``_bits()

  `define DEBUG_REGFILE_WRITE_DATA(n) \
      .io_debug_regfile_writeData_``n``_valid(), \
      .io_debug_regfile_writeData_``n``_bits_addr(), \
      .io_debug_regfile_writeData_``n``_bits_data()

  `define DEBUG_FLOAT_WRITE_DATA(n) \
      .io_debug_float_writeData_``n``_valid(), \
      .io_debug_float_writeData_``n``_bits_addr(), \
      .io_debug_float_writeData_``n``_bits_data()

  `define DEBUG_CORE_PORTS \
      .io_debug_en                             (), \
      .io_debug_addr_0                         (), \
      .io_debug_addr_1                         (), \
      .io_debug_addr_2                         (), \
      .io_debug_addr_3                         (), \
      .io_debug_inst_0                         (), \
      .io_debug_inst_1                         (), \
      .io_debug_inst_2                         (), \
      .io_debug_inst_3                         (), \
      .io_debug_cycles                         (), \
      .io_debug_dbus_valid                     (), \
      .io_debug_dbus_bits_addr                 (), \
      .io_debug_dbus_bits_wdata                (), \
      .io_debug_dbus_bits_write                (), \
      `DEBUG_DISPATCH_LANE(0), \
      `DEBUG_DISPATCH_LANE(1), \
      `DEBUG_DISPATCH_LANE(2), \
      `DEBUG_DISPATCH_LANE(3), \
      `DEBUG_REGFILE_WRITE_ADDR(0), \
      `DEBUG_REGFILE_WRITE_ADDR(1), \
      `DEBUG_REGFILE_WRITE_ADDR(2), \
      `DEBUG_REGFILE_WRITE_ADDR(3), \
      `DEBUG_REGFILE_WRITE_DATA(0), \
      `DEBUG_REGFILE_WRITE_DATA(1), \
      `DEBUG_REGFILE_WRITE_DATA(2), \
      `DEBUG_REGFILE_WRITE_DATA(3), \
      `DEBUG_REGFILE_WRITE_DATA(4), \
      `DEBUG_REGFILE_WRITE_DATA(5), \
      .io_debug_float_writeAddr_valid          (), \
      .io_debug_float_writeAddr_bits           (), \
      `DEBUG_FLOAT_WRITE_DATA(0), \
      `DEBUG_FLOAT_WRITE_DATA(1), \
      `DEBUG_RB_ALL_LANES

  //--------------------------------------------------------------------------
  // DUT Instantiation
  //--------------------------------------------------------------------------
  RvvCoreMiniVerificationAxi u_dut (
      .io_aclk                             (clk),
      .io_aresetn                          (resetn),
      .io_axi_slave_write_addr_ready       (master_axi_if.awready),
      .io_axi_slave_write_addr_valid       (master_axi_if.awvalid),
      .io_axi_slave_write_addr_bits_addr   (master_axi_if.awaddr),
      .io_axi_slave_write_addr_bits_prot   (master_axi_if.awprot),
      .io_axi_slave_write_addr_bits_id     (master_axi_if.awid),
      .io_axi_slave_write_addr_bits_len    (master_axi_if.awlen),
      .io_axi_slave_write_addr_bits_size   (master_axi_if.awsize),
      .io_axi_slave_write_addr_bits_burst  (master_axi_if.awburst),
      .io_axi_slave_write_addr_bits_lock   (master_axi_if.awlock),
      .io_axi_slave_write_addr_bits_cache  (master_axi_if.awcache),
      .io_axi_slave_write_addr_bits_qos    (master_axi_if.awqos),
      .io_axi_slave_write_addr_bits_region (master_axi_if.awregion),
      .io_axi_slave_write_data_ready       (master_axi_if.wready),
      .io_axi_slave_write_data_valid       (master_axi_if.wvalid),
      .io_axi_slave_write_data_bits_data   (master_axi_if.wdata),
      .io_axi_slave_write_data_bits_last   (master_axi_if.wlast),
      .io_axi_slave_write_data_bits_strb   (master_axi_if.wstrb),
      .io_axi_slave_write_resp_ready       (master_axi_if.bready),
      .io_axi_slave_write_resp_valid       (master_axi_if.bvalid),
      .io_axi_slave_write_resp_bits_id     (master_axi_if.bid),
      .io_axi_slave_write_resp_bits_resp   (master_axi_if.bresp),
      .io_axi_slave_read_addr_ready        (master_axi_if.arready),
      .io_axi_slave_read_addr_valid        (master_axi_if.arvalid),
      .io_axi_slave_read_addr_bits_addr    (master_axi_if.araddr),
      .io_axi_slave_read_addr_bits_prot    (master_axi_if.arprot),
      .io_axi_slave_read_addr_bits_id      (master_axi_if.arid),
      .io_axi_slave_read_addr_bits_len     (master_axi_if.arlen),
      .io_axi_slave_read_addr_bits_size    (master_axi_if.arsize),
      .io_axi_slave_read_addr_bits_burst   (master_axi_if.arburst),
      .io_axi_slave_read_addr_bits_lock    (master_axi_if.arlock),
      .io_axi_slave_read_addr_bits_cache   (master_axi_if.arcache),
      .io_axi_slave_read_addr_bits_qos     (master_axi_if.arqos),
      .io_axi_slave_read_addr_bits_region  (master_axi_if.arregion),
      .io_axi_slave_read_data_ready        (master_axi_if.rready),
      .io_axi_slave_read_data_valid        (master_axi_if.rvalid),
      .io_axi_slave_read_data_bits_data    (master_axi_if.rdata),
      .io_axi_slave_read_data_bits_id      (master_axi_if.rid),
      .io_axi_slave_read_data_bits_resp    (master_axi_if.rresp),
      .io_axi_slave_read_data_bits_last    (master_axi_if.rlast),
      .io_axi_master_write_addr_ready      (slave_axi_if.awready),
      .io_axi_master_write_addr_valid      (slave_axi_if.awvalid),
      .io_axi_master_write_addr_bits_addr  (slave_axi_if.awaddr),
      .io_axi_master_write_addr_bits_prot  (slave_axi_if.awprot),
      .io_axi_master_write_addr_bits_id    (slave_axi_if.awid),
      .io_axi_master_write_addr_bits_len   (slave_axi_if.awlen),
      .io_axi_master_write_addr_bits_size  (slave_axi_if.awsize),
      .io_axi_master_write_addr_bits_burst (slave_axi_if.awburst),
      .io_axi_master_write_addr_bits_lock  (slave_axi_if.awlock),
      .io_axi_master_write_addr_bits_cache (slave_axi_if.awcache),
      .io_axi_master_write_addr_bits_qos   (slave_axi_if.awqos),
      .io_axi_master_write_addr_bits_region(slave_axi_if.awregion),
      .io_axi_master_write_data_ready      (slave_axi_if.wready),
      .io_axi_master_write_data_valid      (slave_axi_if.wvalid),
      .io_axi_master_write_data_bits_data  (slave_axi_if.wdata),
      .io_axi_master_write_data_bits_last  (slave_axi_if.wlast),
      .io_axi_master_write_data_bits_strb  (slave_axi_if.wstrb),
      .io_axi_master_write_resp_ready      (slave_axi_if.bready),
      .io_axi_master_write_resp_valid      (slave_axi_if.bvalid),
      .io_axi_master_write_resp_bits_id    (slave_axi_if.bid),
      .io_axi_master_write_resp_bits_resp  (slave_axi_if.bresp),
      .io_axi_master_read_addr_ready       (slave_axi_if.arready),
      .io_axi_master_read_addr_valid       (slave_axi_if.arvalid),
      .io_axi_master_read_addr_bits_addr   (slave_axi_if.araddr),
      .io_axi_master_read_addr_bits_prot   (slave_axi_if.arprot),
      .io_axi_master_read_addr_bits_id     (slave_axi_if.arid),
      .io_axi_master_read_addr_bits_len    (slave_axi_if.arlen),
      .io_axi_master_read_addr_bits_size   (slave_axi_if.arsize),
      .io_axi_master_read_addr_bits_burst  (slave_axi_if.arburst),
      .io_axi_master_read_addr_bits_lock   (slave_axi_if.arlock),
      .io_axi_master_read_addr_bits_cache  (slave_axi_if.arcache),
      .io_axi_master_read_addr_bits_qos    (slave_axi_if.arqos),
      .io_axi_master_read_addr_bits_region (slave_axi_if.arregion),
      .io_axi_master_read_data_ready       (slave_axi_if.rready),
      .io_axi_master_read_data_valid       (slave_axi_if.rvalid),
      .io_axi_master_read_data_bits_data   (slave_axi_if.rdata),
      .io_axi_master_read_data_bits_id     (slave_axi_if.rid),
      .io_axi_master_read_data_bits_resp   (slave_axi_if.rresp),
      .io_axi_master_read_data_bits_last   (slave_axi_if.rlast),
      .io_halted                           (irq_if.halted),
      .io_fault                            (irq_if.fault),
      .io_wfi                              (irq_if.wfi),
      .io_irq                              (irq_if.irq),
      .io_boot_addr                        (32'h0),
      .io_timer_irq                        (1'b0),
      .io_software_irq                     (1'b0),
      `DEBUG_CORE_PORTS,
      .io_dm_req_ready                     (),
      .io_dm_req_valid                     (1'b0),
      .io_dm_req_bits_address              (32'h0),
      .io_dm_req_bits_data                 (32'h0),
      .io_dm_req_bits_op                   (2'b0),
      .io_dm_rsp_ready                     (1'b0),
      .io_dm_rsp_valid                     (),
      .io_dm_rsp_bits_data                 (),
      .io_dm_rsp_bits_op                   (),
      .io_te                               (irq_if.te)
  );

  `undef DEBUG_RB_VEC_WRITE
  `undef DEBUG_RB_VEC_WRITES
  `undef DEBUG_RB_LANE
  `undef DEBUG_RB_ALL_LANES
  `undef DEBUG_DISPATCH_LANE
  `undef DEBUG_REGFILE_WRITE_ADDR
  `undef DEBUG_REGFILE_WRITE_DATA
  `undef DEBUG_FLOAT_WRITE_DATA
  `undef DEBUG_CORE_PORTS


  //--------------------------------------------------------------------------
  // Clock Generation
  //--------------------------------------------------------------------------
  initial begin
    clk = 0;
    forever #(ClkPeriod / 2) clk = ~clk;
  end

  //--------------------------------------------------------------------------
  // Reset Generation and Initial IRQ/TE Driving
  //--------------------------------------------------------------------------
  initial begin
    uvm_event pulse_reset_event;
    pulse_reset_event = new("pulse_reset_event");
    uvm_config_db#(uvm_event)::set(null, "*", "pulse_reset_event", pulse_reset_event);

    // Initialize signals before reset
    irq_if.irq = 1'b0;
    irq_if.te = 1'b0;
    resetn = 1'b0;  // Start in reset

    forever begin
      // Reset Sequence
      resetn = 1'b0;  // Assert reset
      `uvm_info("TB_TOP", "Reset Asserted", UVM_LOW)
      repeat (5) @(posedge clk);
      resetn = 1'b1;  // Deassert reset
      `uvm_info("TB_TOP", "Reset Deasserted", UVM_LOW)
      pulse_reset_event.wait_trigger();
    end
  end

  //--------------------------------------------------------------------------
  // Waveform Dumping
  //--------------------------------------------------------------------------
`ifdef DUMP_WAVES_FSDB
  initial begin
    $fsdbDumpfile($sformatf("./sim_work/waves/%s.fsdb", "coralnpu_base_test"));
    $fsdbDumpvars(0, coralnpu_tb_top, "+mda");
    `uvm_info("TB_TOP", $sformatf(
              "FSDB Waveform Dumping Enabled to: %s",
              $sformatf(
                  "./sim_work/waves/%s.fsdb", "coralnpu_base_test"
              )
              ), UVM_LOW);
  end
`endif
`ifdef DUMP_WAVES_VCD
  initial begin
    $dumpfile($sformatf("./sim_work/waves/%s.vcd", "coralnpu_base_test"));
    $dumpvars(0, coralnpu_tb_top, "+mda");
    `uvm_info("TB_TOP", $sformatf(
              "VCD Waveform Dumping Enabled to: %s",
              $sformatf(
                  "./sim_work/waves/%s.vcd", "coralnpu_base_test"
              )
              ), UVM_LOW);
  end
`endif

  //--------------------------------------------------------------------------
  // ELF Memory Loading and `tohost` Monitor
  //--------------------------------------------------------------------------
  initial begin
    string test_elf;
    string tohost_addr_str;
    logic [31:0] tohost_addr;
    uvm_event tohost_written_event;
    uvm_event test_start_event;

    tohost_written_event = new("tohost_written_event");
    uvm_config_db#(uvm_event)::set(null, "*", "tohost_written_event", tohost_written_event);

    test_start_event = new("test_start_event");
    uvm_config_db#(uvm_event)::set(null, "*", "test_start_event", test_start_event);

    // Get the tohost address from the plusargs
    if ($value$plusargs("TOHOST_ADDR=%s", tohost_addr_str)) begin
      if ($sscanf(
              tohost_addr_str, "'h%h", tohost_addr
          ) != 1 && $sscanf(
              tohost_addr_str, "0x%h", tohost_addr
          ) != 1 && $sscanf(
              tohost_addr_str, "%h", tohost_addr
          ) != 1) begin
        `uvm_fatal("TB_TOP", $sformatf("Invalid +TOHOST_ADDR format: %s", tohost_addr_str))
      end
    end

    // Fork a process that waits for start, then monitors for write
    fork
      forever begin
        test_start_event.wait_trigger();

        // Dynamic tohost update support
        void'(uvm_config_db#(logic [31:0])::get(null, "*", "tohost_addr", tohost_addr));

        forever begin
          @(posedge clk);
          // Check internal data bus (dbus)
          if (u_dut.core.io_dbus_valid && u_dut.core.io_dbus_write &&
              u_dut.core.io_dbus_addr == tohost_addr) begin
            if (u_dut.core.io_dbus_wdata[0] == 1'b1) begin
              `uvm_info("TB_TOP_MONITOR", "tohost write detected on DBUS.", UVM_LOW)
              uvm_config_db#(logic [127:0])::set(null, "*", "final_tohost_data",
                                                 u_dut.core.io_dbus_wdata);
              tohost_written_event.trigger();
              break;  // Stop monitoring for this test
            end
          end

          // Check external bus (ebus)
          if (u_dut.core.io_ebus_dbus_valid && u_dut.core.io_ebus_dbus_ready &&
              u_dut.core.io_ebus_dbus_write && u_dut.core.io_ebus_dbus_addr == tohost_addr) begin
            if (u_dut.core.io_ebus_dbus_wdata[0] == 1'b1) begin
              `uvm_info("TB_TOP_MONITOR", "tohost write detected on EBUS.", UVM_LOW)
              uvm_config_db#(logic [127:0])::set(null, "*", "final_tohost_data",
                                                 u_dut.core.io_ebus_dbus_wdata);
              tohost_written_event.trigger();
              break;  // Stop monitoring for this test
            end
          end

          if (!resetn) break;
        end
      end
    join_none
  end


  //--------------------------------------------------------------------------
  // UVM Test Execution
  //--------------------------------------------------------------------------
  initial begin
    // Assign virtual interface handle procedurally
    rvvi_vif = u_dut.core.score.rvvi.rvviTraceBlackBox.rvvi;

    // Set virtual interfaces in the config_db for the agents/test
    uvm_config_db#(virtual coralnpu_axi_master_if.TB_MASTER_DRIVER)::set(
        null, "*.env.m_master_agent*", "vif", master_axi_if);
    uvm_config_db#(virtual coralnpu_axi_slave_if.TB_SLAVE_MODEL)::set(null, "*.env.m_slave_agent*",
                                                                      "vif", slave_axi_if);
    uvm_config_db#(virtual coralnpu_irq_if.TB_IRQ_DRIVER)::set(null, "*.env.m_irq_agent*", "vif",
                                                               irq_if);
    uvm_config_db#(virtual coralnpu_irq_if.DUT_IRQ_PORT)::set(null, "*", "irq_vif", irq_if);

    uvm_config_db#(rvvi_trace_vif_t)::set(null, "*.env.m_cosim_checker*", "rvvi_vif", rvvi_vif);
    uvm_config_db#(rvvi_trace_vif_t)::set(null, "*.env.m_rvvi_agent*", "rvvi_vif", rvvi_vif);

    uvm_config_db#(time)::set(null, "*", "clk_period", ClkPeriod);

    // Run the test
    run_test();
  end

endmodule
