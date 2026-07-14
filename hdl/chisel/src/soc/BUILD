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

load("@coralnpu_hw//rules:chisel.bzl", "chisel_binary", "chisel_cc_library", "chisel_library")
load("@coralnpu_hw//rules:coco_tb.bzl", "verilator_cocotb_model")
load(
    "//tests/cocotb:build_defs.bzl",
    "VERILATOR_BUILD_ARGS",
)

package(default_visibility = ["//visibility:public"])

chisel_library(
    name = "crossbar_config_lib",
    srcs = [
        "CrossbarConfig.scala",
        "RawTlulSram.scala",
        "SoCChiselConfig.scala",
        "SoCRecords.scala",
        "TlulSram.scala",
    ],
    deps = [
        "//hdl/chisel/src/bus",
        "//hdl/chisel/src/coralnpu:coralnpu_params",
        "//hdl/chisel/src/coralnpu:coralnpu_scalar",
        "//hdl/chisel/src/coralnpu:srams",
    ],
)

chisel_binary(
    name = "validate_crossbar_config",
    main_class = "coralnpu.soc.CrossbarConfigValidator",
    deps = [":crossbar_config_lib"],
)

chisel_library(
    name = "coralnpu_xbar_lib",
    srcs = ["CoralNPUXbar.scala"],
    deps = [
        ":crossbar_config_lib",
        "//hdl/chisel/src/bus",
        "//hdl/chisel/src/coralnpu",
        "//hdl/chisel/src/coralnpu:coralnpu_params",
    ],
)

chisel_cc_library(
    name = "coralnpu_xbar_cc_library",
    chisel_lib = ":coralnpu_xbar_lib",
    emit_class = "coralnpu.soc.CoralNPUXbarEmitter",
    module_name = "CoralNPUXbar",
)

chisel_cc_library(
    name = "coralnpu_xbar_testharness_cc_library",
    chisel_lib = ":coralnpu_xbar_lib",
    emit_class = "coralnpu.soc.CoralNPUXbarEmitter",
    gen_flags = ["--enableTestHarness"],
    module_name = "CoralNPUXbarTestHarness",
)

verilator_cocotb_model(
    name = "coralnpu_xbar_testharness_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "CoralNPUXbarTestHarness",
    trace = True,
    verilog_source = ":coralnpu_xbar_testharness_cc_library_emit_verilog",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

chisel_library(
    name = "coralnpu_chisel_subsystem_lib",
    srcs = ["CoralNPUChiselSubsystem.scala"],
    deps = [
        ":coralnpu_xbar_lib",
        ":crossbar_config_lib",
        "//hdl/chisel/src/bus",
        "//hdl/chisel/src/common:library",
        "//hdl/chisel/src/coralnpu",
        "//hdl/chisel/src/coralnpu:coralnpu_params",
    ],
)

chisel_cc_library(
    name = "coralnpu_chisel_subsystem_cc_library",
    chisel_lib = ":coralnpu_chisel_subsystem_lib",
    emit_class = "coralnpu.soc.CoralNPUChiselSubsystemEmitter",
    module_name = "CoralNPUChiselSubsystem",
)

verilator_cocotb_model(
    name = "coralnpu_chisel_subsystem_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "CoralNPUChiselSubsystem",
    trace = True,
    verilog_source = "//hdl/chisel/src/soc:CoralNPUChiselSubsystem.sv",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

chisel_cc_library(
    name = "coralnpu_chisel_subsystem_testharness_cc_library",
    chisel_lib = ":coralnpu_chisel_subsystem_lib",
    emit_class = "coralnpu.soc.CoralNPUChiselSubsystemEmitter",
    gen_flags = ["--enableTestHarness"],
    module_name = "CoralNPUChiselSubsystemTestHarness",
)

verilator_cocotb_model(
    name = "coralnpu_chisel_subsystem_testharness_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "CoralNPUChiselSubsystemTestHarness",
    trace = True,
    verilog_source = ":coralnpu_chisel_subsystem_testharness_cc_library_emit_verilog",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

# Highmem defined to be 1024kB itcm and 1024kB dtcm at this time.
# CSR base address set to 0x200000 for highmem or any non default itcm size
# (default itcm size is itcm 8 / dtcm 32)
chisel_cc_library(
    name = "coralnpu_chisel_subsystem_highmem_cc_library",
    chisel_lib = ":coralnpu_chisel_subsystem_lib",
    emit_class = "coralnpu.soc.CoralNPUChiselSubsystemEmitter",
    gen_flags = [
        "--itcmSizeKBytes",
        "1024",
        "--dtcmSizeKBytes",
        "1024",
    ],
    module_name = "CoralNPUChiselSubsystemHighmem",
)

chisel_cc_library(
    name = "coralnpu_chisel_subsystem_itcm512kb_dtcm512kb_cc_library",
    chisel_lib = ":coralnpu_chisel_subsystem_lib",
    emit_class = "coralnpu.soc.CoralNPUChiselSubsystemEmitter",
    gen_flags = [
        "--itcmSizeKBytes",
        "512",
        "--dtcmSizeKBytes",
        "512",
    ],
    module_name = "CoralNPUChiselSubsystem_ITCM512KB_DTCM512KB",
)

chisel_cc_library(
    name = "coralnpu_chisel_subsystem_highmem_testharness_cc_library",
    chisel_lib = ":coralnpu_chisel_subsystem_lib",
    emit_class = "coralnpu.soc.CoralNPUChiselSubsystemEmitter",
    gen_flags = [
        "--enableTestHarness",
        "--itcmSizeKBytes",
        "1024",
        "--dtcmSizeKBytes",
        "1024",
    ],
    module_name = "CoralNPUChiselSubsystemHighmemTestHarness",
)

verilator_cocotb_model(
    name = "coralnpu_chisel_subsystem_highmem_testharness_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "CoralNPUChiselSubsystemHighmemTestHarness",
    trace = True,
    verilog_source = ":coralnpu_chisel_subsystem_highmem_testharness_cc_library_emit_verilog",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)
