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

#ifndef HDL_VERILOG_SRAM_BACKDOOR_H_
#define HDL_VERILOG_SRAM_BACKDOOR_H_

#include <cstdint>
#include <string>

namespace coralnpu {

// Loads data into SRAMs via backdoor DPI pointers using global byte addresses.
// This supports late binding; data can be "loaded" before the RTL SRAMs
// have registered themselves.
bool SramBackdoorLoad(uint64_t global_addr, const uint8_t* data, size_t len);

}  // namespace coralnpu

extern "C" {
// A C-ABI wrapper for SramBackdoorLoad to allow dynamic invocation from Python.
__attribute__((visibility("default"))) bool sram_backdoor_load_c(
    uint64_t global_addr, const uint8_t* data, size_t len);

// Zero every registered SRAM. Safe to call only after SRAM modules have run
// their `sram_init` DPI registration (i.e. after the simulator has executed
// at least one cycle).
void sram_clear();

// Parse an ELF file and call SramBackdoorLoad for each PT_LOAD segment.
// Same timing constraint as sram_clear — call after SRAMs have registered.
void sram_load_elf(const char* filename);
}

#endif  // HDL_VERILOG_SRAM_BACKDOOR_H_
