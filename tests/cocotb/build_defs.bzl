# Copyright 2025 Google LLC
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

"""Common build arguments for cocotb tests."""

load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")

VERILATOR_BUILD_ARGS = [
    "-Wno-WIDTH",
    "-Wno-CASEINCOMPLETE",
    "-Wno-LATCH",
    "-Wno-SIDEEFFECT",
    "-Wno-MULTIDRIVEN",
    "-Wno-UNOPTFLAT",
    "-Wno-BLKANDNBLK",
    "-Wno-CASEX",
    # Warnings that we disable for fpnew
    "-Wno-ASCRANGE",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNSIGNED",
    "-DUSE_GENERIC=\"\"",
    "-DTB_SUPPORT",
    "-DZVE32F_ON",
    "-DVLEN_128",
    "-Ihdl/verilog",
    "-LDFLAGS \"-rdynamic\"",
]

VCS_BUILD_ARGS = [
    "-timescale=1ns/1ps",
    "-kdb",
    "+vcs+fsdbon",
    "-debug_access+all",
    "-cm",
    "line+cond+tgl+branch+assert",
    "-cm_hier",
    "../tests/cocotb/coverage_exclude.cfg",
    # Required for zero-delay gate-level simulation. Without these, timing violations produce 'X'
    # which causes cocotb to crash with "ValueError: Cannot convert Logic('X') to bool".
    "+notimingcheck",
    "+nospecify",
    "-hsopt=ignoreasiccap",  # Added to speed up simulation.
    "-LDFLAGS",
    "-rdynamic",
    "-CFLAGS",
    "-I../hdl/verilog",
    "../hdl/verilog/sram_backdoor.cc",
    # TODO(davidgao): enable this when ready
    # "-xprop=../tests/cocotb/xprop.cfg",
]

VCS_TEST_ARGS = [
    "+vcs+fsdbon",
    "+fsdb+mda",
    "+fsdb+struct",
    "-cm",
    "line+cond+tgl+branch+assert",
]

VCS_DEFINES = {
    "USE_GENERIC": "",
    "TB_SUPPORT": "",
    "ZVE32F_ON": "",
    "VLEN_128": "",
    # Skips default value checks for RTSEL and WTSEL pins in TSMC simulation models
    "TSMC_NO_TESTPINS_DEFAULT_VALUE_CHECK": "",
}

VCS_NETLIST_BUILD_ARGS = [
    arg
    for arg in VCS_BUILD_ARGS
    if arg not in ["-I../hdl/verilog", "../hdl/verilog/sram_backdoor.cc"]
]

VCS_NETLIST_DEFINES = {
    k: v
    for k, v in VCS_DEFINES.items()
    if k != "USE_GENERIC"
}

def rvv_core_mini_axi_netlist_test_suite(
        name,
        vcs_verilog_sources,
        vcs_build_args_extra = [],
        vcs_data_extra = [],
        vcs_netlist_defines = VCS_NETLIST_DEFINES,  # Allow overriding netlist defines for technology-specific needs
        **kwargs):
    """A generic template for creating netlist tests for RvvCoreMiniAxi."""
    cocotb_test_suite(
        name = name,
        simulators = ["vcs_netlist"],
        testcases = [
            "core_mini_axi_basic_write_read_memory",
            "core_mini_axi_run_wfi_in_all_slots",
            "core_mini_axi_slow_bready",
            "core_mini_axi_write_read_memory_stress_test",
            "core_mini_axi_master_write_alignment",
            "core_mini_axi_finish_txn_before_halt_test",
            "core_mini_axi_riscv_tests",
            "core_mini_axi_riscv_dv",
            "core_mini_axi_csr_test",
            "core_mini_axi_exceptions_test",
            "core_mini_axi_coralnpu_isa_test",
            "core_mini_axi_rand_instr_test",
            "core_mini_axi_burst_types_test",
            "core_mini_axi_float_csr_test",
            "unreachable_prefetch_fault",
            "core_mini_axi_frm_test",
        ],
        tests_kwargs = {
            "hdl_toplevel": "RvvCoreMiniAxi",
            "waves": False,
            "seed": "42",
            "tags": ["vcs", "manual"],
            "test_module": ["//tests/cocotb:core_mini_axi_sim.py"],
            "deps": [
                "//coralnpu_test_utils:core_mini_axi_sim_interface",
                "//coralnpu_test_utils:sim_test_fixture",
                requirement("tqdm"),
                "@bazel_tools//tools/python/runfiles",
            ],
            "data": ["//tests/cocotb:cocotb_test_binary_targets"],
            "size": "enormous",
        },
        vcs_netlist_build_args = VCS_NETLIST_BUILD_ARGS + vcs_build_args_extra,
        vcs_netlist_data = [
            "//tests/cocotb:cocotb_test_binary_targets",
            "//tests/cocotb:coverage_exclude.cfg",
            "//tests/cocotb:xprop.cfg",
        ] + vcs_data_extra,
        vcs_netlist_defines = vcs_netlist_defines,
        vcs_netlist_test_args = VCS_TEST_ARGS,
        vcs_netlist_verilog_sources = vcs_verilog_sources,
        **kwargs
    )
