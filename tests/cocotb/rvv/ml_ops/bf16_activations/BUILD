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
load("//third_party/python:requirements.bzl", "requirement")

package(default_visibility = ["//visibility:public"])

coralnpu_v2_binary(
    name = "rvv_math_test",
    srcs = ["rvv_math_runner.cc"],
    hdrs = [
        "rvv_math.h",
        "//sw/utils:utils.h",
    ],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = ["//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec"],
)

coralnpu_v2_binary(
    name = "sigmoid_bf16_test",
    srcs = [
        "sigmoid_bf16_kernel.cc",
        "sigmoid_bf16_runner.cc",
    ],
    hdrs = [
        "rvv_math.h",
        "//sw/utils:utils.h",
    ],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = ["//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec"],
)

coralnpu_v2_binary(
    name = "softmax_bf16_test",
    srcs = [
        "softmax_bf16_kernel.cc",
        "softmax_bf16_runner.cc",
    ],
    hdrs = [
        "rvv_math.h",
        "//sw/utils:utils.h",
    ],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = ["//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec"],
)

RVV_MATH_TESTCASES = ["rvv_math_test"]

coralflow_test(
    name = "rvv_math_cocotb_test",
    size = "enormous",
    srcs = ["rvv_math_cocotb_test.py"],
    elf = ":rvv_math_test.elf",
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RVV_MATH_TESTCASES,
    deps = [
        requirement("ml_dtypes"),
    ],
)

SIGMOID_BF16_TESTCASES = [
    "sigmoid_bf16_corr_test",
    "sigmoid_bf16_perf_test",
]

coralflow_test(
    name = "sigmoid_bf16_cocotb_test",
    size = "enormous",
    srcs = ["sigmoid_bf16_cocotb_test.py"],
    elf = ":sigmoid_bf16_test.elf",
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = SIGMOID_BF16_TESTCASES,
    deps = [
        requirement("ml_dtypes"),
    ],
)

SOFTMAX_BF16_TESTCASES = [
    "softmax_bf16_corr_test",
    "softmax_bf16_perf_test",
]

coralflow_test(
    name = "softmax_bf16_cocotb_test",
    size = "enormous",
    srcs = ["softmax_bf16_cocotb_test.py"],
    elf = ":softmax_bf16_test.elf",
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = SOFTMAX_BF16_TESTCASES,
    deps = [
        requirement("ml_dtypes"),
    ],
)
