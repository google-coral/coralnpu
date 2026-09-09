# Copyright 2026 Antmicro
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

package(default_visibility = ["//visibility:public"])

exports_files(glob(["**/*"]))

filegroup(
    name = "all_srcs",
    srcs = glob([
        "**/*",
    ]),
)

alias(
    name = "uvm_src",
    actual = ":all_srcs",
)

cc_library(
    name = "uvm_dpi",
    srcs = [
        "src/dpi/uvm_dpi.cc",
    ],
    hdrs = [
        "src/dpi/uvm_dpi.h",
        "src/dpi/uvm_dpi.svh",
        "src/dpi/uvm_hdl.svh",
        "src/dpi/uvm_regex.svh",
        "src/dpi/uvm_svcmd_dpi.svh",
    ],
    copts = [
        "-O2",
        "-DVERILATOR",
        "-Wno-vla-cxx-extension",
    ],
    includes = ["src/dpi"],
    textual_hdrs = [
        "src/dpi/uvm_common.c",
        "src/dpi/uvm_hdl.c",
        "src/dpi/uvm_hdl_polling.c",
        "src/dpi/uvm_hdl_verilator.c",
        "src/dpi/uvm_regex.cc",
        "src/dpi/uvm_svcmd_dpi.c",
    ],
    deps = [
        "@verilator//:vltstd",
    ],
)
