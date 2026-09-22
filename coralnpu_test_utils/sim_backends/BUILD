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
load("//rules:coco_tb.bzl", "verilator_cocotb_test")

package(default_visibility = ["//visibility:public"])

py_library(
    name = "common_utils",
    srcs = [
        "common_utils.py",
    ],
    deps = [
        requirement("numpy"),
        requirement("pyelftools"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_library(
    name = "verilator_test_fixture",
    srcs = ["verilator_test_fixture.py"],
    deps = [
        ":common_utils",
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        requirement("cocotb"),
        requirement("numpy"),
    ],
)

py_library(
    name = "mpact_npusim_test_fixture",
    srcs = ["mpact_npusim_test_fixture.py"],
    deps = [
        ":common_utils",
        "//sw/coralnpu_sim:coralnpu_v2_sim_utils_lib",
        requirement("numpy"),
    ],
)

py_library(
    name = "uvm_test_fixture",
    srcs = ["uvm_test_fixture.py"],
    deps = [
        ":common_utils",
        requirement("numpy"),
    ],
)

py_library(
    name = "fpga_test_fixture",
    srcs = ["fpga_test_fixture.py"],
    deps = [
        ":common_utils",
        "//coralnpu_test_utils:ftdi_spi_master_lib",
        requirement("numpy"),
    ],
)

py_test(
    name = "sim_backends_unit_test",
    size = "small",
    srcs = ["sim_backends_unit_test.py"],
    data = [
        "//tests/cocotb/rvv/arithmetics:rvv_add_int8_m1",
    ],
    deps = [
        ":common_utils",
        ":fpga_test_fixture",
        ":mpact_npusim_test_fixture",
        ":uvm_test_fixture",
        ":verilator_test_fixture",
        requirement("numpy"),
    ],
)

verilator_cocotb_test(
    name = "sim_backends_integration_test",
    size = "medium",
    data = [
        "//tests/cocotb/rvv/arithmetics:rvv_add_int32_m1",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul",
        "//tests/uvm:uvm_sim_verilator",
    ],
    hdl_toplevel = "RvvCoreMiniAxi",
    model = "//tests/cocotb:rvv_core_mini_axi_model",
    seed = "42",
    test_module = ["sim_backends_integration_test.py"],
    waves = False,
    deps = [
        ":common_utils",
        ":fpga_test_fixture",
        ":mpact_npusim_test_fixture",
        ":uvm_test_fixture",
        ":verilator_test_fixture",
    ],
)

alias(
    name = "fpga_test_fixture_test",
    actual = ":sim_backends_unit_test",
)

alias(
    name = "uvm_test_fixture_test",
    actual = ":sim_backends_unit_test",
)
