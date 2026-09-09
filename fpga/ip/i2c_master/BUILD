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

load("@lowrisc_opentitan_gh//rules:fusesoc.bzl", "fusesoc_build")
load("//rules:verilog.bzl", "verilog_library")

package(default_visibility = ["//visibility:public"])

verilog_library(
    name = "i2c_master",
    srcs = [
        "i2c_master.sv",
        "i2c_master_pkg.sv",
        "i2c_master_top.sv",
    ],
    deps = [
        "//fpga/ip/coralnpu_tlul",
        "//fpga/rtl:fpga_rtl",
    ],
)

filegroup(
    name = "rtl_files",
    srcs = glob([
        "*.sv",
        "*.core",
        "*.vlt",
    ]),
)

fusesoc_build(
    name = "i2c_master_sim",
    srcs = [
        "//fpga:rtl_files",
        "@lowrisc_opentitan_gh//hw:rtl_files",
    ],
    cores = [
        ":i2c_master.core",
        "//fpga/ip/coralnpu_tlul:rtl_files",
        "//fpga:coralnpu_soc_pkg.core",
        "//fpga:racl_pkg.core",
        "@lowrisc_opentitan_gh//hw:check_tool_requirements.core",
    ],
    output_groups = {
        "binary": ["coralnpuv2_ip_i2c_master_0.1/sim-verilator/Vi2c_master_tb"],
    },
    systems = ["coralnpuv2:ip:i2c_master:0.1"],
    target = "sim",
)
