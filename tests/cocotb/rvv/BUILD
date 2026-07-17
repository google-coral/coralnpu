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

load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")

package(default_visibility = ["//visibility:public"])

template_rule(
    coralnpu_v2_binary,
    {
        "rvv_add": {
            "srcs": ["rvv_add.S"],
        },
        "rvv_load": {
            "srcs": ["rvv_load.S"],
        },
        "vcsr_test": {
            "srcs": ["vcsr_test.cc"],
        },
        "vcompress_test": {
            "srcs": ["vcompress_test.cc"],
        },
        "vcpop_exception_test": {
            "srcs": ["vcpop_exception_test.cc"],
        },
        "vcpop_test": {
            "srcs": ["vcpop_test.cc"],
        },
        "vfirst_test": {
            "srcs": ["vfirst_test.cc"],
        },
        "vill_test": {
            "srcs": ["vill_test.cc"],
        },
        "viota_test": {
            "srcs": ["viota_test.cc"],
        },
        "vmsbf_test": {
            "srcs": ["vmsbf_test.cc"],
        },
        "vmsif_test": {
            "srcs": ["vmsif_test.cc"],
        },
        "vmsof_test": {
            "srcs": ["vmsof_test.cc"],
        },
        "vsetvl_test": {
            "srcs": ["vsetvl_test.cc"],
        },
        "vslide": {
            "srcs": ["vslide.cc"],
        },
        "vstart_store": {
            "srcs": ["vstart_store.S"],
        },
        "vgather": {
            "srcs": ["vgather.cc"],
        },
    },
)

filegroup(
    name = "rvv_assem_tests",
    srcs = [
        "rvv_add.elf",
        "rvv_load.elf",
        "vcompress_test.elf",
        "vcpop_exception_test.elf",
        "vcpop_test.elf",
        "vcsr_test.elf",
        "vfirst_test.elf",
        "vgather.elf",
        "vill_test.elf",
        "viota_test.elf",
        "vmsbf_test.elf",
        "vmsif_test.elf",
        "vmsof_test.elf",
        "vsetvl_test.elf",
        "vslide.elf",
        "vstart_store.elf",
    ],
)
