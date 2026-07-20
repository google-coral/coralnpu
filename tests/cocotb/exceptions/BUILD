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

package(default_visibility = ["//visibility:public"])

coralnpu_v2_binary(
    name = "illegal",
    srcs = ["illegal.cc"],
)

coralnpu_v2_binary(
    name = "instr_align_0",
    srcs = ["instr_align_0.cc"],
)

coralnpu_v2_binary(
    name = "instr_align_1",
    srcs = ["instr_align_1.cc"],
)

coralnpu_v2_binary(
    name = "instr_align_2",
    srcs = ["instr_align_2.cc"],
)

coralnpu_v2_binary(
    name = "instr_fault",
    srcs = ["instr_fault.cc"],
)

coralnpu_v2_binary(
    name = "load_fault_0",
    srcs = ["load_fault_0.cc"],
)

coralnpu_v2_binary(
    name = "load_fault_1",
    srcs = ["load_fault_1.cc"],
)

coralnpu_v2_binary(
    name = "store_fault_0",
    srcs = ["store_fault_0.cc"],
)

coralnpu_v2_binary(
    name = "store_fault_1",
    srcs = ["store_fault_1.cc"],
)

filegroup(
    name = "elf_files",
    srcs = [
        ":illegal.elf",
        ":instr_align_0.elf",
        ":instr_align_1.elf",
        ":instr_align_2.elf",
        ":instr_fault.elf",
        ":load_fault_0.elf",
        ":load_fault_1.elf",
        ":store_fault_0.elf",
        ":store_fault_1.elf",
    ],
)

collect_coralnpu_elfs()
