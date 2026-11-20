source ${HDK_SHELL_DIR}/build/scripts/synth_cl_header.tcl

print "Reading Coral NPU RTL"
read_verilog -sv [glob ${src_post_enc_dir}/*.{s,}v]

print "Reading AXI clock converter"
read_ip ${HDK_IP_SRC_DIR}/cl_axi_clock_converter_light/cl_axi_clock_converter_light.xci

print "Reading user constraints"
read_xdc [list \
  ${constraints_dir}/cl_synth_user.xdc \
  ${constraints_dir}/cl_timing_user.xdc]
set_property PROCESSING_ORDER LATE [get_files cl_synth_user.xdc]
set_property PROCESSING_ORDER LATE [get_files cl_timing_user.xdc]

print "Starting synthesis of ${CL}"
update_compile_order -fileset sources_1
synth_design -mode out_of_context \
             -top ${CL} \
             -verilog_define XSDB_SLV_DIS \
             -part ${DEVICE_TYPE} \
             -keep_equivalent_registers

source ${HDK_SHELL_DIR}/build/scripts/synth_cl_footer.tcl
