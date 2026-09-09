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

"""Common generator flags and Verilator options shared between simulation and production targets."""

RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS = [
    "--enableFetchL0=False",
    "--fetchDataBits=128",
    "--lsuDataBits=128",
    "--enableRvv=True",
    "--enableFloat=True",
    "--enableZfbfmin=True",
    "--enableVectorBf16=True",
    "--useAxi",
]

VME_CORE_MINI_AXI_COMMON_GEN_FLAGS = RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS + [
    "--enableVme=True",
]

CORE_MINI_AXI_VOPTS = [
    "-DUSE_GENERIC",
    # Warnings that we disable for fpnew
    "-Wno-ASCRANGE",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNSIGNED",
    "-Wno-BLKANDNBLK",
    "-Wno-BLKSEQ",
]

RVV_CORE_MINI_AXI_VOPTS = [
    "-DUSE_GENERIC",
    # RVV
    "-DTB_SUPPORT",
    "-DVLEN_128",
    "-DZVE32F_ON",
    "-Wno-WIDTH",
    "-Wno-CASEINCOMPLETE",
    "-Wno-LATCH",
    "-Wno-SIDEEFFECT",
    "-Wno-MULTIDRIVEN",
    "-Wno-BLKANDNBLK",
    "-Wno-CASEX",
    # FPNEW
    "-Wno-ASCRANGE",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNSIGNED",
    "-Wno-WIDTHCONCAT",
    "-Ihdl/verilog/rvv/design/FPnew/common_cells/inc",
]

VME_CORE_MINI_AXI_VOPTS = RVV_CORE_MINI_AXI_VOPTS + [
    "-DZVT_ON",
]
