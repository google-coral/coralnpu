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

load("//rules:coralflow_test.bzl", "coralflow_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")

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

coralflow_test(
    name = "cocotb_rvv_opt_test",
    size = "medium",
    srcs = ["cocotb_rvv_opt_test.py"],
    data = [
        ":rvv_memcpy_test.elf",
        ":rvv_memset_test.elf",
    ],
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RUN_RVV_OPT_TESTS,
)
