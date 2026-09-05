# Copyright 2023 Google LLC
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

load("@rules_hdl//verilog:providers.bzl", "verilog_library")

exports_files(
    srcs = [
        "ClockGate.sv",
        "RstSync.sv",
        "Sram.v",
        "Sram_1rw_256x256.v",
        "Sram_1rwm_256x288.v",
        "TlulAdapterSram.sv",
        "Uart.sv",
        "sram_backdoor.core",
        "axi_sim_mem.sv",
        "gen_axi_sim_mem_wrapper.py",
    ],
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "clock_gate",
    srcs = ["ClockGate.sv"],
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "RstSync",
    srcs = ["RstSync.sv"],
    visibility = ["//visibility:public"],
    deps = [
        ":clock_gate",
    ],
)

verilog_library(
    name = "sram_1rw_256x256",
    srcs = ["Sram_1rw_256x256.v"],
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "Sram",
    srcs = ["Sram.v"],
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "sram_1rw_256x288",
    srcs = ["Sram_1rwm_256x288.v"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "dpi_files",
    srcs = [
        "sram_backdoor.cc",
        "sram_backdoor.h",
    ],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "sram_backdoor",
    srcs = ["sram_backdoor.cc"],
    hdrs = ["sram_backdoor.h"],
    visibility = ["//visibility:public"],
    deps = ["@verilator//:svdpi"],
)

# Backing store + DPI for axi_sim_mem.sv (simulation-only external memory).
cc_library(
    name = "ddr_sim_mem",
    srcs = ["ddr_sim_mem.cc"],
    hdrs = ["ddr_sim_mem.h"],
    visibility = ["//visibility:public"],
    deps = ["@verilator//:svdpi"],
)

py_binary(
    name = "gen_axi_sim_mem_wrapper",
    srcs = ["gen_axi_sim_mem_wrapper.py"],
    visibility = ["//visibility:public"],
)
