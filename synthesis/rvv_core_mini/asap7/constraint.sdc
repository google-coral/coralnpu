# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

current_design RvvCoreMiniAxi

# -----------------------------------------------------------------------------
# 1. Clock Definition (Default 400 MHz / 2500 ps; override via CLK_PERIOD_PS)
# -----------------------------------------------------------------------------
set clk_name io_aclk
set clk_port_name io_aclk
set clk_period 2500
if {[info exists ::env(CLK_PERIOD_PS)]} {
  set clk_period $::env(CLK_PERIOD_PS)
}


set clk_port [get_ports $clk_port_name]
create_clock -name $clk_name -period $clk_period $clk_port

# Virtual clock for external I/O budgeting
set clk_io_name vclk_$clk_name
create_clock -name $clk_io_name -period $clk_period

# -----------------------------------------------------------------------------
# 2. Clock Quality, Uncertainty, Latency & Load Budgeting
# -----------------------------------------------------------------------------
set_clock_uncertainty -setup [expr {$clk_period * 0.05}] [all_clocks]
set_clock_uncertainty -hold 30 [all_clocks]
set_clock_transition 20 [all_clocks]
set_input_transition 25 [all_inputs -no_clocks]

# Model estimated CTS insertion delay on virtual clock
set_clock_latency -source 120 [get_clocks $clk_io_name]

# Standard output load model (5 fF pin load for ASAP7 finFET)
set_load -pin_load 5.0 [all_outputs]

# -----------------------------------------------------------------------------
# 3. Asynchronous & Static False Paths (Eliminates Hold Buffer Explosion)
# -----------------------------------------------------------------------------
set_false_path -from [get_ports -quiet io_aresetn]
set_false_path -from [get_ports -quiet io_te]
set_false_path -from [get_ports -quiet io_boot_addr*]
set_false_path -from [get_ports -quiet io_irq]
set_false_path -from [get_ports -quiet io_timer_irq]
set_false_path -from [get_ports -quiet io_software_irq]
set_false_path -to [get_ports -quiet {io_halted io_fault io_wfi}]
set_false_path -from [get_ports -quiet io_dm_req_*]
set_false_path -to   [get_ports -quiet io_dm_req_*]
set_false_path -from [get_ports -quiet io_dm_rsp_*]
set_false_path -to   [get_ports -quiet io_dm_rsp_*]
set_false_path -from [get_cells -hier -quiet *dmcontrol*]

# -----------------------------------------------------------------------------
# 4. Path Groups (for independent cost optimization)
# -----------------------------------------------------------------------------
group_path -name INPUTS -from [all_inputs -no_clocks]
group_path -name OUTPUTS -to [all_outputs]
group_path -name COMBO -from [all_inputs -no_clocks] -to [all_outputs]

# -----------------------------------------------------------------------------
# 5. External I/O Delay Constraints (Split Max Setup / Min Hold Budgeting)
# -----------------------------------------------------------------------------
set non_clock_inputs [all_inputs -no_clocks]

# Setup delay budget (35% clock period)
set_input_delay  -max [expr {$clk_period * 0.35}] -clock $clk_io_name $non_clock_inputs
set_output_delay -max [expr {$clk_period * 0.35}] -clock $clk_io_name [all_outputs]

# Hold delay budget (5% clock period / 50 ps min margin)
set_input_delay  -min [expr {$clk_period * 0.05}] -clock $clk_io_name $non_clock_inputs
set_output_delay -min [expr {$clk_period * 0.05}] -clock $clk_io_name [all_outputs]


