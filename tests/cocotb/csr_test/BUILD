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

CSR_TEST_TESTCASES = [
    "csr_read_write_test",
]

cocotb_test_suite(
    name = "csr_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = CSR_TEST_TESTCASES,
    testcases_vname = "CSR_TEST_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "CoreMiniAxi",
        "seed": "42",
        "test_module": ["csr_test_bench.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":csr_test_program",
        ],
        "size": "medium",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":csr_test_program",
        "//tests/cocotb:coverage_exclude.cfg",
        "//hdl/verilog:dpi_files",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = [
        "//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog",
    ],
    verilator_model = "//tests/cocotb:core_mini_axi_model",
)

coralnpu_v2_binary(
    name = "csr_test_program",
    srcs = ["csr_test_program.cc"],
    visibility = ["//visibility:public"],
)

collect_coralnpu_elfs()
