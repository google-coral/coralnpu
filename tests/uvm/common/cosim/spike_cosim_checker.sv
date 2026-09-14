// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
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
// Description: Wrapper object for interacting with the in-process Spike simulator
//              via DPI-C.
//----------------------------------------------------------------------------
class spike_cosim_checker extends uvm_object;
  `uvm_object_utils(spike_cosim_checker)

  bit spike_enabled = 0;
  string current_elf;

  function new(string name = "spike_cosim_checker");
    super.new(name);
  endfunction

  // Function: initialize
  // Resets Spike, loads the test ELF program, applies memory patch if provided, and enables the checker.
  function bit initialize(string elf_path, int unsigned entry_point = 0, bit has_entry_point = 0,
                          string patch_file = "");
    current_elf = elf_path;
    void'(spike_fini());
    if (spike_init() != 0) begin
      `uvm_error("SPIKE_INIT_FAIL", "Failed to initialize in-process Spike simulator via DPI-C.")
      spike_enabled = 0;
      return 0;
    end

    if (spike_load_program(elf_path, entry_point, has_entry_point) != 0) begin
      `uvm_error("SPIKE_LOAD_FAIL", $sformatf("Failed to load ELF into Spike: %s", elf_path))
      spike_enabled = 0;
      return 0;
    end

    if (patch_file != "") begin
      if (spike_apply_memory_patch(patch_file) != 0) begin
        `uvm_error("SPIKE_PATCH_FAIL", $sformatf("Failed to apply memory patch to Spike ISS: %s",
                                                 patch_file))
        spike_enabled = 0;
        return 0;
      end
    end

    spike_enabled = 1;
    `uvm_info("SPIKE_CHECK", $sformatf(
              "In-process Spike cosim enabled for %s (entry: 0x%h, custom: %0d)",
              elf_path,
              entry_point,
              has_entry_point
              ), UVM_LOW)
    return 1;
  endfunction

  // Function: step
  // Steps Spike by `num_steps` instructions.
  function bit step(int unsigned num_steps = 1);
    if (!spike_enabled) return 1;
    return (spike_step(num_steps) == 0);
  endfunction

  // Function: get_pc
  // Reads current PC from Spike.
  function bit get_pc(output int unsigned pc);
    if (!spike_enabled) return 0;
    return (spike_get_register("pc", pc) == 0);
  endfunction

  // Function: get_gpr
  // Reads GPR register value from Spike.
  function bit get_gpr(input string reg_name, output int unsigned val);
    if (!spike_enabled) return 0;
    return (spike_get_register(reg_name, val) == 0);
  endfunction

  // Function: set_register
  // Writes register value to Spike (GPR or CSR).
  function bit set_register(input string reg_name, input int unsigned val);
    if (!spike_enabled) return 0;
    return (spike_set_register(reg_name, val) == 0);
  endfunction

  // Function: set_gpr
  // Writes GPR register value to Spike (alias to set_register).
  function bit set_gpr(input string reg_name, input int unsigned val);
    return set_register(reg_name, val);
  endfunction

  // Function: get_fpr
  // Reads FPR register value from Spike.
  function bit get_fpr(input string reg_name, output int unsigned val);
    if (!spike_enabled) return 0;
    return (spike_get_register(reg_name, val) == 0);
  endfunction

  // Function: get_vpr
  // Reads 128-bit vector register value from Spike.
  function bit get_vpr(input string reg_name, output logic [127:0] val);
    if (!spike_enabled) return 0;
    return (spike_get_vector_register(reg_name, val) == 0);
  endfunction

  // Function: is_halted
  // Returns true if Spike is in debug mode / halted.
  function bit is_halted();
    if (!spike_enabled) return 1;
    return spike_is_halted();
  endfunction

  // Function: finalize
  // Cleans up Spike simulation instance.
  function void finalize();
    void'(spike_fini());
    spike_enabled = 0;
  endfunction

endclass

`endif  // SPIKE_COSIM_CHECKER_SV
