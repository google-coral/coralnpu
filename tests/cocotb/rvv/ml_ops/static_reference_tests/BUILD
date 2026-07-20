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

load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "collect_coralnpu_elfs", "coralnpu_v2_binary")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

package(default_visibility = ["//visibility:public"])

VCS_COMMON_DATA = [
    "//tests/cocotb:coverage_exclude.cfg",
    "//tests/cocotb:xprop.cfg",
    "//hdl/verilog:dpi_files",
]

# Float matmul 16x48x16 static binary
coralnpu_v2_binary(
    name = "float_matmul_16x48x16",
    srcs = [
        "float_matmul_16x48x16_kernel.cc",
        "float_matmul_16x48x16_runner.cc",
    ],
    deps = [
        "//sw/utils",
    ],
)

# Integer matmul 16x48x16 static binary
coralnpu_v2_binary(
    name = "int_matmul_16x48x16",
    srcs = [
        "int_matmul_16x48x16_kernel.cc",
        "int_matmul_16x48x16_runner.cc",
    ],
    deps = [
        "//sw/utils",
    ],
)

exports_files([
    "static_reference_tests.py",
])

# Float static netlist test suite
cocotb_test_suite(
    name = "float_matmul_16x48x16_test_suite",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "float_matmul_16x48x16_test",
    ],
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": [
            "static_reference_tests.py",
        ],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":float_matmul_16x48x16.elf",
        ],
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":float_matmul_16x48x16.elf",
    ] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_axi_model",
)

# Integer static netlist test suite
cocotb_test_suite(
    name = "int_matmul_16x48x16_test_suite",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "int_matmul_16x48x16_test",
    ],
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": [
            "static_reference_tests.py",
        ],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":int_matmul_16x48x16.elf",
        ],
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":int_matmul_16x48x16.elf",
    ] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_axi_model",
)

collect_coralnpu_elfs()
