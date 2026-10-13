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

load("@coralnpu_hw//rules:coralflow_test.bzl", "coralflow_test")
load("@coralnpu_hw//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")

package(default_visibility = ["//visibility:public"])

coralnpu_v2_binary(
    name = "max_pool_test",
    srcs = ["max_pool_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        "//sw/opt/litert-micro:pooling",
        "//sw/utils",
        "@tflite_micro//tensorflow/lite/kernels/internal:reference_base",
    ],
)

coralnpu_v2_binary(
    name = "conv_test",
    srcs = ["conv_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        "//sw/opt/litert-micro:conv",
        "//sw/utils",
        "@tflite_micro//tensorflow/lite/kernels/internal:reference_base",
    ],
)

coralflow_test(
    name = "max_pool_sim_test",
    srcs = ["max_pool_test.py"],
    elf = ":max_pool_test.elf",
    highmem = True,
    main = "max_pool_test.py",
    targets = [
        "npusim",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
        requirement("numpy"),
    ],
)

coralflow_test(
    name = "conv_sim_test",
    srcs = ["conv_test.py"],
    elf = ":conv_test.elf",
    highmem = True,
    main = "conv_test.py",
    targets = [
        "npusim",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
        requirement("numpy"),
    ],
)
