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

load("//rules:coco_tb.bzl", "cocotb_test_suite", "verilator_cocotb_model")
load("//rules:coralnpu_v2.bzl", "collect_coralnpu_elfs", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
    "VERILATOR_BUILD_ARGS",
)

package(default_visibility = ["//visibility:public"])

template_rule(
    coralnpu_v2_binary,
    {
        "rvv_memcpy_test": {
            "srcs": ["memcpy_test.cc"],
            "hdrs": ["//sw/opt:rvv_opt.h"],
        },
        "rvv_memset_test": {
            "srcs": ["memset_test.cc"],
            "hdrs": ["//sw/opt:rvv_opt.h"],
        },
    },
)

filegroup(
    name = "rvv_opt_tests",
    srcs = [
        ":rvv_memcpy_test.elf",
        ":rvv_memset_test.elf",
    ],
)

RUN_RVV_OPT_TESTS = [
    "rvv_memcpy_test",
    "rvv_memset_test",
]

cocotb_test_suite(
    name = "cocotb_rvv_opt_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = RUN_RVV_OPT_TESTS,
    testcases_vname = "RUN_RVV_OPT_TESTS",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniAxi",
        "seed": "42",
        "test_module": ["cocotb_rvv_opt_test.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": [
            ":rvv_memcpy_test",
            ":rvv_memset_test",
        ],
        "size": "medium",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":rvv_memcpy_test.elf",
        ":rvv_memset_test.elf",
    ] + [
        "//hdl/verilog:dpi_files",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_axi_model",
)

collect_coralnpu_elfs()
