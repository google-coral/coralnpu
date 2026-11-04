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
load("//rules:coco_tb.bzl", "cocotb_test_suite", "verilator_cocotb_model")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")
load(
    "//tests/cocotb:build_defs.bzl",
    "VERILATOR_BUILD_ARGS",
)

package(default_visibility = ["//visibility:public"])

template_rule(
    verilator_cocotb_model,
    {
        "vme_core_mini_verification_axi_model": {
            "cflags": VERILATOR_BUILD_ARGS + [
                "-DZVT_ON",
                "-DZVTBF16FMM_ON",
            ],
            "hdl_toplevel": "VmeCoreMiniVerificationAxi",
            "verilog_source": "//hdl/chisel/src/coralnpu:VmeCoreMiniVerificationAxi.sv",
        },
    },
    trace = False,
    vlt_tpl = "rvvi.vlt.tpl",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

py_library(
    name = "tb",
    srcs = glob(["tb/*.py"]),
    imports = ["."],
    deps = [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        "//coralnpu_test_utils:dispatch_verifier",
        requirement("numpy"),
    ],
)

py_test(
    name = "tb_unit_test",
    srcs = ["tb_unit_test.py"],
    deps = [
        ":tb",
        "//coralnpu_test_utils:dispatch_verifier",
        requirement("numpy"),
    ],
)

coralnpu_v2_binary(
    name = "vwmul",
    srcs = ["programs/vwmul.cc"],
)

# BEGIN_TESTCASES_FOR_smoke_test
SMOKE_TESTCASES = [
    "smoke_vwmul",
]
# END_TESTCASES_FOR_smoke_test

cocotb_test_suite(
    name = "smoke_test",
    simulators = ["verilator"],
    testcases = SMOKE_TESTCASES,
    testcases_vname = "SMOKE_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "VmeCoreMiniVerificationAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["smoke_test.py"],
        "deps": [
            ":tb",
            "//coralnpu_test_utils/sim_backends:verilator_test_fixture",
            "//coralnpu_test_utils:dispatch_verifier",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [":vwmul.elf"],
        "size": "medium",
    },
    verilator_model = ":vme_core_mini_verification_axi_model",
)

# BEGIN_TESTCASES_FOR_axi_agent_test
AXI_AGENT_TESTCASES = [
    "axi_write_read_back",
]
# END_TESTCASES_FOR_axi_agent_test

cocotb_test_suite(
    name = "axi_agent_test",
    simulators = ["verilator"],
    testcases = AXI_AGENT_TESTCASES,
    testcases_vname = "AXI_AGENT_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "VmeCoreMiniVerificationAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["axi_agent_test.py"],
        "deps": [
            ":tb",
            "//coralnpu_test_utils/sim_backends:verilator_test_fixture",
            "//coralnpu_test_utils:dispatch_verifier",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [":vwmul.elf"],
        "size": "medium",
    },
    verilator_model = ":vme_core_mini_verification_axi_model",
)

# BEGIN_TESTCASES_FOR_cosim_test
COSIM_TESTCASES = [
    "rvvi_trace",
    "vwmul_cosim",
]
# END_TESTCASES_FOR_cosim_test

cocotb_test_suite(
    name = "cosim_test",
    simulators = ["verilator"],
    testcases = COSIM_TESTCASES,
    testcases_vname = "COSIM_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "VmeCoreMiniVerificationAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["cosim_test.py"],
        "deps": [
            ":tb",
            "//coralnpu_test_utils/sim_backends:verilator_test_fixture",
            "//sw/coralnpu_sim:coralnpu_v2_sim_utils_lib",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [":vwmul.elf"],
        "size": "medium",
    },
    verilator_model = ":vme_core_mini_verification_axi_model",
)
