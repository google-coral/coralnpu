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

load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)
load("//third_party/python:requirements.bzl", "requirement")

package(default_visibility = ["//visibility:public"])

# Keep the instrumented profiling binary separate from the decoder-layer
# correctness target.  The profiling implementation writes 19 per-stage cycle
# counters and intentionally has different timing instrumentation.
template_rule(
    coralnpu_v2_binary,
    {
        "rvv_bf16_gemma_decoder_layer_profile": {
            "srcs": [
                "rvv_bf16_gemma_decoder_layer_runner_mytest.cc",
                "rvv_gemma_decoder_layer_mytest.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_bf16_matmul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_rms_norm.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_tanh_gelu_mul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_residual_add.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_kernel.cc",
            ],
            "hdrs": ["rvv_gemma_decoder_layer_mytest.h"],
            "deps": [
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec",
                "//sw/utils:utils",
            ],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_gemma_decoder_layer_profile_seg2": {
            "srcs": [
                "rvv_bf16_gemma_decoder_layer_runner_mytest.cc",
                "rvv_gemma_decoder_layer_mytest.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_bf16_matmul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_rms_norm.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_tanh_gelu_mul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_residual_add.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_kernel.cc",
            ],
            "hdrs": ["rvv_gemma_decoder_layer_mytest.h"],
            "deps": [
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec",
                "//sw/utils:utils",
            ],
            "defines": ["RVV_GEMMA_SEG2_PROJECTIONS"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_gemma_decoder_layer_profile_block_seg2": {
            "srcs": [
                "rvv_bf16_gemma_decoder_layer_runner_mytest.cc",
                "rvv_gemma_decoder_layer_mytest.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_bf16_matmul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_rms_norm.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_tanh_gelu_mul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_residual_add.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_kernel.cc",
            ],
            "hdrs": ["rvv_gemma_decoder_layer_mytest.h"],
            "deps": [
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec",
                "//sw/utils:utils",
            ],
            "defines": ["RVV_GEMMA_BLOCK_SEG2_PROJECTIONS"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_gemma_decoder_layer_profile_block_seg2_a_cache": {
            "srcs": [
                "rvv_bf16_gemma_decoder_layer_runner_mytest.cc",
                "rvv_gemma_decoder_layer_mytest.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_bf16_matmul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_rms_norm.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_tanh_gelu_mul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_residual_add.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_kernel.cc",
            ],
            "hdrs": ["rvv_gemma_decoder_layer_mytest.h"],
            "deps": [
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec",
                "//sw/utils:utils",
            ],
            "defines": ["RVV_GEMMA_BLOCK_SEG2_A_CACHE_PROJECTIONS"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
        "rvv_bf16_gemma_decoder_layer_profile_seg2_a_cache": {
            "srcs": [
                "rvv_bf16_gemma_decoder_layer_runner_mytest.cc",
                "rvv_gemma_decoder_layer_mytest.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_bf16_matmul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_rms_norm.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_tanh_gelu_mul.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_residual_add.cc",
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_kernel.cc",
            ],
            "hdrs": ["rvv_gemma_decoder_layer_mytest.h"],
            "deps": [
                "//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_common_vec",
                "//sw/utils:utils",
            ],
            "defines": ["RVV_GEMMA_SEG2_A_CACHE_PROJECTIONS"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
            "enable_vmem": False,
        },
    },
)

_PROFILE_TESTCASES = [
    "core_mini_rvv_bf16_gemma_decoder_layer_test",
]

cocotb_test_suite(
    name = "rvv_gemma_decoder_layer_profile_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = _PROFILE_TESTCASES,
    testcases_vname = "_PROFILE_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "waves": False,
        "seed": "42",
        "tags": ["manual"],
        "test_module": ["cocotb_tests/rvv_gemma_decoder_layer_cocotb_test_mytest.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
            requirement("ml_dtypes"),
        ],
        "data": [
            ":rvv_bf16_gemma_decoder_layer_profile.elf",
            ":rvv_bf16_gemma_decoder_layer_profile_seg2.elf",
            ":rvv_bf16_gemma_decoder_layer_profile_block_seg2.elf",
            ":rvv_bf16_gemma_decoder_layer_profile_block_seg2_a_cache.elf",
            ":rvv_bf16_gemma_decoder_layer_profile_seg2_a_cache.elf",
        ],
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":rvv_bf16_gemma_decoder_layer_profile.elf",
        ":rvv_bf16_gemma_decoder_layer_profile_seg2.elf",
        ":rvv_bf16_gemma_decoder_layer_profile_block_seg2.elf",
        ":rvv_bf16_gemma_decoder_layer_profile_block_seg2_a_cache.elf",
        ":rvv_bf16_gemma_decoder_layer_profile_seg2_a_cache.elf",
        "//tests/cocotb:xprop.cfg",
        "@coralnpu_hw//hdl/verilog:dpi_files",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)
