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
// Package: coralnpu_cosim_checker_pkg
// Description: Package for the UVM component that manages co-simulation.
//----------------------------------------------------------------------------
package coralnpu_cosim_checker_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import coralnpu_cosim_dpi_if::*;
  import memory_map_pkg::*;

  //----------------------------------------------------------------------------
  // Struct: retired_instr_info_s
  // Description: A struct to hold information about a single retired
  //              instruction, captured from the RVVI trace.
  //
  // Fields:
  //   pc           - The program counter of the retired instruction.
  //   insn         - The instruction bit pattern.
  //   x_wb         - One-hot mask of GPR register written by this instruction.
  //   f_wb         - One-hot mask of FPR register written by this instruction.
  //   v_wb         - Bitmask of vector registers written by this instruction.
  //   retire_index - The channel index (0-7) on which this instruction retired
  //                  on the RVVI bus.
  //----------------------------------------------------------------------------
  typedef struct {
    logic [31:0] pc;
    logic [31:0] insn;
    logic [31:0] x_wb;
    logic [31:0] f_wb;
    logic [31:0] v_wb;
    int          retire_index;
  } retired_instr_info_s;

  `include "spike_trace_service.sv"
  `include "spike_cosim_checker.sv"

  //----------------------------------------------------------------------------
  // Class: coralnpu_cosim_checker
  // Description: Manages the MPACT simulator via DPI-C. It receives retired
  //              instruction info from the DUT (via RVVI) and sends that
  //              same instruction to the MPACT simulator to execute, enabling
  //              a trace-and-execute co-simulation flow.
  //----------------------------------------------------------------------------
  class coralnpu_cosim_checker extends uvm_component;
    `uvm_component_utils(coralnpu_cosim_checker)

    // Use fully parameterized virtual interface type
    virtual rvviTrace #(
        .ILEN  (32),
        .XLEN  (32),
        .FLEN  (32),
        .VLEN  (128),
        .NHART (1),
        .RETIRE(8)
    ) rvvi_vif;

    // Event to wait on, which will be triggered by the RVVI monitor
    uvm_event instruction_retired_event;
    string test_elf;
    int unsigned initial_misa_value;

    spike_cosim_checker spike_checker;
    bit mismatch_detected = 0;
    bit [31:0] dirty_gprs = 0;
    bit dirty_stack[int];

    // Function: is_varying_csr_read
    // Checks if the instruction is a CSR read of varying counters (mcycle, cycle, time)
    function bit is_varying_csr_read(logic [31:0] insn);
      logic [ 6:0] opcode = insn[6:0];
      logic [ 2:0] funct3 = insn[14:12];
      logic [11:0] csr = insn[31:20];
      logic [ 4:0] rd = insn[11:7];

      if (opcode == 7'b1110011) begin  // SYSTEM opcode
        if (funct3 != 3'b000) begin
          if (rd != 0 && (csr == 12'hB00 || csr == 12'hB80 ||  // mcycle / mcycleh
              csr == 12'hB02 || csr == 12'hB82 ||  // minstret / minstreth
              csr == 12'hC00 || csr == 12'hC80 ||  // cycle / cycleh
              csr == 12'hC01 || csr == 12'hC81)) begin  // time / timeh
            return 1;
          end
        end
      end
      return 0;
    endfunction

    // Function: update_dirty_registers
    // Tracks the lifetime of registers loaded with varying CSR values
    function bit [31:0] update_dirty_registers(retired_instr_info_s rtl_info,
                                               input int unsigned pre_step_sp);
      logic [ 6:0] opcode = rtl_info.insn[6:0];
      logic [ 2:0] funct3 = rtl_info.insn[14:12];
      logic [11:0] csr = rtl_info.insn[31:20];
      logic [ 4:0] rd = rtl_info.insn[11:7];
      logic [ 4:0] rs1 = rtl_info.insn[19:15];
      logic [ 4:0] rs2 = rtl_info.insn[24:20];

      bit          reads_rs1 = 0;
      bit          reads_rs2 = 0;
      bit          is_varying_read = 0;
      bit          consumes_dirty = 0;
      bit   [31:0] skip_mask = 0;

      // 1. Detect varying CSR read
      is_varying_read = is_varying_csr_read(rtl_info.insn);

      // 2. Decode GPR reads
      case (opcode)
        7'b0110011: begin
          reads_rs1 = 1;
          reads_rs2 = 1;
        end  // OP
        7'b0010011: begin
          reads_rs1 = 1;
        end  // OP-IMM
        7'b0000011: begin
          reads_rs1 = 1;
        end  // LOAD
        7'b0100011: begin
          reads_rs1 = 1;
          reads_rs2 = 1;
        end  // STORE
        7'b1100011: begin
          reads_rs1 = 1;
          reads_rs2 = 1;
        end  // BRANCH


      endcase

      // 3. Propagate GPR-to-GPR dirtiness
      if (reads_rs1 && rs1 != 0 && dirty_gprs[rs1]) consumes_dirty = 1;
      if (reads_rs2 && rs2 != 0 && dirty_gprs[rs2]) consumes_dirty = 1;

      // 3.5. Trace stack reloads (byte-granular)
      if (opcode == 7'b0000011 && rs1 == 2) begin  // LOAD sp-relative (LB, LH, LW, LBU, LHU)
        int offset = $signed(rtl_info.insn[31:20]);
        int size = (funct3 == 3'b000 || funct3 == 3'b100) ? 1 :  // Byte
        (funct3 == 3'b001 || funct3 == 3'b101) ? 2 :  // Halfword
        (funct3 == 3'b010) ? 4 : 0;  // Word
        begin
          int addr = pre_step_sp + offset;
          for (int i = 0; i < size; i++) begin
            if (dirty_stack.exists(addr + i) && dirty_stack[addr+i] == 1) begin
              consumes_dirty = 1;
              `uvm_info(
                  "COSIM_STACK_RELOAD",
                  $sformatf(
                      "Stack address 0x%h (sp+0x%h, size=%0d) is DIRTY, GPR[x%0d] marked DIRTY at PC 0x%h",
                      addr + i, offset + i, size, rd, rtl_info.pc), UVM_LOW)
              break;
            end
          end
        end
      end

      // 4. Update GPR dirty mask and skip mask for current instruction
      if (rtl_info.x_wb != 0) begin
        if (rd != 0) begin
          if (is_varying_read || consumes_dirty) begin
            skip_mask[rd]  = 1;
            dirty_gprs[rd] = 1;
            `uvm_info("COSIM_DIRTY",
                      $sformatf("GPR[x%0d] marked DIRTY at PC 0x%h (varying=%b, consumes=%b)", rd,
                                rtl_info.pc, is_varying_read, consumes_dirty), UVM_LOW)
          end else begin
            dirty_gprs[rd] = 0;  // Overwritten with clean value
          end
        end
      end

      // 4.5. Trace stack spills (byte-granular, uses updated dirty state)
      if (opcode == 7'b0100011 && rs1 == 2) begin  // STORE sp-relative (SB, SH, SW)
        int offset = $signed({rtl_info.insn[31:25], rtl_info.insn[11:7]});
        int size = (funct3 == 3'b000) ? 1 :  // Byte
        (funct3 == 3'b001) ? 2 :  // Halfword
        (funct3 == 3'b010) ? 4 : 0;  // Word
        begin
          int addr = pre_step_sp + offset;
          if (rs2 != 0 && dirty_gprs[rs2]) begin
            for (int i = 0; i < size; i++) begin
              dirty_stack[addr+i] = 1;
            end
            `uvm_info(
                "COSIM_STACK_SPILL",
                $sformatf(
                    "Stack address 0x%h (sp+0x%h, size=%0d) marked DIRTY (spilled GPR[x%0d]) at PC 0x%h",
                    addr, offset, size, rs2, rtl_info.pc), UVM_LOW)
          end else begin
            for (int i = 0; i < size; i++) begin
              dirty_stack.delete(addr + i);
            end
          end
        end
      end

      return skip_mask;
    endfunction


    // Constructor
    function new(string name = "coralnpu_cosim_checker", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // Build phase: Get VIF handle, create and share event
    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // Get the RVVI virtual interface from the config_db (set by tb_top)
      if (!uvm_config_db#(virtual rvviTrace #(
              .ILEN  (32),
              .XLEN  (32),
              .FLEN  (32),
              .VLEN  (128),
              .NHART (1),
              .RETIRE(8)
          ))::get(
              this, "", "rvvi_vif", rvvi_vif
          )) begin
        `uvm_fatal(get_type_name(), "RVVI virtual interface not found!")
      end

      if (!uvm_config_db#(int unsigned)::get(
              this, "", "initial_misa_value", initial_misa_value
          )) begin
        `uvm_fatal(get_type_name(), "'initial_misa_value' not found in config_db")
      end

      // Create the event that this component will wait on.
      instruction_retired_event = new("instruction_retired_event");
      // Pass the event to the monitor using an absolute path
      uvm_config_db#(uvm_event)::set(null, "*.m_rvvi_agent.monitor", "instruction_retired_event",
                                     instruction_retired_event);
    endfunction

    // Task: collect_retired_instructions
    // Waits for the monitor to signal that instructions have retired, then
    // captures the retired instruction information from the RVVI bus.
    virtual task collect_retired_instructions(ref retired_instr_info_s retired_instr_q[$]);
      // Wait for the RVVI monitor to signal an instruction retirement
      instruction_retired_event.wait_trigger();
      retired_instr_q.delete();

      // Collect all retired instructions and their state from the RVVI trace
      for (int i = 0; i < rvvi_vif.RETIRE; i++) begin
        if (rvvi_vif.valid[0][i]) begin
          retired_instr_info_s info;
          info.pc = rvvi_vif.pc_rdata[0][i];
          info.insn = rvvi_vif.insn[0][i];
          info.x_wb = rvvi_vif.x_wb[0][i];
          info.f_wb = rvvi_vif.f_wb[0][i];
          info.v_wb = rvvi_vif.v_wb[0][i];
          info.retire_index = i;  // Store the original channel index
          retired_instr_q.push_back(info);
          `uvm_info(get_type_name(), $sformatf("RTL Retired: PC=0x%h, Insn=0x%h", info.pc,
                                               info.insn), UVM_HIGH)
        end
      end
    endtask

    // Task: process_instruction
    // Matches the current MPACT state with a retired RTL instruction,
    // steps MPACT, performs Spike sync/check if enabled, and verifies writeback.
    virtual task process_instruction(ref retired_instr_info_s retired_instr_q[$],
                                     input uvm_phase phase);
      int unsigned mpact_pc;
      int match_index = -1;
      logic [31:0] rtl_instr;
      bit [31:0] skip_mask;
      int unsigned pre_step_sp;

      if (mpact_get_register("pc", mpact_pc) != 0) begin
        `uvm_error("COSIM_API_FAIL", "Failed to get PC from MPACT simulator.")
      end

      foreach (retired_instr_q[j]) begin
        if (retired_instr_q[j].pc == mpact_pc) begin
          match_index = j;
          break;
        end
      end

      if (match_index == -1) begin
        string rtl_pcs_str = "[ ";
        foreach (retired_instr_q[j]) begin
          rtl_pcs_str = $sformatf("%s0x%h ", rtl_pcs_str, retired_instr_q[j].pc);
        end
        rtl_pcs_str = {rtl_pcs_str, "]"};
        `uvm_error("COSIM_PC_MISMATCH", $sformatf("MPACT PC 0x%h mismatches retired RTL PCs: %s",
                                                  mpact_pc, rtl_pcs_str))
        mismatch_detected = 1;
        return;
      end

      rtl_instr = retired_instr_q[match_index].insn;
      `uvm_info(get_type_name(), $sformatf("PC match (0x%h). Stepping MPACT with 0x%h", mpact_pc,
                                           rtl_instr), UVM_HIGH)

      if (mpact_get_register("sp", pre_step_sp) != 0) begin
        `uvm_error("COSIM_API_FAIL", "Failed to get pre-step SP from MPACT.")
      end

      if (mpact_step(rtl_instr) != 0) begin
        `uvm_error("COSIM_STEP_FAIL", "mpact_step() DPI call failed.")
        mismatch_detected = 1;
        return;
      end

      skip_mask = update_dirty_registers(retired_instr_q[match_index], pre_step_sp);

      if (spike_checker != null) begin
        spike_checker.check_instruction(retired_instr_q[match_index], rvvi_vif, skip_mask);
      end

      // Check return status and terminate on failure
      if (!step_and_compare(retired_instr_q[match_index], skip_mask)) begin
        mismatch_detected = 1;
        return;
      end

      retired_instr_q.delete(match_index);
    endtask

    // Run phase: Contains the main co-simulation loop
    virtual task run_phase(uvm_phase phase);
      retired_instr_info_s retired_instr_q[$];
      sim_config_t dpi_cfg_s;
      logic [31:0] itcm_start_address;
      logic [31:0] itcm_length;
      uvm_event test_start_event;

      if (!uvm_config_db#(uvm_event)::get(this, "", "test_start_event", test_start_event)) begin
        // If not found, assume it is provided by the test via top
      end

      itcm_start_address = memory_map_pkg::ITCM_START_ADDR;
      itcm_length = memory_map_pkg::ITCM_LENGTH;

      `uvm_info("DPI_CALL", $sformatf({"Configuring MPACT with: MISA=0x%h, ITCM Start=0x%h, ",
                                       "ITCM Length=0x%h"}, initial_misa_value, itcm_start_address,
                                        itcm_length), UVM_MEDIUM)

      dpi_cfg_s = {<<32{itcm_start_address, itcm_length, initial_misa_value, 32'd1  // M3
      }};

      forever begin
        string current_test_elf;
        string current_spike_log;

        // Wait for the next test to start
        test_start_event.wait_trigger();

        // Reset state
        mismatch_detected = 0;
        dirty_gprs = 0;
        dirty_stack.delete();
        retired_instr_q.delete();
        uvm_config_db#(bit)::set(null, "*", "cosim_mismatch_detected", 0);

        if (uvm_config_db#(string)::get(this, "", "current_test_elf", current_test_elf)) begin
          test_elf = current_test_elf;
        end

        // Spike checker initialization per test
        if (uvm_config_db#(string)::get(
                this, "", "current_spike_log", current_spike_log
            ) && current_spike_log != "" && current_spike_log != "NONE") begin
          if (spike_checker == null) begin
            spike_checker = spike_cosim_checker::type_id::create("spike_checker");
          end
          spike_checker.initialize(current_spike_log);
        end else begin
          spike_checker = null;
        end

        `uvm_info(get_type_name(), $sformatf("Initializing Co-Sim for %s", test_elf), UVM_LOW)

        void'(mpact_fini());

        if (mpact_init() != 0) `uvm_error(get_type_name(), "MPACT simulator DPI init failed.")
        if (mpact_config(dpi_cfg_s) != 0)
          `uvm_error(get_type_name(), "MPACT simulator DPI config failed.")
        if (mpact_load_program(test_elf) != 0)
          `uvm_error(get_type_name(), "MPACT simulator DPI load program failed.")

        // Inner loop for processing instructions for the current test
        fork
          begin : cosim_process_loop
            forever begin
              collect_retired_instructions(retired_instr_q);

              while (retired_instr_q.size() > 0) begin
                process_instruction(retired_instr_q, phase);
                if (mismatch_detected) begin
                  uvm_config_db#(bit)::set(null, "*", "cosim_mismatch_detected", 1);
                  break;
                end
              end
              if (mismatch_detected) break;
            end
          end
          begin : wait_for_next_test
            // Wait for the event again (which signals next test) to kill the processing loop
            test_start_event.wait_trigger();
          end
        join_any
        disable fork;
      end
    endtask

    // Function: step_and_compare
    // Compares the register writeback state between the RTL (captured via RVVI)
    // and the MPACT simulator. It verifies:
    // 1. GPR (integer) writes: Checks the x_wb mask and compares the written data.
    // 2. FPR (floating-point) writes: Checks the f_wb mask and compares the written data.
    // 3. VPR (vector) writes: Checks the v_wb bitmask and compares each written vector register.
    // Returns 1 if all checks pass, 0 otherwise.
    virtual function bit step_and_compare(retired_instr_info_s rtl_info,
                                          input bit [31:0] skip_mask);
      int unsigned mpact_gpr_val;
      int unsigned rd_index;
      logic [31:0] rtl_wdata;
      string reg_name;

      `uvm_info(get_type_name(), "Comparing GPR writeback state...", UVM_HIGH)

      if (!$onehot0(rtl_info.x_wb)) begin
        `uvm_error("COSIM_GPR_MISMATCH", $sformatf({"Invalid GPR writeback flag at PC 0x%h. ",
                                                    "x_wb is not one-hot: 0x%h"}, rtl_info.pc,
                                                     rtl_info.x_wb))
        return 0;  // FAIL
      end

      if (rtl_info.x_wb == 1) begin
        `uvm_error("COSIM_GPR_MISMATCH", $sformatf("Illegal write to x0 detected at PC 0x%h.",
                                                   rtl_info.pc))
        return 0;  // FAIL
      end else if (rtl_info.x_wb != 0) begin
        rd_index = $clog2(rtl_info.x_wb);
        reg_name = $sformatf("x%0d", rd_index);
        if (skip_mask[rd_index]) begin
          `uvm_info("COSIM_SKIP", $sformatf(
                                      "Skipping GPR[%s] comparison at PC 0x%h due to dirty mask",
                                      reg_name, rtl_info.pc), UVM_LOW)
          return 1;  // PASS (skipped)
        end

        if (mpact_get_register(reg_name, mpact_gpr_val) != 0) begin
          `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get GPR '%s'", reg_name));
          return 0;  // FAIL
        end

        // Get the specific write data from the correct retire channel and
        // register index
        rtl_wdata = rvvi_vif.x_wdata[0][rtl_info.retire_index][rd_index];

        if (mpact_gpr_val != rtl_wdata) begin
          string msg;
          msg = $sformatf(
              {
                "GPR[x%0d] mismatch at PC 0x%h. ", "RTL: 0x%h, MPACT: 0x%h"
              },
              rd_index,
              rtl_info.pc,
              rtl_wdata,
              mpact_gpr_val
          );
          `uvm_error("COSIM_GPR_MISMATCH", msg)
          return 0;  // FAIL
        end else begin
          `uvm_info("MPACT_MATCH", $sformatf(
                    {
                      "GPR[x%0d] match at PC 0x%h. ", "RTL: 0x%h, MPACT: 0x%h"
                    },
                    rd_index,
                    rtl_info.pc,
                    rtl_wdata,
                    mpact_gpr_val
                    ), UVM_HIGH)
        end
      end

      // Floating Point Writeback Detection
      if (rtl_info.f_wb != 0) begin
        int unsigned mpact_fpr_val;
        if (!$onehot0(rtl_info.f_wb)) begin
          `uvm_error("COSIM_FPR_MISMATCH", $sformatf({"Invalid FPR writeback flag at PC 0x%h. ",
                                                      "f_wb is not one-hot: 0x%h"}, rtl_info.pc,
                                                       rtl_info.f_wb))
          return 0;  // FAIL
        end

        rd_index = $clog2(rtl_info.f_wb);
        `uvm_info("COSIM_FPR_WB", $sformatf("Floating point writeback detected to f%0d at PC 0x%h",
                                            rd_index, rtl_info.pc), UVM_MEDIUM)

        reg_name = $sformatf("f%0d", rd_index);
        if (mpact_get_register(reg_name, mpact_fpr_val) != 0) begin
          `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get FPR '%s'", reg_name));
          return 0;  // FAIL
        end

        // Get the specific write data from the correct retire channel and register index
        rtl_wdata = rvvi_vif.f_wdata[0][rtl_info.retire_index][rd_index];

        if (mpact_fpr_val != rtl_wdata) begin
          string msg;
          msg = $sformatf(
              "FPR[f%0d] mismatch at PC 0x%h. RTL: 0x%h, MPACT: 0x%h",
              rd_index,
              rtl_info.pc,
              rtl_wdata,
              mpact_fpr_val
          );
          `uvm_error("COSIM_FPR_MISMATCH", msg)
          return 0;  // FAIL
        end

        `uvm_info("MPACT_MATCH", $sformatf("FPR[f%0d] match at PC 0x%h. RTL: 0x%h, MPACT: 0x%h",
                                           rd_index, rtl_info.pc, rtl_wdata, mpact_fpr_val),
                  UVM_HIGH)
      end

      // Vector Writeback Detection
      if (rtl_info.v_wb != 0) begin
        logic [127:0] mpact_vpr_val;
        logic [127:0] rtl_vpr_wdata;

        for (int i = 0; i < 32; i++) begin
          if (rtl_info.v_wb[i]) begin
            rd_index = i;
            reg_name = $sformatf("v%0d", rd_index);
            if (mpact_get_vector_register(reg_name, mpact_vpr_val) != 0) begin
              `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get VPR '%s'", reg_name));
              return 0;  // FAIL
            end

            // Get the specific write data from the correct retire channel and register index
            rtl_vpr_wdata = rvvi_vif.v_wdata[0][rtl_info.retire_index][rd_index];

            if (mpact_vpr_val != rtl_vpr_wdata) begin
              string msg;
              msg = $sformatf(
                  "VPR[v%0d] mismatch at PC 0x%h. RTL: 0x%h, MPACT: 0x%h",
                  rd_index,
                  rtl_info.pc,
                  rtl_vpr_wdata,
                  mpact_vpr_val
              );
              `uvm_error("COSIM_VPR_MISMATCH", msg)
              return 0;  // FAIL
            end

            `uvm_info("MPACT_MATCH",
                      $sformatf("VPR[v%0d] match at PC 0x%h. RTL: 0x%h, MPACT: 0x%h", rd_index,
                                rtl_info.pc, rtl_vpr_wdata, mpact_vpr_val), UVM_HIGH)
          end
        end
      end

      // If we reach here, all checks passed for this instruction.
      return 1;  // PASS
    endfunction

  endclass : coralnpu_cosim_checker

endpackage : coralnpu_cosim_checker_pkg
