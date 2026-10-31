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

load("@bazel_skylib//rules:common_settings.bzl", "string_flag")
load("//hdl/chisel/src/coralnpu:flags.bzl", "VME_CORE_MINI_AXI_VOPTS")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:verilator.bzl", "verilator_cc_library")

# Verilator --threads for the models; each simulator needs that many free
# CPUs. On large hosts, use e.g. --@coralnpu_hw//hw_sim:verilator_threads=8.
_THREADS = [
    "1",
    "4",
    "8",
]

string_flag(
    name = "verilator_threads",
    build_setting_default = "1",
    values = _THREADS,
)

[
    config_setting(
        name = "verilator_threads_" + t,
        flag_values = {":verilator_threads": t},
    )
    for t in _THREADS
]

# UNOPTTHREADS would fail the 8-thread build, but 8 threads run faster than 4.
_MODEL_VOPTS = VME_CORE_MINI_AXI_VOPTS + ["-Wno-UNOPTTHREADS"] + select({
    ":verilator_threads_" + t: [
        "--threads",
        t,
    ]
    for t in _THREADS
})

verilator_cc_library(
    name = "vme_core_mini_axi_model",
    module = "//hdl/chisel/src/coralnpu:vme_core_mini_axi_cc_library_verilog",
    module_top = "VmeCoreMiniAxi",
    systemc = False,
    trace = False,
    vopts = _MODEL_VOPTS,
)

verilator_cc_library(
    name = "vme_core_mini_highmem_axi_model",
    module = "//hdl/chisel/src/coralnpu:vme_core_mini_highmem_axi_cc_library_verilog",
    module_top = "VmeCoreMiniHighmemAxi",
    systemc = False,
    trace = False,
    vopts = _MODEL_VOPTS,
)

cc_library(
    name = "hw_primitives",
    srcs = [
        "hw_primitives.cc",
    ],
    hdrs = [
        "hw_primitives.h",
    ],
    deps = [
        "@com_google_absl//absl/types:span",
        "@verilator//:libverilator",
    ],
)

cc_library(
    name = "core_mini_axi_wrapper",
    hdrs = [
        "core_mini_axi_wrapper.h",
    ],
    defines = select({
        ":verilator_threads_" + t: ["CORALNPU_VERILATOR_THREADS=" + t]
        for t in _THREADS
    }),
    deps = [
        ":coralnpu_simulator_headers",
        ":hw_primitives",
        ":vme_core_mini_axi_model",
        ":vme_core_mini_highmem_axi_model",
        "//hdl/verilog:sram_backdoor",
    ],
)

cc_binary(
    name = "core_mini_axi_wrapper_example",
    srcs = [
        "core_mini_axi_wrapper_example.cc",
    ],
    data = [
        "//tests/cocotb:wfi_slot_0.elf",
    ],
    deps = [
        ":core_mini_axi_wrapper",
        "//tests/verilator_sim:elf",
    ],
)

cc_library(
    name = "coralnpu_simulator_headers",
    hdrs = [
        "coralnpu_simulator.h",
        "mailbox.h",
    ],
    visibility = ["//visibility:public"],
)

cc_library(
    name = "core_mini_axi_simulator_vme",
    srcs = ["core_mini_axi_simulator.cc"],
    linkstatic = True,
    visibility = ["//visibility:public"],
    deps = [
        ":coralnpu_simulator_headers",
        ":core_mini_axi_wrapper",
    ],
    alwayslink = True,
)

coralnpu_v2_binary(
    name = "mailbox_example",
    srcs = [
        "mailbox_example.cc",
    ],
    visibility = ["//visibility:public"],
)

cc_binary(
    name = "core_mini_axi_simulator_example",
    srcs = [
        "core_mini_axi_simulator_example.cc",
    ],
    data = [
        ":mailbox_example.elf",
    ],
    deps = [
        ":core_mini_axi_simulator_vme",
        "//tests/verilator_sim:elf",
    ],
)

# generate libraries for external projects
cc_binary(
    name = "libcoralnpu_simulator_vme.so",
    linkshared = True,
    visibility = ["//visibility:public"],
    deps = [":core_mini_axi_simulator_vme"],
)

genrule(
    name = "debug_common_cells_path",
    srcs = ["@common_cells//:all_srcs"],
    outs = ["debug_path_out.txt"],
    cmd = "echo '--- external ---' > $@; ls -R external >> $@ 2>&1 || true; echo '--- current ---' >> $@; ls -R . >> $@ 2>&1 || true",
    visibility = ["//visibility:public"],
)
