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
// Package: coralnpu_axi_master_agent_pkg
// Description: Package to create an AXI Master Agent that drives the CoralNPU
//              Slave interface
//----------------------------------------------------------------------------
package coralnpu_axi_master_agent_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import transaction_item_pkg::*;  // Import transaction definitions

  //--------------------------------------------------------------------------
  // Class: coralnpu_axi_master_driver
  //--------------------------------------------------------------------------
  class coralnpu_axi_master_driver extends uvm_driver #(axi_transaction);
    `uvm_component_utils(coralnpu_axi_master_driver)
    virtual coralnpu_axi_master_if.TB_MASTER_DRIVER vif;

    function new(string name = "coralnpu_axi_master_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual coralnpu_axi_master_if.TB_MASTER_DRIVER)::get(
              this, "", "vif", vif
          )) begin
        `uvm_fatal(get_type_name(), "Virtual interface 'vif' not found for TB_MASTER_DRIVER")
      end
    endfunction

    virtual task run_phase(uvm_phase phase);
      `uvm_info(get_type_name(), "Run phase started", UVM_MEDIUM)
      drive_defaults();

      fork
        // Response handlers with reset recovery
        forever begin
          drive_defaults();
          if (vif.resetn !== 1'b1) begin
            @(posedge vif.resetn);
            @(vif.tb_master_cb);
          end

          fork
            begin
              handle_b_channel();
            end
            begin
              handle_r_channel();
            end
            begin
              @(negedge vif.resetn);
            end
          join_any
          disable fork;
          drive_defaults();
        end

        // Main sequence item driver
        forever begin
          seq_item_port.get_next_item(req);
          `uvm_info(get_type_name(), $sformatf("Got transaction: %s", req.sprint()), UVM_LOW)
          if (vif.resetn === 1'b1) begin
            if (req.txn_type == AXI_WRITE) begin
              do_write(req);
            end else if (req.txn_type == AXI_READ) begin
              do_read(req);
            end else begin
              `uvm_warning(get_type_name(), $sformatf(
                           "Unsupported txn_type: %s", req.txn_type.name()))
            end
          end
          seq_item_port.item_done();
          `uvm_info(get_type_name(), "Transaction item_done() called", UVM_LOW)
        end
      join
    endtask

    // Task to drive default/idle values on outputs
    protected virtual task drive_defaults();
      @(vif.tb_master_cb);
      vif.tb_master_cb.awvalid  <= 1'b0;
      vif.tb_master_cb.awid     <= '0;
      vif.tb_master_cb.awaddr   <= '0;
      vif.tb_master_cb.awlen    <= '0;
      vif.tb_master_cb.awsize   <= '0;
      vif.tb_master_cb.awburst  <= '0;
      vif.tb_master_cb.awlock   <= '0;
      vif.tb_master_cb.awcache  <= '0;
      vif.tb_master_cb.awprot   <= '0;
      vif.tb_master_cb.awqos    <= '0;
      vif.tb_master_cb.awregion <= '0;
      vif.tb_master_cb.wvalid   <= 1'b0;
      vif.tb_master_cb.wdata    <= '0;
      vif.tb_master_cb.wstrb    <= '0;
      vif.tb_master_cb.wlast    <= 1'b0;
      vif.tb_master_cb.arvalid  <= 1'b0;
      vif.tb_master_cb.arid     <= '0;
      vif.tb_master_cb.araddr   <= '0;
      vif.tb_master_cb.arlen    <= '0;
      vif.tb_master_cb.arsize   <= '0;
      vif.tb_master_cb.arburst  <= '0;
      vif.tb_master_cb.arlock   <= '0;
      vif.tb_master_cb.arcache  <= '0;
      vif.tb_master_cb.arprot   <= '0;
      vif.tb_master_cb.arqos    <= '0;
      vif.tb_master_cb.arregion <= '0;
      vif.tb_master_cb.bready   <= 1'b0;  // Initialize ready low
      vif.tb_master_cb.rready   <= 1'b0;  // Initialize ready low
    endtask

    // Task to drive AXI write transaction
    protected virtual task do_write(input axi_transaction req);
      int unsigned beat_count = 0;
      int unsigned num_beats = req.len + 1;
      `uvm_info(get_type_name(), $sformatf("Starting WRITE: Addr=0x%h, Len=%0d, ID=%0d", req.addr,
                                           req.len, req.id), UVM_MEDIUM)

      // --- 1. Drive Write Address Channel ---
      @(vif.tb_master_cb);
      if (vif.resetn === 1'b0) return;
      vif.tb_master_cb.awvalid <= 1'b1;
      vif.tb_master_cb.awid    <= req.id;
      vif.tb_master_cb.awaddr  <= req.addr;
      vif.tb_master_cb.awlen   <= req.len;
      vif.tb_master_cb.awsize  <= req.size;
      vif.tb_master_cb.awburst <= req.burst;
      vif.tb_master_cb.awlock  <= req.lock;
      vif.tb_master_cb.awcache <= req.cache;
      vif.tb_master_cb.awprot  <= req.prot;
      vif.tb_master_cb.awqos   <= req.qos;
      vif.tb_master_cb.awregion <= req.region;
      do begin
        @(vif.tb_master_cb);
        if (vif.resetn === 1'b0) begin
          vif.tb_master_cb.awvalid <= 1'b0;
          return;
        end
      end while (!vif.tb_master_cb.awready);
      vif.tb_master_cb.awvalid <= 1'b0;
      `uvm_info(get_type_name(), "AW Handshake complete", UVM_HIGH)

      // --- 2. Drive Write Data Channel ---
      for (beat_count = 0; beat_count < num_beats; beat_count++) begin
        @(vif.tb_master_cb);
        if (vif.resetn === 1'b0) return;
        vif.tb_master_cb.wvalid <= 1'b1;
        if (beat_count < req.data.size()) vif.tb_master_cb.wdata <= req.data[beat_count];
        else
          `uvm_error(get_type_name(), $sformatf("Data queue underflow for beat %0d!", beat_count))
        if (beat_count < req.strb.size()) vif.tb_master_cb.wstrb <= req.strb[beat_count];
        else
          `uvm_error(get_type_name(), $sformatf("Strobe queue underflow for beat %0d!", beat_count))
        vif.tb_master_cb.wlast <= (beat_count == req.len);
        do begin
          @(vif.tb_master_cb);
          if (vif.resetn === 1'b0) begin
            vif.tb_master_cb.wvalid <= 1'b0;
            vif.tb_master_cb.wlast  <= 1'b0;
            return;
          end
        end while (!vif.tb_master_cb.wready);
        `uvm_info(get_type_name(), $sformatf("W Handshake complete for beat %0d", beat_count),
                  UVM_HIGH)
      end
      vif.tb_master_cb.wvalid <= 1'b0;
      vif.tb_master_cb.wlast  <= 1'b0;
      `uvm_info(get_type_name(), "W channel driving complete", UVM_MEDIUM)

      `uvm_info(get_type_name(), $sformatf("Finished WRITE Request: Addr=0x%h, Len=%0d, ID=%0d",
                                           req.addr, req.len, req.id), UVM_MEDIUM)
    endtask

    // Task to drive AXI read transaction
    protected virtual task do_read(input axi_transaction req);
      `uvm_info(get_type_name(), $sformatf("Starting READ: Addr=0x%h, Len=%0d, ID=%0d", req.addr,
                                           req.len, req.id), UVM_MEDIUM)

      // --- 1. Drive Read Address Channel ---
      @(vif.tb_master_cb);
      if (vif.resetn === 1'b0) return;
      vif.tb_master_cb.arvalid <= 1'b1;
      vif.tb_master_cb.arid    <= req.id;
      vif.tb_master_cb.araddr  <= req.addr;
      vif.tb_master_cb.arlen   <= req.len;
      vif.tb_master_cb.arsize  <= req.size;
      vif.tb_master_cb.arburst <= req.burst;
      vif.tb_master_cb.arlock  <= req.lock;
      vif.tb_master_cb.arcache <= req.cache;
      vif.tb_master_cb.arprot  <= req.prot;
      vif.tb_master_cb.arqos   <= req.qos;
      vif.tb_master_cb.arregion <= req.region;
      do begin
        @(vif.tb_master_cb);
        if (vif.resetn === 1'b0) begin
          vif.tb_master_cb.arvalid <= 1'b0;
          return;
        end
      end while (!vif.tb_master_cb.arready);
      vif.tb_master_cb.arvalid <= 1'b0;
      `uvm_info(get_type_name(), "AR Handshake complete", UVM_HIGH)

      `uvm_info(get_type_name(), $sformatf("Finished READ Request: Addr=0x%h, Len=%0d, ID=%0d",
                                           req.addr, req.len, req.id), UVM_MEDIUM)
    endtask

    // Task to handle B channel responses
    protected virtual task handle_b_channel();
      logic [IDWIDTH-1:0] received_bid;
      logic [        1:0] received_bresp;
      forever begin
        vif.tb_master_cb.bready <= 1'b0;  // Default to not ready
        do begin
          @(vif.tb_master_cb);
          if (vif.resetn === 1'b0) break;
        end while (vif.tb_master_cb.bvalid !== 1'b1);
        if (vif.resetn === 1'b0) continue;

        received_bid   = vif.tb_master_cb.bid;
        received_bresp = vif.tb_master_cb.bresp;
        `uvm_info(get_type_name(), $sformatf(
                  "B Channel Rcvd: ID=%0d RESP=%b", received_bid, received_bresp), UVM_HIGH)
        // Always accept the response in this simple model
        // TODO: Randomize ready signal with latency
        vif.tb_master_cb.bready <= 1'b1;
        @(vif.tb_master_cb);  // Wait one cycle for handshake
        vif.tb_master_cb.bready <= 1'b0;  // Deassert ready
        `uvm_info(get_type_name(), $sformatf("B Channel Accepted: ID=%0d", received_bid), UVM_HIGH)
      end
    endtask : handle_b_channel

    // Task to handle R channel responses
    protected virtual task handle_r_channel();
      logic [IDWIDTH-1:0] received_rid;
      logic [        1:0] received_rresp;
      logic [ DWIDTH-1:0] received_rdata;
      logic               received_rlast;
      forever begin
        vif.tb_master_cb.rready <= 1'b0;  // Default to not ready
        do begin
          @(vif.tb_master_cb);
          if (vif.resetn === 1'b0) break;
        end while (vif.tb_master_cb.rvalid !== 1'b1);
        if (vif.resetn === 1'b0) continue;

        received_rid   = vif.tb_master_cb.rid;
        received_rresp = vif.tb_master_cb.rresp;
        received_rdata = vif.tb_master_cb.rdata;
        received_rlast = vif.tb_master_cb.rlast;
        `uvm_info(get_type_name(), $sformatf(
                  "R Channel Rcvd: ID=%0d RESP=%b LAST=%b DATA=0x%h",
                  received_rid,
                  received_rresp,
                  received_rlast,
                  received_rdata
                  ), UVM_HIGH)
        // Always accept the data/response in this simple model
        vif.tb_master_cb.rready <= 1'b1;
        @(vif.tb_master_cb);  // Wait one cycle for handshake
        vif.tb_master_cb.rready <= 1'b0;  // Deassert ready
        `uvm_info(get_type_name(), $sformatf(
                  "R Channel Accepted: ID=%0d LAST=%b", received_rid, received_rlast), UVM_HIGH)
        // TODO: For bursts, need to loop until RLAST is seen for a given ID
      end
    endtask : handle_r_channel

  endclass : coralnpu_axi_master_driver

  //--------------------------------------------------------------------------
  // Class: coralnpu_axi_master_sequencer
  //--------------------------------------------------------------------------
  typedef uvm_sequencer#(axi_transaction) coralnpu_axi_master_sequencer;

  //--------------------------------------------------------------------------
  // Class: coralnpu_axi_master_agent
  //--------------------------------------------------------------------------
  class coralnpu_axi_master_agent extends uvm_agent;
    `uvm_component_utils(coralnpu_axi_master_agent)
    coralnpu_axi_master_driver    driver;
    coralnpu_axi_master_sequencer sequencer;

    function new(string name = "coralnpu_axi_master_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = coralnpu_axi_master_sequencer::type_id::create("sequencer", this);
      driver    = coralnpu_axi_master_driver::type_id::create("driver", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

endpackage : coralnpu_axi_master_agent_pkg
