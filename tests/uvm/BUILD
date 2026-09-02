# Copyright 2026 Antmicro

load("@coralnpu_host_cpus//:defs.bzl", "MAKE_JOBS")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_hdl//verilator:defs.bzl", "verilator_cc_library")
load("@rules_hdl//verilog:providers.bzl", "VerilogInfo", "verilog_library")
load("//rules:utils.bzl", "filter_files_by_extension")
load("//rules:verilator.bzl", "verilator_model")

package(default_visibility = ["//visibility:public"])

exports_files(glob(include = [
    "common/**/*",
    "env/**/*",
    "tb/**/*",
    "tests/**/*",
]))

# +incdir arguments like in coralnpu_dv.f
filegroup(
    name = "include_dirs",
    srcs = [
        "common/coralnpu_axi_master",
        "common/coralnpu_axi_slave",
        "common/coralnpu_irq",
        "common/cosim",
        "common/transaction_item",
        "env",
        "tb",
        "tests",
    ],
)

filegroup(
    name = "include_dirs_deps",
    srcs = glob(include = [
        "common/**/*",
        "env/**/*",
        "tb/**/*",
        "tests/**/*",
    ]),
)

# Source files like in coralnpu_dv.f
filegroup(
    name = "source_files",
    srcs = [
        # Backdoor DPI
        ":sram_backdoor_dpi_cc",
        # Interfaces
        "common/coralnpu_axi_master/coralnpu_axi_master_if.sv",
        "common/coralnpu_axi_slave/coralnpu_axi_slave_if.sv",
        "common/coralnpu_irq/coralnpu_irq_if.sv",
        "common/cosim/coralnpu_cosim_dpi_if.sv",
        # UVM Packages (in dependency order)
        "common/memory_map_pkg.sv",
        "common/transaction_item/transaction_item_pkg.sv",
        "common/coralnpu_axi_master/coralnpu_axi_master_agent_pkg.sv",
        "common/coralnpu_axi_slave/coralnpu_axi_slave_agent_pkg.sv",
        "common/coralnpu_irq/coralnpu_irq_agent_pkg.sv",
        "common/cosim/coralnpu_rvvi_agent_pkg.sv",
        "common/cosim/coralnpu_cosim_checker_pkg.sv",
        "env/coralnpu_env_pkg.sv",
        "tests/coralnpu_test_pkg.sv",
        # Top-Level Testbench
        "tb/coralnpu_tb_top.sv",
    ],
)

filter_files_by_extension(
    name = "sram_backdoor_dpi_cc",
    src = "//hdl/verilog:dpi_files",
    extensions = ["cc"],
)

filter_files_by_extension(
    name = "coralnpu_cosim_lib_static_archive",
    src = "@coralnpu-mpact-verilator//sim/cosim:coralnpu_cosim_lib_static",
    extensions = ["a"],
)

verilator_model(
    name = "uvm_sim_verilator",
    cflags = [
        "+define+UVM_NO_DEPRECATED",
        "+define+TB_SUPPORT",
        "+define+VLEN_128",
        "+define+ZVE32F_ON",
        "+define+DUMP_WAVES_VCD",
        "-Wno-PINMISSING",
        "-Wno-lint",
        "-Wno-style",
        "-Wno-fatal",
        "--timing",
        "--timescale 1ns/1ps",
    ],
    coralnpu_mpact_lib = ":coralnpu_cosim_lib_static_archive",
    hdl_toplevel = "coralnpu_tb_top",
    include_dirs = [":include_dirs"],
    verilog_sources = [
        "//hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library_emit_verilog_single_sv",
        ":source_files",
    ],
    deps = [
        ":include_dirs_deps",
        "//hdl/verilog:dpi_files",
    ],
)
