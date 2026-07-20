# Copyright 2023 Google LLC
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

load("//rules:coralnpu_v2.bzl", "collect_coralnpu_elfs", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")

coralnpu_v2_binary(
    name = "htif_semihosting_test",
    srcs = ["coralnpu/htif_semihosting_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    semihosting = True,
    visibility = ["//visibility:public"],
)

cc_library(
    name = "elf",
    srcs = [
        "elf.cc",
    ],
    hdrs = [
        "elf.h",
    ],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "util",
    hdrs = [
        "util.h",
    ],
)

cc_library(
    name = "sim_libs",
    hdrs = [
        "fifo.h",
        "sysc_module.h",
        "sysc_tb.h",
    ],
    includes = [
        "systemc/include",
    ],
    deps = [
        "@accellera_systemc//:systemc",
    ],
)

cc_library(
    name = "coralnpu_if",
    hdrs = [
        "coralnpu/coralnpu_cfg.h",
        "coralnpu/core_if.h",
        "coralnpu/debug_if.h",
        "coralnpu/memory_if.h",
    ],
    defines = ["CORALNPU_SIMD=256"],
)

cc_binary(
    name = "core_sim",
    srcs = [
        "coralnpu/core_tb.cc",
        "@coralnpu_hw//hdl/chisel/src/coralnpu:VCore_parameters.h",
    ],
    defines = [
        "VERILATOR_MODEL=VCore",
    ],
    deps = [
        ":coralnpu_if",
        ":sim_libs",
        ":util",
        "//hdl/chisel/src/coralnpu:core_cc_library",
        "@com_google_absl//absl/flags:flag",
        "@com_google_absl//absl/flags:parse",
        "@com_google_absl//absl/flags:usage",
    ],
)

CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS = [
    "coralnpu/core_mini_axi_tb.cc",
]

CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS = [
    ":elf",
    ":sim_libs",
    ":util",
    "//hdl/verilog:sram_backdoor",
    "//tests/systemc:Xbar",
    "//tests/systemc:instruction_trace",
    "@accellera_systemc//:systemc",
    "@com_google_absl//absl/log",
    "@com_google_absl//absl/log:check",
    "@com_google_absl//absl/log:initialize",
    "@com_google_absl//absl/status",
    "@libsystemctlm_soc",
]

template_rule(
    cc_library,
    {
        "core_mini_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VCoreMiniAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:core_mini_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VCoreMiniAxi",
            ],
        },
        "core_mini_verification_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VCoreMiniVerificationAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:core_mini_verification_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VCoreMiniVerificationAxi",
            ],
        },
        "core_mini_highmem_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VCoreMiniHighmemAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:core_mini_highmem_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VCoreMiniHighmemAxi",
                "HIGHMEM_RTL",
            ],
        },
        "core_mini_itcm512kb_dtcm512kb_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VCoreMini_ITCM512KB_DTCM512KBAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:core_mini_itcm512kb_dtcm512kb_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VCoreMini_ITCM512KB_DTCM512KBAxi",
                "HIGHMEM_RTL",
            ],
        },
        "rvv_core_mini_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VRvvCoreMiniAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VRvvCoreMiniAxi",
            ],
        },
        "rvv_core_mini_highmem_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VRvvCoreMiniHighmemAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VRvvCoreMiniHighmemAxi",
                "HIGHMEM_RTL",
            ],
        },
        "rvv_core_mini_itcm512kb_dtcm512kb_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VRvvCoreMini_ITCM512KB_DTCM512KBAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:rvv_core_mini_itcm512kb_dtcm512kb_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VRvvCoreMini_ITCM512KB_DTCM512KBAxi",
                "HIGHMEM_RTL",
            ],
        },
        "rvv_core_mini_verification_axi_tb": {
            "srcs": [
                "@coralnpu_hw//hdl/chisel/src/coralnpu:VRvvCoreMiniVerificationAxi_parameters.h",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_SRCS,
            "deps": [
                "//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library",
            ] + CORE_MINI_AXI_TB_CC_LIBRARY_COMMON_DEPS,
            "defines": [
                "VERILATOR_MODEL=VRvvCoreMiniVerificationAxi",
            ],
        },
    },
    hdrs = [
        "coralnpu/core_mini_axi_tb.h",
    ],
)

CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS = [
    "@com_google_absl//absl/flags:flag",
    "@com_google_absl//absl/flags:parse",
    "@com_google_absl//absl/flags:usage",
    "@com_google_absl//absl/log",
    "@com_google_absl//absl/log:check",
]

template_rule(
    cc_binary,
    {
        "core_mini_axi_sim": {
            "deps": [
                ":core_mini_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
        "core_mini_verification_axi_sim": {
            "deps": [
                ":core_mini_verification_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
        "core_mini_highmem_axi_sim": {
            "deps": [
                ":core_mini_highmem_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
        "core_mini_itcm512kb_dtcm512kb_axi_sim": {
            "deps": [
                ":core_mini_itcm512kb_dtcm512kb_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
        "rvv_core_mini_axi_sim": {
            "deps": [
                ":rvv_core_mini_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
        "rvv_core_mini_highmem_axi_sim": {
            "deps": [
                ":rvv_core_mini_highmem_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
        "rvv_core_mini_itcm512kb_dtcm512kb_axi_sim": {
            "deps": [
                ":rvv_core_mini_itcm512kb_dtcm512kb_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
        "rvv_core_mini_verification_axi_sim": {
            "deps": [
                ":rvv_core_mini_verification_axi_tb",
            ] + CORE_MINI_AXI_SIM_CC_BINARY_COMMON_DEPS,
        },
    },
    srcs = [
        "coralnpu/core_mini_axi_sim.cc",
    ],
)

cc_test(
    name = "core_mini_axi_non_incr_tests",
    srcs = [
        "coralnpu/core_mini_axi_non_incr_tests.cc",
    ],
    deps = [
        ":core_mini_axi_tb",
        "@com_google_absl//absl/flags:parse",
        "@com_google_absl//absl/log:initialize",
    ],
)

cc_test(
    name = "backdoor_load_test",
    srcs = [
        "coralnpu/backdoor_load_test.cc",
    ],
    deps = [
        ":core_mini_axi_tb",
        "@com_google_absl//absl/flags:parse",
        "@com_google_absl//absl/log:initialize",
    ],
)

cc_binary(
    name = "core_scalar_sim",
    srcs = [
        "coralnpu/core_tb.cc",
        "@coralnpu_hw//hdl/chisel/src/coralnpu:VCoreScalar_parameters.h",
    ],
    defines = [
        "VERILATOR_MODEL=VCoreScalar",
    ],
    deps = [
        ":coralnpu_if",
        ":sim_libs",
        ":util",
        "//hdl/chisel/src/coralnpu:core_scalar_cc_library",
        "@com_google_absl//absl/flags:flag",
        "@com_google_absl//absl/flags:parse",
        "@com_google_absl//absl/flags:usage",
    ],
)

cc_binary(
    name = "core_mini_sim",
    srcs = [
        "coralnpu/core_tb.cc",
        "@coralnpu_hw//hdl/chisel/src/coralnpu:VCoreMini_parameters.h",
    ],
    defines = [
        "VERILATOR_MODEL=VCoreMini",
    ],
    deps = [
        ":coralnpu_if",
        ":sim_libs",
        ":util",
        "//hdl/chisel/src/coralnpu:core_mini_cc_library",
        "@com_google_absl//absl/flags:flag",
        "@com_google_absl//absl/flags:parse",
        "@com_google_absl//absl/flags:usage",
    ],
)

cc_test(
    name = "dbus2axi_tb",
    srcs = [
        "coralnpu/dbus2axi_tb.cc",
    ],
    deps = [
        ":sim_libs",
        "//hdl/chisel/src/coralnpu:dbus2axi_cc_library",
    ],
)

cc_test(
    name = "l1dcache_tb",
    size = "large",
    srcs = [
        "coralnpu/l1dcache_tb.cc",
    ],
    deps = [
        ":coralnpu_if",
        ":sim_libs",
        "//hdl/chisel/src/coralnpu:l1dcache_cc_library",
    ],
)

cc_test(
    name = "l1dcachebank_tb",
    size = "large",
    srcs = [
        "coralnpu/l1dcache_tb.cc",
    ],
    defines = [
        "L1DCACHEBANK",
    ],
    deps = [
        ":coralnpu_if",
        ":sim_libs",
        "//hdl/chisel/src/coralnpu:l1dcachebank_cc_library",
    ],
)

cc_test(
    name = "l1icache_tb",
    srcs = [
        "coralnpu/l1icache_tb.cc",
    ],
    deps = [
        ":coralnpu_if",
        ":sim_libs",
        "//hdl/chisel/src/coralnpu:l1icache_cc_library",
    ],
)

collect_coralnpu_elfs()
