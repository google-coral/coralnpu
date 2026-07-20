# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@rules_foreign_cc//foreign_cc:configure.bzl", "configure_make")

filegroup(
    name = "all_srcs",
    srcs = glob(["**"]),
)

configure_make(
    name = "riscv_isa_sim",
    args = ["-j16"],
    configure_options = [
        "--enable-commitlog",
        "--with-isa=rv32imf_zve32f_zvl128b_zicsr_zifencei_zbb_zfbfmin_zvfbfa",
        "CXX=clang++",
    ],
    lib_source = ":all_srcs",
    out_binaries = ["spike"],
    visibility = ["//visibility:public"],
)
