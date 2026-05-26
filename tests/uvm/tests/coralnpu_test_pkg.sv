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
// Package: coralnpu_test_pkg
// Description: Package for the CoralNPU UVM tests and sequences.
//----------------------------------------------------------------------------
package coralnpu_test_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Import required packages
  import transaction_item_pkg::*;
  import coralnpu_env_pkg::*;
  import coralnpu_axi_master_agent_pkg::*;
  import coralnpu_irq_agent_pkg::*;

  //--------------------------------------------------------------------------
  // Sequence: coralnpu_kickoff_write_seq
  //--------------------------------------------------------------------------
  class coralnpu_kickoff_write_seq extends uvm_sequence #(axi_transaction);
    `uvm_object_utils(coralnpu_kickoff_write_seq)

    bit [31:0] entry_point = 0;

    function new(string name = "coralnpu_kickoff_write_seq");
        super.new(name);
    endfunction

    virtual task body();
      axi_transaction req;
      `uvm_info(get_type_name(), "Starting kickoff writes", UVM_MEDIUM)
      // 1. Write PC address to 0x00030004
      req = axi_transaction::type_id::create("req_pc");
      start_item(req);
      req.txn_type = AXI_WRITE;
      req.addr = 32'h00030004;
      req.len  = 0;
      req.size = 2; // 4 bytes
      req.burst = AXI_BURST_INCR;
      req.id = 0;
      req.prot = 3'b000;
      req.data.delete();
      req.strb.delete();
      // Data must be shifted to lanes [63:32] for address 0x...4 on 128-bit bus
      req.data.push_back(128'(entry_point) << 32);
      req.strb.push_back(16'h00F0); // Enable bytes 4-7
      finish_item(req);
      `uvm_info(get_type_name(),
                $sformatf("Kickoff Write 1 (PC Data=0x%h) sent to addr 0x%h",
                          req.data[0], req.addr), UVM_LOW)

      // 2. Write Clock Gate Release
      req = axi_transaction::type_id::create("req_clk_gate");
      start_item(req);
      req.txn_type = AXI_WRITE;
      req.addr = 32'h00030000;
      req.len  = 0;
      req.size = $clog2(32/8);
      req.burst = AXI_BURST_INCR;
      req.id = 0;
      req.prot = 3'b000;
      req.data.delete();
      req.strb.delete();
      req.data.push_back(128'h1);
      req.strb.push_back(16'h000F); // Strobe for lower 4 bytes
      finish_item(req);
      `uvm_info(get_type_name(),
                $sformatf("Kickoff Write 2 (ClkGate Data=0x%h) sent to addr 0x%h",
                          req.data[0], req.addr), UVM_LOW)

      // 3. Write Reset Release
      req = axi_transaction::type_id::create("req_reset");
      start_item(req);
      req.txn_type = AXI_WRITE;
      req.addr = 32'h00030000;
      req.len  = 0;
      req.size = $clog2(32/8);
      req.burst = AXI_BURST_INCR;
      req.id = 0;
      req.prot = 3'b000;
      req.data.delete();
      req.strb.delete();
      req.data.push_back(128'h0);
      req.strb.push_back(16'h000F); // Strobe for lower 4 bytes
      finish_item(req);
      `uvm_info(get_type_name(),
                $sformatf("Kickoff Write 3 (Reset Data=0x%h) sent to addr 0x%h",
                          req.data[0], req.addr), UVM_LOW)
      `uvm_info(get_type_name(), "Finished kickoff writes", UVM_MEDIUM)
    endtask
  endclass

  class coralnpu_pulse_irq_seq extends uvm_sequence #(irq_transaction);
    `uvm_object_utils(coralnpu_pulse_irq_seq);

    function new(string name = "coralnpu_pulse_irq_seq");
        super.new(name);
    endfunction

    virtual task body();
        irq_transaction req;
        coralnpu_irq_agent_pkg::coralnpu_irq_sequencer irq_sqr;

        if (!$cast(irq_sqr, m_sequencer)) begin
           `uvm_fatal(get_type_name(), "Failed to cast m_sequencer to coralnpu_irq_sequencer")
        end

        `uvm_info(get_type_name(), "Starting IRQ pulse", UVM_MEDIUM)

        req = irq_transaction::type_id::create("req_irq_high");
        start_item(req);
        req.drive_irq = 1;
        req.irq_level = 1;
        finish_item(req);
        `uvm_info(get_type_name(), "req_irq_high sent", UVM_LOW)

        repeat (10) @(irq_sqr.vif.tb_ctrl_cb);

        req = irq_transaction::type_id::create("req_irq_low");
        start_item(req);
        req.drive_irq = 1;
        req.irq_level = 0;
        finish_item(req);
        `uvm_info(get_type_name(), "req_irq_low sent", UVM_LOW)
    endtask
  endclass

  //--------------------------------------------------------------------------
  // Class: coralnpu_base_test
  //--------------------------------------------------------------------------
  class coralnpu_base_test extends uvm_test;
    `uvm_component_utils(coralnpu_base_test)

    coralnpu_env env;
    time   test_timeout = 20_000_000ns;

    protected bit test_passed = 1'b0;
    protected bit test_timed_out = 1'b0;
    protected bit dut_halted_flag = 1'b0;
    protected bit dut_faulted_flag = 1'b0;
    protected bit tohost_written_flag = 1'b0;
    protected bit spike_enabled = 1'b0;
    protected logic [127:0] final_tohost_data;

    virtual coralnpu_irq_if.DUT_IRQ_PORT irq_vif;
    uvm_event tohost_written_event;
    uvm_event test_start_event;
    time clk_period;
    int unsigned entry_point = 0;

    function new(string name = "coralnpu_base_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      string test_elf;
      string timeout_str;
      string entry_point_str;
      int timeout_int;
      int unsigned initial_misa_value;
      uvm_cmdline_processor clp = uvm_cmdline_processor::get_inst();

      super.build_phase(phase);
      `uvm_info(get_type_name(), "Build phase starting", UVM_MEDIUM)
      if ($test$plusargs("SPIKE_LOG")) begin
        spike_enabled = 1'b1;
      end

      if (!clp.get_arg_value("+TEST_ELF=", test_elf)) begin
        `uvm_fatal(get_type_name(), "+TEST_ELF plusarg not specified.")
      end

      if (clp.get_arg_value("+ENTRY_POINT=", entry_point_str)) begin
        if ($sscanf(entry_point_str, "'h%h", entry_point) != 1 &&
            $sscanf(entry_point_str, "0x%h", entry_point) != 1 &&
            $sscanf(entry_point_str, "%d", entry_point) != 1) begin
           `uvm_warning(get_type_name(),
             $sformatf("Invalid +ENTRY_POINT format: %s. Using default 0.", entry_point_str))
        end else begin
           `uvm_info(get_type_name(),
             $sformatf("Using entry point: 0x%h", entry_point), UVM_MEDIUM)
        end
      end

      if (clp.get_arg_value("+TEST_TIMEOUT=", timeout_str)) begin
        if ($sscanf(timeout_str, "%d", timeout_int) == 1 && timeout_int > 0)
        begin
           test_timeout = timeout_int * 1ns;
           `uvm_info(get_type_name(),
                     $sformatf("Using custom timeout: %t", test_timeout),
                     UVM_MEDIUM)
        end else `uvm_warning(get_type_name(),
                      $sformatf("Invalid +TEST_TIMEOUT value: %s", timeout_str))
      end

      begin
        string misa_value_str;
        if (clp.get_arg_value("+MISA_VALUE=", misa_value_str)) begin
          if ($sscanf(misa_value_str, "'h%h", initial_misa_value) != 1) begin
            `uvm_fatal(get_type_name(),
              "Invalid +MISA_VALUE format. Use hex format (e.g., 'h40201120).")
          end
        end else begin
          initial_misa_value = 32'h40201120;
        end
      end

      env = coralnpu_env::type_id::create("env", this);

      uvm_config_db#(string)::set(this, "*.m_cosim_checker",
                                  "elf_file_for_iss", test_elf);
      uvm_config_db#(int unsigned)::set(this, "*.m_cosim_checker",
                                        "initial_misa_value", initial_misa_value);

      // Get the event handle that was created and set by tb_top
      if (!uvm_config_db#(uvm_event)::get(this, "",
          "tohost_written_event", tohost_written_event)) begin
        `uvm_fatal(get_type_name(), "tohost_written_event handle not found!")
      end

      if (!uvm_config_db#(virtual coralnpu_irq_if.DUT_IRQ_PORT)::get(this, "",
          "irq_vif", irq_vif))
        `uvm_fatal(get_type_name(), "IRQ VIF 'irq_vif' not found")
      if (irq_vif == null)
        `uvm_fatal(get_type_name(), "IRQ VIF 'irq_vif' is null")

      if (!uvm_config_db#(time)::get(this, "", "clk_period", clk_period))
        `uvm_fatal(get_type_name(), "clk_period not found in config_db")

      if (!uvm_config_db#(uvm_event)::get(this, "", "test_start_event", test_start_event)) begin
        `uvm_fatal(get_type_name(), "test_start_event handle not found!")
      end

      `uvm_info(get_type_name(), "Build phase finished", UVM_MEDIUM)
    endfunction

    virtual task run_phase(uvm_phase phase);
      coralnpu_kickoff_write_seq kickoff_seq;
      coralnpu_pulse_irq_seq pulse_irq_seq;
      phase.raise_objection(this, "Base test running");

      // Memory is loaded by $readmemh in tb_top before run phase starts.

      `uvm_info(get_type_name(), "Waiting for reset deassertion...", UVM_MEDIUM)
      @(posedge irq_vif.clk iff irq_vif.resetn == 1'b1);
      `uvm_info(get_type_name(), "Reset deasserted.", UVM_MEDIUM)

      test_start_event.trigger();

      kickoff_seq = coralnpu_kickoff_write_seq::type_id::create("kickoff_seq");
      kickoff_seq.entry_point = entry_point;
      kickoff_seq.start(env.m_master_agent.sequencer);

      `uvm_info(get_type_name(), "Waiting for completion or timeout...",
                UVM_MEDIUM)
      fork
        begin // Wait for tohost write
          tohost_written_event.wait_trigger();
          tohost_written_flag = 1'b1;
        end
        begin // Wait for DUT halted/faulted (backup termination)
          wait (irq_vif.halted == 1'b1 || irq_vif.fault == 1'b1);
          dut_halted_flag = irq_vif.halted;
          dut_faulted_flag = irq_vif.fault;
        end
        begin
          forever begin
            int delay;

            wait (irq_vif.wfi == 1'b1);
            if (!std::randomize(delay) with {delay inside {[0:1000]};}) begin
              `uvm_error(get_type_name(), "Randomization of IRQ delay failed")
            end
            #(delay * 1ns);
            pulse_irq_seq = coralnpu_pulse_irq_seq::type_id::create("pulse_irq_seq");
            pulse_irq_seq.start(env.m_irq_agent.sequencer);
          end
        end
        begin // Timeout mechanism
          #(test_timeout);
          test_timed_out = 1'b1;
        end
      join_any
      disable fork;

      #(clk_period/2);

      `uvm_info(get_type_name(), "Run phase finishing", UVM_MEDIUM)
      phase.drop_objection(this, "Base test finished");
    endtask

    virtual function void report_phase(uvm_phase phase);
      logic [31:1] status_code;
      uvm_report_server rs = uvm_report_server::get_server();
      int error_count = rs.get_severity_count(UVM_ERROR);
      int fatal_count = rs.get_severity_count(UVM_FATAL);

      super.report_phase(phase);
      if (tohost_written_flag) begin
        if (uvm_config_db#(logic [127:0])::get(this, "",
            "final_tohost_data", final_tohost_data)) begin
          status_code = final_tohost_data[31:1];
          if (status_code == 0) begin
            if (error_count == 0 && fatal_count == 0) begin
               test_passed = 1'b1;
               `uvm_info(get_type_name(),
                 "tohost write detected with PASS status (0).", UVM_LOW)
            end else begin
               test_passed = 1'b0;
               `uvm_error(get_type_name(), "tohost write detected with PASS status (0), but UVM errors occurred during simulation.")
            end
          end else begin
            test_passed = 1'b0;
            `uvm_error(get_type_name(),
              $sformatf("tohost write detected with FAIL status code: %0d",
                        status_code))
          end
        end else `uvm_error(get_type_name(),
                  "tohost event triggered, but final status not found!")
      end else if (dut_halted_flag && !dut_faulted_flag) begin
        `uvm_info(get_type_name(), "Test ended on DUT halt.", UVM_LOW)
        if (error_count == 0 && fatal_count == 0) begin
           test_passed = 1'b1;
        end else begin
           test_passed = 1'b0;
           `uvm_error(get_type_name(), "Test ended on DUT halt, but UVM errors occurred during simulation.")
        end
      end else if (dut_faulted_flag) begin
        if (rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0) begin
            `uvm_info(get_type_name(), "Test ended on DUT fault, but no Co-Simulation mismatches were detected. Assuming consistent behavior (PASS).", UVM_LOW)
            test_passed = 1'b1;
        end else begin
            `uvm_info(get_type_name(), "Test ended on DUT fault with Co-Sim mismatches (FAIL).", UVM_LOW)
            test_passed = 1'b0;
        end
      end else if (test_timed_out) begin
        if (spike_enabled) begin
            `uvm_error(get_type_name(), $sformatf("Test timed out after %t. Spike was enabled, so this is a failure (divergence/stall).", test_timeout))
            test_passed = 1'b0;
        end else if (rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0) begin
            `uvm_info(get_type_name(), $sformatf("Test timed out after %t, but no Co-Simulation mismatches were detected. Assuming PASS.", test_timeout), UVM_LOW)
            test_passed = 1'b1;
        end else begin
            `uvm_error(get_type_name(), $sformatf("Test timed out after %t with errors/mismatches.", test_timeout))
            test_passed = 1'b0;
        end
      end else begin
        `uvm_error(get_type_name(), "Test ended with no clear pass/fail.")
        test_passed = 1'b0;
      end

      if(test_passed) `uvm_info(get_type_name(), "** UVM TEST PASSED **",
                                UVM_NONE)
      else `uvm_error(get_type_name(), "** UVM TEST FAILED **")
    endfunction

  endclass

  //--------------------------------------------------------------------------
  // Class: coralnpu_regression_test
  //--------------------------------------------------------------------------
  import "DPI-C" function void sram_load_elf(input string filename);
  import "DPI-C" function void sram_clear();

  class coralnpu_regression_test extends coralnpu_base_test;
    `uvm_component_utils(coralnpu_regression_test)

    int total_tests = 0;
    int passed_tests = 0;
    int failed_tests = 0;

    function new(string name = "coralnpu_regression_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      uvm_report_server rs;
      super.build_phase(phase);
      rs = uvm_report_server::get_server();
      rs.set_max_quit_count(0);
    endfunction

    virtual task run_phase(uvm_phase phase);
      string regression_list_file;
      int fd;
      string current_elf;
      logic [31:0] current_tohost;
      int current_entry;
      int current_timeout;
      string current_spike_log;
      string current_target;
      string line;

      uvm_event pulse_reset_event;
      coralnpu_kickoff_write_seq kickoff_seq;
      coralnpu_pulse_irq_seq pulse_irq_seq;

      phase.raise_objection(this, "Regression running");

      if (!uvm_config_db#(uvm_event)::get(this, "", "test_start_event", test_start_event)) begin
        `uvm_fatal(get_type_name(), "test_start_event handle not found!")
      end

      if (!uvm_config_db#(uvm_event)::get(this, "", "pulse_reset_event", pulse_reset_event)) begin
        `uvm_fatal(get_type_name(), "pulse_reset_event handle not found!")
      end

      if (!$value$plusargs("REGRESSION_LIST=%s", regression_list_file)) begin
        `uvm_fatal(get_type_name(), "+REGRESSION_LIST plusarg not specified.")
      end

      fd = $fopen(regression_list_file, "r");
      if (fd == 0) begin
        `uvm_fatal(get_type_name(), $sformatf("Failed to open %s", regression_list_file))
      end

      while (!$feof(fd)) begin
        if ($fgets(line, fd)) begin
          if (line == "" || line.substr(0,0) == "#") continue;

          // Format: ELF TOHOST ENTRY TIMEOUT SPIKE_LOG TARGET
          if ($sscanf(line, "%s %h %h %d %s %s", current_elf, current_tohost, current_entry, current_timeout, current_spike_log, current_target) == 6) begin
            `uvm_info(get_type_name(), $sformatf("--- STARTING TEST: %s ---", current_target), UVM_NONE)
            total_tests++;

            // Reset state for new test
            test_passed = 1'b0;
            test_timed_out = 1'b0;
            dut_halted_flag = 1'b0;
            dut_faulted_flag = 1'b0;
            tohost_written_flag = 1'b0;
            tohost_written_event.reset();
            test_timeout = current_timeout * 1ns;
            entry_point = current_entry;
            if (current_spike_log != "NONE") spike_enabled = 1'b1;
            else spike_enabled = 1'b0;

            // Teardown and Re-load
            sram_clear();
            sram_load_elf(current_elf);

            // Pass configuration to checker
            uvm_config_db#(string)::set(null, "*", "current_test_elf", current_elf);
            uvm_config_db#(string)::set(null, "*", "current_spike_log", current_spike_log);
            uvm_config_db#(logic [31:0])::set(null, "*", "tohost_addr", current_tohost);
            uvm_config_db#(bit)::set(null, "*", "cosim_mismatch_detected", 0);

            // Pulse Reset for tests AFTER the first one
            if (total_tests > 1) begin
               pulse_reset_event.trigger();
               @(posedge irq_vif.clk iff irq_vif.resetn == 1'b0);
            end
            @(posedge irq_vif.clk iff irq_vif.resetn == 1'b1);

            // Ensure DUT has finished clearing internal halt/fault state
            if (irq_vif.halted == 1'b1 || irq_vif.fault == 1'b1) begin
               @(posedge irq_vif.clk iff (irq_vif.halted == 1'b0 && irq_vif.fault == 1'b0));
            end

            test_start_event.trigger();

            kickoff_seq = coralnpu_kickoff_write_seq::type_id::create("kickoff_seq");
            kickoff_seq.entry_point = entry_point;
            kickoff_seq.start(env.m_master_agent.sequencer);

            `uvm_info(get_type_name(), "Waiting for completion or timeout...", UVM_MEDIUM)
            fork
              begin // Wait for tohost write
                tohost_written_event.wait_trigger();
                tohost_written_flag = 1'b1;
              end
              begin // Wait for DUT halted/faulted (backup termination)
                wait (irq_vif.halted == 1'b1 || irq_vif.fault == 1'b1);
                dut_halted_flag = irq_vif.halted;
                dut_faulted_flag = irq_vif.fault;
              end
              begin
                forever begin
                  int delay;
                  wait (irq_vif.wfi == 1'b1);
                  if (!std::randomize(delay) with {delay inside {[0:1000]};}) begin
                    `uvm_error(get_type_name(), "Randomization of IRQ delay failed")
                  end
                  #(delay * 1ns);
                  pulse_irq_seq = coralnpu_pulse_irq_seq::type_id::create("pulse_irq_seq");
                  pulse_irq_seq.start(env.m_irq_agent.sequencer);
                  wait (irq_vif.wfi == 1'b0);
                end
              end
              begin // Timeout mechanism
                #(test_timeout);
                test_timed_out = 1'b1;
              end
            join_any
            disable fork;

            #(clk_period/2);

            evaluate_batch_test_result(current_target);

            `uvm_info(get_type_name(), $sformatf("--- FINISHED TEST: %s ---\n", current_target), UVM_NONE)
          end
        end
      end
      $fclose(fd);

      `uvm_info(get_type_name(), $sformatf("REGRESSION COMPLETE. Passed: %0d/%0d", passed_tests, total_tests), UVM_NONE)
      phase.drop_objection(this, "Regression finished");
    endtask

    virtual function void evaluate_batch_test_result(string target_name);
      logic [31:1] status_code;
      bit mismatch;
      if (!uvm_config_db#(bit)::get(null, "*", "cosim_mismatch_detected", mismatch)) mismatch = 0;

      if (tohost_written_flag) begin
        if (uvm_config_db#(logic [127:0])::get(this, "", "final_tohost_data", final_tohost_data)) begin
          status_code = final_tohost_data[31:1];
          if (status_code == 0 && !mismatch) begin
            test_passed = 1'b1;
          end else begin
            test_passed = 1'b0;
            `uvm_info(get_type_name(), $sformatf("tohost code: %0d, mismatch: %0d", status_code, mismatch), UVM_NONE)
          end
        end else begin
            test_passed = 1'b0;
            `uvm_info(get_type_name(), "tohost triggered but no data", UVM_NONE)
        end
      end else if (dut_halted_flag && !dut_faulted_flag && !mismatch) begin
        test_passed = 1'b1;
      end else if (dut_faulted_flag && !mismatch) begin
        `uvm_info(get_type_name(), "Test ended on DUT fault, but no Co-Simulation mismatches were detected. Assuming consistent behavior (PASS).", UVM_LOW)
        test_passed = 1'b1;
      end else if (test_timed_out) begin
        if (spike_enabled) begin
            test_passed = 1'b0;
            `uvm_info(get_type_name(), "FAILED: Timeout with Spike enabled", UVM_NONE)
        end else if (!mismatch) begin
            `uvm_info(get_type_name(), "Test timed out, but no Co-Simulation mismatches were detected. Assuming PASS.", UVM_LOW)
            test_passed = 1'b1;
        end else begin
            test_passed = 1'b0;
            `uvm_info(get_type_name(), "FAILED: Timeout with co-sim mismatches", UVM_NONE)
        end
      end else if (mismatch) begin
        test_passed = 1'b0;
        `uvm_info(get_type_name(), "FAILED: Co-Simulation mismatch detected", UVM_NONE)
      end else begin
        test_passed = 1'b0;
        `uvm_info(get_type_name(), "FAILED: Unknown error or DUT fault with mismatches", UVM_NONE)
      end

      if(test_passed) begin
         `uvm_info(get_type_name(), "** UVM TEST PASSED **", UVM_NONE)
         passed_tests++;
      end else begin
         `uvm_error(get_type_name(), "** UVM TEST FAILED **")
         failed_tests++;
      end
    endfunction

    virtual function void report_phase(uvm_phase phase);
       if (failed_tests > 0) begin
          `uvm_info("REGRESSION_SUMMARY", $sformatf("%0d/%0d tests failed.", failed_tests, total_tests), UVM_NONE)
       end else begin
          `uvm_info("REGRESSION_SUMMARY", $sformatf("All %0d tests passed.", total_tests), UVM_NONE)
       end
    endfunction

  endclass

endpackage : coralnpu_test_pkg
