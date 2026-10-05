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
# UG949 Post-Route Quality Assessment & Diagnostics Hook
# ==============================================================================

puts "======================================================================"
puts "INFO: \[UG949 PostRoute\] Running Post-Route Assessment & Diagnostics..."
puts "Time: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts "======================================================================"

# 1. Generate full post-route diagnostic reports
catch { report_route_status -file "chip_nexus_routed_status.rpt" }
catch { report_timing_summary -max_paths 20 -file "chip_nexus_routed_timing.rpt" }
catch { report_design_analysis -congestion -file "chip_nexus_routed_congestion.rpt" }

# 2. Parse routing completion status
set route_rpt [report_route_status -return_string]
puts $route_rpt

set unrouted 0
set conflicts 0
if {[regexp -line {unrouted nets[\.\s]+:\s*(\d+)} $route_rpt match count]} {
    set unrouted $count
}
if {[regexp -line {resource conflicts[\.\s]+:\s*(\d+)} $route_rpt match count]} {
    set conflicts $count
}

# 3. Timing assessment
set timing_paths [get_timing_paths -quiet -max_paths 1 -setup]
set wns [expr {[llength $timing_paths] > 0 ? [get_property -quiet SLACK [lindex $timing_paths 0]] : "N/A"}]
set hold_paths [get_timing_paths -quiet -max_paths 1 -hold]
set whs [expr {[llength $hold_paths] > 0 ? [get_property -quiet SLACK [lindex $hold_paths 0]] : "N/A"}]

puts "INFO: \[UG949 PostRoute\] Final Route Status: Unrouted=$unrouted, Conflicts=$conflicts, WNS=$wns ns, WHS=$whs ns"

if {$unrouted > 0 || $conflicts > 0} {
    puts "======================================================================"
    puts "ERROR: \[UG949 PostRoute\] Routing failed to converge cleanly!"
    puts "ERROR: Residual unrouted nets: $unrouted, resource conflicts: $conflicts"
    puts "ERROR: See chip_nexus_routed_status.rpt and chip_nexus_routed_congestion.rpt."
    puts "======================================================================"
    return -code error "Routing failed to converge cleanly ($unrouted unrouted nets, $conflicts resource conflicts)."
} else {
    puts "======================================================================"
    puts "SUCCESS: \[UG949 PostRoute\] 100% of nets cleanly routed with 0 conflicts!"
    puts "======================================================================"
}
