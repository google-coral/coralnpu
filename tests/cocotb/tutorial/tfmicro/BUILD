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
load("//rules:coco_tb.bzl", "cocotb_test_suite", "verilator_cocotb_model")
load("//rules:coralnpu_v2.bzl", "collect_coralnpu_elfs", "coralnpu_v2_binary")
load("//rules:utils.bzl", "generate_cc_arrays")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
    "VERILATOR_BUILD_ARGS",
)

VCS_COMMON_DATA = [
    "//hdl/verilog:dpi_files",
]

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

# BEGIN_TESTCASES_FOR_running_tflite
RUN_MOBILENET_TEST = [
    "core_mini_rvv_mobilenet_v1",
]
# END_TESTCASES_FOR_running_tflite

cocotb_test_suite(
    name = "cocotb_run_mobilenet_v1",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = RUN_MOBILENET_TEST,
    testcases_vname = "RUN_MOBILENET_TEST",
    tests_kwargs = {
        "waves": False,
        "tags": ["manual"],
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "seed": "42",
        "size": "enormous",
        "test_module": ["cocotb_run_mobilenet_v1.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": ["run_mobilenet_v1_025_partial_binary.elf"],
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["run_mobilenet_v1_025_partial_binary.elf"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
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

cocotb_test_suite(
    name = "cocotb_depthwise_conv",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_dwconv8to8stride1",
        "test_dwconv8to8stride2",
        ("test_dwconv32to32stride1", "large"),
        ("test_dwconv32to32stride2", "large"),
        ("test_dwconv64to64stride1", "large"),
        ("test_dwconv64to64stride2", "large"),
        ("test_dwconv16to32stride2", "large"),
        # Benchmarks are skipped.
    ],
    # testcases_vname = "RUN_MOBILENET_TEST",
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "size": "enormous",
        "default_testcase_size": "medium",
        "test_module": ["cocotb_depthwise_conv.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": ["depthwise_conv_test.elf"],
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["depthwise_conv_test.elf"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)

py_binary(
    name = "npusim_depthwise_conv",
    srcs = ["npusim_depthwise_conv.py"],
    data = [":depthwise_conv_test"],
    deps = [
        "//sw/coralnpu_sim:coralnpu_v2_sim_utils_lib",
        "@bazel_tools//tools/python/runfiles",
        requirement("numpy"),
    ],
)

py_binary(
    name = "npusim_conv2d",
    srcs = ["npusim_conv2d.py"],
    data = [":conv2d_test"],
    deps = [
        "//sw/coralnpu_sim:coralnpu_v2_sim_utils_lib",
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

cocotb_test_suite(
    name = "cocotb_conv2d",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_conv2d_4x1_h2w2",
        "test_conv2d_9x2",
        "test_conv2d_16x1",
        "test_conv2d_18x1",
        "test_conv2d_37x1_h2w2",
        ("test_conv2d_48x48_h2w2", "large"),
        "test_conv2d_16x3_s2",
        ("test_conv2d_21x48_h8w8", "large"),
        ("test_conv2d_16x16", "enormous"),
        ("test_conv2d_16x16_h2w8", "enormous"),
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "size": "enormous",
        "default_testcase_size": "medium",
        "test_module": ["cocotb_conv2d.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": ["conv2d_test.elf"],
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["conv2d_test.elf"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
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

cocotb_test_suite(
    name = "cocotb_pooling",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "test_maxpool16stride2",
        "test_maxpool32stride2",
        "test_maxpool64stride2",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "size": "enormous",
        "test_module": ["cocotb_pooling.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": ["pooling_test.elf"],
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["pooling_test.elf"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
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

cocotb_test_suite(
    name = "cocotb_fully_connected",
    simulators = ["verilator"],
    testcases = [
        "test_fc_16_16",
        "test_fc_64_64",
        "test_fc_256_256",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "size": "enormous",
        "test_module": ["cocotb_fully_connected.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": ["fully_connected_test.elf"],
    },
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
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

cocotb_test_suite(
    name = "cocotb_logistic",
    simulators = ["verilator"],
    testcases = [
        "test_logistic_256",
        "test_logistic_1024",
    ],
    tests_kwargs = {
        "waves": False,
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "size": "enormous",
        "test_module": ["cocotb_logistic.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            "@rules_python//python/runfiles",
        ],
        "data": ["logistic_test.elf"],
    },
    verilator_model = "//tests/cocotb:rvv_core_mini_highmem_axi_model",
)

collect_coralnpu_elfs()
