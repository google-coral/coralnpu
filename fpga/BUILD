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

load("@bazel_skylib//rules:common_settings.bzl", "string_list_flag")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@coralnpu_host_cpus//:defs.bzl", "MAKE_JOBS", "VERILATOR_THREADS")
load("@internal_check//:status.bzl", internal_exists = "FOLDER_EXISTS")
load("@lowrisc_opentitan_gh//rules:fusesoc.bzl", "fusesoc_build")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:coralnpu_v2_sim_test.bzl", "coralnpu_v2_sim_test")
load("//rules:utils.bzl", "cc_embed_data", "template_rule")

package(default_visibility = ["//visibility:public"])

_CLOCK_FREQUENCY_MHZ = "50"

_ISP_CLOCK_FREQUENCY_MHZ = "10"

_SPIM_CLOCK_FREQUENCY_MHZ = "100"

filegroup(
    name = "rtl_files_common",
    srcs = glob(["**/*.sv"]) + glob(["**/*.core"]) + [
        "//fpga/ip/coralnpu_tlul:rtl_files",
        "//fpga/ip/display_dpi:rtl_files",
        "//fpga/ip/gpio_dpi:rtl_files",
        "//fpga/ip/i2c_master:rtl_files",
        "//fpga/ip/ispyocto:rtl_files",
        "//fpga/ip/s25fl512s_dpi:rtl_files",
        "//fpga/ip/spi_dpi_master:rtl_files",
        "//fpga/rtl:rtl_files",
    ],
)

filegroup(
    name = "rtl_files",
    srcs = [
        ":rtl_files_common",
        "//fpga/ip/coralnpu_chisel_subsystem_default:rtl_files",
        "//fpga/ip/coralnpu_chisel_subsystem_highmem:rtl_files",
    ],
)

VERILATOR_OPTIONS_COMMON = [
    "-Wno-ALWCOMBORDER",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNUSEDSIGNAL",
    "-Wno-UNUSEDPARAM",
    "-Wno-VARHIDDEN",
    # TODO: The MULTIDRIVEN warnings are caused by the `prim_arbiter_fixed`
    # module and the `tlul_fifo_sync` module. We should investigate these
    # modules and fix the underlying issues.
    # "-Wno-MULTIDRIVEN",
    "-Wno-UNOPTTHREADS",
    "-Wno-GENUNNAMED",
    "-Wno-DECLFILENAME",
    "-Wno-ASCRANGE",
    "-DRVFI",
    "-DUSE_GENERIC",
    "-DUSE_DPI_MEMORY",
    "-DTB_SUPPORT",
    # RVV
    "-DVLEN_128",
    "-Wno-BLKANDNBLK",
    "-Wno-CASEX",
    # allows verilator to ignore timing code in rtl
    # eg: "out <= #1 RESET_STATE;"
    "--no-timing",
    # Runtime Verilator sim thread count. Populated at workspace-fetch time
    # from `nproc` (capped at 8, since past that Verilator typically hits
    # scheduling overhead). Override at build time with
    # `--//fpga:verilator_options_default=...` or your own string_list_flag.
    "--threads {}".format(VERILATOR_THREADS),
]

string_list_flag(
    name = "verilator_options_default",
    build_setting_default = VERILATOR_OPTIONS_COMMON,
)

string_list_flag(
    name = "verilator_options_highmem",
    build_setting_default = [
        "-CFLAGS \"-DCHISEL_SUBSYSTEM_HIGHMEM\"",
    ] + VERILATOR_OPTIONS_COMMON,
)

# `make -j` for Verilator's C++ compile. Detected from `nproc` at
# workspace-fetch time; override with `--//fpga:make_options=-jN`.
string_list_flag(
    name = "make_options",
    build_setting_default = [
        "-j{}".format(MAKE_JOBS),
    ],
)

cc_embed_data(
    name = "add_uint32_m1_bin_header",
    srcs = [":add_uint32_m1_bin"],
    var_name = "add_uint32_m1_bin",
)

cc_library(
    name = "clk",
    srcs = ["sw/clk.c"],
    hdrs = ["sw/clk.h"],
)

cc_library(
    name = "uart",
    srcs = ["sw/uart.c"],
    hdrs = ["sw/uart.h"],
    deps = [":clk"],
)

cc_library(
    name = "gpio",
    srcs = ["sw/gpio.c"],
    hdrs = ["sw/gpio.h"],
)

cc_library(
    name = "spi",
    srcs = ["sw/spi.c"],
    hdrs = ["sw/spi.h"],
    deps = [":clk"],
)

cc_library(
    name = "i2c",
    srcs = ["sw/i2c.c"],
    hdrs = ["sw/i2c.h"],
    deps = [":clk"],
)

cc_library(
    name = "dma",
    srcs = ["sw/dma.c"],
    hdrs = ["sw/dma.h"],
)

coralnpu_v2_binary(
    name = "clk_test",
    srcs = ["sw/clk_test.c"],
    deps = [
        ":clk",
        ":uart",
    ],
)

cc_library(
    name = "display_hal",
    srcs = ["sw/display_hal.c"],
    deps = [
        ":gpio",
        ":spi",
        "//third_party/waveshare_display",
    ],
    alwayslink = 1,
)

cc_library(
    name = "display_renderer",
    srcs = ["sw/display_renderer.cc"],
    hdrs = ["sw/display_renderer.h"],
    deps = [
        ":display_hal",
        ":dma",
        ":gpio",
        ":spi",
        "//third_party/waveshare_display",
    ],
)

cc_library(
    name = "spi_flash",
    srcs = ["sw/spi_flash.c"],
    hdrs = ["sw/spi_flash.h"],
    deps = [
        ":clk",
        ":dma",
        ":gpio",
        ":spi",
    ],
)

coralnpu_v2_binary(
    name = "display_test",
    srcs = ["sw/display_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        ":display_hal",
        ":gpio",
        ":spi",
        "//third_party/waveshare_display",
    ],
)

coralnpu_v2_binary(
    name = "add_uint32_m1",
    srcs = ["sw/add_uint32_m1.cc"],
    deps = [":uart"],
)

coralnpu_v2_binary(
    name = "spi_test",
    srcs = ["sw/spi_test.cc"],
    deps = [
        ":spi",
        ":uart",
    ],
)

coralnpu_v2_binary(
    name = "gpio_test",
    srcs = ["sw/gpio_test.cc"],
    deps = [
        ":gpio",
        ":uart",
    ],
)

coralnpu_v2_sim_test(
    name = "trivial_pass_sim_test",
    srcs = ["sw/trivial_pass_test.cc"],
    # Pinned to the SPI loader path so we keep regression coverage of the
    # spi2tlul ELF-load bridge. Every other coralnpu_v2_sim_test uses the
    # default backdoor loader.
    loader = "spi",
    deps = [":uart"],
)

coralnpu_v2_sim_test(
    name = "clk_sim_test",
    srcs = ["sw/clk_test.c"],
    deps = [
        ":clk",
        ":uart",
    ],
)

coralnpu_v2_sim_test(
    name = "trivial_pass_highmem_sim_test",
    srcs = ["sw/trivial_pass_test.cc"],
    highmem = True,
    deps = [":uart"],
)

coralnpu_v2_sim_test(
    name = "dma_sim_test",
    srcs = ["sw/dma_test.cc"],
    sim_timeout = 120,
    deps = [
        ":dma",
        ":uart",
    ],
)

coralnpu_v2_binary(
    name = "flash_tool",
    srcs = [
        "sw/flash_tool.c",
        "sw/flash_tool_status.h",
    ],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        ":spi",
        ":spi_flash",
        ":uart",
    ],
)

py_binary(
    name = "flash_tool_sim_test",
    srcs = ["sw/flash_tool_sim_test.py"],
    args = [
        "$(location :flash_tool.elf)",
        "--sim_timeout",
        "600",
    ],
    data = [
        ":copy_chip_verilator_highmem_binary",
        ":flash_tool.elf",
    ],
    main = "sw/flash_tool_sim_test.py",
    deps = [
        ":flash_tool_lib",
        "//utils/coralnpu_soc_loader:spi_driver",
        requirement("pyelftools"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_library(
    name = "flash_tool_lib",
    srcs = ["sw/flash_tool_lib.py"],
    visibility = ["//visibility:public"],
)

py_test(
    name = "flash_tool_test",
    srcs = ["sw/flash_tool_test.py"],
    deps = [
        ":flash_tool_lib",
    ],
)

py_binary(
    name = "flash_tool_ftdi",
    srcs = ["sw/flash_tool_ftdi.py"],
    data = [
        ":flash_tool.elf",
    ],
    main = "sw/flash_tool_ftdi.py",
    deps = [
        ":flash_tool_lib",
        "//coralnpu_test_utils:ftdi_spi_master_lib",
        "//coralnpu_test_utils:run_binary",
        "@bazel_tools//tools/python/runfiles",
        requirement("pyelftools"),
    ],
)

coralnpu_v2_sim_test(
    name = "spi_flash_sim_test",
    srcs = ["sw/spi_flash_test.cc"],
    sim_timeout = 240,
    deps = [
        ":gpio",
        ":spi",
        ":spi_flash",
        ":uart",
    ],
)

coralnpu_v2_binary(
    name = "i2c_camera_test",
    srcs = ["sw/i2c_camera_test.cc"],
    deps = [
        ":i2c",
        ":uart",
    ],
)

coralnpu_v2_binary(
    name = "i2c_camera_test_highmem",
    srcs = ["sw/i2c_camera_test.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
    deps = [
        ":i2c",
        ":uart",
    ],
)

coralnpu_v2_binary(
    name = "timer",
    srcs = ["sw/timer.cc"],
    deps = [":uart"],
)

coralnpu_v2_binary(
    name = "isp_cam_test",
    srcs = [
        "sw/isp_cam_test.c",
        "sw/yocto_isp_register_address.h",
    ],
    deps = [":uart"],
)

filegroup(
    name = "add_uint32_m1_bin",
    srcs = [":add_uint32_m1"],
    output_group = "bin_file",
)

filegroup(
    name = "rom_test_vmem",
    srcs = [":rom_test"],
    output_group = "vmem_file",
)

filegroup(
    name = "rom_test_highmem_vmem",
    srcs = [":rom_test_highmem"],
    output_group = "vmem_file",
)

# Configuration for different memory variants
_MEM_CONFIGS = [
    {
        "name": "default",
        "suffix": "",
        "chisel_core": "//fpga/ip/coralnpu_chisel_subsystem_default:coralnpu_chisel_subsystem_default.core",
        "chisel_rtl": "//fpga/ip/coralnpu_chisel_subsystem_default:rtl_files",
        "verilator_options": ":verilator_options_default",
        "itcm": "8",
        "dtcm": "32",
        "rom_vmem": ":rom_test_vmem",
        "rom_vmem_file": "$(location :rom_test_vmem)",
    },
    {
        "name": "highmem",
        "suffix": "_highmem",
        "chisel_core": "//fpga/ip/coralnpu_chisel_subsystem_highmem:coralnpu_chisel_subsystem_highmem.core",
        "chisel_rtl": "//fpga/ip/coralnpu_chisel_subsystem_highmem:rtl_files",
        "verilator_options": ":verilator_options_highmem",
        "itcm": "1024",
        "dtcm": "1024",
        "rom_vmem": ":rom_test_highmem_vmem",
        "rom_vmem_file": "$(location :rom_test_highmem_vmem)",
    },
]

# Boot modes to generate for each memory variant
_BOOT_MODES = [
    {
        "name": "itcm",
        "suffix": "",
        "is_rom": False,
    },
    {
        "name": "rom",
        "suffix": "_rom",
        "is_rom": True,
    },
]

CORALNPU_SOC_SRCS_COMMON = [
    ":rtl_files_common",
    "@lowrisc_opentitan_gh//hw/dv/sv:dv_macros",
    "@lowrisc_opentitan_gh//hw/dv:verilator_files",
    "@lowrisc_opentitan_gh//hw:check_tool_requirements.py",
    "@lowrisc_opentitan_gh//hw:lint/tools/verilator/common.vlt",
    "@lowrisc_opentitan_gh//hw:lint/tools/verilator/comportable.vlt",
    "@lowrisc_opentitan_gh//hw:rtl_files",
    "@lowrisc_opentitan_gh//hw:tool_requirements.py",
    "@lowrisc_opentitan_gh//hw:vendor/lint/pulp_riscv_dbg.vlt",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/debug_rom/debug_rom.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/debug_rom/debug_rom_one_scratch.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dm_csrs.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dm_mem.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dm_pkg.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dm_sba.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dm_top.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dmi_cdc.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dmi_jtag.sv",
    "@lowrisc_opentitan_gh//hw:vendor/pulp_riscv_dbg/src/dmi_jtag_tap.sv",
    "@lowrisc_opentitan_gh//hw:verilator_files",
    "main.cc",
]

CORALNPU_SOC_CORES_COMMON = [
    ":coralnpu_soc.core",
    ":coralnpu_soc_pkg.core",
    ":racl_pkg.core",
    "@lowrisc_opentitan_gh//hw:check_tool_requirements.core",
]

VERILATOR_COMMON_SRCS = CORALNPU_SOC_SRCS_COMMON + [
    "//fpga/ip/spi_dpi_master:dpi_files",
    "//fpga/ip/display_dpi:dpi_files",
    "//fpga/ip/gpio_dpi:dpi_files",
    "//fpga/ip/s25fl512s_dpi:dpi_files",
    "//hdl/verilog:dpi_files",
    "@lowrisc_opentitan_gh//hw:dpi_files",
]

VERILATOR_COMMON_CORES = [
    ":chip_verilator.core",
    "//hdl/verilog:sram_backdoor.core",
    "//fpga/ip/i2c_master:i2c_master.core",
    "//fpga/ip/spi_dpi_master:spi_dpi_master.core",
    "//fpga/ip/display_dpi:display_dpi.core",
    "//fpga/ip/gpio_dpi:gpio_dpi.core",
    "//fpga/ip/s25fl512s_dpi:s25fl512s_dpi.core",
    "@lowrisc_opentitan_gh//hw/dv:dpi/uartdpi/uartdpi.core",
    "@lowrisc_opentitan_gh//hw/dv:dpi/uartdpi/uartdpi_sv.core",
    "@lowrisc_opentitan_gh//hw/dv:dpi/jtagdpi/jtagdpi.core",
    "@lowrisc_opentitan_gh//hw/dv:dpi/jtagdpi/jtagdpi_sv.core",
    "//fpga/ip/ispyocto:tlul2ahblite_files",
    "//fpga/ip/ispyocto:ispyocto_core",
]

# Generate Verilator build targets
_VERILATOR_NAME_MAP = {
    "build_chip_verilator" + m["suffix"] + b["suffix"]: {
        "cores": CORALNPU_SOC_CORES_COMMON + VERILATOR_COMMON_CORES + [m["chisel_core"]],
        "srcs": VERILATOR_COMMON_SRCS + [m["chisel_rtl"]] + ([m["rom_vmem"]] if b["is_rom"] else []),
        "verilator_options": m["verilator_options"],
        "flags": [
            "--ClockFrequencyMhz=" + _CLOCK_FREQUENCY_MHZ,
            "--IspClockFrequencyMhz=" + _ISP_CLOCK_FREQUENCY_MHZ,
            "--SpimClockFrequencyMhz=" + _CLOCK_FREQUENCY_MHZ,
            "--ItcmSizeKBytes=" + m["itcm"],
            "--DtcmSizeKBytes=" + m["dtcm"],
        ] + ([
            "--EnableAutoboot=1",
            "--BootAddr=268435456",
        ] if b["is_rom"] else []),
    }
    for m in _MEM_CONFIGS
    for b in _BOOT_MODES
}

template_rule(
    fusesoc_build,
    _VERILATOR_NAME_MAP,
    make_options = ":make_options",
    output_groups = {
        "binary": ["com.google.coralnpu_fpga_chip_verilator_0.1/sim-verilator/Vchip_verilator"],
    },
    systems = ["com.google.coralnpu:fpga:chip_verilator:0.1"],
    target = "sim",
)

DDR_CORES = [
    "//internal/fpga/ip/ddr4:ddr4.core",
    "//internal/fpga/ip/ddr4_phy:ddr4_phy.core",
] if internal_exists else [
    "//fpga/ip/ddr4_stub:ddr4_stub.core",
]

DDR_SRCS = [
    "//internal/fpga/ip/ddr4:elf_files",
    "//internal/fpga/ip/ddr4:rtl_files",
    "//internal/fpga/ip/ddr4_phy:rtl_files",
] if internal_exists else [
    "//fpga/ip/ddr4_stub:rtl_files",
]

VIVADO_HOOKS = [
    "vivado_setup_hooks.tcl",
    "vivado_hook_write_bitstream_post.tcl",
    "check_pin_assignments.tcl",
    "vivado_pre_opt_hooks.tcl",
    "pblock_u_isp.tcl",
]

NEXUS_COMMON_SRCS = CORALNPU_SOC_SRCS_COMMON + [
    "pins_nexus.xdc",
] + VIVADO_HOOKS + DDR_SRCS

NEXUS_COMMON_CORES = [
    ":chip_nexus.core",
    "//fpga/ip/i2c_master:i2c_master.core",
    "//fpga/ip/ispyocto:ispyocto_core",
    "//fpga/ip/ispyocto:tlul2ahblite_files",
] + DDR_CORES

# Generate Nexus build targets (bitstream and synth_only)
_NEXUS_NAME_MAP = {
    "build_chip_nexus_" + build_type + m["suffix"] + b["suffix"]: {
        "cores": CORALNPU_SOC_CORES_COMMON + NEXUS_COMMON_CORES + [m["chisel_core"]],
        "srcs": NEXUS_COMMON_SRCS + [m["chisel_rtl"]] + ([m["rom_vmem"]] if b["is_rom"] else []),
        "flags": [
            "--ClockFrequencyMhz=" + _CLOCK_FREQUENCY_MHZ,
            "--IspClockFrequencyMhz=" + _ISP_CLOCK_FREQUENCY_MHZ,
            "--SpimClockFrequencyMhz=" + _SPIM_CLOCK_FREQUENCY_MHZ,
            "--ItcmSizeKBytes=" + m["itcm"],
            "--DtcmSizeKBytes=" + m["dtcm"],
        ] + ([
            "--EnableAutoboot=1",
            "--MemInitFile=" + m["rom_vmem_file"],
            "--BootAddr=268435456",
        ] if b["is_rom"] else []) + (["--pnr=none"] if build_type == "synth_only" else []),
    }
    for m in _MEM_CONFIGS
    for b in _BOOT_MODES
    for build_type in ["bitstream", "synth_only"]
}

template_rule(
    fusesoc_build,
    _NEXUS_NAME_MAP,
    output_groups = {
        "all": ["com.google.coralnpu_fpga_chip_nexus_0.1/"],
    },
    systems = ["com.google.coralnpu:fpga:chip_nexus:0.1"],
    tags = ["manual"],
    target = "synth",
)

filegroup(
    name = "chip_verilator_binary",
    srcs = [":build_chip_verilator"],
    output_group = "binary",
)

genrule(
    name = "copy_chip_verilator_binary",
    srcs = [":chip_verilator_binary"],
    outs = ["Vchip_verilator"],
    cmd = "cp $< $@",
)

filegroup(
    name = "chip_verilator_highmem_binary",
    srcs = [":build_chip_verilator_highmem"],
    output_group = "binary",
)

genrule(
    name = "copy_chip_verilator_highmem_binary",
    srcs = [":chip_verilator_highmem_binary"],
    outs = ["Vchip_verilator_highmem"],
    cmd = "cp $< $@",
)

filegroup(
    name = "chip_verilator_rom_binary",
    srcs = [":build_chip_verilator_rom"],
    output_group = "binary",
)

genrule(
    name = "copy_chip_verilator_rom_binary",
    srcs = [":chip_verilator_rom_binary"],
    outs = ["Vchip_verilator_rom"],
    cmd = "cp $< $@",
)

filegroup(
    name = "chip_verilator_highmem_rom_binary",
    srcs = [":build_chip_verilator_highmem_rom"],
    output_group = "binary",
)

genrule(
    name = "copy_chip_verilator_highmem_rom_binary",
    srcs = [":chip_verilator_highmem_rom_binary"],
    outs = ["Vchip_verilator_highmem_rom"],
    cmd = "cp $< $@",
)

genrule(
    name = "gen_flash_boot_bin",
    srcs = [":trivial_pass_sim_test_binary.elf"],
    outs = ["flash_boot.bin"],
    cmd = "$(location sw/rom_boot/make_flash_image.py) $< $@",
    tools = ["sw/rom_boot/make_flash_image.py"],
)

py_test(
    name = "rom_boot_sim_test",
    srcs = [
        "sw/rom_boot/rom_boot_sim_test.py",
        "sw/rom_boot/make_flash_image.py",
    ],
    args = [
        "--sim_binary",
        "coralnpu_hw/fpga/Vchip_verilator_rom",
        "--rom_vmem",
        "coralnpu_hw/fpga/rom_test.vmem",
        "--flash_image",
        "coralnpu_hw/fpga/flash_boot.bin",
        "--sim_timeout",
        "600",
    ],
    main = "sw/rom_boot/rom_boot_sim_test.py",
    tags = ["exclusive"],
    timeout = "long",
    data = [
        ":copy_chip_verilator_rom_binary",
        ":rom_test.elf",
        ":rom_test_vmem",
        ":flash_boot.bin",
    ],
    deps = [
        "//utils/coralnpu_soc_loader:spi_driver",
        "@bazel_tools//tools/python/runfiles",
    ],
)

genrule(
    name = "gen_flash_boot_highmem_bin",
    srcs = [":trivial_pass_highmem_sim_test_binary.elf"],
    outs = ["flash_boot_highmem.bin"],
    cmd = "$(location sw/rom_boot/make_flash_image.py) $< $@",
    tools = ["sw/rom_boot/make_flash_image.py"],
)

py_test(
    name = "rom_boot_highmem_sim_test",
    srcs = [
        "sw/rom_boot/rom_boot_sim_test.py",
        "sw/rom_boot/make_flash_image.py",
    ],
    args = [
        "--sim_binary",
        "coralnpu_hw/fpga/Vchip_verilator_highmem_rom",
        "--rom_vmem",
        "coralnpu_hw/fpga/rom_test_highmem.vmem",
        "--flash_image",
        "coralnpu_hw/fpga/flash_boot_highmem.bin",
        "--sim_timeout",
        "600",
    ],
    main = "sw/rom_boot/rom_boot_sim_test.py",
    tags = ["exclusive"],
    timeout = "long",
    data = [
        ":copy_chip_verilator_highmem_rom_binary",
        ":rom_test_highmem.elf",
        ":rom_test_highmem_vmem",
        ":flash_boot_highmem.bin",
    ],
    deps = [
        "//utils/coralnpu_soc_loader:spi_driver",
        "@bazel_tools//tools/python/runfiles",
    ],
)

# Ensure bazel clean is run if internal dir is added or removed from tree
py_test(
    name = "check_pins_test",
    srcs = ["check_pins.py"],
    args = [
        "--xdc",
        "$(location pins_nexus.xdc)",
    ] + ([
        "--xdc",
        "$(location //internal/fpga/ip/ddr4:pins_ddr.xdc)",
    ] if internal_exists else []) + [
        "--sv",
        "$(location //fpga/rtl:chip_nexus.sv)",
    ],
    data = [
        "pins_nexus.xdc",
        "//fpga/rtl:chip_nexus.sv",
    ] + (["//internal/fpga/ip/ddr4:pins_ddr.xdc"] if internal_exists else []),
    main = "check_pins.py",
)

# Rules to available ispyocto and axi2sramcrs in the sandbox
cc_library(
    name = "rom_boot_crt0",
    srcs = ["sw/rom_boot/crt0.S"],
    target_compatible_with = ["//platforms/cpu:coralnpu_v2"],
)

coralnpu_v2_binary(
    name = "rom_test",
    srcs = ["sw/rom_boot/main.c"],
    crt = ":rom_boot_crt0",
    linker_script = "sw/rom_boot/rom.ld",
    deps = [
        ":dma",
        ":spi_flash",
        ":uart",
    ],
)

coralnpu_v2_binary(
    name = "rom_test_highmem",
    srcs = ["sw/rom_boot/main.c"],
    crt = ":rom_boot_crt0",
    linker_script = "sw/rom_boot/rom_highmem.ld",
    deps = [
        ":dma",
        ":spi_flash",
        ":uart",
    ],
)

genrule(
    name = "unpack_ispyocto",
    srcs = ["@ispyocto//:ispyocto_rtl_files"],
    outs = ["ispyocto_unpacked.done"],
    cmd = "mkdir -p ispyocto_unpacked && cp -r $(locations @ispyocto//:ispyocto_rtl_files) ispyocto_unpacked/ && touch $@",
)
