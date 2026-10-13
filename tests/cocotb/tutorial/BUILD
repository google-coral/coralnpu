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

load("//rules:coralflow_test.bzl", "coralflow_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "generate_cc_arrays")

# BEGIN_TESTCASES_FOR_tutorial
TUTORIAL_TESTCASES = [
    "core_mini_axi_tutorial",
]
# END_TESTCASES_FOR_tutorial

# BEGIN_TESTCASES_FOR_hello_world_float_core_mini_axi
HELLO_WORLD_TESTCASES = [
    "core_mini_axi_tutorial",
]
# END_TESTCASES_FOR_hello_world_float_core_mini_axi

coralflow_test(
    name = "tutorial",
    size = "medium",
    srcs = ["tutorial.py"],
    data = [":coralnpu_v2_program"],
    hdl_toplevel = "CoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
        "uvm",
    ],
    testcases = TUTORIAL_TESTCASES,
    deps = [
        "@rules_python//python/runfiles",
    ],
)

coralflow_test(
    name = "hello_world_float_core_mini_axi",
    size = "medium",
    srcs = ["hello_world_float_core_mini_axi.py"],
    elf = "//examples:coralnpu_v2_hello_world_add_floats.elf",
    hdl_toplevel = "CoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
        "uvm",
        "nexus_fpga",
    ],
    testcases = HELLO_WORLD_TESTCASES,
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "coralnpu_v2_program",
    srcs = ["program.cc"],
    visibility = ["//visibility:public"],
)

coralnpu_v2_binary(
    name = "tflite_micro_test",
    srcs = [
        "hello_world_tflite_cc",
        "tflite_micro_test.cc",
    ],
    hdrs = ["hello_world_tflite.h"],
    dtcm_size_kbytes = 1024,  # Highmem
    itcm_size_kbytes = 1024,  # Highmem
    deps = [
        "@tflite_micro//tensorflow/lite/micro:micro_framework",
        "@tflite_micro//tensorflow/lite/micro:micro_log",
        "@tflite_micro//tensorflow/lite/micro:micro_profiler",
        "@tflite_micro//tensorflow/lite/micro:op_resolvers",
        "@tflite_micro//tensorflow/lite/micro:system_setup",
    ],
)

generate_cc_arrays(
    name = "hello_world_tflite_cc",
    src = "@tflite_micro//tensorflow/lite/micro/examples/hello_world/models:hello_world_int8.tflite",
    out = "hello_world_tflite.cc",
)

generate_cc_arrays(
    name = "hello_world_tflite_h",
    src = "@tflite_micro//tensorflow/lite/micro/examples/hello_world/models:hello_world_int8.tflite",
    out = "hello_world_tflite.h",
)
