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

load("@coralnpu_hw//rules:vcs.bzl", "vcs_binary")
load("//rules:utils.bzl", "template_rule")

package(default_visibility = ["//visibility:public"])

template_rule(
    vcs_binary,
    {
        "core_mini_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
            "build_args": ["+define+DUT_MODULE=CoreMiniAxi"],
        },
        "core_mini_axi_1ghz_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
            "build_args": [
                "+define+DUT_MODULE=CoreMiniAxi",
                "+define+FPU_PIPEREGS=5",
            ],
        },
        "core_mini_verification_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:core_mini_verification_axi_cc_library_verilog"],
            "build_args": ["+define+DUT_MODULE=CoreMiniVerificationAxi"],
        },
        "core_mini_highmem_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:core_mini_highmem_axi_cc_library_verilog"],
            "build_args": ["+define+DUT_MODULE=CoreMiniHighmemAxi"],
        },
        "core_mini_itcm512kb_dtcm512kb_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:core_mini_itcm512kb_dtcm512kb_axi_cc_library_verilog"],
            "build_args": ["+define+DUT_MODULE=CoreMini_ITCM512KB_DTCM512KBAxi"],
        },
        "rvv_core_mini_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
            "build_args": [
                "+define+DUT_MODULE=RvvCoreMiniAxi",
                "+define+VLEN_128",
                "+define+ZVE32F_ON",
                "+define+TB_SUPPORT",
                "+define+USE_GENERIC",
            ],
        },
        "rvv_core_mini_axi_1ghz_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
            "build_args": [
                "+define+DUT_MODULE=RvvCoreMiniAxi",
                "+define+VLEN_128",
                "+define+ZVE32F_ON",
                "+define+TB_SUPPORT",
                "+define+USE_GENERIC",
                "+define+FPU_PIPEREGS=5",
                "+define+FALU_PIPEREGS=5",
            ],
        },
        "rvv_core_mini_highmem_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
            "build_args": [
                "+define+DUT_MODULE=RvvCoreMiniHighmemAxi",
                "+define+VLEN_128",
                "+define+ZVE32F_ON",
                "+define+TB_SUPPORT",
                "+define+USE_GENERIC",
            ],
        },
        "rvv_core_mini_itcm512kb_dtcm512kb_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:rvv_core_mini_itcm512kb_dtcm512kb_axi_cc_library_verilog"],
            "build_args": [
                "+define+DUT_MODULE=RvvCoreMini_ITCM512KB_DTCM512KBAxi",
                "+define+VLEN_128",
                "+define+ZVE32F_ON",
                "+define+TB_SUPPORT",
                "+define+USE_GENERIC",
            ],
        },
        "rvv_core_mini_verification_axi_sim": {
            "verilog_deps": ["//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library_verilog"],
            "build_args": [
                "+define+DUT_MODULE=RvvCoreMiniVerificationAxi",
                "+define+VLEN_128",
                "+define+ZVE32F_ON",
                "+define+TB_SUPPORT",
                "+define+USE_GENERIC",
            ],
        },
    },
    verilog_srcs = ["top.sv"],
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

sh_test(
    name = "simulators_smoke_test",
    srcs = ["simulators_smoke_test.sh"],
    data = [
        "//tests/cocotb:nop_test.elf",
        "//tests/vcs_sim:rvv_core_mini_verification_axi_sim",
    ],
    tags = ["vcs"],
    deps = [
        "@bazel_tools//tools/bash/runfiles",
    ],
)
