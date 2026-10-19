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

load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library", "cc_test")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "fst_query_lib",
    srcs = ["fst_query.cc"],
    hdrs = ["fst_query.h"],
    copts = ["-std=c++20"],
    linkopts = ["-llz4"],
    deps = [
        "@com_google_absl//absl/flags:usage",
        "@com_google_absl//absl/status",
        "@com_google_absl//absl/status:statusor",
        "@com_googlesource_code_re2//:re2",
        "@net_zlib//:zlib",
        "@verilator//:verilator_runtime",
    ],
)

cc_binary(
    name = "fst_query",
    srcs = ["main.cc"],
    copts = ["-std=c++20"],
    deps = [
        ":fst_query_lib",
        "@com_google_absl//absl/flags:config",
        "@com_google_absl//absl/flags:flag",
        "@com_google_absl//absl/flags:parse",
        "@com_google_absl//absl/flags:usage",
        "@com_google_absl//absl/strings",
    ],
)

cc_test(
    name = "fst_query_test",
    size = "small",
    srcs = ["fst_query_test.cc"],
    copts = ["-std=c++20"],
    data = [
        "//tests/cocotb:math.elf",
        "//tests/verilator_sim:core_mini_axi_sim",
    ],
    deps = [
        ":fst_query_lib",
        "@com_google_absl//absl/strings",
        "@com_google_googletest//:gtest_main",
        "@com_googlesource_code_re2//:re2",
        "@verilator//:verilator_runtime",
    ],
)
