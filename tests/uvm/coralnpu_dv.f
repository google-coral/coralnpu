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

// File list for CoralNPU UVM Testbench compilation

// Defines
+define+USE_GENERIC

// --- Include Directories ---
+incdir+./common
+incdir+./common/coralnpu_axi_master
+incdir+./common/coralnpu_axi_slave
+incdir+./common/coralnpu_irq
+incdir+./common/transaction_item
+incdir+./common/rvvi
+incdir+./common/cosim
+incdir+./env
+incdir+./tests
+incdir+./tb
+incdir+../../

// --- Source Files ---

// Backdoor DPI
../../hdl/verilog/sram_backdoor.cc

// Interfaces
./common/coralnpu_axi_master/coralnpu_axi_master_if.sv
./common/coralnpu_axi_slave/coralnpu_axi_slave_if.sv
./common/coralnpu_irq/coralnpu_irq_if.sv
./common/cosim/coralnpu_cosim_dpi_if.sv
./common/cosim/coralnpu_spike_cosim_dpi_if.sv

// UVM Packages (in dependency order)
./common/memory_map_pkg.sv
./common/transaction_item/transaction_item_pkg.sv
./common/coralnpu_axi_master/coralnpu_axi_master_agent_pkg.sv
./common/coralnpu_axi_slave/coralnpu_axi_slave_agent_pkg.sv
./common/coralnpu_irq/coralnpu_irq_agent_pkg.sv
./common/cosim/coralnpu_rvvi_agent_pkg.sv
./common/cosim/coralnpu_cosim_checker_pkg.sv
./env/coralnpu_env_pkg.sv
./tests/coralnpu_test_pkg.sv

// Top-Level Testbench
./tb/coralnpu_tb_top.sv
