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
# DDR4 Controller & Interface Logic Pblock Configuration for VU13P
# ==============================================================================
# Floorplanning the DDR4 memory interface logic to SLR2 (where DDR4 I/O banks
# and hard memory controllers reside) avoids cross-SLR routing congestion.
# ==============================================================================

# Check if DDR4 controller exists in the netlist
if {[llength [get_cells -quiet -hierarchical -filter {NAME =~ *u_ddr4_mem_intfc*}]] == 0} {
    puts "INFO: No DDR4 memory interface detected. Skipping DDR4 Pblock creation."
    return
}

if {[llength [get_pblocks -quiet pblock_ddr4]] > 0} {
    delete_pblocks [get_pblocks pblock_ddr4]
}

# Find top DDR controller cell, 250MHz AXI CDC FIFO, AXI Bridge, and ID Remapper
set ddr_cells [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0 && (NAME =~ i_ddr4 || NAME =~ *ddr_ctrl* || NAME =~ *deviceInterfaces_ddr_ctrl_bridge*)}]

if {[llength $ddr_cells] > 0} {
    create_pblock pblock_ddr4
    add_cells_to_pblock [get_pblocks pblock_ddr4] $ddr_cells

    # Range covering DDR4 Hard Blocks and surrounding logic in SLR2
    resize_pblock [get_pblocks pblock_ddr4] -add {CLOCKREGION_X0Y8:CLOCKREGION_X5Y11}

    # Soft constraint allows router to utilize neighboring routing resources
    set_property CONTAIN_ROUTING false [get_pblocks pblock_ddr4]
    puts "INFO: Successfully configured Pblock pblock_ddr4 in SLR2 for [llength $ddr_cells] cells."
}
