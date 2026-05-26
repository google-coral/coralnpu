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
// Package: coralnpu_irq_agent_pkg
// Description: Package for the CoralNPU IRQ Agent components.
//----------------------------------------------------------------------------
package coralnpu_irq_agent_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import transaction_item_pkg::*;

  //--------------------------------------------------------------------------
  // Class: coralnpu_irq_driver
  //--------------------------------------------------------------------------
  class coralnpu_irq_driver extends uvm_driver #(irq_transaction);
    `uvm_component_utils(coralnpu_irq_driver)
    virtual coralnpu_irq_if.TB_IRQ_DRIVER vif;

    function new(string name = "coralnpu_irq_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual coralnpu_irq_if.TB_IRQ_DRIVER)::get(this, "", "vif", vif)) begin
         `uvm_fatal(get_type_name(), "Virtual interface 'vif' not found for TB_IRQ_DRIVER")
      end
    endfunction

    virtual task run_phase(uvm_phase phase);
      forever begin
        @(vif.tb_ctrl_cb);
        seq_item_port.get_next_item(req);
        @(vif.tb_ctrl_cb);
        if (req.drive_irq) begin
          vif.tb_ctrl_cb.irq <= req.irq_level;
          `uvm_info(get_type_name(), $sformatf("Driving irq=%0b", req.irq_level), UVM_LOW)
        end
        if (req.drive_te) begin
          vif.tb_ctrl_cb.te <= req.te_level;
          `uvm_info(get_type_name(), $sformatf("Driving te=%0b", req.te_level), UVM_LOW)
        end
        seq_item_port.item_done();
      end
    endtask
  endclass

  //--------------------------------------------------------------------------
  // Class: coralnpu_irq_sequencer
  //--------------------------------------------------------------------------
  class coralnpu_irq_sequencer extends uvm_sequencer #(irq_transaction);
    `uvm_component_utils(coralnpu_irq_sequencer)
    virtual coralnpu_irq_if.TB_IRQ_DRIVER vif;

    function new(string name = "coralnpu_irq_sequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual coralnpu_irq_if.TB_IRQ_DRIVER)::get(this, "", "vif", vif)) begin
         `uvm_fatal(get_type_name(), "Virtual interface 'vif' not found for coralnpu_irq_sequencer")
      end
    endfunction
  endclass

  //--------------------------------------------------------------------------
  // Class: coralnpu_irq_agent
  //--------------------------------------------------------------------------
  class coralnpu_irq_agent extends uvm_agent;
    `uvm_component_utils(coralnpu_irq_agent)
    coralnpu_irq_driver    driver;
    coralnpu_irq_sequencer sequencer;

    function new(string name = "coralnpu_irq_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = coralnpu_irq_sequencer::type_id::create("sequencer", this);
      driver    = coralnpu_irq_driver::type_id::create("driver", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

endpackage : coralnpu_irq_agent_pkg
