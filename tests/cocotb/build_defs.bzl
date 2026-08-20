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

load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("//rules:coco_tb.bzl", "cocotb_test_suite")

VERILATOR_BUILD_ARGS = [
    "-Wno-WIDTH",
    "-Wno-CASEINCOMPLETE",
    "-Wno-LATCH",
    "-Wno-SIDEEFFECT",
    "-Wno-MULTIDRIVEN",
    "-Wno-SPLITVAR",
    "-Wno-UNOPTFLAT",
    "-Wno-BLKANDNBLK",
    "-Wno-CASEX",
    # Warnings that we disable for fpnew
    "-Wno-ASCRANGE",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNSIGNED",
    "-Wno-PINMISSING",
    "-DUSE_GENERIC=\"\"",
    "-DTB_SUPPORT",
    "-DZVE32F_ON",
    "-DVLEN_128",
    "-Ihdl/verilog",
    "-LDFLAGS \"-rdynamic\"",
]

# Note: SRAM backdoor compilation arguments (-CFLAGS, -I../hdl/verilog, and sram_backdoor.cc)
# are dynamically injected in cocotb_test_suite (rules/coco_tb.bzl) for targets
# whose hdl_toplevel is listed in rules/sram_backdoor.bzl.
# Note: To enable FSDB wave dumping in VCS RTL simulations, add "+vcs+fsdbon" to VCS_BUILD_ARGS and VCS_TEST_ARGS.
VCS_BUILD_ARGS = [
    "-timescale=1ns/1ps",
    "-kdb",
    # Required for zero-delay gate-level simulation. Without these, timing violations produce 'X'
    # which causes cocotb to crash with "ValueError: Cannot convert Logic('X') to bool".
    "+notimingcheck",
    "+nospecify",
    "-hsopt=ignoreasiccap",  # Added to speed up simulation.
    "-LDFLAGS",
    "-rdynamic",
    "+vcs+lic+wait",
    "-O3",
    "-Xkeyopt=rtopt",
    "+vpi+1",
    # TODO(davidgao): enable this when ready
    # "-xprop=../tests/cocotb/xprop.cfg",
]

VCS_TEST_ARGS = [
    "+vcs+lic+wait",
]

VCS_DEFINES = {
    "USE_GENERIC": "",
    "TB_SUPPORT": "",
    "ZVE32F_ON": "",
    "VLEN_128": "",
    # Skips default value checks for RTSEL and WTSEL pins in TSMC simulation models
    "TSMC_NO_TESTPINS_DEFAULT_VALUE_CHECK": "",
}

VCS_NETLIST_BUILD_ARGS = list(VCS_BUILD_ARGS) + [
    "+vcs+fsdbon",
]

VCS_NETLIST_TEST_ARGS = list(VCS_TEST_ARGS) + [
    "+vcs+fsdbon",
    "+fsdb+mda",
    "+fsdb+struct",
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
        vcs_netlist_test_args = VCS_NETLIST_TEST_ARGS,
        **kwargs):
    """A generic template for creating netlist tests for RvvCoreMiniAxi."""
    cocotb_test_suite(
        name = name,
        simulators = ["vcs_netlist"],
        name_fsdb_after_test = True,
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
            "test_module": ["@coralnpu_hw//tests/cocotb:core_mini_axi_sim.py"],
            "deps": [
                "@coralnpu_hw//coralnpu_test_utils:core_mini_axi_sim_interface",
                "@coralnpu_hw//coralnpu_test_utils:sim_test_fixture",
                requirement("tqdm"),
                "@bazel_tools//tools/python/runfiles",
            ],
            "data": ["@coralnpu_hw//tests/cocotb:cocotb_test_binary_targets"],
            "size": "enormous",
        },
        vcs_netlist_build_args = VCS_NETLIST_BUILD_ARGS + vcs_build_args_extra,
        vcs_netlist_data = [
            "@coralnpu_hw//tests/cocotb:cocotb_test_binary_targets",
            "@coralnpu_hw//tests/cocotb:xprop.cfg",
        ] + vcs_data_extra,
        vcs_netlist_defines = vcs_netlist_defines,
        vcs_netlist_split_build_test = True,
        vcs_netlist_test_args = vcs_netlist_test_args,
        vcs_netlist_verilog_sources = vcs_verilog_sources,
        **kwargs
    )

def rvv_core_mini_axi_netlist_static_test_suite(name, static_netlist, **kwargs):
    """Wrapper macro to run netlist tests using a static netlist file."""
    rvv_core_mini_axi_netlist_test_suite(
        name = name,
        vcs_verilog_sources = [static_netlist],
        **kwargs
    )
