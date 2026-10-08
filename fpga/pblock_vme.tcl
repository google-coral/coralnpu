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
# VME Subsystem Pblock Configuration for VU13P
# ==============================================================================
# Confines the VME matrix extension (matrix tile storage, reservation station,
# and processing element array) to SLR0 and SLR1 (bottom two SLRs) so that
# storage and compute DSPs are co-located, preventing interposer SLL overflow.
# ==============================================================================

# Check if VME exists in the netlist
set vme_cells [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0 && (NAME =~ *backend/vme || NAME =~ *u_zvt_rs)}]
if {[llength $vme_cells] == 0} {
    puts "INFO: No VME subsystem detected. Skipping VME Pblock creation."
    return
}

if {[llength [get_pblocks -quiet pblock_vme]] > 0} {
    delete_pblocks [get_pblocks pblock_vme]
}

create_pblock pblock_vme
add_cells_to_pblock [get_pblocks pblock_vme] $vme_cells

# Define Clock Region Range for VU13P SLR0 + SLR1 (Y=0..7)
resize_pblock [get_pblocks pblock_vme] -add {CLOCKREGION_X0Y0:CLOCKREGION_X5Y7}

# Soft constraint allows router to utilize neighboring routing resources
set_property CONTAIN_ROUTING false [get_pblocks pblock_vme]

puts "INFO: Successfully configured Pblock pblock_vme across SLR0 and SLR1 for [llength $vme_cells] cells."
