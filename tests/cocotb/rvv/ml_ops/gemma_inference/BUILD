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

# Gemma 3 270M end-to-end inference tests. See README.md.

load("@gemma_deps//:requirements.bzl", gemma_requirement = "requirement")
load("//rules:coco_tb.bzl", "cocotb_test_suite")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//third_party/python:requirements.bzl", "requirement")

package(default_visibility = ["//visibility:public"])

# DUT program: one Gemma3Control command per run (gemma3_model.h).
coralnpu_v2_binary(
    name = "gemma3_runner",
    srcs = [
        "gemma3_aux_kernels.cc",
        "gemma3_model.h",
        "gemma3_runner.cc",
    ],
    dtcm_size_kbytes = 1024,
    enable_vmem = False,
    itcm_size_kbytes = 1024,
    stack_size_bytes = 4096,
    deps = [
        "//sw/utils:utils",
        "//tests/cocotb/rvv/ml_ops/gemma_kernels",
    ],
)

# Strict NumPy reference + DDR image builder, shared by the test and the dump.
py_library(
    name = "gemma3_ref",
    srcs = ["gemma3_ref.py"],
    deps = [requirement("numpy")],
)

py_test(
    name = "gemma3_ref_self_test",
    srcs = ["gemma3_ref.py"],
    main = "gemma3_ref.py",
    deps = [":gemma3_ref"],
)

# HF -> int8 weights + bf16 reference activations. Needs Hub access to the
# gated google/gemma-3-270m (or --model_id <mirror>). Output is ~100 MB and
# is not checked in; write it to test_data/.
py_binary(
    name = "dump_gemma3_model",
    srcs = ["dump_gemma3_model.py"],
    tags = ["manual"],
    deps = [
        ":gemma3_ref",
        gemma_requirement("accelerate"),
        gemma_requirement("numpy"),
        gemma_requirement("torch"),
        gemma_requirement("transformers"),
    ],
)

filegroup(
    name = "test_data",
    srcs = glob(
        ["test_data/*.npz", "test_data/*.npy"],
        allow_empty = True,
    ),
)

# Minutes-to-an-hour tier: safe to run on every RTL change.
GEMMA3_INFERENCE_TESTCASES = [
    "gemma3_layer0_decode_step",
    "gemma3_layer_sweep_teacher_forced",
    "gemma3_layer0_prefill",
    "gemma3_next_token_candidates",
]

# Hours tier: numerics gate before merging anything that can change output codes.
GEMMA3_INFERENCE_SLOW_TESTCASES = [
    "gemma3_greedy_generate",
    "gemma3_full_vocab_logits",
]

# The *SimMem model keeps external memory in the RTL (see //tests/cocotb:BUILD);
# without it one Gemma 3 token costs ~90 minutes of Python-bound simulation.
_COMMON_TEST_KWARGS = {
    "hdl_toplevel": "RvvCoreMiniHighmemAxiSimMem",
    "waves": False,
    "seed": "42",
    "tags": ["manual"],
    "test_module": ["cocotb_tests/gemma3_inference_cocotb_test.py"],
    "deps": [
        ":gemma3_ref",
        "//coralnpu_test_utils:sim_test_fixture",
        "//sw/utils:metrics",
        "@bazel_tools//tools/python/runfiles",
    ],
    "data": [
        ":gemma3_runner.elf",
        ":test_data",
    ],
    "size": "enormous",
}

cocotb_test_suite(
    name = "gemma3_inference_cocotb_test",
    simulators = ["verilator"],
    testcases = GEMMA3_INFERENCE_TESTCASES,
    testcases_vname = "GEMMA3_INFERENCE_TESTCASES",
    tests_kwargs = _COMMON_TEST_KWARGS,
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_simmem_model",
)

cocotb_test_suite(
    name = "gemma3_inference_slow_cocotb_test",
    simulators = ["verilator"],
    testcases = GEMMA3_INFERENCE_SLOW_TESTCASES,
    testcases_vname = "GEMMA3_INFERENCE_SLOW_TESTCASES",
    tests_kwargs = _COMMON_TEST_KWARGS,
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_simmem_model",
)


