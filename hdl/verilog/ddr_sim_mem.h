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

// Backing store for axi_sim_mem.sv. Testbench-side access (ctypes from
// cocotb) goes through the ddr_backdoor_*_c functions; the RTL goes through
// the ddr_sim_* DPI imports. See coralnpu_test_utils/backdoor.py.

#ifndef HDL_VERILOG_DDR_SIM_MEM_H_
#define HDL_VERILOG_DDR_SIM_MEM_H_

#include <cstddef>
#include <cstdint>

extern "C" {
// (Re)allocates the window [base, base + size) and zero-fills it.
__attribute__((visibility("default"))) void ddr_backdoor_configure_c(
    uint64_t base, uint64_t size);
// Bulk copies; return false if [addr, addr + len) is not inside the window.
__attribute__((visibility("default"))) bool ddr_backdoor_write_c(
    uint64_t addr, const uint8_t* data, size_t len);
__attribute__((visibility("default"))) bool ddr_backdoor_read_c(
    uint64_t addr, uint8_t* data, size_t len);
__attribute__((visibility("default"))) uint64_t ddr_backdoor_base_c();
__attribute__((visibility("default"))) uint64_t ddr_backdoor_size_c();
}

#endif  // HDL_VERILOG_DDR_SIM_MEM_H_
