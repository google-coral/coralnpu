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
load("//rules:coralnpu_v2.bzl", "collect_coralnpu_elfs", "coralnpu_v2_binary")

py_binary(
    name = "npusim_run_mobilenet",
    srcs = ["npusim_run_mobilenet.py"],
    data = [
        ":run_full_mobilenet_v1_binary",
    ],
    deps = [
        "//sw/coralnpu_sim:coralnpu_v2_sim_utils_lib",
        "@bazel_tools//tools/python/runfiles",
        requirement("numpy"),
    ],
)

coralnpu_v2_binary(
    name = "run_full_mobilenet_v1_binary",
    srcs = [
        "run_full_mobilenet_v1.cc",
    ],
    dtcm_size_kbytes = 1024,  # Highmem
    itcm_size_kbytes = 1024,  # Highmem
    semihosting = True,
    visibility = ["//visibility:public"],
    deps = [
        "//sw/opt:rvv_opt",
        "//sw/opt/litert-micro:conv",
        "//sw/opt/litert-micro:depthwise_conv",
        "//tests/cocotb/tutorial/tfmicro:mobilenet_v1_025_224_int8_dummy_lib",
        "@tflite_micro//tensorflow/lite/micro:micro_framework",
        "@tflite_micro//tensorflow/lite/micro:micro_log",
        "@tflite_micro//tensorflow/lite/micro:op_resolvers",
        "@tflite_micro//tensorflow/lite/micro:system_setup",
    ],
)

collect_coralnpu_elfs()
