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

alias(
    name = "test_uvm_fixture_unit",
    actual = "//coralnpu_test_utils/sim_backends:uvm_test_fixture_test",
)

py_test(
    name = "uvm_fixture_integration_test",
    size = "large",
    srcs = ["uvm_fixture_integration_test.py"],
    data = [
        "//tests/cocotb/rvv/arithmetics:rvv_add_int32_m1",
        "//tests/cocotb/rvv/arithmetics:rvv_fadd_float_rne_m1",
        "//tests/cocotb/rvv/arithmetics:rvv_max_int32_m1",
        "//tests/cocotb/rvv/arithmetics:rvv_mul_int32_m1",
        "//tests/cocotb/rvv/arithmetics:rvv_sub_int32_m1",
        "//tests/cocotb/rvv/arithmetics:rvv_xor_int32_m1",
        "//tests/cocotb/rvv/ml_ops:rvv_float_matmul",
        "//tests/cocotb/rvv/ml_ops:rvv_float_matmul_optimized",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly",
        "//tests/uvm:uvm_sim_verilator",
    ],
    tags = [
        "requires-kvm",
        "rtl",
        "uvm",
    ],
    deps = [
        "//coralnpu_test_utils/sim_backends:uvm_test_fixture",
        requirement("numpy"),
        "@bazel_tools//tools/python/runfiles",
    ],
)
