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
// Package: coralnpu_axi_slave_agent_pkg
// Description: Package for the CoralNPU AXI Slave Agent components.
//----------------------------------------------------------------------------
package coralnpu_axi_slave_agent_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import transaction_item_pkg::*;
  import memory_map_pkg::*;

  //--------------------------------------------------------------------------
  // Class: coralnpu_axi_slave_model
  //--------------------------------------------------------------------------
  class coralnpu_axi_slave_model extends uvm_component;
    `uvm_component_utils(coralnpu_axi_slave_model)
    virtual coralnpu_axi_slave_if.TB_SLAVE_MODEL vif;

    // Memory storage: Sparse array (Address -> Byte)
    logic [7:0] mem[int unsigned];

    function new(string name = "coralnpu_axi_slave_model", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual coralnpu_axi_slave_if.TB_SLAVE_MODEL)::get(
              this, "", "vif", vif
          )) begin
        `uvm_fatal(get_type_name(), "Virtual interface 'vif' not found for TB_SLAVE_MODEL")
      end
    endfunction

    virtual task run_phase(uvm_phase phase);
      drive_defaults();
      forever begin
        drive_defaults();
        mem.delete();

        if (vif.resetn !== 1'b1) begin
          @(posedge vif.resetn);
          @(vif.tb_slave_cb);
        end

        fork
          begin
            handle_writes();
          end
          begin
            handle_reads();
          end
          begin
            @(negedge vif.resetn);
          end
        join_any
        disable fork;

        drive_defaults();
        mem.delete();
      end
    endtask

    protected virtual task drive_defaults();
      vif.tb_slave_cb.awready <= 1'b0;
      vif.tb_slave_cb.wready  <= 1'b0;
      vif.tb_slave_cb.arready <= 1'b0;
      vif.tb_slave_cb.bvalid  <= 1'b0;
      vif.tb_slave_cb.bid     <= '0;
      vif.tb_slave_cb.bresp   <= AXI_OKAY;
      vif.tb_slave_cb.rvalid  <= 1'b0;
      vif.tb_slave_cb.rlast   <= 1'b0;
      vif.tb_slave_cb.rid     <= '0;
      vif.tb_slave_cb.rresp   <= AXI_OKAY;
      vif.tb_slave_cb.rdata   <= '0;
    endtask

    // Slave agent: Handles AXI write transactions.
    protected virtual task handle_writes();
      logic [IDWIDTH-1:0] current_bid;
      axi_resp_e resp;
      logic [31:0] current_addr;
      logic [7:0] current_len;
      logic [2:0] current_size;
      logic [1:0] current_burst;
      int unsigned data_width_bytes;

      data_width_bytes = $bits(vif.tb_slave_cb.wstrb);

      forever begin
        // Wait for write address
        vif.tb_slave_cb.awready <= 1'b0;
        do begin
          @(vif.tb_slave_cb);
          if (vif.resetn === 1'b0) break;
        end while (vif.tb_slave_cb.awvalid !== 1'b1);
        if (vif.resetn === 1'b0) continue;

        current_bid   = vif.tb_slave_cb.awid;
        current_addr  = vif.tb_slave_cb.awaddr;
        current_len   = vif.tb_slave_cb.awlen;
        current_size  = vif.tb_slave_cb.awsize;
        current_burst = vif.tb_slave_cb.awburst;

        `uvm_info(get_type_name(), $sformatf(
                  "Slave Rcvd AW: Addr=0x%h ID=%0d Len=%0d", current_addr, current_bid, current_len
                  ), UVM_HIGH)

        // Address Decoding / Filtering
        if (is_in_itcm(current_addr) || is_in_dtcm(current_addr)) begin
          `uvm_error(get_type_name(),
                     $sformatf("Internal Write Address leaked to External Bus: 0x%h", current_addr))
          resp = AXI_SLVERR;
        end else if (is_in_ext_mem(current_addr)) begin
          // Write to External Memory
          resp = AXI_OKAY;
          `uvm_info(get_type_name(), $sformatf("EXT_MEM: Write Request Addr=0x%h ID=%0d Len=%0d",
                                               current_addr, current_bid, current_len), UVM_MEDIUM)
        end else begin
          `uvm_info(get_type_name(), $sformatf(
                    "External Write Address (Unmapped): 0x%h", current_addr), UVM_HIGH)
          resp = AXI_DECERR;
        end

        vif.tb_slave_cb.awready <= 1'b1;
        @(vif.tb_slave_cb);
        vif.tb_slave_cb.awready <= 1'b0;
        if (vif.resetn === 1'b0) continue;

        // Handle Write Data
        vif.tb_slave_cb.wready <= 1'b0;

        // Loop through all beats in the burst
        for (int i = 0; i <= current_len; i++) begin
          vif.tb_slave_cb.wready <= 1'b1;
          do begin
            @(vif.tb_slave_cb);
            if (vif.resetn === 1'b0) break;
          end while (vif.tb_slave_cb.wvalid !== 1'b1);
          if (vif.resetn === 1'b0) break;

          // Process data if valid address
          if (resp == AXI_OKAY) begin
            logic [31:0] aligned_addr = current_addr & ~(32'(data_width_bytes) - 1);

            if (is_in_ext_mem(aligned_addr)) begin
              `uvm_info(get_type_name(), $sformatf("EXT_MEM: Writing Data [0x%h] = 0x%h",
                                                   aligned_addr, vif.tb_slave_cb.wdata), UVM_HIGH)
            end

            for (int j = 0; j < data_width_bytes; j++) begin
              if (vif.tb_slave_cb.wstrb[j]) begin
                mem[aligned_addr+j] = vif.tb_slave_cb.wdata[8*j+:8];
              end
            end
          end

          vif.tb_slave_cb.wready <= 1'b0;

          // Update address for next beat
          if (current_burst == 1) begin  // INCR
            current_addr += (1 << current_size);
          end
          // FIXED (0) does not change address.
          // WRAP (2) not implemented fully here (treated as FIXED/Manual).
        end
        if (vif.resetn === 1'b0) continue;

        // Send write response
        @(vif.tb_slave_cb);
        if (vif.resetn === 1'b0) continue;
        vif.tb_slave_cb.bvalid <= 1'b1;
        vif.tb_slave_cb.bresp  <= resp;
        vif.tb_slave_cb.bid    <= current_bid;

        do begin
          @(vif.tb_slave_cb);
          if (vif.resetn === 1'b0) break;
        end while (!vif.tb_slave_cb.bready);
        if (vif.resetn === 1'b0) continue;

        // Handshake happened at this cycle.
        vif.tb_slave_cb.bvalid <= 1'b0;
        `uvm_info(get_type_name(), $sformatf("Slave Sent BResp %s ID=%0d", resp.name(), current_bid
                  ), UVM_HIGH)
      end
    endtask

    // Slave agent: Handles AXI read transactions.
    protected virtual task handle_reads();
      logic [IDWIDTH-1:0] current_rid;
      logic [7:0] current_len;
      logic [31:0] current_addr;
      logic [2:0] current_size;
      logic [1:0] current_burst;
      axi_resp_e r_resp_val;
      int unsigned data_width_bytes;

      data_width_bytes = $bits(vif.tb_slave_cb.wstrb);  // wstrb size is same as bytes in data

      forever begin
        // Wait for read address
        vif.tb_slave_cb.arready <= 1'b0;
        do begin
          @(vif.tb_slave_cb);
          if (vif.resetn === 1'b0) break;
        end while (vif.tb_slave_cb.arvalid !== 1'b1);
        if (vif.resetn === 1'b0) continue;

        current_rid   = vif.tb_slave_cb.arid;
        current_len   = vif.tb_slave_cb.arlen;
        current_addr  = vif.tb_slave_cb.araddr;
        current_size  = vif.tb_slave_cb.arsize;
        current_burst = vif.tb_slave_cb.arburst;

        if (is_in_itcm(current_addr) || is_in_dtcm(current_addr)) begin
          `uvm_error(get_type_name(),
                     $sformatf("Internal Read Address leaked to External Bus: 0x%h", current_addr))
          r_resp_val = AXI_SLVERR;
        end else if (is_in_ext_mem(current_addr)) begin
          r_resp_val = AXI_OKAY;
          `uvm_info(get_type_name(), $sformatf("EXT_MEM: Read Request Addr=0x%h ID=%0d Len=%0d",
                                               current_addr, current_rid, current_len), UVM_MEDIUM)
        end else begin
          `uvm_info(get_type_name(), $sformatf(
                    "External Read Address (Unmapped): 0x%h", current_addr), UVM_HIGH)
          r_resp_val = AXI_DECERR;
        end

        vif.tb_slave_cb.arready <= 1'b1;
        @(vif.tb_slave_cb);
        vif.tb_slave_cb.arready <= 1'b0;
        if (vif.resetn === 1'b0) continue;

        // Send Read Response (Burst)
        for (int i = 0; i <= current_len; i++) begin
          vif.tb_slave_cb.rvalid <= 1'b1;
          vif.tb_slave_cb.rresp  <= r_resp_val;

          // Prepare Read Data
          if (r_resp_val == AXI_OKAY) begin
            logic [DWIDTH-1:0] rdata_tmp = '0;
            logic [31:0] aligned_addr = current_addr & ~(32'(data_width_bytes) - 1);

            for (int j = 0; j < data_width_bytes; j++) begin
              if (mem.exists(aligned_addr + j)) begin
                rdata_tmp[8*j+:8] = mem[aligned_addr+j];
              end else begin
                rdata_tmp[8*j+:8] = 8'h00;  // Return 0 for uninitialized
              end
            end
            vif.tb_slave_cb.rdata <= rdata_tmp;

            if (is_in_ext_mem(aligned_addr)) begin
              `uvm_info(get_type_name(), $sformatf("EXT_MEM: Reading Data [0x%h] = 0x%h",
                                                   aligned_addr, rdata_tmp), UVM_HIGH)
            end
          end else begin
            vif.tb_slave_cb.rdata <= '0;
          end

          vif.tb_slave_cb.rid <= current_rid;

          if (i == current_len) vif.tb_slave_cb.rlast <= 1'b1;
          else vif.tb_slave_cb.rlast <= 1'b0;

          do begin
            @(vif.tb_slave_cb);
            if (vif.resetn === 1'b0) break;
          end while (!vif.tb_slave_cb.rready);
          if (vif.resetn === 1'b0) break;

          // Update address for next beat
          if (current_burst == 1) begin  // INCR
            current_addr += (1 << current_size);
          end
        end
        if (vif.resetn === 1'b0) continue;

        // Handshake for last beat finished.
        vif.tb_slave_cb.rvalid <= 1'b0;
        vif.tb_slave_cb.rlast  <= 1'b0;

        `uvm_info(get_type_name(), $sformatf(
                  "Slave Sent RData %s ID=%0d Len=%0d", r_resp_val.name(), current_rid, current_len
                  ), UVM_HIGH)
      end
    endtask
  endclass

  //--------------------------------------------------------------------------
  // Class: coralnpu_axi_slave_agent
  //--------------------------------------------------------------------------
  class coralnpu_axi_slave_agent extends uvm_agent;
    `uvm_component_utils(coralnpu_axi_slave_agent)
    coralnpu_axi_slave_model slave_model;

    function new(string name = "coralnpu_axi_slave_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      slave_model = coralnpu_axi_slave_model::type_id::create("slave_model", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
    endfunction
  endclass

endpackage : coralnpu_axi_slave_agent_pkg
