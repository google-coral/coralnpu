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
# UG949 Post-Placement Quality Gate & Design Analysis Hook
# ==============================================================================

puts "======================================================================"
puts "INFO: \[UG949 PostPlace\] Running Placement Quality Gate & Diagnostics..."
puts "Time: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts "======================================================================"

# 1. Generate standard UG949 diagnostic reports
catch { report_timing_summary -max_paths 10 -file "chip_nexus_placed_timing.rpt" }
catch { report_design_analysis -congestion -complexity -file "chip_nexus_placed_congestion.rpt" }
catch { report_utilization -file "chip_nexus_placed_utilization.rpt" }

# 2. Timing assessment
set timing_paths [get_timing_paths -quiet -max_paths 1 -setup]
if {[llength $timing_paths] > 0} {
    set wns [get_property SLACK [lindex $timing_paths 0]]
    puts "INFO: \[UG949 PostPlace\] Post-Placement Estimated Setup WNS: $wns ns"
} else {
    puts "INFO: \[UG949 PostPlace\] No setup paths found or design unconstrained."
}

set hold_paths [get_timing_paths -quiet -max_paths 1 -hold]
if {[llength $hold_paths] > 0} {
    set whs [get_property SLACK [lindex $hold_paths 0]]
    puts "INFO: \[UG949 PostPlace\] Post-Placement Estimated Hold WHS: $whs ns"
}

# 3. Placement congestion check (UG949: Level 6/7 congestion leads to routing failure)
if {[file exists "chip_nexus_placed_congestion.rpt"]} {
    set fp [open "chip_nexus_placed_congestion.rpt" r]
    set cong_data [read $fp]
    close $fp
    if {[regexp {\|\s+([6789])\s+\|} $cong_data match lvl]} {
        puts "WARNING: \[UG949 PostPlace\] High routing congestion detected (Level $lvl)!"
        puts "WARNING: \[UG949 PostPlace\] Review chip_nexus_placed_congestion.rpt for hotspots."
    } else {
        puts "INFO: \[UG949 PostPlace\] Congestion check passed (below Level 6)."
    }
}
puts "======================================================================"
