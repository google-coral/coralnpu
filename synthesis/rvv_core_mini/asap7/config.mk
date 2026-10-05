# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export PLATFORM               = asap7
export DESIGN_NAME            = RvvCoreMiniAxi
export DESIGN_NICKNAME        = RvvCoreMiniAxi

export VERILOG_FILES         ?= $(DESIGN_HOME)/RvvCoreMiniAxi.sv $(PLATFORM_DIR)/verilog/fakeram_512x128.sv $(PLATFORM_DIR)/verilog/fakeram_2048x128.sv
export SDC_FILE              ?= $(DESIGN_HOME)/constraint.sdc

export ADDITIONAL_LEFS        = $(PLATFORM_DIR)/lef/fakeram_512x128.lef $(PLATFORM_DIR)/lef/fakeram_2048x128.lef
export ADDITIONAL_LIBS        = $(PLATFORM_DIR)/lib/NLDM/fakeram_512x128.lib $(PLATFORM_DIR)/lib/NLDM/fakeram_2048x128.lib

export SYNTH_HDL_FRONTEND     = slang
export VERILOG_DEFINES        = -DVLEN_128=1 -DZVE32F_ON=1 -DZVFBFWMA_ON=1 -DTB_SUPPORT=1 -DUSE_ASAP7

export SYNTH_HIERARCHICAL      = 0
export SYNTH_ARGS              = -noshare
export SYNTH_MEMORY_MAX_BITS   = 32768
export SYNTH_WRAPPED_OPERATORS = 0
export SWAP_ARITH_OPERATORS    = 0
export OPENROAD_HIERARCHICAL   = 0


# Floorplan geometry
export CORE_ASPECT_RATIO      = 1.0
export CORE_MARGIN            = 2.16
export MAX_ROUTING_LAYER      = M8
export CORE_UTILIZATION       = 35
export MACRO_PLACE_HALO       = 8 8

export LEC_CHECK              = 0
export SEC_CHECK              = 0

# Multi-corner liberty mapping bridge for ASAP7 & SRAM macros
export WC_LIB_FILES           = $(WC_NLDM_LIB_FILES) $(ADDITIONAL_LIBS)
export BC_LIB_FILES           = $(BC_NLDM_LIB_FILES) $(ADDITIONAL_LIBS)
export TC_LIB_FILES           = $(TC_NLDM_LIB_FILES) $(ADDITIONAL_LIBS)

# Standard Physical Design Configuration
export ASAP7_USE_VT                       = RVT
export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT = 2
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT = 1
export GPL_ROUTABILITY_DRIVEN             = 1
export GPL_TIMING_DRIVEN                  = 1
export REMOVE_ABC_BUFFERS                 = 0
export ENABLE_PLACE_REPAIR_TIMING         = 0
export ENABLE_DPO                         = 1
export SKIP_LAST_GASP                     = 0
export CTS_CLUSTER_SIZE                   = 30
export SKIP_CTS_REPAIR_TIMING             = 0
export GLOBAL_ROUTE_ARGS                  = -congestion_iterations 40 -verbose -allow_congestion
export DETAILED_ROUTE_END_ITERATION       = 64
export SKIP_ANTENNA_REPAIR                = 0
export CORNER                             = WC
export CORNERS                            = wc tc bc
export DETAILED_METRICS                   = 1

