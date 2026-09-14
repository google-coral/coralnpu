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

//----------------------------------------------------------------------------
// Package: coralnpu_spike_cosim_dpi_if
// Description: Defines the DPI-C import declarations for interacting with the
//              Spike simulator as an in-process library.
//----------------------------------------------------------------------------
package coralnpu_spike_cosim_dpi_if;

  // Function to initialize the Spike simulator.
  // Returns 0 on success.
  import "DPI-C" function int spike_init();

  // Function to load an ELF program into Spike simulation memory.
  // Returns 0 on success.
  import "DPI-C" function int spike_load_program(
    input string elf_file,
    input int unsigned entry_point,
    input bit has_entry_point
  );

  // Function to reset the Spike simulator.
  // Returns 0 on success.
  import "DPI-C" function int spike_reset();

  // Function to execute `num_steps` instructions in the Spike simulator.
  // Returns 0 on success.
  import "DPI-C" function int spike_step(input int unsigned num_steps);

  // Function to check if the Spike simulator has reached a halted / debug state.
  // Returns 1 if halted/in debug mode.
  import "DPI-C" function bit spike_is_halted();

  // Function to get a register value (GPR, FPR, PC, CSR) by its string name.
  // Returns 0 on success.
  import "DPI-C" function int spike_get_register(
    input string name,
    output int unsigned value
  );

  // Function to set a register value by its string name.
  // Returns 0 on success.
  import "DPI-C" function int spike_set_register(
    input string name,
    input int unsigned value
  );

  // Function to get a 128-bit vector register value by its string name ("v0".."v31").
  // Returns 0 on success.
  import "DPI-C" function int spike_get_vector_register(
    input string name,
    output logic [127:0] value
  );

  // Function to apply a binary memory patch to Spike memory.
  // Returns 0 on success.
  import "DPI-C" function int spike_apply_memory_patch(input string patch_file);

  // Function to finalize and free Spike simulator resources.
  // Returns 0 on success.
  import "DPI-C" function int spike_fini();

endpackage : coralnpu_spike_cosim_dpi_if
