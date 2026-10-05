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

yosys -import

set results_dir $::env(RESULTS_DIR)
set top_design "RvvCoreMiniAxi"

# Explicit child partition manifest
set expected_partitions [list \
  "rvv_backend_mac_unit_0" "rvv_backend_mac_unit_1" \
  "rvv_backend_falu_unit_0" "rvv_backend_falu_unit_1" \
  "rvv_backend_alu_unit_0" "rvv_backend_alu_unit_1" \
  "rvv_backend_div" "rvv_backend_pmtrdt" "rvv_backend_vrf" \
  "rvv_backend_dispatch" "rvv_backend_rob" "RvvFrontEnd" \
  "LsuV3" "SCore" "rvv_backend" \
]

puts "=== Reading Partition Netlists ==="
set top_netlist "$results_dir/1_2_yosys_RvvCoreMiniAxi.v"
if { ![file exists $top_netlist] } {
  error "Missing top-level netlist: $top_netlist"
}
puts "Loading top-level netlist: $top_netlist"
read_verilog -defer $top_netlist

foreach part $expected_partitions {
  set netlist "$results_dir/1_2_yosys_${part}.v"
  if { ![file exists $netlist] } {
    error "Missing child partition netlist for '$part': $netlist"
  }
  puts "Loading child partition netlist (overwrite): $netlist"
  read_verilog -defer -overwrite $netlist
}

# Read ASAP7 fakeram blackboxes
read_verilog -defer $::env(PLATFORM_DIR)/verilog/fakeram_512x128.sv
read_verilog -defer $::env(PLATFORM_DIR)/verilog/fakeram_2048x128.sv

puts "=== Reading Liberty Files for Cell Blackboxes ==="
if { [info exists ::env(LIB_FILES)] && [llength $::env(LIB_FILES)] > 0 } {
  foreach lib $::env(LIB_FILES) {
    if { [file exists $lib] } {
      read_liberty -lib $lib
    }
  }
} else {
  set lib_dir "$::env(PLATFORM_DIR)/lib/NLDM"
  foreach lib [glob -nocomplain "$lib_dir/*.lib" "$lib_dir/*.lib.gz"] {
    read_liberty -lib $lib
  }
}

puts "=== Elaborating Unified Hierarchy ==="
hierarchy -check -top $top_design

puts "=== Checking Gate Netlist Purity ==="
opt_clean -purge

if { [info exists ::env(SYNTH_WRAPPED_OPERATORS)] && $::env(SYNTH_WRAPPED_OPERATORS) == 1 } {
  check -assert
} else {
  check -assert -mapped
}

puts "=== Writing Unified Netlist ==="
write_verilog -nohex -nodec "$results_dir/1_2_yosys.v"
file copy -force $::env(SDC_FILE) "$results_dir/1_2_yosys.sdc"

puts "Stitching complete -> $results_dir/1_2_yosys.v"


