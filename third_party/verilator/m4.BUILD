# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

""" A BUILD file for m4 based on FSF stock source. """

load("@coralnpu_hw//third_party/verilator:copy.bzl", "touch")
load("@rules_cc//cc:defs.bzl", "cc_binary")

package(
    default_visibility = ["//visibility:public"],
    features = [
        "-parse_headers",
        "no_layering_check",
    ],
)

licenses(["restricted"])  # GPLv3

exports_files(["COPYING"])

touch(
    name = "bazel_version_info",
    out = "src/bazel_version_info.h",
    contents = dict(
        PACKAGE_VERSION = '"1.4.18"',
        VERSION = '"1.4.18"',
    ),
)

cc_binary(
    name = "m4",
    srcs = glob([
        "src/*.c",
        "src/*.h",
    ]) + [
        "src/bazel_version_info.h",
    ],
    copts = [
        "-w",
        "-DBAZEL_VERSION_INFO",
    ],
    includes = [
        "src/",
    ],
    output_licenses = ["unencumbered"],
    deps = [
        "@org_gnu_gnulib//:gnulib",
    ],
)
