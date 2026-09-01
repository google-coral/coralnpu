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
// Description: Package for the UVM component that manages unified multi-ISS
//              co-simulation (RTL vs MPACT vs Spike).
//----------------------------------------------------------------------------
package coralnpu_cosim_checker_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import coralnpu_cosim_dpi_if::*;
  import coralnpu_spike_cosim_dpi_if::*;
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

  `include "spike_cosim_checker.sv"

  //----------------------------------------------------------------------------
  // Class: coralnpu_cosim_checker
  // Description: Manages unified in-process co-simulation against MPACT and Spike
  //              via DPI-C. Receives retired instructions from the DUT (via RVVI)
  //              and steps both ISS models in lockstep.
  //----------------------------------------------------------------------------
  class coralnpu_cosim_checker extends uvm_component;
    `uvm_component_utils(coralnpu_cosim_checker)

    // Fully parameterized virtual interface type
    virtual rvviTrace #(
        .ILEN  (32),
        .XLEN  (32),
        .FLEN  (32),
        .VLEN  (128),
        .NHART (1),
        .RETIRE(8)
    ) rvvi_vif;
    virtual coralnpu_irq_if.DUT_IRQ_PORT irq_vif;

    // Event triggered by the RVVI monitor when instructions retire
    uvm_event instruction_retired_event;
    string test_elf;
    int unsigned initial_misa_value;
    int unsigned entry_point = 0;

    spike_cosim_checker spike_checker;
    bit mpact_enabled = 1;
    bit spike_enabled = 1;
    bit trace_logging_enabled = 0;
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
      if (opcode == 7'b0000011 && rs1 == 2) begin  // LOAD sp-relative
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

      // 4.5. Trace stack spills (byte-granular)
      if (opcode == 7'b0100011 && rs1 == 2) begin  // STORE sp-relative
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
      spike_checker = spike_cosim_checker::type_id::create("spike_checker");
    endfunction

    // Build phase: Get VIF handle, create and share event
    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
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

      if ($test$plusargs("COSIM_TRACE_LOG")) begin
        trace_logging_enabled = 1;
      end

      instruction_retired_event = new("instruction_retired_event");
      uvm_config_db#(uvm_event)::set(null, "*.m_rvvi_agent.monitor", "instruction_retired_event",
                                     instruction_retired_event);
    endfunction

    // Task: collect_retired_instructions
    virtual task collect_retired_instructions(ref retired_instr_info_s retired_instr_q[$]);
      instruction_retired_event.wait_trigger();
      retired_instr_q.delete();

      for (int i = 0; i < rvvi_vif.RETIRE; i++) begin
        if (rvvi_vif.valid[0][i]) begin
          retired_instr_info_s info;
          info.pc = rvvi_vif.pc_rdata[0][i];
          info.insn = rvvi_vif.insn[0][i];
          info.x_wb = rvvi_vif.x_wb[0][i];
          info.f_wb = rvvi_vif.f_wb[0][i];
          info.v_wb = rvvi_vif.v_wb[0][i];
          info.retire_index = i;
          retired_instr_q.push_back(info);
          `uvm_info(get_type_name(), $sformatf("RTL Retired: PC=0x%h, Insn=0x%h", info.pc,
                                               info.insn), UVM_HIGH)
        end
      end
    endtask

    // Task: process_instruction
    // Coalesces stepping of MPACT and Spike to the instruction boundary,
    // then performs a unified 3-way evaluation.
    virtual task process_instruction(ref retired_instr_info_s retired_instr_q[$],
                                     input uvm_phase phase);
      int unsigned mpact_pc;
      int unsigned spike_pc;
      int match_index = -1;
      logic [31:0] rtl_instr;
      bit [31:0] skip_mask;
      int unsigned pre_step_sp;

      // 1. Align retired RTL queue with current simulator PC
      if (mpact_enabled) begin
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
      end else begin
        match_index = 0;
      end

      rtl_instr = retired_instr_q[match_index].insn;

      // 2. Align and Step Spike
      if (spike_enabled && spike_checker.spike_enabled) begin
        int unsigned sync_attempts = 0;
        int unsigned initial_spike_pc = 0;
        if (irq_vif != null) begin
          if (irq_vif.irq) begin
            void'(spike_checker.set_register("mip", 32'h800));
          end else begin
            void'(spike_checker.set_register("mip", 32'h0));
          end
        end
        if (!spike_checker.get_pc(initial_spike_pc)) begin
          `uvm_error("COSIM_API_FAIL", "Failed to get PC from Spike simulator.")
        end
        spike_pc = initial_spike_pc;

        // If Spike is at an instruction that faulted/trapped (and therefore was not retired on RVVI),
        // step Spike through the exception trap handler entry until its PC matches the retired RTL PC.
        while (spike_pc != retired_instr_q[match_index].pc && sync_attempts < 10 && !spike_checker.is_halted()) begin
          void'(spike_checker.step(1));
          if (!spike_checker.get_pc(spike_pc)) break;
          sync_attempts++;
        end

        if (!spike_checker.is_halted()) begin
          if (spike_pc != retired_instr_q[match_index].pc) begin
            `uvm_error(
                "SPIKE_PC_MISMATCH",
                $sformatf(
                    "Spike PC 0x%h (initial: 0x%h after %0d sync steps) mismatches RTL PC 0x%h (Insn: 0x%h)",
                    spike_pc, initial_spike_pc, sync_attempts, retired_instr_q[match_index].pc,
                    rtl_instr))
            mismatch_detected = 1;
            retired_instr_q.delete(match_index);
            return;
          end
          if (!spike_checker.step(1)) begin
            `uvm_error("SPIKE_STEP_FAIL", $sformatf("Spike step failed at PC 0x%h (Insn: 0x%h)",
                                                    spike_pc, rtl_instr))
            mismatch_detected = 1;
            retired_instr_q.delete(match_index);
            return;
          end
        end
      end

      // 3. Step MPACT
      if (mpact_enabled) begin
        if (mpact_get_register("sp", pre_step_sp) != 0) begin
          `uvm_error("COSIM_API_FAIL", "Failed to get pre-step SP from MPACT.")
        end
        if (mpact_step(rtl_instr) != 0) begin
          `uvm_error("COSIM_STEP_FAIL", "mpact_step() DPI call failed.")
          mismatch_detected = 1;
          retired_instr_q.delete(match_index);
          return;
        end
      end

      // 4. Update dirty registers and synchronize varying CSRs
      skip_mask = update_dirty_registers(retired_instr_q[match_index], pre_step_sp);
      if (skip_mask != 0 && spike_enabled && spike_checker.spike_enabled) begin
        for (int r = 1; r < 32; r++) begin
          if (skip_mask[r]) begin
            logic [31:0] rtl_val = rvvi_vif.x_wdata[0][retired_instr_q[match_index].retire_index][r];
            string rname = $sformatf("x%0d", r);
            void'(spike_checker.set_register(rname, rtl_val));
          end
        end
      end

      // 5. Unified 3-Way Verification Boundary
      if (!step_and_compare_3way(retired_instr_q[match_index], skip_mask)) begin
        mismatch_detected = 1;
        retired_instr_q.delete(match_index);
        return;
      end

      retired_instr_q.delete(match_index);
    endtask

    // Run phase: Main co-simulation loop
    virtual task run_phase(uvm_phase phase);
      retired_instr_info_s retired_instr_q[$];
      sim_config_t dpi_cfg_s;
      logic [31:0] itcm_start_address;
      logic [31:0] itcm_length;
      uvm_event test_start_event;
      uvm_event cosim_mismatch_event;

      if (!uvm_config_db#(uvm_event)::get(this, "", "test_start_event", test_start_event)) begin
        `uvm_fatal(get_type_name(), "'test_start_event' handle not found in config_db!")
      end
      if (!uvm_config_db#(uvm_event)::get(
              this, "", "cosim_mismatch_event", cosim_mismatch_event
          )) begin
        `uvm_fatal(get_type_name(), "'cosim_mismatch_event' handle not found in config_db!")
      end
      if (!uvm_config_db#(virtual coralnpu_irq_if.DUT_IRQ_PORT)::get(
              this, "", "irq_vif", irq_vif
          )) begin
        `uvm_warning(get_type_name(), "IRQ virtual interface 'irq_vif' not found in config_db")
      end

      itcm_start_address = memory_map_pkg::ITCM_START_ADDR;
      itcm_length = memory_map_pkg::ITCM_LENGTH;

      dpi_cfg_s = {<<32{itcm_start_address, itcm_length, initial_misa_value, 32'd1}};

      test_start_event.wait_trigger();
      forever begin
        string current_test_elf;
        string mem_patch_file = "";
        bit has_entry_point;

        mismatch_detected = 0;
        dirty_gprs = 0;
        dirty_stack.delete();
        retired_instr_q.delete();
        uvm_config_db#(bit)::set(null, "*", "cosim_mismatch_detected", 0);
        if (uvm_config_db#(string)::get(this, "", "current_test_elf", current_test_elf)) begin
          test_elf = current_test_elf;
        end
        void'(uvm_config_db#(string)::get(this, "", "mem_patch_file", mem_patch_file));
        has_entry_point = uvm_config_db#(int unsigned)::get(this, "", "entry_point", entry_point);
        if (!has_entry_point) begin
          entry_point = 0;
        end
        if (!uvm_config_db#(bit)::get(this, "", "spike_enabled", spike_enabled)) begin
          spike_enabled = 1;
        end
        if (!uvm_config_db#(bit)::get(this, "", "mpact_enabled", mpact_enabled)) begin
          if ($test$plusargs("DISABLE_MPACT")) begin
            mpact_enabled = 0;
          end else if (mem_patch_file != "") begin
            // TODO(b/563400507): MPACT's DPI wrapper (@coralnpu_mpact) currently only supports
            // loading static ELF binaries via mpact_load_program() and lacks a runtime backdoor
            // memory patching interface (e.g. mpact_apply_memory_patch). When memory patches
            // (+MEM_PATCH=) are applied, MPACT retains unpatched memory, triggering false co-sim
            // mismatches on load instructions. Temporarily disable MPACT when mem_patch_file is
            // active until MPACT's DPI wrapper is extended to support memory patch injection.
            `uvm_info(
                get_type_name(),
                "Memory patch active (+MEM_PATCH); disabling MPACT co-simulation due to missing patch DPI support (Spike active).",
                UVM_LOW)
            mpact_enabled = 0;
          end else begin
            mpact_enabled = 1;
          end
        end

        `uvm_info(get_type_name(), $sformatf(
                  "Initializing Multi-ISS Co-Sim for %s (entry: 0x%h, custom: %0d, spike: %0d, mpact: %0d)",
                  test_elf,
                  entry_point,
                  has_entry_point,
                  spike_enabled,
                  mpact_enabled
                  ), UVM_LOW)

        // Initialize MPACT
        if (mpact_enabled) begin
          void'(mpact_fini());
          if (mpact_init() != 0) `uvm_error(get_type_name(), "MPACT simulator DPI init failed.")
          if (mpact_config(dpi_cfg_s) != 0) `uvm_error(get_type_name(), "MPACT DPI config failed.")
          if (mpact_load_program(test_elf) != 0)
            `uvm_error(get_type_name(), "MPACT DPI load program failed.")
        end

        // Initialize Spike
        if (spike_enabled) begin
          if (!spike_checker.initialize(
                  test_elf, entry_point, has_entry_point, mem_patch_file
              )) begin
            `uvm_warning(get_type_name(),
                         "Spike in-process initialization failed. Continuing with MPACT.")
          end
        end else begin
          spike_checker.finalize();
        end

        fork
          begin : cosim_process_loop
            forever begin
              collect_retired_instructions(retired_instr_q);

              while (retired_instr_q.size() > 0) begin
                process_instruction(retired_instr_q, phase);
                if (mismatch_detected) begin
                  uvm_config_db#(bit)::set(null, "*", "cosim_mismatch_detected", 1);
                  if (cosim_mismatch_event != null) cosim_mismatch_event.trigger();
                  break;
                end
              end
              if (mismatch_detected) break;
            end
          end
          begin : wait_for_next_test
            test_start_event.wait_trigger();
          end
        join_any
        disable fork;

        // If cosim exited due to mismatch (rather than next test start),
        // wait for the test runner to reset and start the next test.
        if (mismatch_detected) begin
          test_start_event.wait_trigger();
        end
      end
    endtask

    // Function: diagnose_and_report_mismatch
    // Formats a structured 3-way diagnosis table comparing RTL, MPACT, and Spike.
    virtual function void report_3way_mismatch(
        string reg_name, logic [31:0] pc, logic [31:0] insn, string rtl_str, string mpact_str,
        string spike_str, bit rtl_eq_mpact, bit rtl_eq_spike, bit mpact_eq_spike);
      string diagnosis;
      bit has_spike = spike_enabled && spike_checker.spike_enabled;

      if (mpact_enabled && has_spike) begin
        if (mpact_eq_spike && !rtl_eq_mpact) begin
          diagnosis = "🔴 RTL BUG (MPACT and Spike agree; RTL state differs)";
        end else if (rtl_eq_spike && !rtl_eq_mpact) begin
          diagnosis = "🟡 MPACT DIVERGENCE (RTL and Spike agree; MPACT differs)";
        end else if (rtl_eq_mpact && !rtl_eq_spike) begin
          diagnosis = "🟡 SPIKE DIVERGENCE (RTL and MPACT agree; Spike differs)";
        end else begin
          diagnosis = "⚠️ MULTI-WAY DIVERGENCE (All three models report differing values)";
        end
      end else if (mpact_enabled && !rtl_eq_mpact) begin
        diagnosis = "🟡 MPACT DIVERGENCE (Spike disabled; RTL and MPACT differ)";
      end else if (has_spike && !rtl_eq_spike) begin
        diagnosis = "🟡 SPIKE DIVERGENCE (MPACT disabled; RTL and Spike differ)";
      end else begin
        diagnosis = "⚠️ UNEXPECTED CO-SIMULATION MISMATCH";
      end

      `uvm_error("3WAY_COSIM_MISMATCH", $sformatf(
                 {
                   "\n========================= [3-WAY CO-SIM MISMATCH] =========================\n",
                   "  PC:          0x%08h\n",
                   "  Instruction: 0x%08h\n",
                   "  Register:    %s\n",
                   "  -------------------------------------------------------------------------\n",
                   "  RTL:         %s\n",
                   "  MPACT:       %s (RTL match: %s)\n",
                   "  Spike:       %s (RTL match: %s)\n",
                   "  -------------------------------------------------------------------------\n",
                   "  Diagnosis:   %s\n",
                   "==========================================================================="
                 },
                 pc,
                 insn,
                 reg_name,
                 rtl_str,
                 mpact_str,
                 (rtl_eq_mpact ? "YES" : "NO"),
                 spike_str,
                 (rtl_eq_spike ? "YES" : "NO"),
                 diagnosis
                 ))
    endfunction

    // Function: step_and_compare_3way
    // Compares register writeback state across RTL, MPACT, and Spike at the
    // retired instruction boundary.
    virtual function bit step_and_compare_3way(retired_instr_info_s rtl_info,
                                               input bit [31:0] skip_mask);
      int unsigned rd_index;
      string reg_name;
      bit has_spike = spike_enabled && spike_checker.spike_enabled;

      // 1. GPR Writeback Verification
      if (rtl_info.x_wb != 0) begin
        if (!$onehot0(rtl_info.x_wb)) begin
          `uvm_error("COSIM_GPR_MISMATCH",
                     $sformatf("Invalid GPR writeback flag at PC 0x%h. x_wb is not one-hot: 0x%h",
                               rtl_info.pc, rtl_info.x_wb))
          return 0;
        end

        if (rtl_info.x_wb == 1) begin
          `uvm_error("COSIM_GPR_MISMATCH", $sformatf("Illegal write to x0 at PC 0x%h.",
                                                     rtl_info.pc))
          return 0;
        end

        rd_index = $clog2(rtl_info.x_wb);
        reg_name = $sformatf("x%0d", rd_index);

        if (skip_mask[rd_index]) begin
          `uvm_info("COSIM_SKIP", $sformatf("Skipping GPR[%s] at PC 0x%h (dirty mask)", reg_name,
                                            rtl_info.pc), UVM_HIGH)
        end else begin
          logic [31:0] rtl_val = rvvi_vif.x_wdata[0][rtl_info.retire_index][rd_index];
          int unsigned mpact_val = 0;
          int unsigned spike_val = 0;
          bit mpact_ok = 1;
          bit spike_ok = 1;

          if (mpact_enabled) begin
            if (mpact_get_register(reg_name, mpact_val) != 0) begin
              `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT GPR %s", reg_name));
              mpact_ok = 0;
            end
          end

          if (has_spike) begin
            if (!spike_checker.get_gpr(reg_name, spike_val)) begin
              `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike GPR %s", reg_name));
              spike_ok = 0;
            end
          end

          if (trace_logging_enabled) begin
            `uvm_info("COSIM_TRACE",
                      $sformatf(
                          "PC=0x%08h Insn=0x%08h | RTL: %s=0x%08h | MPACT: 0x%08h | Spike: 0x%08h",
                          rtl_info.pc, rtl_info.insn, reg_name, rtl_val, mpact_val, spike_val),
                      UVM_NONE)
          end

          if ((mpact_enabled && mpact_ok && mpact_val != rtl_val) ||
              (has_spike && spike_ok && spike_val != rtl_val)) begin
            report_3way_mismatch(reg_name, rtl_info.pc, rtl_info.insn, $sformatf("0x%08h", rtl_val),
                                 mpact_enabled ? $sformatf("0x%08h", mpact_val) : "DISABLED",
                                 has_spike ? $sformatf("0x%08h", spike_val) : "DISABLED",
                                 mpact_enabled ? (mpact_val == rtl_val) : 1'b1,
                                 has_spike ? (spike_val == rtl_val) : 1'b1,
                                 (mpact_enabled && has_spike) ? (mpact_val == spike_val) : 1'b1);
            return 0;
          end
        end
      end

      // 2. FPR Writeback Verification
      if (rtl_info.f_wb != 0) begin
        if (!$onehot0(rtl_info.f_wb)) begin
          `uvm_error("COSIM_FPR_MISMATCH",
                     $sformatf("Invalid FPR writeback flag at PC 0x%h. f_wb is not one-hot: 0x%h",
                               rtl_info.pc, rtl_info.f_wb))
          return 0;
        end

        rd_index = $clog2(rtl_info.f_wb);
        reg_name = $sformatf("f%0d", rd_index);

        begin
          logic [31:0] rtl_val = rvvi_vif.f_wdata[0][rtl_info.retire_index][rd_index];
          int unsigned mpact_val = 0;
          int unsigned spike_val = 0;
          bit mpact_ok = 1;
          bit spike_ok = 1;

          if (mpact_enabled) begin
            if (mpact_get_register(reg_name, mpact_val) != 0) begin
              `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT FPR %s", reg_name));
              mpact_ok = 0;
            end
          end

          if (has_spike) begin
            if (!spike_checker.get_fpr(reg_name, spike_val)) begin
              `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike FPR %s", reg_name));
              spike_ok = 0;
            end
          end

          if (trace_logging_enabled) begin
            `uvm_info("COSIM_TRACE",
                      $sformatf(
                          "PC=0x%08h Insn=0x%08h | RTL: %s=0x%08h | MPACT: 0x%08h | Spike: 0x%08h",
                          rtl_info.pc, rtl_info.insn, reg_name, rtl_val, mpact_val, spike_val),
                      UVM_NONE)
          end

          if ((mpact_enabled && mpact_ok && mpact_val != rtl_val) ||
              (has_spike && spike_ok && spike_val != rtl_val)) begin
            report_3way_mismatch(reg_name, rtl_info.pc, rtl_info.insn, $sformatf("0x%08h", rtl_val),
                                 mpact_enabled ? $sformatf("0x%08h", mpact_val) : "DISABLED",
                                 has_spike ? $sformatf("0x%08h", spike_val) : "DISABLED",
                                 mpact_enabled ? (mpact_val == rtl_val) : 1'b1,
                                 has_spike ? (spike_val == rtl_val) : 1'b1,
                                 (mpact_enabled && has_spike) ? (mpact_val == spike_val) : 1'b1);
            return 0;
          end
        end
      end

      // 3. VPR Writeback Verification
      if (rtl_info.v_wb != 0) begin
        for (int i = 0; i < 32; i++) begin
          if (rtl_info.v_wb[i]) begin
            reg_name = $sformatf("v%0d", i);
            begin
              logic [127:0] rtl_vval = rvvi_vif.v_wdata[0][rtl_info.retire_index][i];
              logic [127:0] mpact_vval = 0;
              logic [127:0] spike_vval = 0;
              bit mpact_ok = 1;
              bit spike_ok = 1;

              if (mpact_enabled) begin
                if (mpact_get_vector_register(reg_name, mpact_vval) != 0) begin
                  `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT VPR %s", reg_name));
                  mpact_ok = 0;
                end
              end

              if (has_spike) begin
                if (!spike_checker.get_vpr(reg_name, spike_vval)) begin
                  `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike VPR %s", reg_name));
                  spike_ok = 0;
                end
              end

              if (trace_logging_enabled) begin
                `uvm_info(
                    "COSIM_TRACE",
                    $sformatf(
                        "PC=0x%08h Insn=0x%08h | RTL: %s=0x%032h | MPACT: 0x%032h | Spike: 0x%032h",
                        rtl_info.pc, rtl_info.insn, reg_name, rtl_vval, mpact_vval, spike_vval),
                    UVM_NONE)
              end

              if ((mpact_enabled && mpact_ok && mpact_vval != rtl_vval) ||
                  (has_spike && spike_ok && spike_vval != rtl_vval)) begin
                report_3way_mismatch(
                    reg_name, rtl_info.pc, rtl_info.insn, $sformatf("0x%032h", rtl_vval),
                    mpact_enabled ? $sformatf("0x%032h", mpact_vval) : "DISABLED",
                    has_spike ? $sformatf("0x%032h", spike_vval) : "DISABLED",
                    mpact_enabled ? (mpact_vval == rtl_vval) : 1'b1,
                    has_spike ? (spike_vval == rtl_vval) : 1'b1,
                    (mpact_enabled && has_spike) ? (mpact_vval == spike_vval) : 1'b1);
                return 0;
              end
            end
          end
        end
      end

      // CSR Writeback Detection
      if (rvvi_vif.csr_wb[0][rtl_info.retire_index] != 0) begin
        logic [31:0] mpact_csr_val;
        logic [31:0] rtl_csr_wdata;
        logic [31:0] check_mask;
        for (int i = 0; i < 4096; i++) begin
          if (rvvi_vif.csr_wb[0][rtl_info.retire_index][i]) begin
            string csr_name = get_csr_name(i);
            if (mpact_enabled) begin
              if (mpact_get_register(csr_name, mpact_csr_val) != 0) begin
                `uvm_warning("COSIM_CSR_UNKNOWN",
                             $sformatf("Cannot check CSR '%s' (0x%03x) - not in MPACT", csr_name,
                                       i))
              end else begin
                rtl_csr_wdata = rvvi_vif.csr[0][rtl_info.retire_index][i];
                check_mask    = get_csr_compare_mask(i);

                if ((mpact_csr_val & check_mask) != (rtl_csr_wdata & check_mask)) begin
                  string msg;
                  msg = $sformatf(
                      "CSR[0x%03x] %s mismatch at PC 0x%08x, Insn=0x%08x. RTL: 0x%08x, MPACT: 0x%08x (mask: 0x%08x)",
                      i,
                      csr_name,
                      rtl_info.pc,
                      rtl_info.insn,
                      rtl_csr_wdata,
                      mpact_csr_val,
                      check_mask
                  );
                  `uvm_error("COSIM_CSR_MISMATCH", msg)
                  return 0;  // FAIL
                end

                `uvm_info("COSIM_CSR_MATCH", $sformatf(
                          "CSR[0x%03x] %s compare success at PC 0x%08x, Insn=0x%08x. RTL: 0x%08x, MPACT: 0x%08x (mask: 0x%08x)",
                          i,
                          csr_name,
                          rtl_info.pc,
                          rtl_info.insn,
                          rtl_csr_wdata,
                          mpact_csr_val,
                          check_mask
                          ), UVM_HIGH)
              end
            end
          end
        end
      end

      // If we reach here, all checks passed for this instruction.
      return 1;  // PASS
    endfunction

    function automatic logic [31:0] get_csr_compare_mask(int csr_idx);
      case (csr_idx)
        // mip (0x344):
        // Interrupt pending bits reflect asynchronous external signals (PLIC/timer)
        12'h344: return 32'h0000_0000;

        // Default: Exact bit-for-bit check on all standard architectural CSRs
        // (mstatus, mscratch, mepc, mcause, mtval, misa, fflags, frm, fcsr, vstart, vxrm, vxsat, tdata1/2, etc.)
        default: return 32'hffff_ffff;
      endcase
    endfunction

    function automatic string get_csr_name(int csr_idx);
      case (csr_idx)
        12'h001: return "fflags";
        12'h002: return "frm";
        12'h003: return "fcsr";
        12'h008: return "vstart";
        12'h009: return "vxsat";
        12'h00a: return "vxrm";
        12'h00f: return "vcsr";
        12'h300: return "mstatus";
        12'h301: return "misa";
        12'h304: return "mie";
        12'h305: return "mtvec";
        12'h310: return "mstatush";
        12'h340: return "mscratch";
        12'h341: return "mepc";
        12'h342: return "mcause";
        12'h343: return "mtval";
        12'h344: return "mip";
        12'h7a0: return "tselect";
        12'h7a1: return "tdata1";
        12'h7a2: return "tdata2";
        12'h7a4: return "tinfo";
        12'h7b0: return "dcsr";
        12'h7b1: return "dpc";
        12'h7b2: return "dscratch0";
        12'h7b3: return "dscratch1";
        12'h7c0: return "mcontext0";
        12'h7c1: return "mcontext1";
        12'h7c2: return "mcontext2";
        12'h7c3: return "mcontext3";
        12'h7c4: return "mcontext4";
        12'h7c5: return "mcontext5";
        12'h7c6: return "mcontext6";
        12'h7c7: return "mcontext7";
        12'h7e0: return "mpc";
        12'h7e1: return "msp";
        12'hb00: return "mcycle";
        12'hb02: return "minstret";
        12'hb80: return "mcycleh";
        12'hb82: return "minstreth";
        12'hc20: return "vl";
        12'hc21: return "vtype";
        12'hc22: return "vlenb";
        12'hc23: return "mtype";
        12'hf11: return "mvendorid";
        12'hf12: return "marchid";
        12'hf13: return "mimpid";
        12'hf14: return "mhartid";
        12'hfc0: return "kisa";
        12'hfc4: return "kscm0";
        12'hfc8: return "kscm1";
        12'hfcc: return "kscm2";
        12'hfd0: return "kscm3";
        12'hfd4: return "kscm4";
        default: return $sformatf("csr_%03x", csr_idx);
      endcase
    endfunction

  endclass : coralnpu_cosim_checker

endpackage : coralnpu_cosim_checker_pkg
