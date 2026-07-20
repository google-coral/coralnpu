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
    name = "ecall",
    srcs = ["ecall.cc"],
)

coralnpu_v2_binary(
    name = "perf_counters",
    srcs = ["perf_counters.cc"],
)

filegroup(
    name = "coralnpu_isa_tests",
    srcs = [
        "ecall.elf",
        "perf_counters.elf",
    ],
)

collect_coralnpu_elfs()
