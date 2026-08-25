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

`ifndef SPIKE_COSIM_CHECKER_SV
`define SPIKE_COSIM_CHECKER_SV

//----------------------------------------------------------------------------
// Class: spike_cosim_checker
// Description: Handles synchronization and comparison between RTL retirement
//              events and a Spike simulator commit log.
//----------------------------------------------------------------------------
class spike_cosim_checker extends uvm_object;
  `uvm_object_utils(spike_cosim_checker)

  spike_trace_service spike_svc;
  bit spike_enabled = 0;
  bit spike_synced = 0;
  spike_instr_txn_t current_spike_txns[$];

  function new(string name = "spike_cosim_checker");
    super.new(name);
  endfunction

  // Function: initialize
  // Opens the Spike log and enables checking if the log path is valid.
  function void initialize(string spike_log_path);
    spike_svc = spike_trace_service::type_id::create("spike_svc");
    if (spike_svc.open_trace(spike_log_path)) begin
      spike_enabled = 1;
      `uvm_info("SPIKE_CHECK", $sformatf("Spike 3-way cosim enabled. Log: %s", spike_log_path),
                UVM_LOW)
    end
  endfunction

  // Function: check_instruction
  // Synchronizes the Spike log to the retired RTL instruction and verifies
  // that all register writes reported by Spike match the RTL state.
  function void check_instruction(retired_instr_info_s rtl_info,
                                  virtual rvviTrace #(
                                      .ILEN  (32),
                                      .XLEN  (32),
                                      .FLEN  (32),
                                      .VLEN  (128),
                                      .NHART (1),
                                      .RETIRE(8)
                                  ) rvvi_vif,
                                  input bit [31:0] skip_mask);
    bit is_vec_insn;
    if (!spike_enabled) return;

    current_spike_txns.delete();

    // Synchronization Logic:
    // Spike logs often contain asynchronous events or non-retired instructions.
    // We must ensure the log is aligned with the current RTL retired instruction PC.

    // Attempt 1: If already synced, check if the next log entry matches the retired PC.
    if (spike_synced) begin
      spike_instr_txn_t t = spike_svc.get_next_instruction();
      if (!t.is_valid || t.pc != rtl_info.pc) begin
        // Out of sync (e.g., due to a trap or discontinuity).
        // Push back the mismatched transaction and trigger a re-seek.
        `uvm_info("SPIKE_RESYNC", $sformatf(
                                      "Spike out of sync at PC 0x%h (Spike 0x%h). Resyncing...",
                                      rtl_info.pc, t.pc), UVM_MEDIUM)
        spike_synced = 0;
        if (t.is_valid) spike_svc.push_front(t);
      end else begin
        current_spike_txns.push_back(t);
      end
    end

    // Attempt 2: If not synced (initially or lost sync), seek the log to the correct PC.
    if (!spike_synced) begin
      if (!spike_svc.seek_to_pc(rtl_info.pc)) begin
        `uvm_error("SPIKE_SYNC",
                   $sformatf("Could not sync Spike log to PC 0x%h. Disabling Spike checks.",
                             rtl_info.pc))
        spike_enabled = 0;
        return;
      end
      spike_synced = 1;
      current_spike_txns.push_back(spike_svc.get_next_instruction());
    end

    // Collect any additional writes for the same PC (e.g., for multi-register vector ops).
    forever begin
      spike_instr_txn_t next_t = spike_svc.get_next_instruction();
      if (next_t.is_valid && next_t.pc == rtl_info.pc) begin
        current_spike_txns.push_back(next_t);
      end else begin
        if (next_t.is_valid) spike_svc.push_front(next_t);
        break;
      end
    end

    // Perform Comparisons
    if (current_spike_txns.size() == 0) begin
      `uvm_error("SPIKE_EOF", "Spike log ended unexpectedly while searching for PC")
      spike_enabled = 0;
      return;
    end

    `uvm_info("SPIKE_MATCH", $sformatf(
              "Spike PC match: 0x%h (commit count: %0d)", rtl_info.pc, current_spike_txns.size()),
              UVM_HIGH)

    foreach (current_spike_txns[k]) begin
      // 1. GPR Verification
      if (current_spike_txns[k].has_gpr_write && current_spike_txns[k].rd != 0) begin
        if (skip_mask[current_spike_txns[k].rd]) begin
          `uvm_info("SPIKE_SKIP",
                    $sformatf("Skipping GPR[x%0d] verification at PC 0x%h due to dirty mask",
                              current_spike_txns[k].rd, rtl_info.pc), UVM_LOW)
        end else if (!rtl_info.x_wb[current_spike_txns[k].rd]) begin
          `uvm_fatal("SPIKE_GPR_MISMATCH",
                     $sformatf("GPR[x%0d] mismatch at PC 0x%h. Spike wrote 0x%h but RTL did not.",
                               current_spike_txns[k].rd, rtl_info.pc, current_spike_txns[k].wdata))
        end else begin
          logic [31:0] rtl_val = rvvi_vif.x_wdata[0][rtl_info.retire_index][current_spike_txns[k].rd];
          if (rtl_val != current_spike_txns[k].wdata) begin
            `uvm_fatal("SPIKE_VAL_MISMATCH",
                       $sformatf("GPR[x%0d] value mismatch at PC 0x%h. RTL: 0x%h, Spike: 0x%h",
                                 current_spike_txns[k].rd, rtl_info.pc, rtl_val,
                                 current_spike_txns[k].wdata))
          end
        end
      end

      // 2. FPR Verification
      if (current_spike_txns[k].has_fpr_write) begin
        if (!rtl_info.f_wb[current_spike_txns[k].rd]) begin
          `uvm_fatal("SPIKE_FPR_MISMATCH",
                     $sformatf("FPR[f%0d] mismatch at PC 0x%h. Spike wrote 0x%h but RTL did not.",
                               current_spike_txns[k].rd, rtl_info.pc, current_spike_txns[k].wdata))
        end else begin
          logic [31:0] rtl_val = rvvi_vif.f_wdata[0][rtl_info.retire_index][current_spike_txns[k].rd];
          if (rtl_val != current_spike_txns[k].wdata) begin
            `uvm_fatal("SPIKE_VAL_MISMATCH",
                       $sformatf("FPR[f%0d] value mismatch at PC 0x%h. RTL: 0x%h, Spike: 0x%h",
                                 current_spike_txns[k].rd, rtl_info.pc, rtl_val,
                                 current_spike_txns[k].wdata))
          end
        end
      end

      // 3. VPR Verification
      if (current_spike_txns[k].has_vpr_write) begin
        if (!rtl_info.v_wb[current_spike_txns[k].rd]) begin
          `uvm_fatal("SPIKE_VPR_MISMATCH",
                     $sformatf("VPR[v%0d] mismatch at PC 0x%h. Spike wrote 0x%h but RTL did not.",
                               current_spike_txns[k].rd, rtl_info.pc,
                               current_spike_txns[k].v_wdata))
        end else begin
          logic [127:0] rtl_val = rvvi_vif.v_wdata[0][rtl_info.retire_index][current_spike_txns[k].rd];
          if (rtl_val != current_spike_txns[k].v_wdata) begin
            `uvm_fatal("SPIKE_VAL_MISMATCH",
                       $sformatf("VPR[v%0d] value mismatch at PC 0x%h. RTL: 0x%h, Spike: 0x%h",
                                 current_spike_txns[k].rd, rtl_info.pc, rtl_val,
                                 current_spike_txns[k].v_wdata))
          end
        end
      end
    end

    // 4. Verify RTL did not write registers that Spike missed (GPR/FPR/VPR masks)
    // (This ensures one-to-one mapping between simulator state updates)
    is_vec_insn = (rtl_info.insn[6:0] == 7'b1010111 || rtl_info.insn[6:0] == 7'b0000111 ||
                   rtl_info.insn[6:0] == 7'b0100111);
    for (int r = 0; r < 32; r++) begin
      if (r > 0 && rtl_info.x_wb[r]) begin
        bit found = 0;
        if (skip_mask[r]) continue;
        foreach (current_spike_txns[k])
        if (current_spike_txns[k].has_gpr_write && current_spike_txns[k].rd == r) found = 1;
        if (!found)
          `uvm_fatal("SPIKE_GPR_MISMATCH", $sformatf(
                     "RTL wrote GPR[x%0d] at PC 0x%h but Spike did not.", r, rtl_info.pc))
      end
      if (rtl_info.f_wb[r]) begin
        bit found = 0;
        foreach (current_spike_txns[k])
        if (current_spike_txns[k].has_fpr_write && current_spike_txns[k].rd == r) found = 1;
        if (!found)
          `uvm_fatal("SPIKE_FPR_MISMATCH", $sformatf(
                     "RTL wrote FPR[f%0d] at PC 0x%h but Spike did not.", r, rtl_info.pc))
      end
      if (rtl_info.v_wb[r]) begin
        bit found = 0;
        foreach (current_spike_txns[k])
        if (current_spike_txns[k].has_vpr_write && current_spike_txns[k].rd == r) found = 1;
        if (!found) begin
          if (is_vec_insn) begin
            // For vector instructions, Spike only logs writes to registers containing active/updated elements.
            // When vstart/vl causes all elements of a register in a group to be undisturbed, RTL still asserts
            // writeback of the undisturbed value, while Spike omits logging it.
            `uvm_info(
                "SPIKE_VPR_UNDISTURBED",
                $sformatf(
                    "RTL wrote VPR[v%0d] at PC 0x%h (undisturbed vector register) but Spike omitted it.",
                    r, rtl_info.pc), UVM_HIGH)
          end else begin
            `uvm_fatal("SPIKE_VPR_MISMATCH", $sformatf(
                       "RTL wrote VPR[v%0d] at PC 0x%h but Spike did not.", r, rtl_info.pc))
          end
        end
      end
    end
  endfunction

endclass

`endif  // SPIKE_COSIM_CHECKER_SV
