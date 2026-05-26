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

load("@coralnpu_hw//rules:coco_tb.bzl", "cocotb_test_suite", "verilator_cocotb_model")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")

package(default_visibility = ["//visibility:public"])

load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

# BEGIN_TESTCASES_FOR_tlul2axi_cocotb_test
TLUL2AXI_TESTCASES = [
    "test_put_request",
    "test_get_request",
    "test_backpressure",
    "test_put_then_get",
]
# END_TESTCASES_FOR_tlul2axi_cocotb_test

cocotb_test_suite(
    name = "tlul2axi_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = TLUL2AXI_TESTCASES,
    testcases_vname = "TLUL2AXI_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "TLUL2Axi",
        "test_module": ["tlul2axi_cocotb_test.py"],
        "default_testcase_size": "small",
        "size": "large",
        "deps": [
            "@bazel_tools//tools/python/runfiles",
            requirement("tqdm"),
        ],
        "waves": True,
    },
    vcs_verilog_sources = ["//hdl/chisel/src/bus:tlul2axi_cc_library_verilog"],
    verilator_model = "//hdl/chisel/src/bus:tlul2axi_model",
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_axi2tlul_cocotb_test
AXI2TLUL_TESTCASES = [
    "test_write_request",
    "test_read_request",
    "test_read_error",
]
# END_TESTCASES_FOR_axi2tlul_cocotb_test

cocotb_test_suite(
    name = "axi2tlul_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = AXI2TLUL_TESTCASES,
    testcases_vname = "AXI2TLUL_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "Axi2TLUL",
        "test_module": ["axi2tlul_cocotb_test.py"],
        "default_testcase_size": "small",
        "size": "large",
        "deps": [
            "@bazel_tools//tools/python/runfiles",
            requirement("tqdm"),
        ],
        "waves": True,
    },
    vcs_verilog_sources = ["//hdl/chisel/src/bus:axi2tlul_cc_library_verilog"],
    verilator_model = "//hdl/chisel/src/bus:axi2tlul_model",
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_tlul_fifo_async_128_cocotb_test
TLUL_FIFO_ASYNC_TESTCASES = [
    "test_async_crossing",
]
# END_TESTCASES_FOR_tlul_fifo_async_128_cocotb_test

cocotb_test_suite(
    name = "tlul_fifo_async_128_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = TLUL_FIFO_ASYNC_TESTCASES,
    testcases_vname = "TLUL_FIFO_ASYNC_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "TlulFifoAsync128",
        "test_module": ["test_tlul_fifo_async.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:tlul_fifo_async_128_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:tlul_fifo_async_128_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_tlul_fifo_sync_cocotb_test
TLUL_FIFO_SYNC_TESTCASES = [
    "test_passthrough_with_spare",
]
# END_TESTCASES_FOR_tlul_fifo_sync_cocotb_test

cocotb_test_suite(
    name = "tlul_fifo_sync_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = TLUL_FIFO_SYNC_TESTCASES,
    testcases_vname = "TLUL_FIFO_SYNC_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "TlulFifoSync",
        "test_module": ["test_tlul_fifo_sync.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:tlul_fifo_sync_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:tlul_fifo_sync_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_tlul_socket_1n_128_cocotb_test
TLUL_SOCKET_1N_TESTCASES = [
    "test_steering",
    "test_error_response",
]
# END_TESTCASES_FOR_tlul_socket_1n_128_cocotb_test

cocotb_test_suite(
    name = "tlul_socket_1n_128_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = TLUL_SOCKET_1N_TESTCASES,
    testcases_vname = "TLUL_SOCKET_1N_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "TlulSocket1N_128",
        "test_module": ["test_tlul_socket_1n.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:tlul_socket_1n_128_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:tlul_socket_1n_128_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_tlul_socket_m1_2_128_cocotb_test
TLUL_SOCKET_M1_2_TESTCASES = [
    "test_arbitration",
]
# END_TESTCASES_FOR_tlul_socket_m1_2_128_cocotb_test

cocotb_test_suite(
    name = "tlul_socket_m1_2_128_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = TLUL_SOCKET_M1_2_TESTCASES,
    testcases_vname = "TLUL_SOCKET_M1_2_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "TlulSocketM1_2_128",
        "test_module": ["test_tlul_socket_m1.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:tlul_socket_m1_2_128_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:tlul_socket_m1_2_128_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_tlul_integrity_cocotb_test
TLUL_INTEGRITY_TESTCASES = [
    "test_request_integrity_gen",
    "test_request_integrity_check",
    "test_response_integrity_gen",
    "test_response_integrity_check",
]
# END_TESTCASES_FOR_tlul_integrity_cocotb_test

cocotb_test_suite(
    name = "tlul_integrity_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = TLUL_INTEGRITY_TESTCASES,
    testcases_vname = "TLUL_INTEGRITY_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "TlulIntegrityTestbench",
        "test_module": ["test_tlul_integrity.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
            "//coralnpu_test_utils:secded_golden",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:tlul_integrity_testbench_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:tlul_integrity_testbench_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_secded_encoder_cocotb_test
SECDED_ENCODER_TESTCASES = [
    "test_secded_encoder",
]
# END_TESTCASES_FOR_secded_encoder_cocotb_test

cocotb_test_suite(
    name = "secded_encoder_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = SECDED_ENCODER_TESTCASES,
    testcases_vname = "SECDED_ENCODER_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "SecdedEncoderTestbench128",
        "test_module": ["test_secded_encoder.py"],
        "deps": [
            "//coralnpu_test_utils:secded_golden",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:secded_encoder_testbench_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:secded_encoder_testbench_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_secded_encoder_32_cocotb_test
SECDED_ENCODER_32_TESTCASES = [
    "test_secded_encoder",
]
# END_TESTCASES_FOR_secded_encoder_32_cocotb_test
cocotb_test_suite(
    name = "secded_encoder_32_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = SECDED_ENCODER_32_TESTCASES,
    testcases_vname = "SECDED_ENCODER_32_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "SecdedEncoderTestbench32",
        "test_module": ["test_secded_encoder.py"],
        "deps": [
            "//coralnpu_test_utils:secded_golden",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:secded_encoder_testbench_32_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:secded_encoder_testbench_32_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_secded_encoder_57_cocotb_test
SECDED_ENCODER_57_TESTCASES = [
    "test_secded_encoder",
]
# END_TESTCASES_FOR_secded_encoder_57_cocotb_test
cocotb_test_suite(
    name = "secded_encoder_57_cocotb_test",
    simulators = ["verilator", "vcs"],
    testcases = SECDED_ENCODER_57_TESTCASES,
    testcases_vname = "SECDED_ENCODER_57_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "SecdedEncoderTestbench57",
        "test_module": ["test_secded_encoder.py"],
        "deps": [
            "//coralnpu_test_utils:secded_golden",
        ],
        "waves": True,
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/bus:secded_encoder_testbench_57_model",
    vcs_verilog_sources = ["//hdl/chisel/src/bus:secded_encoder_testbench_57_cc_library_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# --- Rules for CoralNPUXbar cocotb test ---

verilator_cocotb_model(
    name = "coralnpu_xbar_model",
    cflags = ["-Wno-fatal"],
    hdl_toplevel = "CoralNPUXbar",
    trace = True,
    verilog_source = "//hdl/chisel/src/soc:CoralNPUXbar.sv",
)

# BEGIN_TESTCASES_FOR_coralnpu_xbar_cocotb
CORALNPU_XBAR_TESTCASES = [
    "test_coralnpu_core_to_sram",
    "test_coralnpu_core_to_invalid_addr",
    "test_coralnpu_core_to_uart1",
    "test_test_host_32_to_coralnpu_device",
    "test_coralnpu_core_to_coralnpu_device",
    "test_test_host_32_to_coralnpu_device_csr_read",
    "test_test_host_32_to_coralnpu_device_specific_addr",
    "test_wide_to_narrow_integrity",
    "test_16bit_writes_to_sram",
    "test_interleaved_hosts_to_sram",
]
# END_TESTCASES_FOR_coralnpu_xbar_cocotb

cocotb_test_suite(
    name = "coralnpu_xbar_cocotb",
    simulators = ["verilator", "vcs"],
    testcases = CORALNPU_XBAR_TESTCASES,
    testcases_vname = "CORALNPU_XBAR_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "CoralNPUXbarTestHarness",
        "waves": True,
        "seed": "42",
        "test_module": ["coralnpu_xbar_test.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
            "//coralnpu_test_utils:secded_golden",
        ],
        "size": "small",
    },
    verilator_model = "//hdl/chisel/src/soc:coralnpu_xbar_testharness_model",
    vcs_verilog_sources = ["//hdl/chisel/src/soc:coralnpu_xbar_testharness_cc_library_emit_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_coralnpu_chisel_subsystem_cocotb
CORALNPU_CHISEL_SUBSYSTEM_TESTCASES = [
    "test_tlul_passthrough",
    "test_program_execution_via_host",
    ("test_program_execution_via_spi", "large"),
    "test_ddr_access",
    ("test_ddr_access_via_spi", "large"),
    "test_tlul_width_bridge_bug_reproduction",
    "test_ibus_fetch_from_sram",
    "test_boot_addr_sram",
    "test_boot_addr_override",
    "test_timer_interrupt",
    "test_ddr_burst_pattern_repro",
    "test_software_interrupt",
    "test_plic",
]
# END_TESTCASES_FOR_coralnpu_chisel_subsystem_cocotb

py_library(
    name = "test_subsystem_lib",
    srcs = ["test_subsystem.py"],
    deps = [
        "//coralnpu_test_utils:TileLinkULInterface",
        "//coralnpu_test_utils:axi_slave",
        "//coralnpu_test_utils:backdoor",
        "//coralnpu_test_utils:spi_master",
        requirement("pyelftools"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

cocotb_test_suite(
    name = "coralnpu_chisel_subsystem_cocotb",
    simulators = ["verilator", "vcs"],
    testcases = CORALNPU_CHISEL_SUBSYSTEM_TESTCASES,
    testcases_vname = "CORALNPU_CHISEL_SUBSYSTEM_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "CoralNPUChiselSubsystemTestHarness",
        "waves": True,
        "seed": "42",
        "test_module": ["test_subsystem.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
            "//coralnpu_test_utils:axi_slave",
            "//coralnpu_test_utils:backdoor",
            "//coralnpu_test_utils:spi_master",
            requirement("pyelftools"),
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            "//tests/cocotb/rvv/arithmetics:rvv_add_int32_m1.elf",
            "//tests/cocotb:timer_interrupt_test.elf",
            "//tests/cocotb:ddr_test.elf",
            "//tests/cocotb:software_interrupt_test.elf",
            "//tests/cocotb:plic_test.elf",
        ],
        "default_testcase_size": "small",
        "size": "enormous",
    },
    verilator_model = "//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_model",
    vcs_verilog_sources = ["//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_cc_library_emit_verilog"],
    vcs_data = [
        "//hdl/verilog:dpi_files",
        "//tests/cocotb/rvv/arithmetics:rvv_add_int32_m1.elf",
        "//tests/cocotb:timer_interrupt_test.elf",
        "//tests/cocotb:ddr_test.elf",
        "//tests/cocotb:software_interrupt_test.elf",
        "//tests/cocotb:plic_test.elf",
    ],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
)

# BEGIN_TESTCASES_FOR_spi_master_cocotb
SPI_MASTER_TESTCASES = [
    "test_spi_master_basic_tx",
    "test_spi_master_half_duplex_rx",
    "test_spi_master_half_duplex_tx",
]
# END_TESTCASES_FOR_spi_master_cocotb

cocotb_test_suite(
    name = "spi_master_cocotb",
    simulators = ["verilator", "vcs"],
    testcases = SPI_MASTER_TESTCASES,
    testcases_vname = "SPI_MASTER_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "CoralNPUChiselSubsystemTestHarness",
        "waves": True,
        "seed": "42",
        "test_module": ["test_spi_master.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
        ],
        "default_testcase_size": "small",
        "size": "medium",
    },
    verilator_model = "//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_model",
    vcs_verilog_sources = ["//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_cc_library_emit_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_dma_integration_cocotb
DMA_INTEGRATION_TESTCASES = [
    "test_dma_csr_access",
    "test_dma_mem_to_mem",
    "test_dma_descriptor_chain",
]
# END_TESTCASES_FOR_dma_integration_cocotb

cocotb_test_suite(
    name = "dma_integration_cocotb",
    simulators = ["verilator", "vcs"],
    testcases = DMA_INTEGRATION_TESTCASES,
    testcases_vname = "DMA_INTEGRATION_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "CoralNPUChiselSubsystemTestHarness",
        "waves": True,
        "seed": "42",
        "test_module": ["test_dma_integration.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
        ],
        "default_testcase_size": "small",
        "size": "medium",
    },
    verilator_model = "//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_model",
    vcs_verilog_sources = ["//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_cc_library_emit_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

# BEGIN_TESTCASES_FOR_gpio_integration_cocotb
GPIO_INTEGRATION_TESTCASES = [
    "test_gpio_integration",
]
# END_TESTCASES_FOR_gpio_integration_cocotb

cocotb_test_suite(
    name = "gpio_integration_cocotb",
    simulators = ["verilator", "vcs"],
    testcases = GPIO_INTEGRATION_TESTCASES,
    testcases_vname = "GPIO_INTEGRATION_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "CoralNPUChiselSubsystemTestHarness",
        "waves": True,
        "seed": "42",
        "test_module": ["test_gpio_integration.py"],
        "deps": [
            "//coralnpu_test_utils:TileLinkULInterface",
        ],
        "default_testcase_size": "small",
        "size": "medium",
    },
    verilator_model = "//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_model",
    vcs_verilog_sources = ["//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_cc_library_emit_verilog"],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_defines = VCS_DEFINES,
    vcs_data = ["//hdl/verilog:dpi_files"],
)

cocotb_test_suite(
    name = "coralnpu_chisel_subsystem_highmem_cocotb_test_freertos",
    simulators = ["verilator"],
    testcases = ["test_freertos"],
    testcases_vname = "FREERTOS_TESTCASE",
    tests_kwargs = {
        "hdl_toplevel": "CoralNPUChiselSubsystemHighmemTestHarness",
        "waves": True,
        "seed": "42",
        "test_module": ["test_freertos.py"],
        "deps": [
            ":test_subsystem_lib",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            "//tests/cocotb/freertos_app:freertos_app.elf",
        ],
        "size": "large",
    },
    verilator_model = "//hdl/chisel/src/soc:coralnpu_chisel_subsystem_highmem_testharness_model",
)
