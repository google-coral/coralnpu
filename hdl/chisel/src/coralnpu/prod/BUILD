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

# This package contains production-targeted (clean) RTL targets.
# We isolate these targets in a separate Bazel package so that they can be
# generated with verification disabled (enableVerification = False) while
# preserving the original module names (CoreMiniAxi, RvvCoreMiniAxi).
# This avoids naming conflicts with the simulation targets in the parent
# package, and prevents breaking downstream tools (like LEC and Power Analysis)
# that have the module names hardcoded.

load(
    "@coralnpu_hw//rules:chisel.bzl",
    "chisel_cc_library",
)
load(
    "//hdl/chisel/src/coralnpu:flags.bzl",
    "RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS",
    "VME_CORE_MINI_AXI_COMMON_GEN_FLAGS",
)

package(default_visibility = ["//visibility:public"])

CORE_MINI_AXI_VOPTS = [
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNSIGNED",
    "-Wno-BLKANDNBLK",
    "-Wno-BLKSEQ",
]

# Production target for CoreMiniAxi (verification disabled)
chisel_cc_library(
    name = "core_mini_axi_prod_cc_library",
    chisel_lib = "//hdl/chisel/src/coralnpu:coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VCoreMiniAxi_parameters.h",
        "CoreMiniAxi.zip",
    ],
    gen_flags = [
        "--enableFetchL0=False",
        "--fetchDataBits=128",
        "--lsuDataBits=128",
        "--enableFloat=True",
        "--enableZfbfmin=True",
        "--moduleName=CoreMini",  # Generates CoreMiniAxi module
        "--useAxi",
        # --enableVerification=False is the default in Chisel
    ],
    module_name = "CoreMiniAxi",
    verilog_file_path = "CoreMiniAxi.sv",
    vopts = CORE_MINI_AXI_VOPTS,
)

# Common generator flags are loaded from //hdl/chisel/src/coralnpu:flags.bzl

# Production target for RvvCoreMiniAxi (verification disabled)
chisel_cc_library(
    name = "rvv_core_mini_axi_prod_cc_library",
    chisel_lib = "//hdl/chisel/src/coralnpu:coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VRvvCoreMiniAxi_parameters.h",
        "RvvCoreMiniAxi.zip",
    ],
    gen_flags = [
        "--moduleName=RvvCoreMini",  # Generates RvvCoreMiniAxi module
        "--enableAxiInstructionFetch=False",
    ] + RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS,
    module_name = "RvvCoreMiniAxi",
    verilog_file_path = "RvvCoreMiniAxi.sv",
    vopts = CORE_MINI_AXI_VOPTS,
)

# Production target for VmeCoreMiniAxi with 8kB ITCM and 128kB DTCM (verification disabled)
chisel_cc_library(
    name = "vme_core_mini_itcm8kb_dtcm128kb_axi_prod_cc_library",
    chisel_lib = "//hdl/chisel/src/coralnpu:coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VVmeCoreMini_ITCM8KB_DTCM128KBAxi_parameters.h",
        "VmeCoreMini_ITCM8KB_DTCM128KBAxi.zip",
    ],
    gen_flags = [
        "--moduleName=VmeCoreMini",  # Generates VmeCoreMini_ITCM8KB_DTCM128KBAxi module
        "--itcmSizeKBytes=8",
        "--dtcmSizeKBytes=128",
    ] + VME_CORE_MINI_AXI_COMMON_GEN_FLAGS,
    module_name = "VmeCoreMini_ITCM8KB_DTCM128KBAxi",
    verilog_file_path = "VmeCoreMini_ITCM8KB_DTCM128KBAxi.sv",
    vopts = CORE_MINI_AXI_VOPTS,
)
