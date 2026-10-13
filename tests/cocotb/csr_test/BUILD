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

CSR_TEST_TESTCASES = [
    "csr_read_write_test",
]

coralflow_test(
    name = "csr_test",
    size = "medium",
    srcs = ["csr_test_bench.py"],
    elf = ":csr_test_program.elf",
    hdl_toplevel = "CoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
        "uvm",
    ],
    testcases = CSR_TEST_TESTCASES,
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "csr_test_program",
    srcs = ["csr_test_program.cc"],
    visibility = ["//visibility:public"],
)
