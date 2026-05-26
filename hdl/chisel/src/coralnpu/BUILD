# Copyright 2024 Google LLC
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

load("@coralnpu_hw//rules:autogen.bzl", "autogen_scm_info")
load(
    "@coralnpu_hw//rules:chisel.bzl",
    "chisel_binary",
    "chisel_cc_library",
    "chisel_library",
    "chisel_test",
)
load("@coralnpu_hw//rules:lint.bzl", "vcstatic_lint")
load("@coralnpu_hw//rules:verilog.bzl", "verilog_zip_bundle")
load("@coralnpu_hw//rules:utils.bzl", "template_rule")

package(default_visibility = ["//visibility:public"])

chisel_library(
    name = "coralnpu_float",
    srcs = [
        "float/FloatCore.scala",
        "float/FloatCoreInterface.scala",
        "scalar/FRegfile.scala",
        "scalar/Fpu.scala",
    ],
    resources = [
        "@common_cells//:all_srcs",
        "@cvfpu//:all_srcs",
        "@fpu_div_sqrt_mvp//:all_srcs",
    ],
    deps = [
        ":coralnpu_base",
        "//hdl/chisel/src/common:fma",
        "//hdl/chisel/src/common:fp",
        "//hdl/chisel/src/common:library",
    ],
)

chisel_test(
    name = "coralnpu_float_tests",
    size = "medium",
    srcs = [
        "scalar/FRegfileTest.scala",
        "scalar/FpuTest.scala",
    ],
    deps = [
        ":coralnpu",
        ":coralnpu_base",
        ":coralnpu_float",
        "//hdl/chisel/src/common:fp",
    ],
)

chisel_library(
    name = "rvvi_trace",
    srcs = [
        "RvviTrace.scala",
    ],
    resources = [
        "@RVVI//:all_srcs",
    ],
    deps = [
        ":coralnpu_base",
    ],
)

chisel_library(
    name = "retirement_buffer",
    srcs = [
        "RetirementBuffer.scala",
    ],
    deps = [
        ":coralnpu_base",
        "//hdl/chisel/src/common:aligner",
        "//hdl/chisel/src/common:circular_buffer_multi",
        "//hdl/chisel/src/common:library",
    ],
)

chisel_library(
    name = "coralnpu_rvv",
    srcs = [
        "rvv/RvvAlu.scala",
        "rvv/RvvBackendParams.scala",
        "rvv/RvvCore.scala",
        "rvv/RvvCoreNative.scala",
        "rvv/RvvDecode.scala",
        "rvv/RvvDecodeStage.scala",
        "rvv/RvvExecutionUnits.scala",
        "rvv/RvvFpWrappers.scala",
        "rvv/RvvFrontEnd.scala",
        "rvv/RvvInterface.scala",
        "rvv/RvvPrimitives.scala",
        "rvv/RvvReductionUnit.scala",
        "rvv/RvvRob.scala",
        "rvv/RvvVrf.scala",
    ],
    resources = [
        # FPNew (third-party Verilog IP — still needed for FMA/FDIV BlackBox wrappers)
        "@common_cells//:all_srcs",
        "@cvfpu//:all_srcs",
        "@fpu_div_sqrt_mvp//:all_srcs",
        # FP-related Verilog sources
        "//hdl/verilog/rvv/design:rvv_backend_fma_wrapper.sv",
        "//hdl/verilog/rvv/design:rvv_backend_fdiv_wrapper.sv",
        "//hdl/verilog/rvv/design:rvv_backend_sqrt7_rec7.sv",
        "//hdl/verilog/rvv/design:rvv_backend_fma.sv",
        "//hdl/verilog/rvv/inc:rvv_backend_fma.svh",
        "//hdl/verilog/rvv/inc:rvv_backend.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_define.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_config.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_sva.svh",
    ],
    deps = [
        ":coralnpu_base",
        "//hdl/chisel/src/common:library",
    ],
)

chisel_test(
    name = "coralnpu_rvv_tests",
    srcs = [
        "rvv/RvvDecodeTest.scala",
    ],
    args = [
        "-P",  # Allows parallel tests.
    ],
    deps = [
        ":coralnpu_rvv",
        "//hdl/chisel/src/common:testing",
    ],
)

chisel_test(
    name = "coralnpu_scalar_tests",
    size = "large",
    srcs = [
        "scalar/AluTest.scala",
        "scalar/MluTest.scala",
    ],
    args = [
        "-P",  # Allows parallel tests.
    ],
    deps = [
        ":coralnpu_base",
        ":coralnpu_scalar",
        "//hdl/chisel/src/common:testing",
    ],
)

chisel_test(
    name = "coralnpu_uncached_fetch_tests",
    size = "medium",
    srcs = [
        "scalar/UncachedFetchTest.scala",
    ],
    deps = [
        ":coralnpu_base",
        ":coralnpu_scalar",
        "//hdl/chisel/src/common",
        "//hdl/chisel/src/common:instruction_buffer",
    ],
)

chisel_test(
    name = "coralnpu_core_axi_tests",
    size = "large",
    srcs = [
        "CoreAxiCSRTest.scala",
        "DBus2AxiTest.scala",
        "FabricTest.scala",
    ],
    deps = [
        ":coralnpu",
        ":coralnpu_base",
        "//hdl/chisel/src/bus",
    ],
)

chisel_library(
    name = "clock_gate",
    srcs = [
        "ClockGate.scala",
    ],
    resource_strip_prefix = "hdl/verilog",
    resources = [
        "//hdl/verilog:ClockGate.sv",
    ],
)

chisel_test(
    name = "clock_gate_test",
    srcs = [
        "ClockGateTest.scala",
    ],
    deps = [
        ":clock_gate",
        ":coralnpu_base",
    ],
)

chisel_library(
    name = "RstSync",
    srcs = [
        "RstSync.scala",
    ],
    resource_strip_prefix = "hdl/verilog",
    resources = [
        "//hdl/verilog:RstSync.sv",
    ],
)

autogen_scm_info(name = "CoralNPUScmInfo")

chisel_library(
    name = "coralnpu_base",
    srcs = [
        "DBus2Axi.scala",
        "IBus2Axi.scala",
        "Interfaces.scala",
        "L1DCache.scala",
        "L1ICache.scala",
        "Library.scala",
        "Parameters.scala",
    ],
    deps = [
        ":clock_gate",
        "//hdl/chisel/src/bus",
        "//hdl/chisel/src/common",
        "//hdl/chisel/src/common:fp",
    ],
)

chisel_library(
    name = "coralnpu_scalar",
    srcs = [
        "scalar/Alu.scala",
        "scalar/Bru.scala",
        "scalar/Csr.scala",
        "scalar/Debug.scala",
        "scalar/Decode.scala",
        "scalar/Dvu.scala",
        "scalar/FaultManager.scala",
        "scalar/Fetch.scala",
        "scalar/Lsu.scala",
        "scalar/Mlu.scala",
        "scalar/Regfile.scala",
        "scalar/SCore.scala",
        "scalar/UncachedFetch.scala",
    ],
    deps = [
        ":CoralNPUScmInfo",
        ":coralnpu_base",
        ":coralnpu_float",
        ":coralnpu_rvv",
        ":retirement_buffer",
        ":rvvi_trace",
        "//hdl/chisel/src/common",
        "//hdl/chisel/src/common:aligner",
        "//hdl/chisel/src/common:circular_buffer_multi",
        "//hdl/chisel/src/common:fp",
        "//hdl/chisel/src/common:instruction_buffer",
        "//hdl/chisel/src/common:scatter_gather",
    ],
)

chisel_library(
    name = "srams",
    srcs = [
        "SramNx128.scala",
    ],
    deps = [
        ":coralnpu_base",
        "//hdl/chisel/src/bus",
    ],
    resource_strip_prefix = "hdl/verilog",
    resources = [
        "//hdl/verilog:Sram.v",
    ],
)

chisel_library(
    name = "coralnpu",
    srcs = [
        "AxiSlave.scala",
        "Core.scala",
        "CoreAxi.scala",
        "CoreAxiCSR.scala",
        "CoreTlul.scala",
        "Fabric.scala",
        "SRAM.scala",
        "TCM.scala",
    ],
    deps = [
        ":RstSync",
        ":clock_gate",
        ":coralnpu_base",
        ":coralnpu_float",
        ":coralnpu_rvv",
        ":coralnpu_scalar",
        ":srams",
        "//hdl/chisel/src/bus",
        "//hdl/chisel/src/common",
        "//hdl/chisel/src/common:instruction_buffer",
    ],
)

chisel_library(
    name = "coralnpu_params",
    srcs = [
        "MemorySize.scala",
        "Parameters.scala",
    ],
    deps = [
    ],
)

chisel_cc_library(
    name = "alu_cc_library",
    chisel_lib = ":coralnpu_scalar",
    emit_class = "coralnpu.EmitAlu",
    module_name = "Alu",
)

chisel_cc_library(
    name = "core_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VCore_parameters.h",
    ],
    module_name = "Core",
)

chisel_cc_library(
    name = "core_scalar_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VCoreScalar_parameters.h",
    ],
    gen_flags = [
        "--moduleName=CoreScalar",
    ],
    module_name = "CoreScalar",
    verilog_file_path = "CoreScalar.sv",
)

chisel_cc_library(
    name = "core_mini_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VCoreMini_parameters.h",
    ],
    gen_flags = [
        "--enableFetchL0=False",
        "--fetchDataBits=128",
        "--lsuDataBits=128",
        "--moduleName=CoreMini",
    ],
    module_name = "CoreMini",
    verilog_file_path = "CoreMini.sv",
)

CORE_MINI_AXI_VOPTS = [
    "-DUSE_GENERIC",
    # Warnings that we disable for fpnew
    "-Wno-UNOPTFLAT",
    "-Wno-ASCRANGE",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNSIGNED",
]

template_rule(
    chisel_cc_library,
    {
        "core_mini_axi_cc_library": {
            "extra_outs": [
                "VCoreMiniAxi_parameters.h",
                "CoreMiniAxi.zip",
            ],
            "gen_flags": [
                "--enableFetchL0=False",
                "--fetchDataBits=128",
                "--lsuDataBits=128",
                "--enableFloat=True",
                "--moduleName=CoreMini",
                "--useAxi",
            ],
            "module_name": "CoreMiniAxi",
            "verilog_file_path": "CoreMiniAxi.sv",
        },
        "core_mini_verification_axi_cc_library": {
            "extra_outs": [
                "VCoreMiniVerificationAxi_parameters.h",
                "CoreMiniVerificationAxi.zip",
            ],
            "gen_flags": [
                "--enableFetchL0=False",
                "--fetchDataBits=128",
                "--lsuDataBits=128",
                "--enableFloat=True",
                "--moduleName=CoreMiniVerification",
                "--useAxi",
                "--enableVerification=True",
            ],
            "module_name": "CoreMiniVerificationAxi",
            "verilog_file_path": "CoreMiniVerificationAxi.sv",
        },
    },
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    vopts = CORE_MINI_AXI_VOPTS,
)

chisel_cc_library(
    name = "core_mini_highmem_axi_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VCoreMiniHighmemAxi_parameters.h",
        "CoreMiniHighmemAxi.zip",
    ],
    gen_flags = [
        "--enableFetchL0=False",
        "--fetchDataBits=128",
        "--lsuDataBits=128",
        "--enableFloat=True",
        "--moduleName=CoreMini",
        "--useAxi",
        "--itcmSizeKBytes=1024",
        "--dtcmSizeKBytes=1024",
    ],
    module_name = "CoreMiniHighmemAxi",
    vopts = CORE_MINI_AXI_VOPTS,
)

chisel_cc_library(
    name = "core_mini_itcm512kb_dtcm512kb_axi_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    extra_outs = [
        "VCoreMini_ITCM512KB_DTCM512KBAxi_parameters.h",
        "CoreMini_ITCM512KB_DTCM512KBAxi.zip",
    ],
    gen_flags = [
        "--enableFetchL0=False",
        "--fetchDataBits=128",
        "--lsuDataBits=128",
        "--enableFloat=True",
        "--moduleName=CoreMini",
        "--useAxi",
        "--itcmSizeKBytes=512",
        "--dtcmSizeKBytes=512",
    ],
    module_name = "CoreMini_ITCM512KB_DTCM512KBAxi",
    vopts = CORE_MINI_AXI_VOPTS,
)


CORE_MINI_AXI_BLACKBOX_DESIGNS = [
    "CKLNQD10BWP6T20P96CPDLVT",
    "TS1N12FFCLLMBLVTD2048X128M4SWBSHO",
    "TS1N12FFCLLSBLVTD512X128M4SWBSHO",
    "sasdulssd8LOW1p512x128m4b1w0c0p0d0l0rm3sdrw01",
    "sasdulssd8LOW1p2048x128m4b2w0c0p0d0l0rm3sdrw01",
]

CORE_MINI_AXI_LINT_TAGS = [
    "STARC05-1.3.1.3",
    "STARC05-2.7.1.3a",
    "STARC05-2.7.1.3b",
]

vcstatic_lint(
    name = "core_mini_axi_cc_library_lint_check",
    blackbox_designs = CORE_MINI_AXI_BLACKBOX_DESIGNS,
    lint_tags = CORE_MINI_AXI_LINT_TAGS,
    module = "CoreMiniAxi",
    package = "core_mini_axi_cc_library_verilog",
)

vcstatic_lint(
    name = "core_mini_axi_cc_library_lint",
    blackbox_designs = CORE_MINI_AXI_BLACKBOX_DESIGNS,
    goal = "lint_rtl",
    lint_tags = CORE_MINI_AXI_LINT_TAGS,
    module = "CoreMiniAxi",
    package = "core_mini_axi_cc_library_verilog",
    waive_tags = ["UndrivenInTerm-ML"],
)

vcstatic_lint(
    name = "rvv_core_mini_axi_cc_library_lint",
    blackbox_designs = CORE_MINI_AXI_BLACKBOX_DESIGNS,
    goal = "lint_rtl",
    lint_tags = CORE_MINI_AXI_LINT_TAGS,
    module = "RvvCoreMiniAxi",
    package = "rvv_core_mini_axi_cc_library_verilog",
    waive_tags = ["UndrivenInTerm-ML"],
)

RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS = [
    "--enableFetchL0=False",
    "--fetchDataBits=128",
    "--lsuDataBits=128",
    "--enableRvv=True",
    "--enableFloat=True",
    "--useAxi",
]

template_rule(
    chisel_cc_library,
    {
        "rvv_core_mini_tlul_cc_library": {
            "verilog_file_path": "RvvCoreMiniTlul.sv",
            "extra_outs": [
                "VRvvCoreMiniTlul_parameters.h",
                "RvvCoreMiniTlul.zip",
            ],
            "gen_flags": [
                "--moduleName=RvvCoreMini",
                "--enableFetchL0=False",
                "--fetchDataBits=128",
                "--lsuDataBits=128",
                "--enableRvv=True",
                "--enableFloat=True",
                "--useTlul=True",
            ],
            "module_name": "RvvCoreMiniTlul",
        },
        "rvv_core_mini_axi_cc_library": {
            "verilog_file_path": "RvvCoreMiniAxi.sv",
            "extra_outs": [
                "VRvvCoreMiniAxi_parameters.h",
                "RvvCoreMiniAxi.zip",
            ],
            "gen_flags": [
                "--moduleName=RvvCoreMini",
                "--itcmSizeKBytes=8",
                "--dtcmSizeKBytes=32",
            ] + RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS,
            "module_name": "RvvCoreMiniAxi",
        },
        "rvv_core_mini_verification_axi_cc_library": {
            "verilog_file_path": "RvvCoreMiniVerificationAxi.sv",
            "extra_outs": [
                "VRvvCoreMiniVerificationAxi_parameters.h",
                "RvvCoreMiniVerificationAxi.zip",
            ],
            "gen_flags": [
                "--moduleName=RvvCoreMiniVerification",
                "--enableVerification=True",
            ] + RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS,
            "module_name": "RvvCoreMiniVerificationAxi",
        },
        "rvv_core_mini_highmem_axi_cc_library": {
            "extra_outs": [
                "VRvvCoreMiniHighmemAxi_parameters.h",
                "RvvCoreMiniHighmemAxi.zip",
            ],
            "gen_flags": [
                "--moduleName=RvvCoreMini",
                "--itcmSizeKBytes=1024",
                "--dtcmSizeKBytes=1024",
                # Highmem naming is handled in Core.scala
            ] + RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS,
            "module_name": "RvvCoreMiniHighmemAxi",
        },
        "rvv_core_mini_itcm512kb_dtcm512kb_axi_cc_library": {
            "extra_outs": [
                "VRvvCoreMini_ITCM512KB_DTCM512KBAxi_parameters.h",
                "RvvCoreMini_ITCM512KB_DTCM512KBAxi.zip",
            ],
            "gen_flags": [
                "--moduleName=RvvCoreMini",
                "--itcmSizeKBytes=512",
                "--dtcmSizeKBytes=512",
            ] + RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS,
            "module_name": "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
        },
    },
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    vopts = [
        "-DUSE_GENERIC",
        # RVV
        "-DTB_SUPPORT",
        "-DVLEN_128",
        "-Wno-WIDTH",
        "-Wno-CASEINCOMPLETE",
        "-Wno-LATCH",
        "-Wno-SIDEEFFECT",
        "-Wno-MULTIDRIVEN",
        "-Wno-UNOPTFLAT",
        "-Wno-BLKANDNBLK",
        "-Wno-CASEX",
        # FPNEW
        "-Wno-ASCRANGE",
        "-Wno-WIDTHEXPAND",
        "-Wno-WIDTHTRUNC",
        "-Wno-UNSIGNED",
        "-Ihdl/verilog/rvv/inc",
        "-Ihdl/verilog/rvv/design/FPnew/common_cells/inc",
    ],
)

filegroup(
    name = "rvv_core_mini_tlul_verilog",
    srcs = [":rvv_core_mini_tlul_cc_library_verilog"],
)

verilog_zip_bundle(
    name = "core_mini_axi_bundle",
    lib = ":core_mini_axi_cc_library_verilog",
)

chisel_cc_library(
    name = "dbus2axi_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitDBus2Axi",
    module_name = "DBus2AxiV2",
)

chisel_cc_library(
    name = "dvu_cc_library",
    chisel_lib = ":coralnpu_scalar",
    emit_class = "coralnpu.EmitDvu",
    module_name = "Dvu",
)

chisel_cc_library(
    name = "mlu_cc_library",
    chisel_lib = ":coralnpu_scalar",
    emit_class = "coralnpu.EmitMlu",
    module_name = "Mlu",
)

chisel_cc_library(
    name = "l1dcache_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitL1DCache",
    module_name = "L1DCache",
    verilog_deps = [
        "//hdl/verilog:sram_1rw_256x288",
    ],
)

chisel_cc_library(
    name = "l1dcachebank_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitL1DCacheBank",
    module_name = "L1DCacheBank",
    verilog_deps = [
        "//hdl/verilog:sram_1rw_256x288",
    ],
)

chisel_cc_library(
    name = "l1icache_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitL1ICache",
    module_name = "L1ICache",
    verilog_deps = [
        "//hdl/verilog:sram_1rw_256x256",
    ],
)
