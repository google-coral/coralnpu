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

# Clock Signal
create_clock -period 10.00 -name sys_clk_pin -waveform {0 5} [get_ports clk_p_i]
set_property -dict { PACKAGE_PIN U13 IOSTANDARD DIFF_SSTL18_I } [get_ports { clk_p_i }];
set_property -dict { PACKAGE_PIN T13 IOSTANDARD DIFF_SSTL18_I } [get_ports { clk_n_i }];
create_clock -period 6.4 -name c0_sys_clk_p [get_ports c0_sys_clk_p]
create_clock -period 200.00 -name ISP_DVP_PCLK -waveform {0 100.0} [get_ports ISP_DVP_PCLK]; # 5MHz camera clock

# Generated Clocks
create_generated_clock -name clk_main [get_pin i_clkgen/i_clkgen/pll/CLKOUT0]
create_generated_clock -name clk_aon [get_pin i_clkgen/i_clkgen/pll/CLKOUT4]

# Reset
set_property -dict { PACKAGE_PIN AR19 IOSTANDARD LVCMOS18 } [get_ports { rst_ni }];

## False Paths ISP (from config registers)
## Timing exceptions for ISP static configuration registers
## These registers are statically configured by software before the ISP is enabled.
#### MOST BASIC (matches only what we see failing now) ###
#set_false_path -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_isp_regs/*_reg*}] -to [get_cells -quiet -hierarchical -filter {NAME =~ *u_isp_tpg_cfg/*_reg*}]

### MORE COMPLETE Should match everywhere these paths go. Note negatives omitted list ###
# *pvci*: The bus interface, ensuring your read/write handshaking still meets setup and hold times.
# *u_marvin_ctrl*: The master controller, ensuring the signals that actually kick off or reset the pipeline are timed correctly.
# *u_isp_regs/*: Internal register readbacks or state updates.
# We explicitly false-path from the config registers into all datapath processing modules
# within the marvin top-level wrapper, but importantly, we exclude the readback 
# bridges and control bus (PVCI/AHB) to maintain readback timing.
set_false_path -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_isp_regs/*_reg*}] -to [get_cells -quiet -hierarchical -filter {NAME =~ *u_marvin_top*/*_reg* && NAME !~ *u_isp_regs/* && NAME !~ *pvci* && NAME !~ *u_marvin_ctrl*}]

# Ignore setup/hold for static configuration register readbacks (massive muxes)
set_false_path -to [get_cells -quiet -hierarchical -filter {NAME =~ *u_isp*/*cfg_mi_rdata_reg*}]

# Ignore static ISP memory buffer settings driving into address generators because they are set before the pixel DMA engine is turned on
set_false_path -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_marvin_mi*/*_base_ad_reg*}]
set_false_path -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_marvin_mi*/*_size_reg*}]
set_false_path -from [get_cells -quiet -hierarchical -filter {NAME =~ *u_marvin_mi*/*_start_reg*}]


# JTAG
# 500 kHz clock constraint
create_clock -period 2000.00 -name jtag_tck_i -waveform {0 1000} [get_ports {tck_i}]
set_property -dict { PACKAGE_PIN BE18 IOSTANDARD LVCMOS18 PULLTYPE PULLDOWN } [get_ports {tms_i}]
set_property -dict { PACKAGE_PIN BE17 IOSTANDARD LVCMOS18 PULLTYPE PULLDOWN } [get_ports {td_o}]
set_property -dict { PACKAGE_PIN BB19 IOSTANDARD LVCMOS18 PULLTYPE PULLDOWN } [get_ports {td_i}]
set_property -dict { PACKAGE_PIN AW18 IOSTANDARD LVCMOS18 PULLTYPE PULLDOWN } [get_ports {tck_i}]
set_property -dict { PACKAGE_PIN BC19 IOSTANDARD LVCMOS18 } [get_ports {trst_ni}]

# SPI (FTDI)
create_clock -period 83.333 -name spi_clk_i -waveform {0 41.667} [get_ports spi_clk_i]
set_property -dict { PACKAGE_PIN AV19 IOSTANDARD LVCMOS18 } [get_ports { spi_clk_i }];
set_property -dict { PACKAGE_PIN AW20 IOSTANDARD LVCMOS18 } [get_ports { spi_csb_i }];
set_property -dict { PACKAGE_PIN AV20 IOSTANDARD LVCMOS18 } [get_ports { spi_mosi_i }];
set_property -dict { PACKAGE_PIN AV18 IOSTANDARD LVCMOS18 } [get_ports { spi_miso_o }];

# SPI (FLASH)
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS18 } [get_ports { spim_flash_sclk_o }];
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS18 PULLTYPE PULLUP } [get_ports { spim_flash_mosi_o }];
set_property -dict { PACKAGE_PIN C13 IOSTANDARD LVCMOS18 PULLTYPE PULLUP } [get_ports { spim_flash_miso_i }];
set_property -dict { PACKAGE_PIN A14 IOSTANDARD LVCMOS18 } [get_ports { spim_flash_csb_o }];
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS18 } [get_ports { spim_flash_rst_no }];
# Pin mappins for future Quad-SPI expansion
# set_property -dict { PACKAGE_PIN C13 IOSTANDARD LVCMOS18 PULLTYPE PULLUP } [get_ports { spim_flash_d1 }];
# set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS18 PULLTYPE PULLUP } [get_ports { spim_flash_d2 }];
# set_property -dict { PACKAGE_PIN H15 IOSTANDARD LVCMOS18 PULLTYPE PULLUP } [get_ports { spim_flash_d3 }];

# UART0
set_property -dict { PACKAGE_PIN BF20 IOSTANDARD LVCMOS18 } [get_ports { uart_tx_o[0] }];
set_property -dict { PACKAGE_PIN BD20 IOSTANDARD LVCMOS18 } [get_ports { uart_rx_i[0] }];

# UART1
set_property -dict { PACKAGE_PIN R23 IOSTANDARD LVCMOS18 } [get_ports { uart_tx_o[1] }];
set_property -dict { PACKAGE_PIN T23 IOSTANDARD LVCMOS18 } [get_ports { uart_rx_i[1] }];

# LEDs
set_property -dict { PACKAGE_PIN T31 DRIVE 8 IOSTANDARD LVCMOS12 } [get_ports { io_halted }];
set_property -dict { PACKAGE_PIN P31 DRIVE 8 IOSTANDARD LVCMOS12 } [get_ports { io_fault }];
set_property -dict { PACKAGE_PIN N37 DRIVE 8 IOSTANDARD LVCMOS12 } [get_ports { ddr_cal_complete_o }];
set_property -dict { PACKAGE_PIN M38 DRIVE 8 IOSTANDARD LVCMOS12 } [get_ports { io_ddr_mem_axi_aw_ready }];
set_property -dict { PACKAGE_PIN L38 DRIVE 8 IOSTANDARD LVCMOS12 } [get_ports { io_ddr_mem_axi_ar_ready }];
set_property -dict { PACKAGE_PIN L36 DRIVE 8 IOSTANDARD LVCMOS12 } [get_ports { ddr_ui_clk }];
set_property -dict { PACKAGE_PIN K36 DRIVE 8 IOSTANDARD LVCMOS12 } [get_ports { ddr_ui_clk_sync_rst }];

## Parallel Camera Nexus
set_property -dict { PACKAGE_PIN AK29  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D0 }];    #PMOD1_7_FPGA          -ISP_DVP_D0
set_property -dict { PACKAGE_PIN AL29  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D1 }];    #PMOD1_1_FPGA          -ISP_DVP_D1
set_property -dict { PACKAGE_PIN AL31  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D2 }];    #PMOD1_8_FPGA          -ISP_DVP_D2
set_property -dict { PACKAGE_PIN AL32  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D3 }];    #PMOD1_2_FPGA          -ISP_DVP_D3
set_property -dict { PACKAGE_PIN AL30  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D4 }];    #PMOD1_9_FPGA          -ISP_DVP_D4
set_property -dict { PACKAGE_PIN AM29  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D5 }];    #PMOD1_3_FPGA          -ISP_DVP_D5
set_property -dict { PACKAGE_PIN AM33  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D6 }];    #PMOD1_10_FPGA         -ISP_DVP_D6
set_property -dict { PACKAGE_PIN AM32  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_D7 }];    #PMOD1_4_FPGA          -ISP_DVP_D7
set_property -dict { PACKAGE_PIN AN33  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_PCLK }];  #PMOD2_1_FPGA          -ISP_DVP_PCLK
#set_property -dict { PACKAGE_PIN AN34  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_MCLK }]; #PMOD2_7_FPGA          -ISP_DVP_MCLK  # UNUSED (using camera built in clock)
set_property -dict { PACKAGE_PIN AM31  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_VSYNC }]; #PMOD2_2_FPGA          -ISP_DVP_VSYNC
set_property -dict { PACKAGE_PIN AP33  IOSTANDARD LVCMOS18 } [get_ports { ISP_DVP_HSYNC }]; #PMOD2_8_FPGA          -ISP_DVP_HSYNC
set_property -dict { PACKAGE_PIN AT36  IOSTANDARD LVCMOS18 } [get_ports { CAM_INT }];       #PMOD2_4_FPGA          -CAM_INT
set_property -dict { PACKAGE_PIN AT37  IOSTANDARD LVCMOS18 } [get_ports { CAM_TRIG }];      #PMOD2_10_FPGA         -CAM_TRIG     # UNUSED (I2C trigger used in past)

# Bypass sub-optimal clock routing error for slow PCLK, because AN33 used for cam PCLK does not have clock resources
# Vivado does not like that
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets ISP_DVP_PCLK_IBUF_inst/O]

# Asynchronous Clock Groups
# Define all primary, asynchronous clocks
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks sys_clk_pin] \
  -group [get_clocks -include_generated_clocks c0_sys_clk_p] \
  -group [get_clocks spi_clk_i] \
  -group [get_clocks jtag_tck_i] \
  -group [get_clocks ISP_DVP_PCLK]

# SPI Probe Outputs (PMOD3) -> Reassigned to SpiMaster
# PMOD4: 1=AY38, 2=BA39, 3=AW35, 4=AY35, 7=AY40, 8=BA40, 9=AW36, 10=BC40
set_property -dict { PACKAGE_PIN AY38 IOSTANDARD LVCMOS18 } [get_ports { spim_mosi_o }]; # PMOD4_1 (D0)
set_property -dict { PACKAGE_PIN BA39 IOSTANDARD LVCMOS18 } [get_ports { spim_miso_i }]; # PMOD4_2 (D1)
set_property -dict { PACKAGE_PIN AW35 IOSTANDARD LVCMOS18 } [get_ports { gpio[0] }];     # PMOD4_3 (D2)
set_property -dict { PACKAGE_PIN AY35 IOSTANDARD LVCMOS18 } [get_ports { gpio[1] }];     # PMOD4_3 (D3)

# I2C (PMOD2)
set_property -dict { PACKAGE_PIN AR35 IOSTANDARD LVCMOS18 } [get_ports { i2c_scl }];     # PMOD2_9
set_property -dict { PACKAGE_PIN AT35 IOSTANDARD LVCMOS18 } [get_ports { i2c_sda }];     # PMOD2_3

set_property -dict { PACKAGE_PIN AY40 IOSTANDARD LVCMOS18 } [get_ports { spim_sclk_o }]; # PMOD4_7 (CLK)
set_property -dict { PACKAGE_PIN BA40 IOSTANDARD LVCMOS18 } [get_ports { spim_csb_o }];  # PMOD4_8 (CS)
set_property -dict { PACKAGE_PIN AW36 IOSTANDARD LVCMOS18 } [get_ports { gpio[2] }];     # PMOD4_9
set_property -dict { PACKAGE_PIN BC40 IOSTANDARD LVCMOS18 } [get_ports { gpio[3] }];     # PMOD4_10

# Proactively replicate high-fanout drivers feeding 512-bit DDR write data/strobe bus (250MHz DDR clock)
set_property MAX_FANOUT 16 [get_nets -quiet -hierarchical -filter {NAME =~ *USE_UPSIZER.upsizer_d2*wdata*}]
set_property MAX_FANOUT 16 [get_nets -quiet -hierarchical -filter {NAME =~ *USE_UPSIZER.upsizer_d2*wstrb*}]
