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

load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_python//python:defs.bzl", "py_binary")
load("//rules:coralflow_test.bzl", "coralflow_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "generate_cc_arrays")

coralnpu_v2_binary(
    name = "run_mobilenet_v1_025_partial_binary",
    srcs = [
        "mobilenet_v1_025_partial_layers_cc",
        "run_partial_mobilenet.cc",
    ],
    hdrs = ["mobilenet_v1_025_partial_layers.h"],
    dtcm_size_kbytes = 1024,  # Highmem
    itcm_size_kbytes = 1024,  # Highmem
    visibility = ["//visibility:public"],
    deps = [
        "//sw/opt/litert-micro:depthwise_conv",
        "@tflite_micro//tensorflow/lite/micro:micro_framework",
        "@tflite_micro//tensorflow/lite/micro:micro_log",
        "@tflite_micro//tensorflow/lite/micro:micro_profiler",
        "@tflite_micro//tensorflow/lite/micro:op_resolvers",
        "@tflite_micro//tensorflow/lite/micro:system_setup",
    ],
)

cc_library(
    name = "mobilenet_v1_025_224_int8_dummy_lib",
    srcs = ["mobilenet_v1_025_224_int8_dummy_cc"],
    hdrs = ["mobilenet_v1_025_224_int8_dummy_h"],
    visibility = ["//visibility:public"],
)

generate_cc_arrays(
    name = "mobilenet_v1_025_partial_layers_cc",
    src = "models/mobilenet_v1_025_partial_layers.tflite",
    out = "mobilenet_v1_025_partial_layers.cc",
)

generate_cc_arrays(
    name = "mobilenet_v1_025_partial_layers_h",
    src = "models/mobilenet_v1_025_partial_layers.tflite",
    out = "mobilenet_v1_025_partial_layers.h",
)

generate_cc_arrays(
    name = "mobilenet_v1_025_224_int8_dummy_cc",
    src = "models/mobilenet_v1_0.25_224_int8_dummy.tflite",
    out = "mobilenet_v1_025_224_int8_dummy.cc",
)

generate_cc_arrays(
    name = "mobilenet_v1_025_224_int8_dummy_h",
    src = "models/mobilenet_v1_0.25_224_int8_dummy.tflite",
    out = "mobilenet_v1_025_224_int8_dummy.h",
)

RUN_MOBILENET_TEST = [
    "core_mini_rvv_mobilenet_v1",
]

coralflow_test(
    name = "cocotb_run_mobilenet_v1",
    size = "enormous",
    srcs = ["cocotb_run_mobilenet_v1.py"],
    elf = ":run_mobilenet_v1_025_partial_binary",
    highmem = True,
    tags = ["manual"],
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = RUN_MOBILENET_TEST,
)

coralnpu_v2_binary(
    name = "depthwise_conv_test",
    srcs = ["depthwise_conv_test.cc"],
    dtcm_size_kbytes = 1024,  # Highmem
    itcm_size_kbytes = 1024,  # Highmem
    deps = [
        "//sw/opt/litert-micro:depthwise_conv",
        "@tflite_micro//tensorflow/lite/kernels/internal:reference_base",
    ],
)

coralflow_test(
    name = "cocotb_depthwise_conv",
    size = "large",
    srcs = ["cocotb_depthwise_conv.py"],
    elf = ":depthwise_conv_test",
    exclude_testcases = {
        "verilator": [
            "test_dwconv64to64stride1",
            "test_dwconv64to64stride2",
        ],
    },
    highmem = True,
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = [
        "test_dwconv8to8stride1",
        "test_dwconv8to8stride2",
        "test_dwconv32to32stride1",
        "test_dwconv32to32stride2",
        "test_dwconv64to64stride1",
        "test_dwconv64to64stride2",
        "test_dwconv16to32stride2",
        # Benchmarks are skipped.
    ],
)

py_binary(
    name = "npusim_depthwise_conv",
    srcs = ["npusim_depthwise_conv.py"],
    data = [":depthwise_conv_test"],
    deps = [
        "//coralnpu_test_utils/sim_backends:mpact_npusim_test_fixture",
        "@bazel_tools//tools/python/runfiles",
        requirement("numpy"),
    ],
)

py_binary(
    name = "npusim_conv2d",
    srcs = ["npusim_conv2d.py"],
    data = [":conv2d_test"],
    deps = [
        "//coralnpu_test_utils/sim_backends:mpact_npusim_test_fixture",
        "@bazel_tools//tools/python/runfiles",
        requirement("numpy"),
    ],
)

coralnpu_v2_binary(
    name = "conv2d_test",
    srcs = ["conv2d_test.cc"],
    dtcm_size_kbytes = 1024,  # Highmem
    itcm_size_kbytes = 1024,  # Highmem
    deps = [
        "//sw/opt/litert-micro:conv",
        "@tflite_micro//tensorflow/lite/kernels/internal:reference_base",
    ],
)

coralflow_test(
    name = "cocotb_conv2d",
    size = "enormous",
    srcs = ["cocotb_conv2d.py"],
    elf = ":conv2d_test",
    exclude_testcases = {
        "verilator": [
            "test_conv2d_16x16",
        ],
    },
    highmem = True,
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = [
        "test_conv2d_4x1_h2w2",
        "test_conv2d_9x2",
        "test_conv2d_16x1",
        "test_conv2d_18x1",
        "test_conv2d_37x1_h2w2",
        "test_conv2d_16x3_s2",
        "test_conv2d_21x48_h8w8",
        "test_conv2d_16x16",
        "test_conv2d_16x16_h2w8",
    ],
)

coralnpu_v2_binary(
    name = "pooling_test",
    srcs = ["pooling_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        "//sw/opt/litert-micro:pooling",
        "//sw/utils",
        "@tflite_micro//tensorflow/lite/kernels/internal:reference_base",
    ],
)

coralflow_test(
    name = "cocotb_pooling",
    size = "enormous",
    srcs = ["cocotb_pooling.py"],
    elf = ":pooling_test",
    exclude_testcases = {
        "verilator": [
            "test_maxpool64stride2",
        ],
    },
    highmem = True,
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
)

coralnpu_v2_binary(
    name = "fully_connected_test",
    srcs = ["fully_connected_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        "//sw/opt/litert-micro:fully_connected",
        "//sw/utils",
        "@tflite_micro//tensorflow/lite/kernels/internal:reference_base",
    ],
)

coralflow_test(
    name = "cocotb_fully_connected",
    size = "enormous",
    srcs = ["cocotb_fully_connected.py"],
    elf = ":fully_connected_test",
    highmem = True,
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = [
        "test_fc_16_16",
        "test_fc_64_64",
    ],
)

coralnpu_v2_binary(
    name = "logistic_test",
    srcs = ["logistic_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        "//sw/opt/litert-micro:logistic",
        "//sw/utils",
        "@tflite_micro//tensorflow/lite/kernels/internal:reference_base",
    ],
)

coralflow_test(
    name = "cocotb_logistic",
    size = "enormous",
    srcs = ["cocotb_logistic.py"],
    elf = ":logistic_test",
    highmem = True,
    targets = [
        "npusim",
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    testcases = [
        "test_logistic_256",
    ],
)
