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

load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_pkg//:pkg.bzl", "pkg_zip")
load("//rules:coco_tb.bzl", "vcs_cocotb_model", "vcs_test_macro_smoke_test", "verilator_cocotb_model")
load("//rules:coralflow_test.bzl", "coralflow_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VERILATOR_BUILD_ARGS",
)
load("//tests/cocotb:wfi_targets.bzl", "get_wfi_slot_targets")

package(default_visibility = ["//visibility:public"])

COCOTB_TEST_BINARY_TARGETS = glob(["**/*.elf"]) + glob(["**/*.o"]) + [
    ":align_test.elf",
    ":csr_illegal_write_test.elf",
    ":spi_exec_test.elf",
    ":fcsr_frm_hazard_test.elf",
    ":rvv_frm_hazard_test.elf",
    ":frm_test.elf",
    ":float_csr_interlock_test.elf",
    ":float_hazard_tests.elf",
    ":finish_txn_before_halt.elf",
    ":math.elf",
    ":minstret_test.elf",
    ":misa_test.elf",
    ":stress_test.elf",
    ":retire_buffer_full_illegal_inst.elf",
    ":cf_fault_retire_test.elf",
    ":unreachable_prefetch_fault.elf",
    ":vector_store_fault.elf",
    ":wfi_slot_0.elf",
    ":wfi_slot_1.elf",
    ":wfi_slot_2.elf",
    ":wfi_slot_3.elf",
    ":zfbfmin_test.elf",
    ":zvfbf_test.elf",
    ":rvv_fflags_test.elf",
    ":rvv_vsetvli_keep_vl_test.elf",
    ":mstatus_vs_fs_dirty_test.elf",
    ":fencei_test.elf",
    "//tests/cocotb/coralnpu_isa:coralnpu_isa_tests",
    "//tests/cocotb/exceptions:elf_files",
    "//third_party/riscv-tests:all_files",
    ":csr_behavior.elf",
]

VCS_COMMON_DATA = [
    ":xprop.cfg",
    "@coralnpu_hw//hdl/verilog:dpi_files",
]

verilator_cocotb_model(
    name = "core_mini_axi_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "CoreMiniAxi",
    trace = False,
    verilog_source = "//hdl/chisel/src/coralnpu:CoreMiniAxi.sv",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

verilator_cocotb_model(
    name = "rvv_core_mini_axi_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "RvvCoreMiniAxi",
    trace = False,
    verilog_source = "//hdl/chisel/src/coralnpu:RvvCoreMiniAxi.sv",
    vlt_tpl = "//coralnpu_test_utils:dispatch.vlt.tpl",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

verilator_cocotb_model(
    name = "rvv_core_mini_axi_openroad_arithmetic_model",
    cflags = VERILATOR_BUILD_ARGS + [
        "-DCORALNPU_STRUCTURAL_DATAPATH=1",
    ],
    hdl_toplevel = "RvvCoreMiniAxi",
    trace = False,
    verilog_source = "//hdl/chisel/src/coralnpu:RvvCoreMiniAxi.sv",
    vlt_tpl = "//coralnpu_test_utils:dispatch.vlt.tpl",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

verilator_cocotb_model(
    name = "rvv_core_mini_highmem_axi_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "RvvCoreMiniHighmemAxi",
    trace = False,
    verilog_source = "//hdl/chisel/src/coralnpu:RvvCoreMiniHighmemAxi.sv",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

verilator_cocotb_model(
    name = "rvv_core_mini_itcm512kb_dtcm512kb_axi_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
    trace = False,
    verilog_source = "//hdl/chisel/src/coralnpu:RvvCoreMini_ITCM512KB_DTCM512KBAxi.sv",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

# VME (Zvt) variant. Adds -DZVT_ON so the SystemVerilog `RVVConfigState`
# struct gets the matrix-extension fields it needs.
verilator_cocotb_model(
    name = "vme_core_mini_axi_model",
    cflags = VERILATOR_BUILD_ARGS + [
        "-DZVT_ON",
        "-DZVTBF16FMM_ON",
    ],
    hdl_toplevel = "VmeCoreMiniAxi",
    trace = False,
    verilog_source = "//hdl/chisel/src/coralnpu:VmeCoreMiniAxi.sv",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

vcs_cocotb_model(
    name = "core_mini_axi_vcs_model",
    build_args = VCS_BUILD_ARGS,
    data = VCS_COMMON_DATA,
    defines = VCS_DEFINES,
    hdl_toplevel = "CoreMiniAxi",
    tags = [
        "manual",
        "rtl",
        "vcs",
    ],
    verilog_sources = ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
)

vcs_cocotb_model(
    name = "rvv_core_mini_axi_vcs_model",
    build_args = VCS_BUILD_ARGS,
    data = VCS_COMMON_DATA,
    defines = VCS_DEFINES,
    hdl_toplevel = "RvvCoreMiniAxi",
    tags = [
        "manual",
        "rtl",
        "vcs",
    ],
    verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
)

vcs_cocotb_model(
    name = "rvv_core_mini_highmem_axi_vcs_model",
    build_args = VCS_BUILD_ARGS,
    data = VCS_COMMON_DATA,
    defines = VCS_DEFINES,
    hdl_toplevel = "RvvCoreMiniHighmemAxi",
    tags = [
        "manual",
        "rtl",
        "vcs",
    ],
    verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library_verilog"],
)

vcs_cocotb_model(
    name = "rvv_core_mini_itcm512kb_dtcm512kb_axi_vcs_model",
    build_args = VCS_BUILD_ARGS,
    data = VCS_COMMON_DATA,
    defines = VCS_DEFINES,
    hdl_toplevel = "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
    tags = [
        "manual",
        "rtl",
        "vcs",
    ],
    verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_itcm512kb_dtcm512kb_axi_cc_library_verilog"],
)

vcs_cocotb_model(
    name = "vme_core_mini_axi_vcs_model",
    build_args = VCS_BUILD_ARGS,
    data = VCS_COMMON_DATA,
    defines = dict(
        VCS_DEFINES,
        ZVTBF16FMM_ON = "",
        ZVT_ON = "",
    ),
    hdl_toplevel = "VmeCoreMiniAxi",
    tags = [
        "manual",
        "rtl",
        "vcs",
    ],
    verilog_sources = ["//hdl/chisel/src/coralnpu:vme_core_mini_axi_cc_library_verilog"],
)

# BEGIN_TESTCASES_FOR_core_mini_axi_sim_cocotb
CORE_MINI_AXI_SIM_TESTCASES = [
    "core_mini_axi_basic_write_read_memory",
    "core_mini_axi_run_wfi_in_all_slots",
    "core_mini_axi_slow_bready",
    "core_mini_axi_write_read_memory_stress_test",
    "core_mini_axi_master_write_alignment",
    "core_mini_axi_finish_txn_before_halt_test",
    "core_mini_axi_riscv_tests",
    "core_mini_axi_riscv_dv",
    "core_mini_axi_csr_test",
    "core_mini_axi_csr_illegal_write_test",
    "core_mini_axi_exceptions_test",
    "core_mini_axi_coralnpu_isa_test",
    "core_mini_axi_rand_instr_test",
    "core_mini_axi_burst_types_test",
    "core_mini_axi_float_csr_test",
    "core_mini_axi_float_hazard_test",
    "unreachable_prefetch_fault",
    "core_mini_axi_retire_buffer_full_illegal_inst_test",
    "core_mini_axi_cf_fault_retire_test",
    "core_mini_axi_frm_test",
    "core_mini_axi_fcsr_frm_hazard_test",
    "core_mini_axi_backdoor_load_test",
    "core_mini_axi_minstret_test",
    "fencei_test",
    "core_mini_axi_misa_test",
    "core_mini_axi_wrap_burst_test",
    "core_mini_axi_csr_behavior_test",
]
# END_TESTCASES_FOR_core_mini_axi_sim_cocotb

# BEGIN_TESTCASES_FOR_rvv_core_mini_axi_sim_cocotb
RVV_CORE_MINI_AXI_SIM_TESTCASES = [
    "core_mini_axi_basic_write_read_memory",
    "core_mini_axi_run_wfi_in_all_slots",
    "core_mini_axi_slow_bready",
    "core_mini_axi_write_read_memory_stress_test",
    "core_mini_axi_master_write_alignment",
    "core_mini_axi_finish_txn_before_halt_test",
    "core_mini_axi_riscv_tests",
    "core_mini_axi_riscv_dv",
    "core_mini_axi_csr_test",
    "core_mini_axi_csr_illegal_write_test",
    "core_mini_axi_exceptions_test",
    "rvv_exceptions_test",
    "core_mini_axi_coralnpu_isa_test",
    "core_mini_axi_rand_instr_test",
    "core_mini_axi_burst_types_test",
    "core_mini_axi_float_csr_test",
    "core_mini_axi_float_hazard_test",
    "unreachable_prefetch_fault",
    "core_mini_axi_retire_buffer_full_illegal_inst_test",
    "core_mini_axi_cf_fault_retire_test",
    "core_mini_axi_frm_test",
    "core_mini_axi_fcsr_frm_hazard_test",
    "rvv_frm_hazard_test",
    "core_mini_axi_backdoor_load_test",
    "fencei_test",
    "core_mini_axi_misa_test",
    "rvv_misa_test",
    "core_mini_axi_wrap_burst_test",
]
# END_TESTCASES_FOR_rvv_core_mini_axi_sim_cocotb

CORE_MINI_AXI_SIM_DEPS = [
    "//coralnpu_test_utils:core_mini_axi_sim_interface",
    requirement("tqdm"),
    "@bazel_tools//tools/python/runfiles",
]

coralflow_test(
    name = "core_mini_axi_sim_cocotb",
    size = "large",
    srcs = ["core_mini_axi_sim.py"],
    data = COCOTB_TEST_BINARY_TARGETS,
    hdl_toplevel = "CoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    testcases = CORE_MINI_AXI_SIM_TESTCASES,
    deps = CORE_MINI_AXI_SIM_DEPS,
)

coralflow_test(
    name = "rvv_core_mini_axi_sim_cocotb",
    size = "enormous",
    srcs = ["core_mini_axi_sim.py"],
    data = COCOTB_TEST_BINARY_TARGETS,
    hdl_toplevel = "RvvCoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    testcases = RVV_CORE_MINI_AXI_SIM_TESTCASES,
    deps = CORE_MINI_AXI_SIM_DEPS,
)

COCOTB_DEBUG_TEST_BINARY_TARGETS = [
    ":debug_trigger_test.elf",
    ":fptr.elf",
    ":loop.elf",
    ":math.elf",
    ":noop.elf",
    ":registers.elf",
]

CORE_MINI_AXI_DEBUG_DEPS = [
    "//coralnpu_test_utils:core_mini_axi_sim_interface",
    "//coralnpu_test_utils:core_mini_axi_pyocd_gdbserver",
    "@bazel_tools//tools/python/runfiles",
]

coralflow_test(
    name = "core_mini_axi_debug_cocotb",
    size = "large",
    srcs = ["core_mini_axi_debug.py"],
    data = COCOTB_DEBUG_TEST_BINARY_TARGETS,
    hdl_toplevel = "CoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    deps = CORE_MINI_AXI_DEBUG_DEPS,
)

coralflow_test(
    name = "rvv_core_mini_axi_debug_cocotb",
    size = "large",
    srcs = ["core_mini_axi_debug.py"],
    data = COCOTB_DEBUG_TEST_BINARY_TARGETS,
    hdl_toplevel = "RvvCoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    deps = CORE_MINI_AXI_DEBUG_DEPS,
)

coralflow_test(
    name = "rvv_assembly_cocotb_test",
    size = "large",
    srcs = ["rvv_assembly_cocotb_test.py"],
    data = ["//tests/cocotb/rvv:rvv_assem_tests"],
    hdl_toplevel = "RvvCoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    deps = [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        "//coralnpu_test_utils:dispatch_verifier",
        "//coralnpu_test_utils:rvv_type_util",
        requirement("tqdm"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralflow_test(
    name = "rvv_assembly_openroad_arithmetic_test",
    size = "large",
    srcs = ["rvv_assembly_cocotb_test.py"],
    data = ["//tests/cocotb/rvv:rvv_assem_tests"],
    hdl_toplevel = "RvvCoreMiniAxi",
    targets = [
        "verilator",
    ],
    verilator_model = ":rvv_core_mini_axi_openroad_arithmetic_model",
    deps = [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        "//coralnpu_test_utils:dispatch_verifier",
        "//coralnpu_test_utils:rvv_type_util",
        requirement("tqdm"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "loop",
    srcs = [
        "loop.S",
    ],
)

coralnpu_v2_binary(
    name = "align_test",
    srcs = [
        "align_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "rvv_vsetvli_keep_vl_test",
    srcs = [
        "rvv_vsetvli_keep_vl_test.S",
    ],
)

# Generate WFI targets for each slot (for elf generation)
template_rule(
    coralnpu_v2_binary,
    get_wfi_slot_targets(),
)

coralflow_test(
    name = "rvv_highmem_tests",
    size = "large",
    srcs = ["rvv_highmem_sim.py"],
    data = [
        ":wfi_slot_0_highmem.elf",
        ":wfi_slot_1_highmem.elf",
        ":wfi_slot_2_highmem.elf",
        ":wfi_slot_3_highmem.elf",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_highmem.elf",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_highmem.elf",
    ],
    hdl_toplevel = "RvvCoreMiniHighmemAxi",
    highmem = True,
    targets = [
        "verilator",
        "vcs",
    ],
    deps = [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        requirement("tqdm"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralflow_test(
    name = "rvv_itcm512kb_dtcm512kb_tests",
    size = "large",
    srcs = ["rvv_itcm512kb_dtcm512kb_sim.py"],
    data = [
        ":wfi_slot_0_itcm512kb_dtcm512kb.elf",
        ":wfi_slot_1_itcm512kb_dtcm512kb.elf",
        ":wfi_slot_2_itcm512kb_dtcm512kb.elf",
        ":wfi_slot_3_itcm512kb_dtcm512kb.elf",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_itcm512kb_dtcm512kb.elf",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_itcm512kb_dtcm512kb.elf",
    ],
    hdl_toplevel = "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    deps = [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        requirement("tqdm"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "finish_txn_before_halt",
    srcs = [
        "finish_txn_before_halt.cc",
    ],
)

coralnpu_v2_binary(
    name = "retire_buffer_full_illegal_inst",
    srcs = [
        "retire_buffer_full_illegal_inst.S",
    ],
)

coralnpu_v2_binary(
    name = "cf_fault_retire_test",
    srcs = [
        "cf_fault_retire_test.S",
    ],
)

coralnpu_v2_binary(
    name = "unreachable_prefetch_fault",
    srcs = [
        "unreachable_prefetch_fault.cc",
    ],
)

coralnpu_v2_binary(
    name = "stress_test",
    srcs = [
        "stress_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "timer_interrupt_test",
    srcs = [
        "timer_interrupt_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "software_interrupt_test",
    srcs = [
        "software_interrupt_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "plic_test",
    srcs = [
        "plic_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "debug_trigger_test",
    srcs = [
        "debug_trigger_test.S",
    ],
)

coralnpu_v2_binary(
    name = "csr_illegal_write_test",
    srcs = [
        "csr_illegal_write_test.S",
    ],
    crt = "",
    linkopts = ["-nostartfiles"],
)

coralnpu_v2_binary(
    name = "spi_exec_test",
    srcs = [
        "spi_exec_test.S",
    ],
    crt = "",
    linkopts = ["-nostartfiles"],
)

coralnpu_v2_binary(
    name = "float_csr_interlock_test",
    srcs = [
        "float_csr_interlock_test.S",
    ],
)

coralnpu_v2_binary(
    name = "float_hazard_tests",
    srcs = [
        "float_hazard_tests.S",
    ],
)

coralnpu_v2_binary(
    name = "fcsr_frm_hazard_test",
    srcs = ["fcsr_frm_hazard_test.cc"],
    copts = ["-std=c++20"],
)

coralnpu_v2_binary(
    name = "rvv_frm_hazard_test",
    srcs = ["rvv_frm_hazard_test.cc"],
    copts = ["-std=c++20"],
)

coralnpu_v2_binary(
    name = "frm_test",
    srcs = [
        "frm_test.cc",
    ],
    copts = [
        "-std=c++20",
    ],
)

coralnpu_v2_binary(
    name = "mstatus_vs_fs_dirty_test",
    srcs = [
        "mstatus_vs_fs_dirty_test.cc",
    ],
    copts = [
        "-std=c++20",
    ],
)

coralnpu_v2_binary(
    name = "fptr",
    srcs = [
        "fptr.cc",
    ],
)

coralnpu_v2_binary(
    name = "math",
    srcs = [
        "math.cc",
    ],
)

coralnpu_v2_binary(
    name = "noop",
    srcs = [
        "noop.cc",
    ],
)

coralnpu_v2_binary(
    name = "minstret_test",
    srcs = [
        "minstret_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "misa_test",
    srcs = [
        "misa_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "mcycle_test",
    srcs = [
        "mcycle_test.cc",
    ],
)

# Benchmark groups of //tests/cocotb:isa_cycle_bench. ITCM is 8 KiB, which is
# not enough room for every benchmarked instruction, so the benchmarks are
# split into one ELF per group. Must match the BENCH_LIST_<GROUP>() macros in
# isa_cycle_bench_defs.h, which isa_cycle_bench_test.py parses.
ISA_CYCLE_BENCH_GROUPS = [
    "SCALAR_ALU",
    "SCALAR_MEM",
    "SCALAR_CTRL",
    "SCALAR_FP",
    "VECTOR_INT_A",
    "VECTOR_INT_B",
    "VECTOR_MASK",
    "VECTOR_PERM",
    "VECTOR_MEM",
    "VECTOR_FP_A",
    "VECTOR_FP_B",
]

[
    coralnpu_v2_binary(
        name = "isa_cycle_bench_" + group.lower(),
        srcs = [
            "isa_cycle_bench.cc",
        ],
        hdrs = [
            "isa_cycle_bench_defs.h",
        ],
        defines = ["BENCH_GROUP=" + group],
    )
    for group in ISA_CYCLE_BENCH_GROUPS
]

# This test is used for baseline vector power analysis.
coralnpu_v2_binary(
    name = "nop_test",
    srcs = [
        "nop_test.cc",
    ],
)

coralnpu_v2_binary(
    name = "registers",
    srcs = [
        "registers.S",
    ],
)

coralnpu_v2_binary(
    name = "float_store",
    srcs = ["float_store.cc"],
)

coralnpu_v2_binary(
    name = "vector_store",
    srcs = ["vector_store.cc"],
)

coralnpu_v2_binary(
    name = "vector_store_fault",
    srcs = ["vector_store_fault.cc"],
)

coralnpu_v2_binary(
    name = "fencei_test",
    srcs = ["fencei_test.cc"],
)

coralnpu_v2_binary(
    name = "csr_behavior",
    srcs = ["csr_behavior.S"],
)

coralflow_test(
    name = "rvv_load_store_test",
    size = "enormous",
    srcs = ["rvv_load_store_test.py"],
    data = ["//tests/cocotb/rvv/load_store:rvv_load_store_tests"],
    hdl_toplevel = "RvvCoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    deps = [
        "//coralnpu_test_utils:rvv_type_util",
        "@bazel_tools//tools/python/runfiles",
        requirement("tqdm"),
    ],
)

coralflow_test(
    name = "vme_rvv_load_store_test",
    size = "enormous",
    srcs = ["rvv_load_store_test.py"],
    data = ["//tests/cocotb/rvv/load_store:rvv_load_store_tests"],
    hdl_toplevel = "VmeCoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    deps = [
        "//coralnpu_test_utils:rvv_type_util",
        "@bazel_tools//tools/python/runfiles",
        requirement("tqdm"),
    ],
)

coralflow_test(
    name = "rvv_arithmetic_cocotb_test",
    size = "large",
    srcs = ["rvv_arithmetic_cocotb_test.py"],
    data = [
        "//tests/cocotb/rvv/arithmetics:rvv_arith_tests",
    ],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
        requirement("tqdm"),
    ],
)

coralflow_test(
    name = "rvv_arithmetic_openroad_arithmetic_test",
    size = "large",
    srcs = ["rvv_arithmetic_cocotb_test.py"],
    data = [
        "//tests/cocotb/rvv/arithmetics:rvv_arith_tests",
    ],
    hdl_toplevel = "RvvCoreMiniAxi",
    targets = [
        "verilator",
    ],
    verilator_model = ":rvv_core_mini_axi_openroad_arithmetic_model",
    deps = [
        "@bazel_tools//tools/python/runfiles",
        requirement("tqdm"),
    ],
)

test_suite(
    name = "rvv_openroad_arithmetic_tests",
    tests = [
        ":rvv_arithmetic_openroad_arithmetic_test_verilator",
        ":rvv_assembly_openroad_arithmetic_test_verilator",
    ],
)

pkg_zip(
    name = "rvv_test_binaries",
    srcs = COCOTB_TEST_BINARY_TARGETS + [
        "//tests/cocotb/rvv/arithmetics:rvv_arith_tests",
        "//tests/cocotb/rvv/load_store:rvv_load_store_tests",
    ],
)

coralflow_test(
    name = "rvv_ml_ops_cocotb_test",
    size = "enormous",
    srcs = ["rvv_ml_ops_cocotb_test.py"],
    data = ["//tests/cocotb/rvv/ml_ops:rvv_mlop_tests"],
    exclude_testcases = {
        "uvm": ["core_mini_rvv_bf16_matmul_c_test"],
    },
    targets = [
        "verilator",
        "vcs",
        "uvm",
        "nexus_fpga",
    ],
    deps = [
        "//sw/utils:metrics",
        requirement("ml_dtypes"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralflow_test(
    name = "isa_cycle_bench_test",
    size = "large",
    srcs = ["isa_cycle_bench_test.py"],
    data = [
        "isa_cycle_bench_defs.h",
    ] + [
        ":isa_cycle_bench_%s.elf" % group.lower()
        for group in ISA_CYCLE_BENCH_GROUPS
    ],
    targets = [
        "verilator",
        "vcs",
        "uvm",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

# This test is used for baseline vector power analysis.
coralflow_test(
    name = "nop_stress_test",
    size = "large",
    srcs = ["nop_test.py"],
    elf = ":nop_test.elf",
    targets = [
        "verilator",
        "vcs",
        "npusim",
        "uvm",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "zvfbf_test",
    srcs = [
        "zvfbf_test.cc",
    ],
)

coralflow_test(
    name = "zvfbf_cocotb_test",
    size = "medium",
    srcs = ["zvfbf_test.py"],
    elf = ":zvfbf_test.elf",
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "rvv_fflags_test",
    srcs = [
        "rvv_fflags_test.cc",
    ],
)

coralflow_test(
    name = "rvv_fflags_cocotb_test",
    size = "medium",
    srcs = ["rvv_fflags_test.py"],
    elf = ":rvv_fflags_test.elf",
    targets = [
        "verilator",
        "vcs",
        "uvm",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralflow_test(
    name = "rvv_bf16_ops_cocotb_test",
    size = "medium",
    srcs = ["rvv_bf16_ops_cocotb_test.py"],
    data = [
        "//tests/cocotb/rvv/arithmetics:rvv_bf16_{}_{}.elf".format(op, lmul)
        for op in [
            "mac_vv",
            "mac_vf",
            "pipeline",
            "strided",
            "indexed",
        ]
        for lmul in [
            "mf2",
            "m1",
            "m2",
            "m4",
        ]
    ],
    targets = [
        "verilator",
        "vcs",
        "nexus_fpga",
    ],
    deps = [
        requirement("ml_dtypes"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "zfbfmin_test",
    srcs = [
        "zfbfmin_test.cc",
    ],
)

coralflow_test(
    name = "zfbfmin_cocotb_test",
    size = "medium",
    srcs = ["zfbfmin_test.py"],
    elf = ":zfbfmin_test.elf",
    targets = [
        "verilator",
        "vcs",
        "uvm",
        "nexus_fpga",
    ],
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralnpu_v2_binary(
    name = "ddr_test",
    srcs = [
        "ddr_test.cc",
    ],
)

coralflow_test(
    name = "rvv_highmem_tests_slow",
    size = "large",
    srcs = ["rvv_highmem_sim.py"],
    data = [
        ":wfi_slot_0_highmem.elf",
        ":wfi_slot_1_highmem.elf",
        ":wfi_slot_2_highmem.elf",
        ":wfi_slot_3_highmem.elf",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_highmem.elf",
        "//tests/cocotb/rvv/ml_ops:rvv_matmul_highmem.elf",
    ],
    hdl_toplevel = "RvvCoreMiniHighmemAxi",
    highmem = True,
    targets = [
        "verilator",
        "vcs",
    ],
    test_args = ["+CLOCK_NS=2.0"],
    deps = [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        requirement("tqdm"),
        "@bazel_tools//tools/python/runfiles",
    ],
)

coralflow_test(
    name = "core_mini_axi_sim_cocotb_slow",
    size = "large",
    srcs = ["core_mini_axi_sim.py"],
    data = COCOTB_TEST_BINARY_TARGETS,
    hdl_toplevel = "CoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    test_args = ["+CLOCK_NS=2.0"],
    testcases = CORE_MINI_AXI_SIM_TESTCASES,
    deps = CORE_MINI_AXI_SIM_DEPS,
)

coralflow_test(
    name = "rvv_core_mini_axi_sim_cocotb_slow",
    size = "enormous",
    srcs = ["core_mini_axi_sim.py"],
    data = COCOTB_TEST_BINARY_TARGETS,
    hdl_toplevel = "RvvCoreMiniAxi",
    targets = [
        "verilator",
        "vcs",
    ],
    test_args = ["+CLOCK_NS=2.0"],
    testcases = RVV_CORE_MINI_AXI_SIM_TESTCASES,
    deps = CORE_MINI_AXI_SIM_DEPS,
)

filegroup(
    name = "cocotb_test_binary_targets",
    srcs = COCOTB_TEST_BINARY_TARGETS,
)

exports_files([
    "core_mini_axi_sim.py",
    "coverage_exclude.cfg",
    "xprop.cfg",
    "rvv_ml_ops_cocotb_test.py",
    "rvv_flashattention_cocotb_test.py",
])

# Smoke test to prevent signature divergence between regular and split VCS flows.
vcs_test_macro_smoke_test(
    name = "vcs_flow_smoke_test",
    size = "small",
    timeout = "short",
    data = ["//tests/cocotb/rvv:rvv_assem_tests"],
    extra_env = ["TEST_VAR=smoke_value"],
    flaky = True,
    hdl_toplevel = "RvvCoreMiniAxi",
    local = True,
    seed = "12345",
    shard_count = 2,
    test_args = ["+CLOCK_NS=2.0"],
    test_module = ["rvv_assembly_cocotb_test.py"],
    testcase = ["test_addi"],
    verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    waves = False,
    deps = [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        "//coralnpu_test_utils:dispatch_verifier",
        "//coralnpu_test_utils/coralflow",
    ],
)
