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
load("@pybind11_bazel//:build_defs.bzl", "pybind_extension")
load("//rules:mpact.bzl", "mpact_binary")

package(default_visibility = ["//visibility:public"])

pybind_extension(
    name = "coralnpu_v2_sim_pybind",
    srcs = ["//sw/coralnpu_sim:coralnpu_v2_sim_pybind.cc"],
    target_compatible_with = ["//toolchain/host_clang:clang_compiler"],
    deps = [
        "@com_google_absl//absl/log",
        "@com_google_absl//absl/status",
        "@com_google_absl//absl/status:statusor",
        "@coralnpu_mpact//sim:coralnpu_simulator",
        "@pybind11_abseil//pybind11_abseil:status_casters",
    ],
)

mpact_binary(
    name = "coralnpu_v2_sim",
    dep = ":coralnpu_v2_sim_pybind.so",
)

py_library(
    name = "coralnpu_v2_sim_lib",
    data = [":coralnpu_v2_sim"],
    imports = ["."],
)

py_library(
    name = "coralnpu_v2_sim_utils_lib",
    srcs = ["coralnpu_v2_sim_utils.py"],
    deps = [
        ":coralnpu_v2_sim_lib",
        requirement("numpy"),
        requirement("pyelftools"),
    ],
)

py_test(
    name = "coralnpu_v2_sim_test",
    srcs = ["coralnpu_v2_sim_test.py"],
    data = [
        "//tests/cocotb/rvv:vrgather_test",
        "//tests/cocotb/rvv/arithmetics:rvv_add_int8_m1",
        "//tests/verilator_sim:htif_semihosting_test",
    ],
    deps = [
        ":coralnpu_v2_sim_utils_lib",
        "@bazel_tools//tools/python/runfiles",
        requirement("numpy"),
    ],
)
