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

"""Test targets for CoralFlow framework."""

load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("//rules:coralflow_test.bzl", "coralflow_test")

package(default_visibility = ["//visibility:public"])

coralflow_test(
    name = "test_rvv_add",
    srcs = ["test_rvv_add.py"],
    elf = "//tests/cocotb/rvv/arithmetics:rvv_add_int8_m1.elf",
)

coralflow_test(
    name = "test_matmul",
    srcs = ["test_matmul.py"],
    elf = "//tests/cocotb/rvv/ml_ops:rvv_matmul.elf",
    highmem_elf = "//tests/cocotb/rvv/ml_ops:rvv_matmul_highmem.elf",
)

coralflow_test(
    name = "test_rvv_ml_ops",
    srcs = ["test_rvv_ml_ops.py"],
    elf = "//tests/cocotb/rvv/ml_ops:rvv_mlop_tests",
    deps = [
        requirement("ml_dtypes"),
    ],
)

py_test(
    name = "runner_test",
    srcs = ["runner_test.py"],
    deps = [
        "//coralnpu_test_utils/coralflow",
    ],
)
