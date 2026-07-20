# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ==============================================================================
# DDR4 CONTROLLER FLOORPLANNING & PLACEMENT LOCK
# ==============================================================================
# Hard-binds the 59,000 DDR4 controller primitives (i_ddr4) to Clock Regions
# X3Y8:X4Y11 on the far right edge of the FPGA die (I/O Banks 68-71).
# ==============================================================================

# Delete existing pblock if re-running
if {[llength [get_pblocks -quiet pblock_ddr4]] > 0} {
    delete_pblock [get_pblocks pblock_ddr4]
    puts "INFO: Deleted existing pblock_ddr4 to start fresh."
}

# Find top DDR controller cell
set ddr_cells [get_cells -quiet -hierarchical -filter {NAME =~ i_ddr4}]

if {[llength $ddr_cells] > 0} {
    create_pblock pblock_ddr4
    add_cells_to_pblock [get_pblocks pblock_ddr4] $ddr_cells

    # Floorplan to physical DDR I/O Bank clock regions (X3Y8 to X4Y11)
    resize_pblock [get_pblocks pblock_ddr4] -add {CLOCKREGION_X3Y8:CLOCKREGION_X4Y11}

    # Set soft bounds to allow interconnect buffers to route cleanly
    set_property IS_SOFT TRUE [get_pblocks pblock_ddr4]
    puts "INFO: Created pblock_ddr4 spanning CLOCKREGION_X3Y8:CLOCKREGION_X4Y11 for [llength $ddr_cells] DDR instances."
} else {
    puts "INFO: No top i_ddr4 instance found for pblock_ddr4 floorplanning."
}
