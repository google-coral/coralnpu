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

`ifndef SPIKE_TRACE_SERVICE_SV
`define SPIKE_TRACE_SERVICE_SV

typedef struct {
  bit [31:0] pc;
  bit [31:0] insn;
  bit        is_valid;
  bit        has_gpr_write;
  bit        has_fpr_write;
  bit        has_vpr_write;
  int        rd; // 0-31
  bit [31:0] wdata;
  bit [127:0] v_wdata;
} spike_instr_txn_t;

//----------------------------------------------------------------------------
// Class: spike_trace_service
// Description: This class provides a service to read and parse Spike simulator
//              commit logs (typically generated with -l --log-commits).
//              It enables 3-way co-simulation comparison by providing instruction
//              and register writeback data from a pre-generated Spike trace.
//----------------------------------------------------------------------------
class spike_trace_service extends uvm_object;
  `uvm_object_utils(spike_trace_service)

  int fd;
  string filename;
  bit is_open = 0;

  spike_instr_txn_t txn_q[$];
  string lookahead_line;
  bit has_lookahead_line = 0;

  function new(string name = "spike_trace_service");
    super.new(name);
  endfunction

  // Function: open_trace
  // Opens the Spike log file for reading. Returns 1 on success, 0 on failure.
  function bit open_trace(string fname);
    if (is_open && fd != 0) begin
       $fclose(fd);
    end
    filename = fname;
    fd = $fopen(filename, "r");
    if (fd == 0) begin
      `uvm_warning("SPIKE_TRACE", $sformatf("Could not open Spike log: %s", filename))
      return 0;
    end
    is_open = 1;
    return 1;
  endfunction

  // Function: pop_token
  // Helper function to extract the next whitespace-separated token from a string.
  function string pop_token(ref string s);
     int i = 0;
     string res;
     // Skip whitespace
     while (s.len() > 0 && (s.substr(0,0) == " " || s.substr(0,0) == "\t" || s.substr(0,0) == "\n" || s.substr(0,0) == "\r")) s = s.substr(1);
     if (s.len() == 0) return "";
     // Find end of token
     while (i < s.len() && s.substr(i,i) != " " && s.substr(i,i) != "\t" && s.substr(i,i) != "\n" && s.substr(i,i) != "\r") i++;
     res = s.substr(0, i-1);
     s = s.substr(i);
     return res;
  endfunction

  // Function: process_commit_line
  // Parses a Spike 'commit' line containing instruction retirement and register
  // updates (e.g., "core 0: 3 0x0000015c (0x02068207) v4 0x0606...").
  // Extracts GPR, FPR, and VPR writes and pushes them to the internal transaction queue.
  function bit process_commit_line(string line);
    int core_id, priv_mode;
    bit [31:0] pc_val, insn_val;
    int pos;
    string remainder;
    string token;
    spike_instr_txn_t base_txn;
    int num_writes = 0;

    // Match header: "core   %d: %d 0x%h (0x%h)"
    if ($sscanf(line, "core   %d: %d 0x%h (0x%h)", core_id, priv_mode, pc_val, insn_val) != 4) return 0;

    base_txn.pc = pc_val;
    base_txn.insn = insn_val;
    base_txn.is_valid = 1;
    base_txn.has_gpr_write = 0;
    base_txn.has_fpr_write = 0;
    base_txn.has_vpr_write = 0;

    // Find end of header (after insn)
    pos = -1;
    for (int j=0; j<line.len(); j++) begin
       if (line.substr(j,j) == ")") begin
          pos = j;
          break;
       end
    end
    if (pos == -1) return 0;
    remainder = line.substr(pos + 1);

    while (remainder.len() > 0) begin
       token = pop_token(remainder);
       if (token == "") break;

       if (token.len() >= 2 && (token.substr(0,0) == "x" || token.substr(0,0) == "f" || token.substr(0,0) == "v")) begin
          string reg_type = token.substr(0,0);
          string idx_str = token.substr(1);
          int reg_idx;
          string val_str;
          bit is_numeric = 1;

          for (int j=0; j<idx_str.len(); j++) if (idx_str[j] < "0" || idx_str[j] > "9") is_numeric = 0;

          if (is_numeric) begin
             reg_idx = idx_str.atoi();
             val_str = pop_token(remainder);
             // Skip underscores in vector values if present
             for (int j=0; j<val_str.len(); j++) begin
                if (val_str[j] == "_") begin
                   val_str = {val_str.substr(0, j-1), val_str.substr(j+1, val_str.len()-1)};
                   j--;
                end
             end

             if (val_str.len() >= 3 && val_str.substr(0,1) == "0x") begin
                spike_instr_txn_t write_txn = base_txn;
                write_txn.rd = reg_idx;
                if (reg_type == "x") begin
                   write_txn.has_gpr_write = 1;
                   void'($sscanf(val_str, "0x%h", write_txn.wdata));
                end else if (reg_type == "f") begin
                   write_txn.has_fpr_write = 1;
                   void'($sscanf(val_str, "0x%h", write_txn.wdata));
                end else if (reg_type == "v") begin
                   write_txn.has_vpr_write = 1;
                   void'($sscanf(val_str, "0x%h", write_txn.v_wdata));
                end
                txn_q.push_back(write_txn);
                num_writes++;
             end
          end
       end else if (token == "mem") begin
          // Skip address and value for memory writes
          void'(pop_token(remainder)); // addr
          void'(pop_token(remainder)); // val
       end
    end

    if (num_writes == 0) txn_q.push_back(base_txn);
    return 1;
  endfunction

  // Function: parse_fetch_line
  // Parses a Spike 'fetch' line (e.g., "core 0: 0x0000015c (0x02068207) vle8.v v4, (a3)").
  function bit parse_fetch_line(string line, output spike_instr_txn_t txn);
    int core_id;
    bit [31:0] pc_val, insn_val;
    if ($sscanf(line, "core   %d: 0x%h (0x%h)", core_id, pc_val, insn_val) == 3) begin
       txn.pc = pc_val;
       txn.insn = insn_val;
       txn.is_valid = 1;
       txn.has_gpr_write = 0;
       txn.has_fpr_write = 0;
       txn.has_vpr_write = 0;
       return 1;
    end
    return 0;
  endfunction

  // Function: seek_to_pc
  // Advances the log file pointer until a transaction with the matching target PC is found.
  // Useful for initial synchronization or recovering from mismatches.
  function bit seek_to_pc(bit [31:0] target_pc);
    spike_instr_txn_t txn;

    if (txn_q.size() > 0 && txn_q[0].pc == target_pc) begin
      return 1;
    end

    txn_q.delete();
    has_lookahead_line = 0;

    while (1) begin
      txn = get_next_instruction_internal();
      if (!txn.is_valid) return 0; // EOF or error

      if (txn.pc == target_pc) begin
        // Push back since get_next_instruction_internal popped it
        txn_q.push_front(txn);
        return 1;
      end
    end
  endfunction

  // Function: get_next_instruction
  // Returns the next parsed Spike instruction transaction from the internal queue.
  function spike_instr_txn_t get_next_instruction();
    return get_next_instruction_internal();
  endfunction

  // Function: push_front
  // Pushes a transaction back into the internal queue.
  function void push_front(spike_instr_txn_t txn);
    txn_q.push_front(txn);
  endfunction

  // Function: get_next_instruction_internal
  // Core parsing logic. Reads lines from the file and resolves Fetch/Commit pairs.
  // Handles vector instructions that may report multiple register writes on one line
  // by expanding them into multiple transactions in the internal queue.
  function spike_instr_txn_t get_next_instruction_internal();
    spike_instr_txn_t txn, next_txn;
    string line, next_line;
    int code;

    if (txn_q.size() > 0) return txn_q.pop_front();
    if (!is_open) return txn;

    while (!$feof(fd) || has_lookahead_line) begin
      if (has_lookahead_line) begin
         line = lookahead_line;
         has_lookahead_line = 0;
         code = 1;
      end else begin
         code = $fgets(line, fd);
      end
      if (code == 0) break;

      if (process_commit_line(line)) begin
         if (txn_q.size() > 0) return txn_q.pop_front();
      end else if (parse_fetch_line(line, txn)) begin
            // It's a Fetch line. Check if next line is a Commit line for same PC.
            if ($feof(fd)) return txn;

            code = $fgets(next_line, fd);
            if (code == 0) return txn;

            if (process_commit_line(next_line)) begin
               if (txn_q.size() > 0 && txn_q[0].pc == txn.pc) begin
                  return txn_q.pop_front();
               end else begin
                  // Commit line for a DIFFERENT pc? Unlikely.
                  // But buffer the commit line.
                  lookahead_line = next_line;
                  has_lookahead_line = 1;
                  return txn;
               end
            end else begin
               // Next line is not a commit line.
               lookahead_line = next_line;
               has_lookahead_line = 1;
               return txn;
            end
      end
    end

    txn.is_valid = 0;
    return txn;
  endfunction

  // Function: close_trace
  // Closes the Spike log file.
  function void close_trace();
    if (is_open) begin
      $fclose(fd);
      is_open = 0;
    end
  endfunction

endclass

`endif // SPIKE_TRACE_SERVICE_SV
