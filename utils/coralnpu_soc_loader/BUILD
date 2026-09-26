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
load("@rules_python//python:defs.bzl", "py_binary", "py_library")

package(default_visibility = ["//visibility:public"])

# Library for interacting with the SPI DPI master via ctypes.
py_library(
    name = "spi_driver",
    srcs = ["spi_driver.py"],
)

# Binary to load a program onto the CoralNPU SoC and start execution.
py_binary(
    name = "loader",
    srcs = ["loader.py"],
    imports = ["."],
    deps = [
        ":spi_driver",
        "//coralnpu_test_utils:spi_constants",
        requirement("pyelftools"),
    ],
)

# Binary to run the full SoC simulation and monitor its execution.
py_binary(
    name = "run_simulation",
    srcs = ["run_simulation.py"],
    data = [
        ":loader",
        "//coralnpu_test_utils:run_sram_test",
        "//fpga:copy_chip_verilator_binary",
    ],
    tags = ["manual"],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

# Test runner for automated SoC simulation tests.
py_binary(
    name = "sim_test_runner",
    srcs = ["sim_test_runner.py"],
    data = [
        ":loader",
        "//coralnpu_test_utils:run_sram_test",
        "//fpga:copy_chip_verilator_binary",
        "//fpga/ip/ispyocto:grey_bars_320x240.raw",
    ],
    main = "sim_test_runner.py",
    tags = ["manual"],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_binary(
    name = "sim_test_runner_highmem",
    srcs = ["sim_test_runner.py"],
    data = [
        ":loader",
        "//coralnpu_test_utils:run_sram_test",
        "//fpga:copy_chip_verilator_highmem_binary",
        "//fpga/ip/ispyocto:grey_bars_320x240.raw",
    ],
    main = "sim_test_runner.py",
    tags = ["manual"],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_binary(
    name = "run_isp_cam_sim",
    srcs = ["run_simulation.py"],
    args = [
        "--elf_file",
        "$(location //fpga:isp_cam_test.elf)",
        "--run_time",
        "100",
    ],
    data = [
        ":loader",
        "//fpga:copy_chip_verilator_binary",
        "//fpga:isp_cam_test.elf",
        "//fpga/ip/ispyocto:grey_bars_320x240.raw",
    ],
    main = "run_simulation.py",
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)
