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

set script_dir [file dirname [info script]]

# Run Pin Assignment Check
source "${script_dir}/check_pin_assignments.tcl"

# Run ISP Pblock configuration
source "${script_dir}/pblock_u_isp.tcl"

# Run DDR4 Pblock configuration
source "${script_dir}/pblock_u_ddr.tcl"

# Remap dense MUX trees in LsuSuperSlot to LUTs
catch { set_property MUXF_REMAP 1 [get_cells -hierarchical -filter {NAME =~ *score/lsu/slot*}] }

# Replicate high-fanout deqPtr registers in CircularBufferMulti
catch { set_property MAX_FANOUT 256 [get_cells -hierarchical -filter {NAME =~ *score/lsu/rs/deqPtr_reg*}] }

