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

# =============================================================================
# Timing Mode: Functional (func)
# Target:      RvvCoreMiniAxi @ 200 MHz (ASAP7 7nm Predictive PDK)
#
# Note: This constraint file covers functional mode only. Manufacturing DFT
#       and scan test modes are not timed in this flow.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Clock Definition (Default 200 MHz / 5000 ps; override via CLK_PERIOD_PS)
# -----------------------------------------------------------------------------
set clk_name io_aclk
set clk_port_name io_aclk
set clk_period 5000
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
# Physical clock slew model (virtual clocks cannot have transitions)
set_clock_transition 20 [get_clocks $clk_name]
set_input_transition 25 [all_inputs -no_clocks]

# Symmetrical network latency model matching ORFS ASAP7 reference standards (~1050 ps on ASAP7 CTS mesh)
set_clock_latency 1050 [get_clocks $clk_name]
set_clock_latency 1050 [get_clocks $clk_io_name]

# Standard output load model (5 fF pin load for ASAP7 finFET where capacitive_load_unit is 1ff)
set_load -pin_load 5.0 [all_outputs]

# -----------------------------------------------------------------------------
# 3. Asynchronous & Static False Paths (Eliminates Hold Buffer Explosion)
# -----------------------------------------------------------------------------
# Functional mode: exclude DFT scan paths from timing analysis.
# Ties io_te low to prune CoreAxi DFT reset-bypass muxes (Mux(io.te, !io.aresetn, ...))
# and ClockGate scan pins.
set te_port [get_ports -quiet io_te]
if {[llength $te_port] > 0} {
  set_case_analysis 0 $te_port
  set_false_path -from $te_port
}

# Asynchronous active-low reset; internal deassertion is synchronized by RstSync
set_false_path -from [get_ports -quiet io_aresetn]

# Quasi-static boot address strap sampled into pcStartReg only on cycle 0 out of reset
set_false_path -from [get_ports -quiet io_boot_addr*]

# Asynchronous interrupt inputs registered immediately at core boundary (RegNext)
set_false_path -from [get_ports -quiet {io_irq io_timer_irq io_software_irq}]

# Quasi-static CPU status flags; direct flop outputs with no single-cycle timing contract
set_false_path -to [get_ports -quiet {io_halted io_fault io_wfi}]

# Low-speed asynchronous RISC-V Debug Module Interface (DMI) timed at JTAG/DTM boundary.
# Split strictly by Decoupled port direction (req_ready is output; rsp_ready is input)
# to avoid OpenSTA STA-1554 (invalid startpoint) and STA-1551 (invalid endpoint) warnings.
set_false_path -from [get_ports -quiet {io_dm_req_valid io_dm_req_bits_* io_dm_rsp_ready}]
set_false_path -to   [get_ports -quiet {io_dm_req_ready io_dm_rsp_valid io_dm_rsp_bits_*}]

# Asynchronous soft-reset flops (CoreCSR.resetReg[0] and DebugModule.dmcontrol[1])
set soft_rst_pins [get_pins -hier -quiet {*/*dmcontrol*1*/Q */*resetReg*0*/Q}]
if {[llength $soft_rst_pins] > 0} {
  set_false_path -from $soft_rst_pins
}

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
