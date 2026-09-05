if {[llength [glob -nocomplain -dir $src_post_enc_dir *]] != 0} {
  eval file delete -force [glob $src_post_enc_dir/*]
}

set UNUSED_TEMPLATES_DIR $HDK_SHELL_DESIGN_DIR/interfaces
foreach f {
  unused_flr_template.inc
  unused_ddr_template.inc
  unused_cl_sda_template.inc
  unused_apppf_irq_template.inc
  unused_dma_pcis_template.inc
  unused_pcim_template.inc
} {
  file copy -force $UNUSED_TEMPLATES_DIR/$f $src_post_enc_dir
}

foreach f {
  cl_id_defines.vh
  coralnpu_axil_to_axi.sv
  cl_coralnpu.sv
  RvvCoreMiniAxi.sv
} {
  file copy -force $CL_DIR/design/$f $src_post_enc_dir
}

exec chmod +w {*}[glob ${src_post_enc_dir}/*]
if {$ENCRYPT} {
  print "Encryption enabled"
  encrypt -k ${HDK_SHELL_DIR}/build/scripts/vivado_keyfile.txt -lang verilog -quiet \
    [glob -nocomplain -- ${src_post_enc_dir}/*.{v,sv,vh,inc}]
} else {
  print "Encryption disabled"
}
