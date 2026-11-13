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

proc endian_reverse_sort {bram1 bram2} {
    set lsb1 [lindex $bram1 3]
    set lsb2 [lindex $bram2 3]

    set byte1 [expr {floor($lsb1 / 8)}]
    set byte2 [expr {floor($lsb2 / 8)}]

    if {$byte1 < $byte2} {
        return -1
    } elseif {$byte1 > $byte2} {
        return 1
    } else {
        # Bytes are the same, sort by LSB descending
        if {$lsb1 > $lsb2} {
            return -1
        } elseif {$lsb1 < $lsb2} {
            return 1
        } else {
            return 0
        }
    }
}

proc extract_bram_details {filename} {
    set output_file $filename
    set fileout [open $output_file "w"]

    puts "Extracting BRAM details to $output_file..."

    set lmb_brams [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.* && NAME =~ "*/lmb_bram_I/*"}]
    set second_lmb_brams [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.* && NAME =~ "*/second_lmb_bram_I/*"}]
    set all_brams [lsort -dictionary [concat $lmb_brams $second_lmb_brams]]

    if {[llength $all_brams] == 0} {
        puts "ERROR: No BRAMs found in the specified hierarchies. Aborting."
        close $fileout
        exit 1
    }

    puts $fileout "Found [llength $all_brams] BRAMs."
    puts $fileout "----------------------------------------"

    foreach bram_cell $all_brams {
        set cell [get_cells $bram_cell]
        puts $fileout "Instance:      [get_property NAME $cell]"
        puts $fileout "  Type:          [get_property REF_NAME $cell]"
        puts $fileout "  Location:      [get_property LOC $cell]"
        puts $fileout "  SLR Index:     [get_property SLR_INDEX $cell]"
        puts $fileout "  Read Width A:  [get_property READ_WIDTH_A $cell]"
        puts $fileout "  Write Width A: [get_property WRITE_WIDTH_A $cell]"
        puts $fileout "  Read Width B:  [get_property READ_WIDTH_B $cell]"
        puts $fileout "  Write Width B: [get_property WRITE_WIDTH_B $cell]"
        puts $fileout "  BMM Info:      [get_property bmm_info_memory_device $cell]"
        puts $fileout "----------------------------------------"
    }

    close $fileout
    puts "Successfully extracted BRAM details to $output_file"
}

proc create_final_mmi {bram_details_filename output_filename} {
    set input_file $bram_details_filename
    set output_file $output_filename
    set processor_inst "i_ddr4/inst/u_ddr4_mem_intfc/u_ddr_cal_riu/mcs0/inst/microblaze_I"
    set address_space_name "i_ddr4_inst_u_ddr4_mem_intfc_u_ddr_cal_riu_mcs0_inst_microblaze_I.i_ddr4_inst_u_ddr4_mem_intfc_u_ddr_cal_riu_mcs0_inst_dlmb_cntlr"

    # --- Define address space boundaries ---
    set total_address_end 98303
    set first_space_end 65535
    set second_space_begin 65536
    set second_space_end 98303
    set first_block_addr_depth 16384

    # --- Main script ---
    set fin [open $input_file "r"]

    set first_bram_group {}
    set second_bram_group {}

    # Skip the first two header lines of the input file
    gets $fin
    gets $fin

    # 1. Read and Store all BRAM data from the input file
    while {[gets $fin line] >= 0} {
        if {[string match "Instance:*" $line]} {
            set instance_path $line
            gets $fin type_line
            gets $fin loc_line
            gets $fin slr_line
            gets $fin rwa_line
            gets $fin wwa_line
            gets $fin rwb_line
            gets $fin wwb_line
            gets $fin bmm_line
            gets $fin separator_line

            regexp {RAMB\d+} $loc_line mem_type
            regexp {X\d+Y\d+} $loc_line placement
            regexp {BMM Info:\s+\[(\d+):(\d+)\]\[(\d+):(\d+)\]} $bmm_line match msb lsb addr_begin addr_end

            set bram_details [list $mem_type $placement $msb $lsb $addr_begin $addr_end]

            if {[string match "*second_lmb_bram_I*" $instance_path]} {
                lappend second_bram_group $bram_details
            } else {
                lappend first_bram_group $bram_details
            }
        }
    }
    close $fin

    # 2. Sort the two groups using the same logic
    set sorted_first_group [lsort -command endian_reverse_sort $first_bram_group]
    set sorted_second_group [lsort -command endian_reverse_sort $second_bram_group]


    # 3. Write the sorted data to the output file
    set fout [open $output_file "w"]

    # Write MMI Header
    puts $fout {<?xml version="1.0" encoding="UTF-8"?>}
    puts $fout {<MemInfo Version="1" Minor="9">}
    puts $fout [format {  <Processor Endianness="Little" InstPath="%s">} $processor_inst]
    puts $fout [format {    <AddressSpace Name="%s" Begin="0" End="%d">} $address_space_name $total_address_end]

    # Write first address space range
    puts $fout [format {      <AddressSpaceRange Name="%s" Begin="0" End="%d" CoreMemory_Width="32" MemoryType="RAM_SP" MemoryConfiguration="">} $address_space_name $first_space_end]
    puts $fout {        <BusBlock>}
    foreach bram $sorted_first_group {
        set mem_type   [lindex $bram 0]
        set placement  [lindex $bram 1]
        set msb        [lindex $bram 2]
        set lsb        [lindex $bram 3]
        set addr_begin [lindex $bram 4]
        set addr_end   [lindex $bram 5]
        puts $fout [format {          <BitLane MemType="%s" Placement="%s" Read_Width="0" SLR_INDEX="-1">} $mem_type $placement]
        puts $fout [format {            <DataWidth MSB="%d" LSB="%d"/>} $msb $lsb]
        puts $fout [format {            <AddressRange Begin="%d" End="%d"/>} $addr_begin $addr_end]
        puts $fout {            <BitLayout pattern=""/>}
        puts $fout {            <Parity ON="false" NumBits="0"/>}
        puts $fout {          </BitLane>}
    }
    puts $fout {        </BusBlock>}
    puts $fout {      </AddressSpaceRange>}

    # Write second address space range
    puts $fout [format {      <AddressSpaceRange Name="%s" Begin="%d" End="%d" CoreMemory_Width="32" MemoryType="RAM_SP" MemoryConfiguration="">} $address_space_name $second_space_begin $second_space_end]
    puts $fout {        <BusBlock>}
    foreach bram $sorted_second_group {
        set mem_type   [lindex $bram 0]
        set placement  [lindex $bram 1]
        set msb        [lindex $bram 2]
        set lsb        [lindex $bram 3]
        set addr_begin [expr {[lindex $bram 4] + $first_block_addr_depth}]
        set addr_end   [expr {[lindex $bram 5] + $first_block_addr_depth}]
        puts $fout [format {          <BitLane MemType="%s" Placement="%s" Read_Width="0" SLR_INDEX="-1">} $mem_type $placement]
        puts $fout [format {            <DataWidth MSB="%d" LSB="%d"/>} $msb $lsb]
        puts $fout [format {            <AddressRange Begin="%d" End="%d"/>} $addr_begin $addr_end]
        puts $fout {            <BitLayout pattern=""/>}
        puts $fout {            <Parity ON="false" NumBits="0"/>}
        puts $fout {          </BitLane>}
    }
    puts $fout {        </BusBlock>}
    puts $fout {      </AddressSpaceRange>}

    # Write MMI Footer
    puts $fout {    </AddressSpace>}
    puts $fout {  </Processor>}
    puts $fout {  <Config>}
    puts $fout {    <Option Name="Part" Val="xcvu13p-fhga2104-2-e"/>}
    puts $fout {  </Config>}
    puts $fout {  <DRC>}
    puts $fout {    <Rule Name="RDADDRCHANGE" Val="false"/>}
    puts $fout {  </DRC>}
    puts $fout {</MemInfo>}

    close $fout

    puts "Successfully converted $input_file to $output_file"
}

proc stage_artifact {src dst} {
    if {![file exists $src]} {
        puts "ERROR: Expected build artifact not found: $src"
        exit 1
    }
    file mkdir [file dirname $dst]
    file delete -force $dst
    if {[catch {file link -hard $dst $src}]} {
        file copy -force $src $dst
    }
    puts "INFO: Staged artifact $src -> $dst"
}

# Define paths relative to the bitstream implementation run directory
set bit_file "./chip_nexus.bit"
set mmi_file "./memories.mmi"
set bram_details_file "./bram_details.txt"
# Assumes elf is in the parent dir of the run dir
set elf_file "../../calibration_ddr.elf"
set output_bin_file [string map {.bit .bin} $bit_file]
set proc_instance "i_ddr4/inst/u_ddr4_mem_intfc/u_ddr_cal_riu/mcs0/inst/microblaze_I"

if {[file exists "../../src/xilinx_ddr4_0_0.1_0"]} {
    # --- Step 1: Extract BRAM details ---
    extract_bram_details $bram_details_file

    # --- Step 2: Create the final MMI file ---
    create_final_mmi $bram_details_file $mmi_file

    # --- Step 3: Run updatemem to merge ELF data into the bitstream (in-place) ---
    puts "INFO: Running updatemem to update bitstream in-place..."
    set cmd [list updatemem -meminfo $mmi_file -data $elf_file -bit $bit_file -proc $proc_instance -out $bit_file -force]

    if {[catch {eval exec $cmd} result]} {
        puts "ERROR: updatemem failed."
        puts "  Command executed: $cmd"
        puts "  Result: $result"
        exit 1
    } else {
        puts "INFO: updatemem completed successfully."
        puts "  Bitstream updated: $bit_file"
        puts "  Result: $result"
    }
} else {
    puts "INFO: Xilinx DDR4 IP not present; skipping MicroBlaze updatemem stitch."
    if {[file exists "./chip_nexus.mmi"]} {
        file copy -force "./chip_nexus.mmi" $mmi_file
    } else {
        set mmi_out [open $mmi_file "w"]
        puts $mmi_out {<?xml version="1.0" encoding="UTF-8"?>}
        puts $mmi_out {<MemInfo Version="1" Minor="15"/>}
        close $mmi_out
    }
}

# --- Step 4: Convert the updated bitstream to BIN format ---
puts "INFO: Converting bitstream to BIN format..."
if {[catch {write_cfgmem -format BIN -disablebitswap -loadbit "up 0x0 $bit_file" -file $output_bin_file -force} result]} {
    puts "ERROR: write_cfgmem failed."
    puts "  Result: $result"
    exit 1
} else {
    puts "INFO: write_cfgmem completed successfully."
    puts "  Output BIN file written to: $output_bin_file"
}

# --- Step 5: Stage canonical artifacts into sibling exported/ dir for Bazel output_groups ---
# Run directory is <build_dir>/<system>/synth-vivado/<system>.runs/impl_1, so
# ../../../../exported resolves to <build_dir>/exported outside the <system>/ TreeArtifact.
set export_dir [file normalize "../../../../exported"]
file mkdir $export_dir

stage_artifact $output_bin_file "${export_dir}/chip_nexus.bin"
stage_artifact $bit_file "${export_dir}/chip_nexus.bit"
stage_artifact $mmi_file "${export_dir}/memories.mmi"

if {[file exists "./chip_nexus_postroute_physopt.dcp"]} {
    stage_artifact "./chip_nexus_postroute_physopt.dcp" "${export_dir}/chip_nexus_postroute.dcp"
} else {
    stage_artifact "./chip_nexus_routed.dcp" "${export_dir}/chip_nexus_postroute.dcp"
}

if {[file exists "./chip_nexus_timing_summary_postroute_physopted.rpt"]} {
    stage_artifact "./chip_nexus_timing_summary_postroute_physopted.rpt" "${export_dir}/chip_nexus_timing_summary.rpt"
} else {
    stage_artifact "./chip_nexus_routed_timing.rpt" "${export_dir}/chip_nexus_timing_summary.rpt"
}

stage_artifact "./chip_nexus_placed_utilization.rpt" "${export_dir}/chip_nexus_placed_utilization.rpt"
stage_artifact "./chip_nexus_routed_congestion.rpt" "${export_dir}/chip_nexus_routed_congestion.rpt"
stage_artifact "./chip_nexus_routed_status.rpt" "${export_dir}/chip_nexus_routed_status.rpt"
