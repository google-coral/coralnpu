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

package(default_visibility = ["//visibility:public"])

genrule(
    name = "grey_bars_320x240_raw_gen",
    srcs = ["dv/camera_model/gen_test_pattern.py"],
    outs = ["grey_bars_320x240.raw"],
    cmd = "python3 $(location dv/camera_model/gen_test_pattern.py) && mv test_pattern_320x240.raw $@",
)

filegroup(
    name = "tlul2ahblite_files",
    srcs = glob([
        "*.core",
        "lint/*.vlt",
        "rtl/*.v",
        "rtl/*.sv",
        "rtl/*.svh",
    ]),
)

filegroup(
    name = "rtl_files",
    srcs = [
        ":tlul2ahblite_files",
        "@ispyocto//:rtl_files",
    ],
)

filegroup(
    name = "tlul2ahblite_verilog_files",
    srcs = glob([
        "rtl/*.v",
        "rtl/*.sv",
    ]),
)

filegroup(
    name = "verilog_files",
    srcs = [
        ":tlul2ahblite_verilog_files",
        "@ispyocto//:rtl_files",
    ],
)

filegroup(
    name = "ispyocto_core",
    srcs = [
        ":tlul2ahblite_files",
        "@ispyocto//:ispyocto_core",
    ],
)

# Generate default simulation testbench binary using the internal TPG.
# Run binary with ./path/to/Visp_wrapper_tb
fusesoc_build(
    name = "isp_wrapper_sim",
    srcs = [
        ":grey_bars_320x240.raw",
        ":ispyocto_core",
        ":rtl_files",
        "//fpga:rtl_files",
        "//fpga/ip/coralnpu_tlul:rtl_files",
        "@lowrisc_opentitan_gh//hw:rtl_files",
    ],
    cores = [
        ":ispyocto_core",
        "//fpga/ip/coralnpu_tlul:rtl_files",
        "//fpga:coralnpu_soc_pkg.core",
        "@lowrisc_opentitan_gh//hw:check_tool_requirements.core",
    ],
    output_groups = {
        "binary": ["google_ip_ispyocto_0.1/sim-verilator/Visp_wrapper_tb"],
    },
    systems = ["google:ip:ispyocto:0.1"],
    target = "sim",
)

filegroup(
    name = "isp_wrapper_sim_binary",
    srcs = [":isp_wrapper_sim"],
    output_group = "binary",
)

sh_test(
    name = "isp_wrapper_sim_test",
    srcs = ["run_wrapper_sim.sh"],
    args = ["$(location :isp_wrapper_sim_binary)"],
    data = [
        ":grey_bars_320x240.raw",
        ":isp_wrapper_sim_binary",
    ],
)
