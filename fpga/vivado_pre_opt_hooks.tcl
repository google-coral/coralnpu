# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the License);
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an AS IS BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set script_dir [file dirname [file normalize [info script]]]

# Run pin assignment and DDR IO standard check
source "${script_dir}/check_pin_assignments.tcl"

# Run ISP Pblock configuration
source "${script_dir}/pblock_u_isp.tcl"

# Run DDR4 Pblock configuration
source "${script_dir}/pblock_u_ddr.tcl"

# Fine-Grained Multi-SLR Partitioning (Floorplan Rationalization)
# SLR1: System Crossbar + System SRAM (128 URAM288 blocks = 40% SLR1 URAMs)
set sram_slr1 [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0 && (NAME =~ *sram/sram*)}]
if {[llength $sram_slr1] > 0} {
    set_property USER_SLR_ASSIGNMENT SLR1 $sram_slr1
    puts "INFO: Assigned USER_SLR_ASSIGNMENT SLR1 to [llength $sram_slr1] System SRAM cells."
}

# SLR3: CPU Core + ITCM (32 URAMs) + DTCM (32 URAMs) + ISP Subsystem (16 URAMs)
set tcm_slr3 [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0 && (NAME =~ *itcm* || NAME =~ *dtcm*)}]
if {[llength $tcm_slr3] > 0} {
    set_property USER_SLR_ASSIGNMENT SLR3 $tcm_slr3
    puts "INFO: Assigned USER_SLR_ASSIGNMENT SLR3 to [llength $tcm_slr3] TCM cells."
}

# Proposal A: Map Highmem SRAMs and TCMs to dedicated UltraRAM (URAM288) blocks
catch {
    set sram_cells [get_cells -quiet -hierarchical -filter {PRIMITIVE_SUBGROUP == ram && (NAME =~ *SRAM* || NAME =~ *sram* || NAME =~ *tcm*)}]
    if {[llength $sram_cells] > 0} {
        set_property RAM_STYLE ultra $sram_cells
        puts "INFO: Enforced RAM_STYLE ultra on [llength $sram_cells] SRAM cells."
    }
}

# Proposal 4: Map VME matrix multiplication and multiply-accumulate to hardware DSP48E2
catch {
    set dsp_cells [get_cells -quiet -hierarchical -filter {NAME =~ *backend/vme* && (NAME =~ *peBlock* || NAME =~ *peAdder* || NAME =~ *mulbulk*)}]
    if {[llength $dsp_cells] > 0} {
        set_property USE_DSP yes $dsp_cells
        puts "INFO: Set USE_DSP yes on [llength $dsp_cells] VME arithmetic cells."
    }
}

# Remap dense MUX trees in VME and LSU to LUTs (exempting u_zvt_rs to allow native MUXF7/MUXF8 sharing)
catch { set_property MUXF_REMAP 1 [get_cells -hierarchical -filter {REF_NAME =~ MUXF* && (NAME =~ *backend/vme* || NAME =~ *score/lsu*)}] }

# Replicate high-fanout deqPtr registers in CircularBufferMulti
catch { set_property MAX_FANOUT 256 [get_cells -hierarchical -filter {NAME =~ *score/lsu/rs/deqPtr_reg*}] }

# Replicate high-fanout DDR UI clock sync reset (16,461 loads) to close 5.12ns DDR recovery timing
catch { set_property MAX_FANOUT 256 [get_cells -hierarchical -filter {NAME =~ *div_clk_rst_r1_reg*}] }
catch { set_property FORCE_MAX_FANOUT 256 [get_nets -hierarchical -filter {NAME =~ *c0_ddr4_ui_clk_sync_rst*}] }

# Limit fanout on 512-bit DDR write bus nets
set ddr_nets [get_nets -quiet -hierarchical -filter {NAME =~ *USE_UPSIZER.upsizer_d2*wdata* || NAME =~ *USE_UPSIZER.upsizer_d2*wstrb*}]
if {[llength $ddr_nets] > 0} {
    set_property MAX_FANOUT 16 $ddr_nets
    puts "INFO: Set MAX_FANOUT 16 on [llength $ddr_nets] 512-bit DDR write bus nets."
}

# Proposal 3: Assign AXI and inter-SLR pipeline registers to dedicated Laguna hard columns
set sll_regs [get_cells -quiet -hierarchical -filter {PRIMITIVE_SUBGROUP == flop && (NAME =~ *u_ddr_axi_reg_slice* || NAME =~ *inter_slr*) && (NAME =~ *buf_data_reg* || NAME =~ *skid_data_reg* || NAME =~ *_reg*)}]
if {[llength $sll_regs] > 0} {
    catch { set_property USER_SLL_REG true $sll_regs }
    puts "INFO: Enforced USER_SLL_REG true on [llength $sll_regs] inter-die register cells."
}
