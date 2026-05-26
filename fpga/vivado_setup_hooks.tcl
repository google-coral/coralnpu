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

## Elevate warning for not finding file for readmemh to ERROR.
set_msg_config -id {[Synth 8-4445]} -new_severity ERROR

set workroot [pwd]

# Fix up MemInitFile path if it's relative to the execroot but we are in a subdirectory
# This is common in Bazel builds where FuseSoC runs in a subdirectory of the sandbox.
set generics [get_property generic [get_filesets sources_1]]
set new_generics [list]
set changed 0
foreach g $generics {
    if {[regexp {MemInitFile=\"?([^\"]*)\"?} $g match val]} {
        if {$val != "" && ![file exists $val]} {
            # Search for the file in parent directories (up to 10 levels)
            set search_root $workroot
            set found 0
            for {set i 0} {$i < 10} {incr i} {
                set search_root [file dirname $search_root]
                if {[file exists [file join $search_root $val]]} {
                    set val [file normalize [file join $search_root $val]]
                    set found 1
                    break
                }
            }
            if {$found} {
                set changed 1
            }
        }
        # Re-quote the value for the generic property
        lappend new_generics "MemInitFile=\"$val\""
    } else {
        lappend new_generics $g
    }
}
if {$changed} {
    set_property generic $new_generics [get_filesets sources_1]
}

# Register the pre-optimization hooks (pin check, pblocks, etc.)
set_property STEPS.OPT_DESIGN.TCL.PRE "${workroot}/vivado_pre_opt_hooks.tcl" [get_runs impl_1]

# If we see the Xilinx DDR core, register the post-bitstream hook to stitch the calibration FW.
if {[file exists "${workroot}/src/xilinx_ddr4_0_0.1_0"]} {
    set_property STEPS.WRITE_BITSTREAM.TCL.POST "${workroot}/vivado_hook_write_bitstream_post.tcl" [get_runs impl_1]
}
