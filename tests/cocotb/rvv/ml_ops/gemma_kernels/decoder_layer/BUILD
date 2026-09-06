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
load("@gemma_deps//:requirements.bzl", gemma_requirement = "requirement")
load("//third_party/python:requirements.bzl", "requirement")

package(default_visibility = ["//visibility:public"])

template_rule(
    coralnpu_v2_binary,
    {
        "rvv_bf16_gemma_decoder_layer": {
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
    },
)

py_binary(
    name = "prepare_real_gemma_layer",
    main = "prepare_real_gemma_layer_mytest.py",
    srcs = ["prepare_real_gemma_layer_mytest.py"],
    tags = ["manual"],
    deps = [
        gemma_requirement("numpy"),
        gemma_requirement("safetensors"),
        gemma_requirement("torch"),
        gemma_requirement("transformers"),
    ],
)

_DECODER_LAYER_TESTCASES = [
    "core_mini_rvv_bf16_gemma_decoder_layer_test",
]

_REAL_DECODER_LAYER_TESTCASES = [
    "core_mini_rvv_bf16_real_gemma_decoder_layer_test",
]

_COMMON_TEST_KWARGS = {
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
    "data": [":rvv_bf16_gemma_decoder_layer.elf"],
    "size": "enormous",
}

_COMMON_VCS_DATA = [
    ":rvv_bf16_gemma_decoder_layer.elf",
    "//tests/cocotb:xprop.cfg",
    "@coralnpu_hw//hdl/verilog:dpi_files",
]

cocotb_test_suite(
    name = "rvv_gemma_decoder_layer_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = _DECODER_LAYER_TESTCASES,
    testcases_vname = "_DECODER_LAYER_TESTCASES",
    tests_kwargs = _COMMON_TEST_KWARGS,
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = _COMMON_VCS_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)

cocotb_test_suite(
    name = "rvv_real_gemma_decoder_layer_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = _REAL_DECODER_LAYER_TESTCASES,
    testcases_vname = "_REAL_DECODER_LAYER_TESTCASES",
    tests_kwargs = _COMMON_TEST_KWARGS,
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = _COMMON_VCS_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)
