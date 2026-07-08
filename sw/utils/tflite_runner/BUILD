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

load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "tflite_runner_deps",
    deps = [
        "@tflite_micro//tensorflow/lite/micro:micro_framework",
        "@tflite_micro//tensorflow/lite/micro:micro_log",
        "@tflite_micro//tensorflow/lite/micro:op_resolvers",
        "@tflite_micro//tensorflow/lite/micro:system_setup",
    ] + select({
        "//platforms/cpu:coralnpu_v2": [
            "//sw/opt/litert-micro:conv",
            "//sw/opt/litert-micro:depthwise_conv",
            "//sw/opt/litert-micro:fully_connected",
            "//sw/opt/litert-micro:logistic",
            "//sw/opt/litert-micro:pooling",
        ],
        "//conditions:default": [],
    }),
)

coralnpu_v2_binary(
    name = "tflite_runner",
    srcs = ["tflite_runner.cc"],
    hdrs = ["//sw/utils:utils.h"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    linkopts = ["-Wl,--wrap=DebugLog"],
    stack_size_bytes = 131072,  # 128KB stack
    deps = [
        ":tflite_runner_deps",
    ],
)
