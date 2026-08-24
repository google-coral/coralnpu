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

load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

VME_TEST_TESTCASES = [
    "vme_mset_csr_test",
    "vme_matmul_int8_test",
    "vme_matmul_fp32_test",
    "vme_decode_test",
    "vme_load_store_test",
    "vme_transpose_test",
]

cocotb_test_suite(
    name = "vme_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = VME_TEST_TESTCASES,
    testcases_vname = "VME_TEST_TESTCASES",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "VmeCoreMiniAxi",
        "seed": "42",
        "test_module": ["vme_test_bench.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            requirement("tqdm"),
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":vme_matmul_test_program",
            ":vme_test_program",
            ":vme_decode_test",
            ":vme_load_store_test",
            ":vme_transpose_test",
        ],
        "size": "medium",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":vme_matmul_test_program",
        ":vme_test_program",
        ":vme_decode_test",
        ":vme_load_store_test",
        ":vme_transpose_test",
        "//tests/cocotb:coverage_exclude.cfg",
        "//hdl/verilog:dpi_files",
    ],
    vcs_defines = dict(
        VCS_DEFINES,
        ZVT_ON = "",
    ),
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = [
        "//hdl/chisel/src/coralnpu:vme_core_mini_axi_cc_library_verilog",
    ],
    verilator_model = "//tests/cocotb:vme_core_mini_axi_model",
)

coralnpu_v2_binary(
    name = "vme_test_program",
    srcs = ["vme_test_program.cc"],
    hdrs = ["vme_test_utils.h"],
)

coralnpu_v2_binary(
    name = "vme_matmul_test_program",
    srcs = ["vme_matmul_test_program.cc"],
    hdrs = ["vme_test_utils.h"],
)

coralnpu_v2_binary(
    name = "vme_decode_test",
    srcs = ["vme_decode_test.cc"],
)

coralnpu_v2_binary(
    name = "vme_load_store_test",
    srcs = ["vme_load_store_test.cc"],
)

coralnpu_v2_binary(
    name = "vme_transpose_test",
    srcs = ["vme_transpose_test.cc"],
)
