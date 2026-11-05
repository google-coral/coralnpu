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
  //   t_wb         - Bitmask of matrix tile registers written by this
  //                  instruction.
  //   trap         - Indicates whether this instruction trapped on retirement.
  //   retire_index - The channel index (0-7) on which this instruction retired
  //                  on the RVVI bus.
  //----------------------------------------------------------------------------
  typedef struct {
    logic [31:0] pc;
    logic [31:0] insn;
    logic [31:0] x_wb;
    logic [31:0] f_wb;
    logic [31:0] v_wb;
    logic [15:0] t_wb;
    logic        trap;
    int          retire_index;
  } retired_instr_info_s;

  //----------------------------------------------------------------------------
  // Struct: lsu_mem_tx_s
  // Description: A struct representing a coalesced 16-byte-aligned memory row
  //              transaction (read or write).
  //
  // Fields:
  //   addr - 16-byte-aligned base byte address of the memory row ({addr[31:4], 4'h0}).
  //   data - 128-bit memory payload for the 16-byte row.
  //   mask - 16-bit byte enable mask indicating active bytes within the row.
  //----------------------------------------------------------------------------
  typedef struct {
    logic [31:0]  addr;
    logic [127:0] data;
    logic [15:0]  mask;
  } lsu_mem_tx_s;

  //----------------------------------------------------------------------------
  // Struct: completed_lsu_instr_s
  // Description: Holds all coalesced RTL LSU memory read and write row
  //              transactions captured for a single completed LSU instruction.
  //
  // Fields:
  //   pc     - The program counter of the LSU instruction.
  //   writes - Queue of coalesced 16-byte memory write transactions, sorted by
  //            ascending row address.
  //   reads  - Queue of coalesced 16-byte memory read transactions, sorted by
  //            ascending row address.
  //----------------------------------------------------------------------------
  typedef struct {
    logic [31:0] pc;
    lsu_mem_tx_s writes[$];
    lsu_mem_tx_s reads[$];
  } completed_lsu_instr_s;

  //----------------------------------------------------------------------------
  // Struct: expected_lsu_instr_s
  // Description: Holds the expected MPACT and Spike memory read and write row
  //              transactions for a retired instruction.
  //
  // Fields:
  //   pc           - The program counter of the retired instruction.
  //   insn         - The instruction bit pattern.
  //   mpact_writes - Queue of coalesced 16-byte memory writes from MPACT.
  //   spike_writes - Queue of coalesced 16-byte memory writes from Spike.
  //   mpact_reads  - Queue of coalesced 16-byte memory reads from MPACT.
  //   spike_reads  - Queue of coalesced 16-byte memory reads from Spike.
  //----------------------------------------------------------------------------
  typedef struct {
    logic [31:0] pc;
    logic [31:0] insn;
    lsu_mem_tx_s mpact_writes[$];
    lsu_mem_tx_s spike_writes[$];
    lsu_mem_tx_s mpact_reads[$];
    lsu_mem_tx_s spike_reads[$];
  } expected_lsu_instr_s;

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
    virtual coralnpu_lsu_if lsu_vif;

    // Event triggered by the RVVI monitor when instructions retire
    uvm_event instruction_retired_event;
    uvm_event cosim_mismatch_event;
    string test_elf;
    int unsigned initial_misa_value;
    int unsigned entry_point = 0;

    spike_cosim_checker spike_checker;
    bit trace_logging_enabled = 0;
    bit lsu_mem_check_enabled = 1;
    bit mismatch_detected = 0;
    bit [31:0] dirty_gprs = 0;
    bit dirty_stack[int];

    completed_lsu_instr_s completed_lsu_q[$];
    expected_lsu_instr_s pending_expected_lsu_q[$];
    lsu_mem_tx_s cur_lsu_writes[$];
    lsu_mem_tx_s cur_lsu_reads[$];
    bit cur_lsu_faulted = 0;
    bit pending_tx_valid[8];
    bit pending_tx_write[8];
    logic [31:0] pending_tx_addr[8];
    logic [127:0] pending_tx_wdata[8];
    logic [15:0] pending_tx_mask[8];

    // Function: reset_cur_lsu_tracking
    // Clears in-flight LSU bus transaction tracking state for the active slot.
    function void reset_cur_lsu_tracking();
      cur_lsu_writes.delete();
      cur_lsu_reads.delete();
      cur_lsu_faulted = 0;
      for (int t = 0; t < 8; t++) begin
        pending_tx_valid[t] = 0;
        pending_tx_write[t] = 0;
        pending_tx_addr[t]  = 0;
        pending_tx_wdata[t] = 0;
        pending_tx_mask[t]  = 0;
      end
    endfunction

    // Function: coalesce_mem_tx
    // Coalesces a 16-byte-aligned memory access into an instruction's transaction
    // queue, merging byte masks and data for accesses targeting the same row.
    function void coalesce_mem_tx(ref lsu_mem_tx_s tx_q[$], input logic [31:0] row_addr,
                                  input logic [127:0] data, input logic [15:0] mask,
                                  input bit mask_data);
      int found_idx = -1;
      for (int i = 0; i < tx_q.size(); i++) begin
        if (tx_q[i].addr == row_addr) begin
          found_idx = i;
          break;
        end
      end
      if (found_idx == -1) begin
        lsu_mem_tx_s new_tx;
        new_tx.addr = row_addr;
        new_tx.data = 0;
        new_tx.mask = 0;
        tx_q.push_back(new_tx);
        found_idx = tx_q.size() - 1;
      end
      for (int b = 0; b < 16; b++) begin
        if (mask_data) begin
          if (mask[b]) begin
            tx_q[found_idx].data[b*8+:8] = data[b*8+:8];
          end
        end else begin
          tx_q[found_idx].data[b*8+:8] = data[b*8+:8];
        end
      end
      tx_q[found_idx].mask |= mask;
    endfunction

    // Function: sample_lsu_cycle
    // Samples the internal LSU bus interface on each clock cycle, coalescing
    // 128-bit memory reads/writes per instruction and matching completed LSU
    // instructions against retired RVVI instructions.
    function void sample_lsu_cycle();
      if (lsu_vif == null) return;
      if (!lsu_vif.resetn) begin
        reset_cur_lsu_tracking();
        completed_lsu_q.delete();
        pending_expected_lsu_q.delete();
        return;
      end

      if (lsu_vif.slot_fault_valid || lsu_vif.lsu_fault_valid) begin
        cur_lsu_faulted = 1;
      end

      // 1. Process bus response for the active instruction in slot
      if (lsu_vif.bus_resp_valid) begin
        logic [2:0] r_txid = lsu_vif.bus_resp_txid;
        if (lsu_vif.bus_resp_fault) begin
          cur_lsu_faulted = 1;
        end else if (pending_tx_valid[r_txid]) begin
          if (pending_tx_write[r_txid]) begin
            coalesce_mem_tx(cur_lsu_writes, pending_tx_addr[r_txid], pending_tx_wdata[r_txid],
                            pending_tx_mask[r_txid], 1'b1);
          end else begin
            coalesce_mem_tx(cur_lsu_reads, pending_tx_addr[r_txid], lsu_vif.bus_resp_rdata,
                            pending_tx_mask[r_txid], 1'b0);
          end
        end
        pending_tx_valid[r_txid] = 0;
      end

      // 2. Process bus request handshake for the active instruction in slot
      if (lsu_vif.bus_req_valid && lsu_vif.bus_req_ready) begin
        logic [2:0] req_txid = lsu_vif.bus_req_txid;
        pending_tx_valid[req_txid] = 1;
        pending_tx_write[req_txid] = lsu_vif.bus_req_write;
        pending_tx_addr[req_txid]  = {lsu_vif.bus_req_row_addr, 4'h0};
        pending_tx_wdata[req_txid] = lsu_vif.bus_req_wdata;
        pending_tx_mask[req_txid]  = lsu_vif.bus_req_wmask;
      end

      // 3. Finalize instruction when slot completes (slot_active && uop_ready)
      if (lsu_vif.slot_active && lsu_vif.uop_ready) begin
        if (!cur_lsu_faulted && (cur_lsu_writes.size() > 0 || cur_lsu_reads.size() > 0)) begin
          completed_lsu_instr_s done_instr;
          cur_lsu_writes.sort(x) with (x.addr);
          cur_lsu_reads.sort(x) with (x.addr);
          done_instr.pc     = lsu_vif.slot_pc;
          done_instr.writes = cur_lsu_writes;
          done_instr.reads  = cur_lsu_reads;
          if (pending_expected_lsu_q.size() > 0 &&
              pending_expected_lsu_q[0].pc == done_instr.pc) begin
            expected_lsu_instr_s exp_instr = pending_expected_lsu_q.pop_front();
            if (!compare_lsu_transactions(done_instr, exp_instr)) begin
              mismatch_detected = 1;
              uvm_config_db#(bit)::set(null, "*", "cosim_mismatch_detected", 1);
              if (cosim_mismatch_event != null) cosim_mismatch_event.trigger();
            end
          end else begin
            completed_lsu_q.push_back(done_instr);
          end
        end
        reset_cur_lsu_tracking();
      end else if (!lsu_vif.slot_active) begin
        reset_cur_lsu_tracking();
      end
    endfunction

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

      begin
        int lsu_mem_check_arg = 1;
        if ($value$plusargs("COSIM_LSU_MEM_CHECK=%d", lsu_mem_check_arg)) begin
          lsu_mem_check_enabled = (lsu_mem_check_arg != 0);
        end else if ($test$plusargs("NO_COSIM_LSU_MEM_CHECK")) begin
          lsu_mem_check_enabled = 0;
        end else if ($test$plusargs("COSIM_LSU_MEM_CHECK")) begin
          lsu_mem_check_enabled = 1;
        end
        void'(uvm_config_db#(bit)::get(this, "", "lsu_mem_check_enabled", lsu_mem_check_enabled));
      end

      if (!uvm_config_db#(virtual coralnpu_lsu_if)::get(this, "", "lsu_vif", lsu_vif)) begin
        if (lsu_mem_check_enabled) begin
          `uvm_warning(get_type_name(), "LSU virtual interface 'lsu_vif' not found in config_db")
        end
      end

      if ($test$plusargs("COSIM_TRACE_LOG")) begin
        trace_logging_enabled = 1;
      end

      instruction_retired_event = new("instruction_retired_event");
      uvm_config_db#(uvm_event)::set(null, "*.m_rvvi_agent.monitor", "instruction_retired_event",
                                     instruction_retired_event);
    endfunction

    // Task: collect_retired_instructions
    // Waits until at least one instruction retires on the RVVI trace interface
    // and collects all instructions retiring in that cycle. When LSU memory
    // transaction checking is enabled, steps every clock edge to sample
    // intermediate LSU activity; otherwise sleeps on instruction_retired_event
    // until the next retirement cycle.
    virtual task collect_retired_instructions(ref retired_instr_info_s retired_instr_q[$]);
      retired_instr_q.delete();

      forever begin
        if (lsu_mem_check_enabled) begin
          // Sample the LSU interface on every clock edge so transactions
          // completing between instruction retirements are captured.
          @(posedge rvvi_vif.clk);
          sample_lsu_cycle();
        end else begin
          // Skip idle cycles by sleeping until the RVVI monitor triggers a
          // retirement event.
          instruction_retired_event.wait_trigger();
        end

        for (int i = 0; i < rvvi_vif.RETIRE; i++) begin
          if (rvvi_vif.valid[0][i]) begin
            retired_instr_info_s info;
            info.pc = rvvi_vif.pc_rdata[0][i];
            info.insn = rvvi_vif.insn[0][i];
            info.x_wb = rvvi_vif.x_wb[0][i];
            info.f_wb = rvvi_vif.f_wb[0][i];
            info.v_wb = rvvi_vif.v_wb[0][i];
            info.t_wb = rvvi_vif.t_wb[0][i];
            info.trap = rvvi_vif.trap[0][i];
            info.retire_index = i;
            retired_instr_q.push_back(info);
            `uvm_info(get_type_name(), $sformatf("RTL Retired: PC=0x%h, Insn=0x%h", info.pc,
                                                 info.insn), UVM_HIGH)
          end
        end
        if (retired_instr_q.size() > 0) break;
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

      // 2. Align and Step Spike
      begin
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
      if (mpact_get_register("sp", pre_step_sp) != 0) begin
        `uvm_error("COSIM_API_FAIL", "Failed to get pre-step SP from MPACT.")
      end
      if (mpact_step(rtl_instr) != 0) begin
        `uvm_error("COSIM_STEP_FAIL", "mpact_step() DPI call failed.")
        mismatch_detected = 1;
        retired_instr_q.delete(match_index);
        return;
      end

      // 4. Update dirty registers and synchronize varying CSRs
      skip_mask = update_dirty_registers(retired_instr_q[match_index], pre_step_sp);
      if (skip_mask != 0) begin
        for (int r = 1; r < 32; r++) begin
          if (skip_mask[r]) begin
            logic [31:0] rtl_val = rvvi_vif.x_wdata[0][retired_instr_q[match_index].retire_index][r];
            string rname = $sformatf("x%0d", r);
            void'(mpact_set_register(rname, rtl_val));
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

      // sim_config_t is a packed struct passed to C via DPI. In SV packed structs,
      // the first field is at MSB (bits 127:96) while in C (little-endian) the first
      // member is at byte offset 0. Streaming operator {<<32{...}} packs 32-bit slices
      // in reverse order so that itcm_start_address aligns with C struct byte offset 0.
`ifdef ZVT_ON
      dpi_cfg_s = {<<32{itcm_start_address, itcm_length, initial_misa_value, 32'd2}};
`else
      dpi_cfg_s = {<<32{itcm_start_address, itcm_length, initial_misa_value, 32'd1}};
`endif

      test_start_event.wait_trigger();
      forever begin
        string current_test_elf;
        string mem_patch_file = "";
        bit has_entry_point;

        if (!mismatch_detected && pending_expected_lsu_q.size() > 0) begin
          `uvm_error(
              "COSIM_MISMATCH",
              $sformatf(
                  "Test ended with %0d unverified in-flight LSU transaction(s) (first PC=0x%08h)",
                  pending_expected_lsu_q.size(), pending_expected_lsu_q[0].pc))
        end

        mismatch_detected = 0;
        dirty_gprs = 0;
        dirty_stack.delete();
        retired_instr_q.delete();
        completed_lsu_q.delete();
        pending_expected_lsu_q.delete();
        reset_cur_lsu_tracking();
        uvm_config_db#(bit)::set(null, "*", "cosim_mismatch_detected", 0);
        if (uvm_config_db#(string)::get(this, "", "current_test_elf", current_test_elf)) begin
          test_elf = current_test_elf;
        end
        void'(uvm_config_db#(string)::get(this, "", "mem_patch_file", mem_patch_file));
        has_entry_point = uvm_config_db#(int unsigned)::get(this, "", "entry_point", entry_point);
        if (!has_entry_point) begin
          entry_point = 0;
        end
        `uvm_info(get_type_name(), $sformatf(
                  "Initializing Multi-ISS Co-Sim for %s (entry: 0x%h, custom: %0d, lsu_mem_check: %0d)",
                  test_elf,
                  entry_point,
                  has_entry_point,
                  lsu_mem_check_enabled
                  ), UVM_LOW)

        // Initialize MPACT
        void'(mpact_fini());
        if (mpact_set_mem_tracing(lsu_mem_check_enabled) != 0) begin
          `uvm_fatal(get_type_name(), "MPACT DPI set_mem_tracing failed.")
        end
        itcm_start_address = memory_map_pkg::ITCM_START_ADDR;
        itcm_length = memory_map_pkg::ITCM_LENGTH;
`ifdef ZVT_ON
        dpi_cfg_s = {<<32{itcm_start_address, itcm_length, initial_misa_value, 32'd2}};
`else
        dpi_cfg_s = {<<32{itcm_start_address, itcm_length, initial_misa_value, 32'd1}};
`endif
        if (mpact_init() != 0) `uvm_fatal(get_type_name(), "MPACT simulator DPI init failed.")
        if (mpact_config(dpi_cfg_s) != 0) `uvm_fatal(get_type_name(), "MPACT DPI config failed.")
        if (mpact_load_program(test_elf) != 0) begin
          `uvm_fatal(get_type_name(), "MPACT DPI load program failed.")
        end
        if (has_entry_point) begin
          if (mpact_set_register("pc", entry_point) != 0) begin
            `uvm_fatal(get_type_name(), $sformatf("MPACT DPI failed to set entry point 0x%h.",
                                                  entry_point))
          end
        end
        if (mem_patch_file != "") begin
          if (mpact_apply_memory_patch(mem_patch_file) != 0) begin
            `uvm_fatal(get_type_name(), $sformatf("MPACT DPI failed to apply memory patch: %s",
                                                  mem_patch_file))
          end
        end

        // Initialize Spike
        spike_checker.initialize(test_elf, entry_point, has_entry_point, mem_patch_file,
                                 lsu_mem_check_enabled);

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
              if (lsu_mem_check_enabled && pending_expected_lsu_q.size() > 0 &&
                  mpact_is_halted()) begin
                int drain_cycles = 0;
                phase.raise_objection(this, "Draining in-flight LSU transactions");
                while (pending_expected_lsu_q.size() > 0 && !mismatch_detected &&
                       drain_cycles < 512) begin
                  @(posedge rvvi_vif.clk);
                  sample_lsu_cycle();
                  drain_cycles++;
                end
                phase.drop_objection(this, "Drained in-flight LSU transactions");
                if (mismatch_detected) break;
              end
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

    // Function: check_phase
    // Verifies at end of test that all expected in-flight LSU transactions
    // have completed and been checked.
    virtual function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (!mismatch_detected && pending_expected_lsu_q.size() > 0) begin
        `uvm_error(
            "COSIM_MISMATCH",
            $sformatf(
                "Test ended with %0d unverified in-flight LSU transaction(s) (first PC=0x%08h)",
                pending_expected_lsu_q.size(), pending_expected_lsu_q[0].pc))
      end
    endfunction

    // Function: diagnose_and_report_mismatch
    // Formats a structured 3-way diagnosis table comparing RTL, MPACT, and Spike.
    virtual function void report_3way_mismatch(
        string reg_name, logic [31:0] pc, logic [31:0] insn, string rtl_str, string mpact_str,
        string spike_str, bit rtl_eq_mpact, bit rtl_eq_spike, bit mpact_eq_spike);
      string diagnosis;

      if (mpact_eq_spike && !rtl_eq_mpact) begin
        diagnosis = "🔴 RTL BUG (MPACT and Spike agree; RTL state differs)";
      end else if (rtl_eq_spike && !rtl_eq_mpact) begin
        diagnosis = "🟡 MPACT DIVERGENCE (RTL and Spike agree; MPACT differs)";
      end else if (rtl_eq_mpact && !rtl_eq_spike) begin
        diagnosis = "🟡 SPIKE DIVERGENCE (RTL and MPACT agree; Spike differs)";
      end else begin
        diagnosis = "⚠️ MULTI-WAY DIVERGENCE (All three models report differing values)";
      end

      `uvm_error("COSIM_MISMATCH", $sformatf(
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

    // Function: compare_lsu_transactions
    // Compares coalesced 16-byte LSU memory write (addr, wdata, wmask) and read
    // (addr, rdata, rmask) transactions for a retired instruction across RTL,
    // MPACT, and Spike.
    virtual function bit compare_lsu_transactions(completed_lsu_instr_s rtl_entry,
                                                  expected_lsu_instr_s exp_entry);
      int num_rtl_writes = rtl_entry.writes.size();
      int num_mpact_writes = exp_entry.mpact_writes.size();
      int num_spike_writes = exp_entry.spike_writes.size();
      int num_rtl_reads = rtl_entry.reads.size();
      int num_mpact_reads = exp_entry.mpact_reads.size();
      int num_spike_reads = exp_entry.spike_reads.size();

      // 6a. Memory Write Transactions (mem_addr, mem_wdata, mem_wmask)
      if (num_rtl_writes != num_mpact_writes || num_rtl_writes != num_spike_writes) begin
        report_3way_mismatch("LSU_MEM_WRITE_COUNT", exp_entry.pc, exp_entry.insn, $sformatf(
                             "%0d", num_rtl_writes), $sformatf("%0d", num_mpact_writes), $sformatf(
                             "%0d", num_spike_writes), (num_rtl_writes == num_mpact_writes),
                             (num_rtl_writes == num_spike_writes),
                             (num_mpact_writes == num_spike_writes));
        return 0;
      end

      for (int i = 0; i < num_rtl_writes; i++) begin
        logic [31:0]  rtl_addr    = rtl_entry.writes[i].addr;
        logic [15:0]  rtl_wmask   = rtl_entry.writes[i].mask;
        logic [31:0]  mpact_addr  = exp_entry.mpact_writes[i].addr;
        logic [15:0]  mpact_wmask = exp_entry.mpact_writes[i].mask;
        logic [31:0]  spike_addr  = exp_entry.spike_writes[i].addr;
        logic [15:0]  spike_wmask = exp_entry.spike_writes[i].mask;
        logic [127:0] rtl_wdata_masked   = 0;
        logic [127:0] mpact_wdata_masked = 0;
        logic [127:0] spike_wdata_masked = 0;
        bit rtl_eq_mpact;
        bit rtl_eq_spike;
        bit mpact_eq_spike;

        for (int b = 0; b < 16; b++) begin
          if (rtl_wmask[b]) rtl_wdata_masked[b*8+:8] = rtl_entry.writes[i].data[b*8+:8];
          if (mpact_wmask[b]) mpact_wdata_masked[b*8+:8] = exp_entry.mpact_writes[i].data[b*8+:8];
          if (spike_wmask[b]) spike_wdata_masked[b*8+:8] = exp_entry.spike_writes[i].data[b*8+:8];
        end

        if (trace_logging_enabled) begin
          `uvm_info(
              "COSIM_TRACE",
              $sformatf(
                  "PC=0x%08h Insn=0x%08h | MEM_WRITE[%0d] RTL: addr=0x%08h mask=0x%04h data=0x%032h | MPACT: addr=0x%08h mask=0x%04h data=0x%032h | Spike: addr=0x%08h mask=0x%04h data=0x%032h",
                  exp_entry.pc, exp_entry.insn, i, rtl_addr, rtl_wmask, rtl_wdata_masked,
                  mpact_addr, mpact_wmask, mpact_wdata_masked, spike_addr, spike_wmask,
                  spike_wdata_masked), UVM_NONE)
        end

        rtl_eq_mpact = (rtl_addr == mpact_addr) && (rtl_wmask == mpact_wmask) &&
                       (rtl_wdata_masked == mpact_wdata_masked);
        rtl_eq_spike = (rtl_addr == spike_addr) && (rtl_wmask == spike_wmask) &&
                       (rtl_wdata_masked == spike_wdata_masked);
        mpact_eq_spike = (mpact_addr == spike_addr) && (mpact_wmask == spike_wmask) &&
                         (mpact_wdata_masked == spike_wdata_masked);

        if (!rtl_eq_mpact || !rtl_eq_spike) begin
          report_3way_mismatch(
              $sformatf("LSU_MEM_WRITE[%0d]", i), exp_entry.pc, exp_entry.insn, $sformatf(
              "addr=0x%08h wmask=0x%04h wdata=0x%032h", rtl_addr, rtl_wmask, rtl_wdata_masked),
              $sformatf(
              "addr=0x%08h wmask=0x%04h wdata=0x%032h", mpact_addr, mpact_wmask, mpact_wdata_masked
              ), $sformatf(
              "addr=0x%08h wmask=0x%04h wdata=0x%032h", spike_addr, spike_wmask, spike_wdata_masked
              ), rtl_eq_mpact, rtl_eq_spike, mpact_eq_spike);
          return 0;
        end
      end

      // 6b. Memory Read Transactions (mem_addr, mem_rdata, mem_rmask)
      if (num_rtl_reads != num_mpact_reads || num_rtl_reads != num_spike_reads) begin
        report_3way_mismatch("LSU_MEM_READ_COUNT", exp_entry.pc, exp_entry.insn, $sformatf(
                             "%0d", num_rtl_reads), $sformatf("%0d", num_mpact_reads), $sformatf(
                             "%0d", num_spike_reads), (num_rtl_reads == num_mpact_reads),
                             (num_rtl_reads == num_spike_reads),
                             (num_mpact_reads == num_spike_reads));
        return 0;
      end

      for (int i = 0; i < num_rtl_reads; i++) begin
        logic [31:0]  rtl_addr    = rtl_entry.reads[i].addr;
        logic [15:0]  rtl_rmask   = rtl_entry.reads[i].mask;
        logic [31:0]  mpact_addr  = exp_entry.mpact_reads[i].addr;
        logic [15:0]  mpact_rmask = exp_entry.mpact_reads[i].mask;
        logic [31:0]  spike_addr  = exp_entry.spike_reads[i].addr;
        logic [15:0]  spike_rmask = exp_entry.spike_reads[i].mask;
        logic [127:0] rtl_rdata_masked   = 0;
        logic [127:0] mpact_rdata_masked = 0;
        logic [127:0] spike_rdata_masked = 0;
        bit rtl_eq_mpact;
        bit rtl_eq_spike;
        bit mpact_eq_spike;

        for (int b = 0; b < 16; b++) begin
          if (mpact_rmask[b]) begin
            rtl_rdata_masked[b*8+:8]   = rtl_entry.reads[i].data[b*8+:8];
            mpact_rdata_masked[b*8+:8] = exp_entry.mpact_reads[i].data[b*8+:8];
          end
          if (spike_rmask[b]) begin
            spike_rdata_masked[b*8+:8] = exp_entry.spike_reads[i].data[b*8+:8];
          end
        end

        if (trace_logging_enabled) begin
          `uvm_info(
              "COSIM_TRACE",
              $sformatf(
                  "PC=0x%08h Insn=0x%08h | MEM_READ[%0d] RTL: addr=0x%08h mask=0x%04h data=0x%032h | MPACT: addr=0x%08h mask=0x%04h data=0x%032h | Spike: addr=0x%08h mask=0x%04h data=0x%032h",
                  exp_entry.pc, exp_entry.insn, i, rtl_addr, rtl_rmask, rtl_rdata_masked,
                  mpact_addr, mpact_rmask, mpact_rdata_masked, spike_addr, spike_rmask,
                  spike_rdata_masked), UVM_NONE)
        end

        // In LsuSuperSlot (Lsu.scala), bus_req_wmask on reads is driven from the
        // active byte cells in the 16-cell scheduling window (bundle.reduce(_ | _)).
        // For multi-window vector loads (>16 cells), subsequent cells targeting the
        // same 16-byte row snoop the full 128-bit read response without re-requesting,
        // so rtl_rmask is a non-empty subset of mpact_rmask/spike_rmask while all
        // architecturally read bytes in the 128-bit row are checked in rtl_rdata_masked.
        rtl_eq_mpact = (rtl_addr == mpact_addr) && (rtl_rmask != 16'h0) &&
                       ((rtl_rmask & ~mpact_rmask) == 16'h0) &&
                       (rtl_rdata_masked == mpact_rdata_masked);
        rtl_eq_spike = (rtl_addr == spike_addr) && (rtl_rmask != 16'h0) &&
                       ((rtl_rmask & ~spike_rmask) == 16'h0) &&
                       (mpact_rmask == spike_rmask) &&
                       (rtl_rdata_masked == spike_rdata_masked);
        mpact_eq_spike = (mpact_addr == spike_addr) && (mpact_rmask == spike_rmask) &&
                         (mpact_rdata_masked == spike_rdata_masked);

        if (!rtl_eq_mpact || !rtl_eq_spike) begin
          report_3way_mismatch(
              $sformatf("LSU_MEM_READ[%0d]", i), exp_entry.pc, exp_entry.insn, $sformatf(
              "addr=0x%08h rmask=0x%04h rdata=0x%032h", rtl_addr, rtl_rmask, rtl_rdata_masked),
              $sformatf(
              "addr=0x%08h rmask=0x%04h rdata=0x%032h", mpact_addr, mpact_rmask, mpact_rdata_masked
              ), $sformatf(
              "addr=0x%08h rmask=0x%04h rdata=0x%032h", spike_addr, spike_rmask, spike_rdata_masked
              ), rtl_eq_mpact, rtl_eq_spike, mpact_eq_spike);
          return 0;
        end
      end

      return 1;
    endfunction

    // Function: step_and_compare_3way
    // Compares register writeback, CSR, and LSU memory transaction state across
    // RTL, MPACT, and Spike at the retired instruction boundary.
    virtual function bit step_and_compare_3way(retired_instr_info_s rtl_info,
                                               input bit [31:0] skip_mask);
      int unsigned rd_index;
      string reg_name;

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

          if (mpact_get_register(reg_name, mpact_val) != 0) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT GPR %s", reg_name));
            mpact_ok = 0;
          end

          if (!spike_checker.get_gpr(reg_name, spike_val)) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike GPR %s", reg_name));
            spike_ok = 0;
          end

          if (trace_logging_enabled) begin
            `uvm_info("COSIM_TRACE",
                      $sformatf(
                          "PC=0x%08h Insn=0x%08h | RTL: %s=0x%08h | MPACT: 0x%08h | Spike: 0x%08h",
                          rtl_info.pc, rtl_info.insn, reg_name, rtl_val, mpact_val, spike_val),
                      UVM_NONE)
          end

          if ((mpact_ok && mpact_val != rtl_val) || (spike_ok && spike_val != rtl_val)) begin
            report_3way_mismatch(reg_name, rtl_info.pc, rtl_info.insn, $sformatf("0x%08h", rtl_val),
                                 $sformatf("0x%08h", mpact_val), $sformatf("0x%08h", spike_val),
                                 (mpact_val == rtl_val), (spike_val == rtl_val),
                                 (mpact_val == spike_val));
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

          if (mpact_get_register(reg_name, mpact_val) != 0) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT FPR %s", reg_name));
            mpact_ok = 0;
          end

          if (!spike_checker.get_fpr(reg_name, spike_val)) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike FPR %s", reg_name));
            spike_ok = 0;
          end

          if (trace_logging_enabled) begin
            `uvm_info("COSIM_TRACE",
                      $sformatf(
                          "PC=0x%08h Insn=0x%08h | RTL: %s=0x%08h | MPACT: 0x%08h | Spike: 0x%08h",
                          rtl_info.pc, rtl_info.insn, reg_name, rtl_val, mpact_val, spike_val),
                      UVM_NONE)
          end

          if ((mpact_ok && mpact_val != rtl_val) || (spike_ok && spike_val != rtl_val)) begin
            report_3way_mismatch(reg_name, rtl_info.pc, rtl_info.insn, $sformatf("0x%08h", rtl_val),
                                 $sformatf("0x%08h", mpact_val), $sformatf("0x%08h", spike_val),
                                 (mpact_val == rtl_val), (spike_val == rtl_val),
                                 (mpact_val == spike_val));
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

              if (mpact_get_vector_register(reg_name, mpact_vval) != 0) begin
                `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT VPR %s", reg_name));
                mpact_ok = 0;
              end

              if (!spike_checker.get_vpr(reg_name, spike_vval)) begin
                `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike VPR %s", reg_name));
                spike_ok = 0;
              end

              if (trace_logging_enabled) begin
                `uvm_info(
                    "COSIM_TRACE",
                    $sformatf(
                        "PC=0x%08h Insn=0x%08h | RTL: %s=0x%032h | MPACT: 0x%032h | Spike: 0x%032h",
                        rtl_info.pc, rtl_info.insn, reg_name, rtl_vval, mpact_vval, spike_vval),
                    UVM_NONE)
              end

              if ((mpact_ok && mpact_vval != rtl_vval) || (spike_ok && spike_vval != rtl_vval)) begin
                report_3way_mismatch(reg_name, rtl_info.pc, rtl_info.insn, $sformatf(
                                     "0x%032h", rtl_vval), $sformatf("0x%032h", mpact_vval),
                                     $sformatf("0x%032h", spike_vval), (mpact_vval == rtl_vval),
                                     (spike_vval == rtl_vval), (mpact_vval == spike_vval));
                return 0;
              end
            end
          end
        end
      end

      // 4. Tile Writeback Detection and Verification
      if (rtl_info.t_wb != 0) begin
        for (int i = 0; i < 16; i++) begin
          if (rtl_info.t_wb[i]) begin
            reg_name = $sformatf("mt%0d", i);
            if (trace_logging_enabled) begin
              `uvm_info("COSIM_TRACE",
                        $sformatf("PC=0x%08h Insn=0x%08h | RTL: %s writeback (retire_index=%0d)",
                                  rtl_info.pc, rtl_info.insn, reg_name, rtl_info.retire_index),
                        UVM_NONE)
            end

            begin
              logic [1023:0][31:0] mpact_words;
              logic [1023:0][31:0] spike_words;
              int unsigned mpact_tew = 0;
              int unsigned spike_tew = 0;
              int unsigned mpact_word_count = 0;
              int unsigned spike_word_count = 0;
              bit mpact_ok = 1;
              bit spike_ok = 1;

              if (mpact_get_current_matrix_tile(
                      i, mpact_words, mpact_tew, mpact_word_count
                  ) != 0) begin
                `uvm_error("COSIM_API_FAIL", $sformatf(
                                                 "Failed to get MPACT matrix tile %s at PC 0x%08h",
                                                 reg_name, rtl_info.pc))
                mpact_ok = 0;
              end

              if (!spike_checker.get_current_matrix_tile(
                      i, spike_words, spike_tew, spike_word_count
                  )) begin
                `uvm_error("COSIM_API_FAIL", $sformatf(
                                                 "Failed to get Spike matrix tile %s at PC 0x%08h",
                                                 reg_name, rtl_info.pc))
                spike_ok = 0;
              end

              begin
                int unsigned valid_word_count = mpact_ok ? mpact_word_count :
                                                spike_ok ? spike_word_count : 0;
                int unsigned current_tew = mpact_ok ? mpact_tew : spike_tew;
                if (valid_word_count > 0) begin
                  int num_128b_chunks = valid_word_count / 4;
                  for (int chunk = 0; chunk < num_128b_chunks && chunk < 16; chunk++) begin
                    logic [127:0] rtl_chunk = rvvi_vif.t_wdata[0][rtl_info.retire_index][i][chunk];
                    logic [127:0] mpact_chunk = {
                      mpact_words[chunk*4+3],
                      mpact_words[chunk*4+2],
                      mpact_words[chunk*4+1],
                      mpact_words[chunk*4+0]
                    };
                    logic [127:0] spike_chunk = {
                      spike_words[chunk*4+3],
                      spike_words[chunk*4+2],
                      spike_words[chunk*4+1],
                      spike_words[chunk*4+0]
                    };

                    if ((mpact_ok && mpact_chunk != rtl_chunk) ||
                        (spike_ok && spike_chunk != rtl_chunk)) begin
                      string tile_reg_name = $sformatf(
                          "%s (chunk %0d / %0d, TEW=%0d)",
                          reg_name,
                          chunk,
                          num_128b_chunks,
                          current_tew
                      );
                      report_3way_mismatch(tile_reg_name, rtl_info.pc, rtl_info.insn, $sformatf(
                                           "0x%032h", rtl_chunk), $sformatf("0x%032h", mpact_chunk),
                                           $sformatf("0x%032h", spike_chunk),
                                           (mpact_chunk == rtl_chunk), (spike_chunk == rtl_chunk),
                                           (mpact_chunk == spike_chunk));
                      return 0;
                    end
                  end
                end
              end
            end
          end
        end
      end

      // CSR Writeback Detection
      if (rvvi_vif.csr_wb[0][rtl_info.retire_index] != 0) begin
        for (int i = 0; i < 4096; i++) begin
          if (rvvi_vif.csr_wb[0][rtl_info.retire_index][i]) begin
            string csr_name = get_csr_name(i);
            string csr_label = $sformatf("CSR[0x%03x] (%s)", i, csr_name);
            logic [31:0] rtl_csr_wdata = rvvi_vif.csr[0][rtl_info.retire_index][i];
            logic [31:0] check_mask = get_csr_compare_mask(i);
            logic [31:0] mpact_csr_val = 0;
            logic [31:0] spike_csr_val = 0;
            bit mpact_ok = 1;
            bit spike_ok = 1;

            if (check_mask == 32'h0000_0000) begin
              continue;
            end

            if (mpact_get_register(csr_name, mpact_csr_val) != 0) begin
              `uvm_warning("COSIM_CSR_UNKNOWN",
                           $sformatf("Cannot check CSR '%s' (0x%03x) - not in MPACT", csr_name, i))
              mpact_ok = 0;
            end

            if (!spike_checker.get_gpr(csr_name, spike_csr_val)) begin
              `uvm_warning("COSIM_CSR_UNKNOWN",
                           $sformatf("Cannot check CSR '%s' (0x%03x) - not in Spike", csr_name, i))
              spike_ok = 0;
            end

            if (trace_logging_enabled) begin
              `uvm_info(
                  "COSIM_TRACE",
                  $sformatf(
                      "PC=0x%08h Insn=0x%08h | RTL: %s=0x%08h | MPACT: 0x%08h | Spike: 0x%08h (mask: 0x%08h)",
                      rtl_info.pc, rtl_info.insn, csr_label, rtl_csr_wdata, mpact_csr_val,
                      spike_csr_val, check_mask), UVM_NONE)
            end

            begin
              bit rtl_eq_mpact = mpact_ok ?
                  ((mpact_csr_val & check_mask) == (rtl_csr_wdata & check_mask)) : 1'b1;
              bit rtl_eq_spike = spike_ok ?
                  ((spike_csr_val & check_mask) == (rtl_csr_wdata & check_mask)) : 1'b1;
              bit mpact_eq_spike = (mpact_ok && spike_ok) ?
                  ((mpact_csr_val & check_mask) == (spike_csr_val & check_mask)) : 1'b1;

              if (!rtl_eq_mpact || !rtl_eq_spike) begin
                report_3way_mismatch(csr_label, rtl_info.pc, rtl_info.insn, $sformatf(
                                     "0x%08h (mask: 0x%08h)", rtl_csr_wdata, check_mask),
                                     mpact_ok ? $sformatf("0x%08h", mpact_csr_val) : "UNKNOWN",
                                     spike_ok ? $sformatf("0x%08h", spike_csr_val) : "UNKNOWN",
                                     rtl_eq_mpact, rtl_eq_spike, mpact_eq_spike);
                return 0;  // FAIL
              end
            end

            `uvm_info(
                "COSIM_CSR_MATCH",
                $sformatf(
                    "%s compare success at PC 0x%08x, Insn=0x%08x. RTL: 0x%08x, MPACT: 0x%08x, Spike: 0x%08x (mask: 0x%08x)",
                    csr_label, rtl_info.pc, rtl_info.insn, rtl_csr_wdata, mpact_csr_val,
                    spike_csr_val, check_mask), UVM_HIGH)
          end
        end
      end

      // 6. LSU Memory Write and Read Transaction Verification (3-Way: RTL vs MPACT vs Spike)
      if (lsu_mem_check_enabled && !rtl_info.trap && lsu_vif != null) begin
        int unsigned mpact_num_writes = 0;
        int unsigned spike_num_writes = 0;
        int unsigned mpact_num_reads = 0;
        int unsigned spike_num_reads = 0;
        expected_lsu_instr_s exp_entry;

        if (mpact_get_num_mem_writes(mpact_num_writes) != 0) begin
          `uvm_error("COSIM_API_FAIL", "Failed to get num_mem_writes from MPACT")
          return 0;
        end
        if (!spike_checker.get_num_mem_writes(spike_num_writes)) begin
          `uvm_error("COSIM_API_FAIL", "Failed to get num_mem_writes from Spike")
          return 0;
        end
        if (mpact_get_num_mem_reads(mpact_num_reads) != 0) begin
          `uvm_error("COSIM_API_FAIL", "Failed to get num_mem_reads from MPACT")
          return 0;
        end
        if (!spike_checker.get_num_mem_reads(spike_num_reads)) begin
          `uvm_error("COSIM_API_FAIL", "Failed to get num_mem_reads from Spike")
          return 0;
        end

        exp_entry.pc   = rtl_info.pc;
        exp_entry.insn = rtl_info.insn;

        for (int i = 0; i < mpact_num_writes; i++) begin
          int unsigned addr = 0;
          logic [127:0] wdata = 0;
          int unsigned wmask_u = 0;
          lsu_mem_tx_s tx;
          if (mpact_get_mem_write(i, addr, wdata, wmask_u) != 0) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT mem_write[%0d]", i))
            return 0;
          end
          tx.addr = addr;
          tx.data = wdata;
          tx.mask = wmask_u[15:0];
          exp_entry.mpact_writes.push_back(tx);
        end

        for (int i = 0; i < spike_num_writes; i++) begin
          int unsigned addr = 0;
          logic [127:0] wdata = 0;
          int unsigned wmask_u = 0;
          lsu_mem_tx_s tx;
          if (!spike_checker.get_mem_write(i, addr, wdata, wmask_u)) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike mem_write[%0d]", i))
            return 0;
          end
          tx.addr = addr;
          tx.data = wdata;
          tx.mask = wmask_u[15:0];
          exp_entry.spike_writes.push_back(tx);
        end

        for (int i = 0; i < mpact_num_reads; i++) begin
          int unsigned addr = 0;
          logic [127:0] rdata = 0;
          int unsigned rmask_u = 0;
          lsu_mem_tx_s tx;
          if (mpact_get_mem_read(i, addr, rdata, rmask_u) != 0) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get MPACT mem_read[%0d]", i))
            return 0;
          end
          tx.addr = addr;
          tx.data = rdata;
          tx.mask = rmask_u[15:0];
          exp_entry.mpact_reads.push_back(tx);
        end

        for (int i = 0; i < spike_num_reads; i++) begin
          int unsigned addr = 0;
          logic [127:0] rdata = 0;
          int unsigned rmask_u = 0;
          lsu_mem_tx_s tx;
          if (!spike_checker.get_mem_read(i, addr, rdata, rmask_u)) begin
            `uvm_error("COSIM_API_FAIL", $sformatf("Failed to get Spike mem_read[%0d]", i))
            return 0;
          end
          tx.addr = addr;
          tx.data = rdata;
          tx.mask = rmask_u[15:0];
          exp_entry.spike_reads.push_back(tx);
        end

        if (pending_expected_lsu_q.size() == 0 &&
            completed_lsu_q.size() > 0 &&
            completed_lsu_q[0].pc == rtl_info.pc) begin
          completed_lsu_instr_s rtl_entry = completed_lsu_q.pop_front();
          if (!compare_lsu_transactions(rtl_entry, exp_entry)) begin
            return 0;
          end
        end else if (mpact_num_writes > 0 || spike_num_writes > 0 ||
                     mpact_num_reads > 0 || spike_num_reads > 0) begin
          // RTL LSU transaction is still in flight in lsu.rs / lsu.slot (e.g. tight loop stores);
          // queue expected MPACT & Spike transactions to be verified as soon as lsu.slot completes.
          pending_expected_lsu_q.push_back(exp_entry);
        end
      end else if (lsu_mem_check_enabled && rtl_info.trap) begin
        if (completed_lsu_q.size() > 0 && completed_lsu_q[0].pc == rtl_info.pc) begin
          void'(completed_lsu_q.pop_front());
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

        // Custom machine CSRs (0x7c0-0x7c7 mcontext0-mcontext7, 0x7e0-0x7e1 mpc/msp):
        // CoralNPU custom registers are not modeled in MPACT or Spike.
        12'h7c0, 12'h7c1, 12'h7c2, 12'h7c3, 12'h7c4, 12'h7c5, 12'h7c6, 12'h7c7, 12'h7e0, 12'h7e1:
        return 32'h0000_0000;

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
