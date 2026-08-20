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
# 0. CLEANUP (START FRESH)
# ==============================================================================
# Check if the Pblock already exists, and if so, delete it to avoid conflicts
if {[llength [get_pblocks -quiet pblock_u_isp]] > 0} {
    delete_pblock [get_pblocks pblock_u_isp]
    puts "INFO: Deleted existing pblock_u_isp to start fresh."
}


# ==============================================================================
# 1. CREATE AND POPULATE PBLOCK
# ==============================================================================
# Create the physical block container
create_pblock pblock_u_isp

# Assign the entire module hierarchy to the Pblock
add_cells_to_pblock [get_pblocks pblock_u_isp] [get_cells -hierarchical -filter {NAME =~ *u_isp}]


# ==============================================================================
# 2. PRUNE FIXED, SHARED, AND HARD MACRO RESOURCES (ROBUST VERSION)
# ==============================================================================
# Find any DSPs, RAMs, or Clocks currently assigned to the pblock.
set macros_to_prune [get_cells -quiet -of_objects [get_pblocks pblock_u_isp] -filter {
    REF_NAME =~ DSP* || 
    REF_NAME =~ RAMB* || 
    REF_NAME =~ FIFO* || 
    REF_NAME =~ URAM* || 
    REF_NAME =~ BUFG* || 
    REF_NAME =~ MMCM* || 
    REF_NAME =~ PLL*
}]

# Only execute the remove command if the list actually contains items
if {[llength $macros_to_prune] > 0} {
    remove_cells_from_pblock [get_pblocks pblock_u_isp] $macros_to_prune
    puts "INFO: Pruned [llength $macros_to_prune] hard macros (DSPs/Clocks) from pblock_u_isp."
} else {
    puts "INFO: No hard macros found to prune."
}


# Re-aligned to physical camera I/O Bank 63 in SLR0 (CLOCKREGION_X3Y0 to X4Y3)
resize_pblock [get_pblocks pblock_u_isp] -add {CLOCKREGION_X3Y0:CLOCKREGION_X4Y3}
set_property IS_SOFT TRUE [get_pblocks pblock_u_isp]
set_property EXCLUDE_PLACEMENT FALSE [get_pblocks pblock_u_isp]

