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

#ifndef SW_CORALNPU_SIM_SPIKE_COSIM_DPI_H_
#define SW_CORALNPU_SIM_SPIKE_COSIM_DPI_H_

#include <cstdint>

#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

// Initializes the Spike simulator for in-process co-simulation.
// Returns 0 on success.
int spike_init();

// Loads an ELF program into Spike simulation memory and sets entry point.
// If has_entry_point is true, entry_point is used; otherwise entry point from ELF is used.
// Returns 0 on success.
int spike_load_program(const char *elf_file, uint32_t entry_point, svBit has_entry_point);

// Resets the Spike simulator.
// Returns 0 on success.
int spike_reset();

// Steps the Spike simulator by `num_steps` instructions.
// Returns 0 on success.
int spike_step(uint32_t num_steps);

// Returns true (1) if Spike simulator has halted / entered debug mode.
svBit spike_is_halted();

// Reads register (PC, GPR x0..x31, FPR f0..f31, CSRs) by name.
// Returns 0 on success.
int spike_get_register(const char *name, uint32_t *value);

// Writes register (PC, GPR x0..x31, FPR f0..f31, CSRs) by name.
// Returns 0 on success.
int spike_set_register(const char *name, uint32_t value);

// Reads 128-bit vector register by name ("v0".."v31").
// Value array has 4 elements of svLogicVecVal (128-bit).
// Returns 0 on success.
int spike_get_vector_register(const char *name, svLogicVecVal *value);

// Finalizes and frees Spike simulator resources.
// Returns 0 on success.
int spike_fini();

#ifdef __cplusplus
}
#endif

#endif  // SW_CORALNPU_SIM_SPIKE_COSIM_DPI_H_
