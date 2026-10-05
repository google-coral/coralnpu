# Copyright 2025 Google LLC
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
# ISP Subsystem Pblock Configuration for VU13P
# ==============================================================================
# Confines the ISP image processing pipeline to SLR3 to isolate high routing
# congestion away from the core CPU logic and DDR4 interface.
# ==============================================================================

# Check if ISP exists in the netlist
if {[llength [get_cells -quiet -hierarchical -filter {NAME =~ *u_isp*}]] == 0} {
    puts "INFO: No ISP subsystem detected. Skipping ISP Pblock creation."
    return
}

if {[llength [get_pblocks -quiet pblock_u_isp]] > 0} {
    delete_pblocks [get_pblocks pblock_u_isp]
}

# Create the physical block container
create_pblock pblock_u_isp

# Assign the module hierarchy to the Pblock
set isp_hier [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0 && NAME =~ *u_isp}]
if {[llength $isp_hier] > 0} {
    add_cells_to_pblock [get_pblocks pblock_u_isp] $isp_hier
}

# ==============================================================================
# Define Clock Region Range for VU13P SLR3 (Top 4 clock regions of SLR3)
# Restricting ISP to Y=14..15 keeps ISP well-contained while leaving Y=12..13
# (~216k LUTs) open for CPU logic, SRAMs, and system crossbars.
# ==============================================================================
resize_pblock [get_pblocks pblock_u_isp] -add {CLOCKREGION_X0Y14:CLOCKREGION_X5Y15}

# Set soft constraints to prevent over-constraining the router
set_property CONTAIN_ROUTING false [get_pblocks pblock_u_isp]

puts "INFO: Successfully configured Pblock pblock_u_isp in top SLR3 (Y14..Y15)."
