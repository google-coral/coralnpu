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
load("@coralnpu_hw//rules:utils.bzl", "filter_files_by_extension", "template_rule")
load("@coralnpu_hw//rules:verilog.bzl", "verilog_zip_bundle")
load("//hdl/chisel/src/coralnpu:flags.bzl", "RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS")

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
    name = "coralnpu_fregfile_tests",
    size = "large",
    srcs = [
        "scalar/FRegfileTest.scala",
    ],
    deps = [
        ":coralnpu",
        ":coralnpu_base",
        ":coralnpu_float",
        "//hdl/chisel/src/common:fp",
    ],
)

chisel_test(
    name = "coralnpu_fpu_tests",
    size = "large",
    srcs = [
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
        "rvv/RvvCore.scala",
        "rvv/RvvDecode.scala",
        "rvv/RvvInterface.scala",
    ],
    resources = [
        # FPNew
        "@common_cells//:all_srcs",
        "@cvfpu//:all_srcs",
        "@fpu_div_sqrt_mvp//:all_srcs",
        "//hdl/verilog/rvv/common:adder.sv",
        "//hdl/verilog/rvv/common:arb_round_robin.sv",
        "//hdl/verilog/rvv/common:barrel_shifter.sv",
        "//hdl/verilog/rvv/common:handshake_ff.sv",
        "//hdl/verilog/rvv/common:handshake_multistage_ctrl.sv",
        "//hdl/verilog/rvv/common:handshake_multi_fifo.sv",
        "//hdl/verilog/rvv/common:cdffr.sv",
        "//hdl/verilog/rvv/common:compressor_3to2.sv",
        "//hdl/verilog/rvv/common:compressor_4to2.sv",
        "//hdl/verilog/rvv/common:dff.sv",
        "//hdl/verilog/rvv/common:edff.sv",
        "//hdl/verilog/rvv/common:edff_2d.sv",
        "//hdl/verilog/rvv/common:multi_fifo.sv",
        "//hdl/verilog/rvv/common:intdivider.sv",
        "//hdl/verilog/rvv/design:Aligner.sv",
        "//hdl/verilog/rvv/design:RvvCore.sv",
        "//hdl/verilog/rvv/design:RvvFrontEnd.sv",
        "//hdl/verilog/rvv/design:Zvt/fp_absaddsub.sv",
        "//hdl/verilog/rvv/design:Zvt/fp_addfront.sv",
        "//hdl/verilog/rvv/design:Zvt/fp_align.sv",
        "//hdl/verilog/rvv/design:Zvt/fp_classifier.sv",
        "//hdl/verilog/rvv/design:Zvt/fp_mulfront.sv",
        "//hdl/verilog/rvv/design:Zvt/fp_rounding.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_acc.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_acc_reg.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_ctrl.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_adder.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_adder_fp_lane.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_adder_int_lane.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_array.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_block.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_mulbulk.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_mulbulk_fp_lane.sv",
        "//hdl/verilog/rvv/design:Zvt/zvt_pe_mulbulk_int_lane.sv",
        "//hdl/verilog/rvv/design:rvv_backend_falu_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_falu.sv",
        "//hdl/verilog/rvv/design:rvv_backend.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu_unit_addsub.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu_unit_execution_p1.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu_unit_mask.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu_unit_mask_viota.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu_unit_other.sv",
        "//hdl/verilog/rvv/design:rvv_backend_alu_unit_shift.sv",
        "//hdl/verilog/rvv/design:rvv_backend_arb.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_unit_ari_de2.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_unit_lsu_de2.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_unit_de2.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_de2.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_ctrl.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_unit_ari.sv",
        "//hdl/verilog/rvv/design:rvv_backend_decode_unit_lsu.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch_bypass.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch_ctrl.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch_operand.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch_opr_byte_type.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch_raw_uop_rob.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch_raw_uop_uop.sv",
        "//hdl/verilog/rvv/design:rvv_backend_dispatch_structure_hazard.sv",
        "//hdl/verilog/rvv/design:rvv_backend_div.sv",
        "//hdl/verilog/rvv/design:rvv_backend_fdiv_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_div_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_fdiv_wrapper.sv",
        "//hdl/verilog/rvv/design:rvv_backend_lsu_remap.sv",
        "//hdl/verilog/rvv/design:rvv_backend_mac_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_mul_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_mul_unit_mul8.sv",
        "//hdl/verilog/rvv/design:rvv_backend_sqrt7_rec7.sv",
        "//hdl/verilog/rvv/design:rvv_backend_mulmac.sv",
        "//hdl/verilog/rvv/design:rvv_backend_pmtrdt.sv",
        "//hdl/verilog/rvv/design:rvv_backend_pmtrdt_unit.sv",
        "//hdl/verilog/rvv/design:rvv_backend_freduction.sv",
        "//hdl/verilog/rvv/design:rvv_backend_pmtrdt_unit_permutation.sv",
        "//hdl/verilog/rvv/design:rvv_backend_pmtrdt_unit_reduction_alu.sv",
        "//hdl/verilog/rvv/design:rvv_backend_pmtrdt_unit_reduction.sv",
        "//hdl/verilog/rvv/design:rvv_backend_retire_waw.sv",
        "//hdl/verilog/rvv/design:rvv_backend_retire.sv",
        "//hdl/verilog/rvv/design:rvv_backend_rob.sv",
        "//hdl/verilog/rvv/design:rvv_backend_vrf.sv",
        "//hdl/verilog/rvv/design:rvv_backend_vrf_reg.sv",
        "//hdl/verilog/rvv/inc:rvv_backend.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_alu.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_define.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_dispatch.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_div.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_falu.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_opcode.svh",
        "//hdl/verilog/rvv/inc:rvv_backend_pmtrdt.svh",
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
        ":coralnpu_base",
        ":coralnpu_rvv",
        "//hdl/chisel/src/common:testing",
    ],
)

chisel_test(
    name = "coralnpu_alu_tests",
    size = "large",
    srcs = [
        "scalar/AluTest.scala",
    ],
    deps = [
        ":coralnpu_base",
        ":coralnpu_scalar",
        "//hdl/chisel/src/common:testing",
    ],
)

chisel_test(
    name = "coralnpu_mlu_tests",
    size = "large",
    srcs = [
        "scalar/MluTest.scala",
    ],
    deps = [
        ":coralnpu_base",
        ":coralnpu_scalar",
        "//hdl/chisel/src/common:testing",
    ],
)

chisel_test(
    name = "coralnpu_fetch_reorder_buffer_tests",
    size = "large",
    srcs = [
        "scalar/FetchReorderBufferSpec.scala",
    ],
    deps = [
        ":coralnpu_base",
        ":coralnpu_scalar",
        "//hdl/chisel/src/common",
        "//hdl/chisel/src/common:instruction_buffer",
    ],
)

chisel_test(
    name = "coralnpu_fetch_control_tests",
    size = "large",
    srcs = [
        "scalar/FetchControlSpec.scala",
    ],
    deps = [
        ":coralnpu_base",
        ":coralnpu_scalar",
        "//hdl/chisel/src/common",
        "//hdl/chisel/src/common:instruction_buffer",
    ],
)

chisel_test(
    name = "coralnpu_fetcher_tests",
    srcs = [
        "scalar/FetcherSpec.scala",
    ],
    deps = [
        ":coralnpu_base",
        ":coralnpu_scalar",
        "//hdl/chisel/src/common",
        "//hdl/chisel/src/common:instruction_buffer",
    ],
)

chisel_test(
    name = "coralnpu_core_axi_csr_tests",
    srcs = [
        "CoreAxiCSRTest.scala",
    ],
    deps = [
        ":coralnpu",
        ":coralnpu_base",
        "//hdl/chisel/src/bus",
    ],
)

chisel_test(
    name = "coralnpu_dbus2axi_tests",
    srcs = [
        "DBus2AxiTest.scala",
    ],
    deps = [
        ":coralnpu",
        ":coralnpu_base",
        "//hdl/chisel/src/bus",
    ],
)

chisel_test(
    name = "coralnpu_fabric_arbiter_tests",
    size = "large",
    srcs = [
        "FabricArbiterSpec.scala",
    ],
    deps = [
        ":coralnpu",
        ":coralnpu_base",
        "//hdl/chisel/src/bus",
    ],
)

chisel_test(
    name = "coralnpu_fabric_mux_tests",
    size = "large",
    srcs = [
        "FabricMuxSpec.scala",
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
        "Sram.scala",
        "SramNx128.scala",
    ],
    resource_strip_prefix = "hdl/verilog",
    resources = [
        "//hdl/verilog:Sram.v",
    ],
    deps = [
        ":coralnpu_base",
        "//hdl/chisel/src/bus",
    ],
)

chisel_library(
    name = "coralnpu",
    srcs = [
        "AxiSlave.scala",
        "BankedDtcm.scala",
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
        "//hdl/chisel/src/soc:crossbar_config_lib",
    ],
)

chisel_library(
    name = "coralnpu_params",
    srcs = [
        "MemorySize.scala",
        "Parameters.scala",
    ],
    deps = [
        "//hdl/chisel/src/bus",
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
    "-Wno-BLKANDNBLK",
    "-Wno-BLKSEQ",
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
                "--enableZfbfmin=True",
                "--moduleName=CoreMini",
                "--useAxi",
                "--exposeDebugPorts=True",
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
                "--enableZfbfmin=True",
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
        "--enableZfbfmin=True",
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
        "--enableZfbfmin=True",
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
                "--enableVerification=True",
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
        "-DZVE32F_ON",
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
        "-Wno-WIDTHCONCAT",
        "-Ihdl/verilog/rvv/design/FPnew/common_cells/inc",
    ],
)

filter_files_by_extension(
    name = "rvv_core_mini_verification_axi_cc_library_emit_verilog_single_sv",
    src = ":rvv_core_mini_verification_axi_cc_library_emit_verilog",
    extensions = ["sv"],
)

filegroup(
    name = "rvv_core_mini_tlul_verilog",
    srcs = [":rvv_core_mini_tlul_cc_library_verilog"],
)

# VME (Zvt) variant. Adds the non-tile mset* CSR plumbing on top of the RVV
# core. Kept as a separate template_rule call so the RVV-only targets above
# remain byte-identical (the ZVT_ON define widens the RVVConfigState struct).
VME_CORE_MINI_AXI_COMMON_GEN_FLAGS = RVV_CORE_MINI_AXI_COMMON_GEN_FLAGS + [
    "--enableVme=True",
]

template_rule(
    chisel_cc_library,
    {
        "vme_core_mini_axi_cc_library": {
            "verilog_file_path": "VmeCoreMiniAxi.sv",
            "extra_outs": [
                "VVmeCoreMiniAxi_parameters.h",
                "VmeCoreMiniAxi.zip",
            ],
            "gen_flags": [
                "--moduleName=VmeCoreMini",
                "--itcmSizeKBytes=8",
                "--dtcmSizeKBytes=32",
            ] + VME_CORE_MINI_AXI_COMMON_GEN_FLAGS,
            "module_name": "VmeCoreMiniAxi",
        },
    },
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.EmitCore",
    vopts = [
        "-DUSE_GENERIC",
        # RVV
        "-DTB_SUPPORT",
        "-DVLEN_128",
        "-DZVE32F_ON",
        # VME (Zvt) non-tile state and mset* instructions.
        "-DZVT_ON",
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
        "-Wno-WIDTHCONCAT",
        "-Ihdl/verilog/rvv/design/FPnew/common_cells/inc",
    ],
)

vcstatic_lint(
    name = "vme_core_mini_axi_cc_library_lint",
    blackbox_designs = CORE_MINI_AXI_BLACKBOX_DESIGNS,
    goal = "lint_rtl",
    lint_tags = CORE_MINI_AXI_LINT_TAGS,
    module = "VmeCoreMiniAxi",
    package = "vme_core_mini_axi_cc_library_verilog",
    waive_tags = ["UndrivenInTerm-ML"],
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
    name = "banked_dtcm_cc_library",
    chisel_lib = ":coralnpu",
    emit_class = "coralnpu.BankedDtcmEmitter",
    gen_flags = [
        "--lsuDataBits=128",
    ],
    module_name = "BankedDtcm",
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
