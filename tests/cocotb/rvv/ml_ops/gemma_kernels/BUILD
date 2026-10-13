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
load("//rules:utils.bzl", "template_rule")
load("//third_party/python:requirements.bzl", "requirement")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "rvv_common_vec",
    hdrs = ["rvv_common_vec.h"],
    target_compatible_with = ["//platforms/cpu:coralnpu_v2"],
)

# Compile binary for NPU simulation
template_rule(
    coralnpu_v2_binary,
    {
        "rvv_rms_norm": {
            "srcs": [
                "rms_norm_runner.cc",
                "rvv_rms_norm.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
        },
        "rvv_bf16_rms_norm": {
            "srcs": [
                "rvv_bf16_rms_norm_runner.cc",
                "rvv_rms_norm.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
        },
        "rvv_flashattention_test": {
            "srcs": [
                "rvv_flashattention_runner.cc",
                "rvv_flashattention_kernel.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_matmul": {
            "srcs": [
                "rvv_matmul_runner.cc",
                "rvv_matmul.cc",
            ],
            "deps": ["//sw/utils:utils"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_matmul": {
            "srcs": [
                "rvv_bf16_matmul_runner.cc",
                "rvv_bf16_matmul.cc",
            ],
            "deps": ["//sw/utils:utils"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_int8_matmul": {
            "srcs": [
                "rvv_int8_matmul_runner.cc",
                "rvv_int8_matmul.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_residual_add": {
            "srcs": [
                "rvv_residual_add_runner.cc",
                "rvv_residual_add.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_residual_add": {
            "srcs": [
                "rvv_bf16_residual_add_runner.cc",
                "rvv_residual_add.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_tanh_gelu_mul": {
            "srcs": [
                "rvv_tanh_gelu_mul_runner.cc",
                "rvv_tanh_gelu_mul.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_tanh_gelu_mul": {
            "srcs": [
                "rvv_bf16_tanh_gelu_mul_runner.cc",
                "rvv_tanh_gelu_mul.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_flashattention": {
            "srcs": [
                "rvv_bf16_flashattention_runner.cc",
                "rvv_flashattention_kernel.cc",
            ],
            "deps": [
                ":rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
    },
)

# Test cases
RVV_RMS_NORM_TESTCASES = [
    "core_mini_rvv_rms_norm_test",
    "core_mini_rvv_bf16_rms_norm_test",
]

RVV_RESIDUAL_ADD_TESTCASES = [
    "core_mini_rvv_residual_add_test",
    "core_mini_rvv_bf16_residual_add_test",
]

RVV_TANH_GELU_MUL_TESTCASES = [
    "core_mini_rvv_tanh_gelu_mul_test",
    "core_mini_rvv_bf16_tanh_gelu_mul_test",
]

RVV_MATMUL_TESTCASES = [
    "core_mini_rvv_matmul_lhs_1d_test",
    "core_mini_rvv_matmul_2d_test",
    "core_mini_rvv_bf16_matmul_lhs_1d_test",
    "core_mini_rvv_bf16_matmul_2d_test",
]

RVV_FLASHATTENTION_TESTCASES = [
    "core_mini_rvv_flashattention_prefill_test",
    "core_mini_rvv_flashattention_decode_test",
    "core_mini_rvv_bf16_flashattention_test",
]

# Filegroup for gemma weights to be packaged into runfiles
filegroup(
    name = "weights_files",
    srcs = glob(["test_data/*.npy"]),
)

# CoralFlow test suite targets
coralflow_test(
    name = "rvv_rms_norm_cocotb_test",
    size = "enormous",
    srcs = ["cocotb_tests/rvv_rms_norm_cocotb_test.py"],
    data = [
        ":rvv_bf16_rms_norm.elf",
        ":rvv_rms_norm.elf",
        ":weights_files",
    ],
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RVV_RMS_NORM_TESTCASES,
    deps = [
        "//sw/utils:metrics",
        requirement("ml_dtypes"),
    ],
)

coralflow_test(
    name = "rvv_residual_add_cocotb_test",
    size = "enormous",
    srcs = ["cocotb_tests/rvv_residual_add_cocotb_test.py"],
    data = [
        ":rvv_bf16_residual_add.elf",
        ":rvv_residual_add.elf",
        ":weights_files",
    ],
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RVV_RESIDUAL_ADD_TESTCASES,
    deps = [
        "//sw/utils:metrics",
        requirement("ml_dtypes"),
    ],
)

coralflow_test(
    name = "rvv_tanh_gelu_mul_cocotb_test",
    size = "enormous",
    srcs = ["cocotb_tests/rvv_tanh_gelu_mul_cocotb_test.py"],
    data = [
        ":rvv_bf16_tanh_gelu_mul.elf",
        ":rvv_tanh_gelu_mul.elf",
        ":weights_files",
    ],
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RVV_TANH_GELU_MUL_TESTCASES,
    deps = [
        "//sw/utils:metrics",
        requirement("ml_dtypes"),
    ],
)

coralflow_test(
    name = "rvv_matmul_cocotb_test",
    size = "enormous",
    srcs = ["cocotb_tests/rvv_matmul_cocotb_test.py"],
    data = [
        ":rvv_bf16_matmul.elf",
        ":rvv_matmul.elf",
        ":weights_files",
    ],
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RVV_MATMUL_TESTCASES,
    deps = [
        "//sw/utils:metrics",
        requirement("ml_dtypes"),
    ],
)

coralflow_test(
    name = "rvv_flashattention_cocotb_test",
    size = "enormous",
    srcs = ["cocotb_tests/rvv_flashattention_cocotb_test.py"],
    data = [
        ":rvv_bf16_flashattention.elf",
        ":rvv_flashattention_test.elf",
        ":weights_files",
    ],
    highmem = True,
    tags = ["manual"],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RVV_FLASHATTENTION_TESTCASES,
    deps = [
        "//sw/utils:metrics",
        requirement("ml_dtypes"),
    ],
)

RVV_INT8_MATMUL_LHS_1D_TESTCASES = [
    "gemv",
    "matmul",
]

coralflow_test(
    name = "rvv_int8_matmul_test",
    size = "enormous",
    srcs = ["cocotb_tests/rvv_int8_matmul_cocotb_test.py"],
    elf = ":rvv_int8_matmul.elf",
    highmem = True,
    tags = ["manual"],
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RVV_INT8_MATMUL_LHS_1D_TESTCASES,
    deps = [
        "//sw/utils:metrics",
    ],
)
