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

load("//rules:coralflow_test.bzl", "coralflow_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")

package(default_visibility = ["//visibility:public"])

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
coralflow_test(
    name = "float_matmul_16x48x16_test_suite",
    size = "enormous",
    srcs = ["static_reference_tests.py"],
    elf = ":float_matmul_16x48x16.elf",
    targets = [
        "verilator",
        "vcs",
        "uvm",
        "nexus_fpga",
    ],
    testcases = [
        "float_matmul_16x48x16_test",
    ],
    deps = [
        "//sw/utils:metrics",
    ],
)

# Integer static netlist test suite
coralflow_test(
    name = "int_matmul_16x48x16_test_suite",
    size = "enormous",
    srcs = ["static_reference_tests.py"],
    elf = ":int_matmul_16x48x16.elf",
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "uvm",
        "nexus_fpga",
    ],
    testcases = [
        "int_matmul_16x48x16_test",
    ],
    deps = [
        "//sw/utils:metrics",
    ],
)
