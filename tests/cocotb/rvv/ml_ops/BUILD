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

load("//rules:coralnpu_v2.bzl", "collect_coralnpu_elfs", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")

package(default_visibility = ["//visibility:public"])

template_rule(
    coralnpu_v2_binary,
    {
        "rvv_matmul_assembly": {
            "srcs": [
                "matmul_runner.cc",
                "rvv_matmul_assembly.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
        },
        "rvv_matmul": {
            "srcs": [
                "matmul_runner.cc",
                "rvv_matmul.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
        },
        "rvv_matmul_assembly_highmem": {
            "srcs": [
                "matmul_runner.cc",
                "rvv_matmul_assembly.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
        },
        "rvv_matmul_highmem": {
            "srcs": [
                "matmul_runner.cc",
                "rvv_matmul.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
            "itcm_size_kbytes": 1024,
            "dtcm_size_kbytes": 1024,
        },
        "rvv_matmul_assembly_itcm512kb_dtcm512kb": {
            "srcs": [
                "matmul_runner.cc",
                "rvv_matmul_assembly.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
            "itcm_size_kbytes": 512,
            "dtcm_size_kbytes": 512,
        },
        "rvv_matmul_itcm512kb_dtcm512kb": {
            "srcs": [
                "matmul_runner.cc",
                "rvv_matmul.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
            "itcm_size_kbytes": 512,
            "dtcm_size_kbytes": 512,
        },
        "rvv_float_matmul": {
            "srcs": [
                "float_matmul_runner.cc",
                "rvv_float_matmul.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
        },
        "rvv_float_matmul_optimized": {
            "srcs": [
                "float_matmul_runner.cc",
                "rvv_float_matmul_optimized.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
        },
        "rvv_float_matmul_assembly": {
            "srcs": [
                "float_matmul_runner.cc",
                "rvv_float_matmul_assembly.cc",
            ],
            "hdrs": ["//sw/utils:utils.h"],
        },
    },
)

filegroup(
    name = "rvv_mlop_tests",
    srcs = [
        ":rvv_float_matmul.elf",
        ":rvv_float_matmul_assembly.elf",
        ":rvv_float_matmul_optimized.elf",
        ":rvv_matmul.elf",
        ":rvv_matmul_assembly.elf",
    ],
)

collect_coralnpu_elfs()
