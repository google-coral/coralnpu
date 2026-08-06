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

load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")

py_library(
    name = "TileLinkULInterface",
    srcs = ["TileLinkULInterface.py"],
    visibility = ["//visibility:public"],
    deps = [
        requirement("cocotb"),
        "//coralnpu_test_utils:secded_golden",
    ],
)

py_library(
    name = "TlulVerificationEnv",
    srcs = ["TlulVerificationEnv.py"],
    visibility = ["//visibility:public"],
    deps = [
        requirement("cocotb"),
        ":TileLinkULInterface",
    ],
)

py_library(
    name = "rvv_type_util",
    srcs = ["rvv_type_util.py"],
    visibility = ["//visibility:public"],
    deps = [
        requirement("numpy"),
    ],
)

py_library(
    name = "spi_master",
    srcs = ["spi_master.py"],
    visibility = ["//visibility:public"],
    deps = [
        requirement("cocotb"),
        ":spi_constants",
    ],
)

py_library(
    name = "spi_constants",
    srcs = ["spi_constants.py"],
    visibility = ["//visibility:public"],
)

py_library(
    name = "secded_golden",
    srcs = ["secded_golden.py"],
    visibility = ["//visibility:public"],
)

py_library(
    name = "elf_util",
    srcs = ["elf_util.py"],
    visibility = ["//visibility:public"],
    deps = [
        requirement("pyelftools"),
    ],
)

py_library(
    name = "backdoor",
    srcs = ["backdoor.py"],
    visibility = ["//visibility:public"],
)

py_library(
    name = "core_mini_axi_sim_interface",
    srcs = [
        "core_mini_axi_interface.py",
    ],
    visibility = ["//visibility:public"],
    deps = [
        requirement("cocotb"),
        requirement("numpy"),
        requirement("pyelftools"),
        ":backdoor",
    ],
)

py_library(
    name = "sim_test_fixture",
    srcs = [
        "sim_test_fixture.py",
    ],
    visibility = ["//visibility:public"],
    deps = [
        requirement("cocotb"),
        requirement("numpy"),
        ":core_mini_axi_sim_interface",
    ],
)

py_library(
    name = "core_mini_axi_pyocd_gdbserver",
    srcs = [
        "core_mini_axi_pyocd_gdbserver.py",
    ],
    data = [
        "//toolchain:gdb",
    ],
    visibility = ["//visibility:public"],
    deps = [
        requirement("cocotb"),
        requirement("pyocd"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_library(
    name = "ftdi_spi_master_lib",
    srcs = ["ftdi_spi_master.py"],
    data = [
        "//sw/utils/nexus_loader",
    ],
    visibility = ["//visibility:public"],
    deps = [
        "@bazel_tools//tools/python/runfiles",
        requirement("pyelftools"),
        ":spi_constants",
    ],
)

py_binary(
    name = "ftdi_spi_master",
    srcs = ["ftdi_spi_master.py"],
    deps = [
        ":ftdi_spi_master_lib",
    ],
)

py_library(
    name = "fpga_test_fixture",
    srcs = ["fpga_test_fixture.py"],
    visibility = ["//visibility:public"],
    deps = [
        ":ftdi_spi_master_lib",
        requirement("numpy"),
        requirement("pyelftools"),
    ],
)

py_test(
    name = "fpga_test_fixture_test",
    srcs = ["fpga_test_fixture_test.py"],
    deps = [
        ":fpga_test_fixture",
        requirement("numpy"),
    ],
)

py_binary(
    name = "run_matmul_test",
    srcs = ["run_matmul_test.py"],
    data = [
        "//tests/cocotb/rvv/ml_ops:rvv_matmul",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_highmem",
    ],
    deps = [
        ":fpga_test_fixture",
        "//sw/utils:metrics",
        requirement("numpy"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_binary(
    name = "run_float_matmul_fpga",
    srcs = ["run_float_matmul_fpga.py"],
    data = [
        "//tests/cocotb/rvv/ml_ops:rvv_float_matmul_optimized",
    ],
    deps = [
        ":fpga_test_fixture",
        "//sw/utils:metrics",
        requirement("numpy"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_binary(
    name = "run_tflite_profile",
    srcs = ["run_tflite_profile.py"],
    data = [
        "//sw/utils/tflite_runner:tflite_runner.elf",
    ],
    deps = [
        ":elf_util",
        ":ftdi_spi_master_lib",
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_binary(
    name = "run_sram_test",
    srcs = ["run_sram_test.py"],
    visibility = ["//visibility:public"],
    deps = [
        ":ftdi_spi_master_lib",
        requirement("numpy"),
        "//utils/coralnpu_soc_loader:spi_driver",
    ],
)

py_binary(
    name = "run_ddr_test",
    srcs = ["run_ddr_test.py"],
    visibility = ["//visibility:public"],
    deps = [
        ":fpga_test_fixture",
        requirement("numpy"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_library(
    name = "axi_slave",
    srcs = ["axi_slave.py"],
    visibility = ["//visibility:public"],
    deps = [
        requirement("cocotb"),
    ],
)

py_binary(
    name = "rvv_cpp_util_header_generator",
    srcs = [
        "rvv_cpp_util_header_generator.py",
    ],
)

py_binary(
    name = "run_binary",
    srcs = ["run_binary.py"],
    visibility = ["//visibility:public"],
    deps = [
        ":fpga_test_fixture",
    ],
)

genrule(
    name = "rvv_cpp_util_header",
    srcs = [],
    outs = ["rvv_cpp_util.h"],
    cmd = "./$(location rvv_cpp_util_header_generator) > \"$@\"",
    tools = [":rvv_cpp_util_header_generator"],
)

cc_library(
    name = "rvv_cpp_util",
    hdrs = [":rvv_cpp_util.h"],
    visibility = ["//visibility:public"],
)
