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
load("@gemma_deps//:requirements.bzl", gemma_requirement = "requirement")
load("@rules_pkg//:pkg.bzl", "pkg_zip")
load("//rules:coco_tb.bzl", "cocotb_test_suite", "vcs_test_macro_smoke_test", "verilator_cocotb_model")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
    "VERILATOR_BUILD_ARGS",
)
load("//tests/cocotb:wfi_targets.bzl", "get_wfi_slot_targets")

package(default_visibility = ["//visibility:public"])

COCOTB_TEST_BINARY_TARGETS = glob(["**/*.elf"]) + glob(["**/*.o"]) + [
    ":align_test.elf",
    ":fcsr_frm_hazard_test.elf",
    ":rvv_frm_hazard_test.elf",
    ":frm_test.elf",
    ":float_csr_interlock_test.elf",
    ":float_hazard_tests.elf",
    ":finish_txn_before_halt.elf",
    ":math.elf",
    ":minstret_test.elf",
    ":stress_test.elf",
    ":unreachable_prefetch_fault.elf",
    ":vector_store_fault.elf",
    ":wfi_slot_0.elf",
    ":wfi_slot_1.elf",
    ":wfi_slot_2.elf",
    ":wfi_slot_3.elf",
    ":zfbfmin_test.elf",
    ":zvfbf_test.elf",
    "//tests/cocotb/coralnpu_isa:coralnpu_isa_tests",
    "//tests/cocotb/exceptions:elf_files",
    "//third_party/riscv-tests:all_files",
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
    cflags = VERILATOR_BUILD_ARGS + ["-DZVT_ON"],
    hdl_toplevel = "VmeCoreMiniAxi",
    trace = False,
    verilog_source = "//hdl/chisel/src/coralnpu:VmeCoreMiniAxi.sv",
    deps = [
        "//hdl/verilog:sram_backdoor",
    ],
)

# BEGIN_TESTCASES_FOR_core_mini_axi_sim_cocotb
CORE_MINI_AXI_SIM_TESTCASES = [
    ("core_mini_axi_basic_write_read_memory", "large"),
    "core_mini_axi_run_wfi_in_all_slots",
    "core_mini_axi_slow_bready",
    ("core_mini_axi_write_read_memory_stress_test", "large"),
    "core_mini_axi_master_write_alignment",
    "core_mini_axi_finish_txn_before_halt_test",
    "core_mini_axi_riscv_tests",
    "core_mini_axi_riscv_dv",
    "core_mini_axi_csr_test",
    "core_mini_axi_exceptions_test",
    "core_mini_axi_coralnpu_isa_test",
    ("core_mini_axi_rand_instr_test", "large"),
    ("core_mini_axi_burst_types_test", "large"),
    "core_mini_axi_float_csr_test",
    "core_mini_axi_float_hazard_test",
    "unreachable_prefetch_fault",
    "core_mini_axi_frm_test",
    "core_mini_axi_fcsr_frm_hazard_test",
    "core_mini_axi_backdoor_load_test",
    "core_mini_axi_minstret_test",
]
# END_TESTCASES_FOR_core_mini_axi_sim_cocotb

# BEGIN_TESTCASES_FOR_rvv_core_mini_axi_sim_cocotb
RVV_CORE_MINI_AXI_SIM_TESTCASES = [
    ("core_mini_axi_basic_write_read_memory", "enormous"),
    "core_mini_axi_run_wfi_in_all_slots",
    "core_mini_axi_slow_bready",
    "core_mini_axi_write_read_memory_stress_test",
    "core_mini_axi_master_write_alignment",
    "core_mini_axi_finish_txn_before_halt_test",
    "core_mini_axi_riscv_tests",
    "core_mini_axi_riscv_dv",
    ("core_mini_axi_csr_test", "large"),
    "core_mini_axi_exceptions_test",
    "rvv_exceptions_test",
    "core_mini_axi_coralnpu_isa_test",
    ("core_mini_axi_rand_instr_test", "large"),
    ("core_mini_axi_burst_types_test", "large"),
    "core_mini_axi_float_csr_test",
    "core_mini_axi_float_hazard_test",
    "unreachable_prefetch_fault",
    "core_mini_axi_frm_test",
    "core_mini_axi_fcsr_frm_hazard_test",
    "rvv_frm_hazard_test",
    "core_mini_axi_backdoor_load_test",
]
# END_TESTCASES_FOR_rvv_core_mini_axi_sim_cocotb

CORE_MINI_AXI_SIM_COMMON_TEST_KWARGS = {
    "waves": False,
    "seed": "42",
    "test_module": ["core_mini_axi_sim.py"],
    "deps": [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        "//coralnpu_test_utils:sim_test_fixture",
        requirement("tqdm"),
        "@bazel_tools//tools/python/runfiles",
    ],
    "data": COCOTB_TEST_BINARY_TARGETS,
    "size": "enormous",
}

template_rule(
    cocotb_test_suite,
    {
        "core_mini_axi_sim_cocotb": {
            "tests_kwargs": dict(
                CORE_MINI_AXI_SIM_COMMON_TEST_KWARGS,
                size = "enormous",
                default_testcase_size = "medium",
                hdl_toplevel = "CoreMiniAxi",
            ),
            "vcs_verilog_sources": ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
            "verilator_model": ":core_mini_axi_model",
            "testcases": CORE_MINI_AXI_SIM_TESTCASES,
            "testcases_vname": "CORE_MINI_AXI_SIM_TESTCASES",
        },
        "rvv_core_mini_axi_sim_cocotb": {
            "tests_kwargs": dict(
                CORE_MINI_AXI_SIM_COMMON_TEST_KWARGS,
                size = "enormous",
                default_testcase_size = "medium",
                hdl_toplevel = "RvvCoreMiniAxi",
            ),
            "vcs_verilog_sources": ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
            "verilator_model": ":rvv_core_mini_axi_model",
            "testcases": RVV_CORE_MINI_AXI_SIM_TESTCASES,
            "testcases_vname": "RVV_CORE_MINI_AXI_SIM_TESTCASES",
        },
    },
    simulators = [
        "verilator",
        "vcs",
    ],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = COCOTB_TEST_BINARY_TARGETS + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
)

# BEGIN_TESTCASES_FOR_core_mini_axi_debug_cocotb
CORE_MINI_AXI_DEBUG_TESTCASES = [
    "core_mini_axi_debug_trigger_match",
    "core_mini_axi_debug_gdbserver",
    "core_mini_axi_debug_dmactive",
    "core_mini_axi_debug_probe_impl",
    "core_mini_axi_debug_ndmreset",
    "core_mini_axi_debug_halt_resume",
    "core_mini_axi_debug_hartsel",
    "core_mini_axi_debug_abstract_access_registers",
    "core_mini_axi_debug_abstract_access_nonexistent_register",
    "core_mini_axi_debug_single_step",
    "core_mini_axi_debug_breakpoint",
    "core_mini_axi_debug_scalar_registers",
]
# END_TESTCASES_FOR_core_mini_axi_debug_cocotb

# BEGIN_TESTCASES_FOR_rvv_assembly_cocotb_test
RVV_ASSEMBLY_TESTCASES = [
    "core_mini_rvv_load",
    "core_mini_rvv_add",
    "core_mini_vstart_store",
    "core_mini_vcsr_test",
    "core_mini_viota_test",
    "core_mini_vfirst_test",
    "core_mini_vcpop_exception_test",
    "core_mini_vcpop_test",
    "core_mini_vcompress_test",
    "core_mini_vmsbf_test",
    "core_mini_vmsof_test",
    "core_mini_vmsif_test",
    "core_mini_vill_test",
    "core_mini_vl_test",
    "vsetvl_test",
    "vslideup_test",
    "vslidedown_test",
    "vslide1up_test",
    "vslide1down_test",
    "vgather_test",
]
# END_TESTCASES_FOR_rvv_assembly_cocotb_test

# BEGIN_TESTCASES_FOR_rvv_load_store_test
RVV_LOAD_STORE_TESTCASES = [
    "load_store_bits",
    "load_store_whole_register_test",
    "load_unit_masked",
    "load_unit_all_vtypes_test",
    ("load_strided_all_vtypes_test", "large"),
    "load8_index8",
    "load8_index8_seg",
    "load8_index16",
    ("load8_index16_seg", "large"),
    "load8_index32",
    ("load8_index32_seg", "large"),
    "load8_seg_unit",
    "load8_stride0_m1",
    "load8_stride0strict_m1",
    "load8_stride2_m1",
    "load8_stride2_m1_partial",
    "load8_stride2_mf4",
    "load16_index8",
    "load16_index8_seg",
    ("load16_index16_seg", "large"),
    ("load16_index32_seg", "large"),
    "load16_seg_unit",
    "load16_stride4_m1",
    "load16_stride4_m1_partial",
    "load16_stride4_mf2",
    "load32_index8",
    "load32_index8_seg",
    "load32_index16_seg",
    "load32_index32_seg",
    "load32_seg_unit",
    "load32_stride8_m1",
    "load32_stride8_m1_partial",
    "load_store8_unit_m2",
    "load_store16_unit_m2",
    "load_store32_unit_m2",
    "load8_segment2_stride6_m1",
    "load16_segment2_stride6_m1",
    "store_unit_masked",
    "store_unit_all_vtypes_test",
    ("store_strided_all_vtypes_test", "large"),
    "store8_index8",
    "store8_index8_seg",
    "store8_index16",
    "store8_index32",
    "store16_index8",
    "store16_index16",
    "store16_index32",
    "store32_index8",
    "store32_index16",
    "store32_index32",
    "store8_seg_unit",
    "store16_seg_unit",
    "store32_seg_unit",
    "load_store8_fault",
    "load_store8_test",
]
# END_TESTCASES_FOR_rvv_load_store_test

# BEGIN_TESTCASES_FOR_rvv_arithmetic_cocotb_test
RVV_ARITHMETIC_TESTCASES = [
    "arithmetic_m1_vanilla_ops",
    "float32_arithmetic_m1_vanilla_ops",
    "reduction_m1_vanilla_ops",
    "float32_reduction_m1_vanilla_ops",
    "reduction_m1_failure_ops",
    "widen_math_ops_test_impl",
    "vnclip_test",
    "vnclip_vxsat_test",
    "vnclipu_test",
    "vnsra_test",
    "vnsrl_test",
    "ternary_op_vx",
    "comparison_op_vx",
    "comparison_op_vv",
    "carry_op_vx",
    "merge_op_vv",
    "widen_wide_math_ops_test",
    "extension_op_test",
    "immediate_op_test",
    "float_comparison_op",
    "float_misc_op",
    "float_convert_op",
    ("binary_op_vx", "large"),
]
# END_TESTCASES_FOR_rvv_arithmetic_cocotb_test

# BEGIN_TESTCASES_FOR_highmem_test
HIGHMEM_TESTCASES = [
    "core_mini_axi_run_wfi_in_all_slots_highmem",
    "core_mini_rvv_matmul_test",
    "core_mini_axi_basic_write_read_memory",
]
# END_TESTCASES_FOR_highmem_test

COCOTB_DEBUG_TEST_BINARY_TARGETS = [
    ":debug_trigger_test.elf",
    ":fptr.elf",
    ":loop.elf",
    ":math.elf",
    ":noop.elf",
    ":registers.elf",
]

CORE_MINI_AXI_DEBUG_COMMON_TEST_KWARGS = {
    "deps": [
        "//coralnpu_test_utils:core_mini_axi_sim_interface",
        "//coralnpu_test_utils:core_mini_axi_pyocd_gdbserver",
        "@bazel_tools//tools/python/runfiles",
    ],
    "waves": False,
    "seed": "42",
    "test_module": ["core_mini_axi_debug.py"],
    "data": COCOTB_DEBUG_TEST_BINARY_TARGETS,
    "default_testcase_size": "medium",
    "size": "medium",
}

template_rule(
    cocotb_test_suite,
    {
        "core_mini_axi_debug_cocotb": {
            "tests_kwargs": dict(
                CORE_MINI_AXI_DEBUG_COMMON_TEST_KWARGS,
                hdl_toplevel = "CoreMiniAxi",
            ),
            "vcs_verilog_sources": ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
            "verilator_model": ":core_mini_axi_model",
        },
        "rvv_core_mini_axi_debug_cocotb": {
            "tests_kwargs": dict(
                CORE_MINI_AXI_DEBUG_COMMON_TEST_KWARGS,
                hdl_toplevel = "RvvCoreMiniAxi",
            ),
            "vcs_verilog_sources": ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
            "verilator_model": ":rvv_core_mini_axi_model",
        },
    },
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = CORE_MINI_AXI_DEBUG_TESTCASES,
    testcases_vname = "CORE_MINI_AXI_DEBUG_TESTCASES",
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = COCOTB_DEBUG_TEST_BINARY_TARGETS + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
)

cocotb_test_suite(
    name = "rvv_assembly_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = RVV_ASSEMBLY_TESTCASES,
    testcases_vname = "RVV_ASSEMBLY_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["rvv_assembly_cocotb_test.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:rvv_type_util",
            "//coralnpu_test_utils:sim_test_fixture",
            requirement("tqdm"),
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": ["//tests/cocotb/rvv:rvv_assem_tests"],
        "default_testcase_size": "medium",
        "size": "medium",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["//tests/cocotb/rvv:rvv_assem_tests"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = ":rvv_core_mini_axi_model",
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

# Generate WFI targets for each slot (for elf generation)
template_rule(
    coralnpu_v2_binary,
    get_wfi_slot_targets(),
)

cocotb_test_suite(
    name = "rvv_highmem_tests",
    simulators = [
        "verilator",
    ],
    testcases = HIGHMEM_TESTCASES,
    testcases_vname = "HIGHMEM_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["rvv_highmem_sim.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            requirement("tqdm"),
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":wfi_slot_0_highmem.elf",
            ":wfi_slot_1_highmem.elf",
            ":wfi_slot_2_highmem.elf",
            ":wfi_slot_3_highmem.elf",
            "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_highmem.elf",
            "//tests/cocotb/rvv/ml_ops:rvv_matmul_highmem.elf",
        ],
        "size": "large",
    },
    verilator_model = ":rvv_core_mini_highmem_axi_model",
)

cocotb_test_suite(
    name = "rvv_itcm512kb_dtcm512kb_tests",
    simulators = [
        "verilator",
    ],
    testcases = [
        "core_mini_axi_run_wfi_in_all_slots_itcm512kb_dtcm512kb",
        "core_mini_rvv_matmul_test",
        "core_mini_axi_basic_write_read_memory",
    ],
    testcases_vname = "ITCM512KB_DTCM512KB_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["rvv_itcm512kb_dtcm512kb_sim.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            requirement("tqdm"),
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":wfi_slot_0_itcm512kb_dtcm512kb.elf",
            ":wfi_slot_1_itcm512kb_dtcm512kb.elf",
            ":wfi_slot_2_itcm512kb_dtcm512kb.elf",
            ":wfi_slot_3_itcm512kb_dtcm512kb.elf",
            "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_itcm512kb_dtcm512kb.elf",
            "//tests/cocotb/rvv/ml_ops:rvv_matmul_itcm512kb_dtcm512kb.elf",
        ],
        "size": "large",
    },
    verilator_model = ":rvv_core_mini_itcm512kb_dtcm512kb_axi_model",
)

coralnpu_v2_binary(
    name = "finish_txn_before_halt",
    srcs = [
        "finish_txn_before_halt.cc",
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
    name = "mcycle_test",
    srcs = [
        "mcycle_test.cc",
    ],
)

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

cocotb_test_suite(
    name = "rvv_load_store_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = RVV_LOAD_STORE_TESTCASES,
    testcases_vname = "RVV_LOAD_STORE_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["rvv_load_store_test.py"],
        "deps": [
            "//coralnpu_test_utils:rvv_type_util",
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
            requirement("tqdm"),
        ],
        "data": ["//tests/cocotb/rvv/load_store:rvv_load_store_tests"],
        "default_testcase_size": "medium",
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["//tests/cocotb/rvv/load_store:rvv_load_store_tests"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = ":rvv_core_mini_axi_model",
)

cocotb_test_suite(
    name = "rvv_arithmetic_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = RVV_ARITHMETIC_TESTCASES,
    testcases_vname = "RVV_ARITHMETIC_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["rvv_arithmetic_cocotb_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
            requirement("tqdm"),
        ],
        "data": [
            "//tests/cocotb/rvv/arithmetics:rvv_arith_tests",
        ],
        "default_testcase_size": "medium",
        "size": "large",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["//tests/cocotb/rvv/arithmetics:rvv_arith_tests"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = ":rvv_core_mini_axi_model",
)

pkg_zip(
    name = "rvv_test_binaries",
    srcs = [
        "//tests/cocotb/rvv/arithmetics:rvv_arith_tests",
        "//tests/cocotb/rvv/load_store:rvv_load_store_tests",
    ],
)

# BEGIN_TESTCASES_FOR_rvv_ml_ops_cocotb_test
RVV_ML_OPS_TESTCASES = [
    "core_mini_rvv_matmul_c_test",
    "core_mini_rvv_matmul_asm_test",
    "core_mini_rvv_float_matmul_c_test",
    "core_mini_rvv_float_matmul_asm_test",
    "core_mini_rvv_float_matmul_optimized_c_test",
]
# END_TESTCASES_FOR_rvv_ml_ops_cocotb_test

py_binary(
    name = "dump_gemma_tensors",
    srcs = ["dump_gemma_tensors.py"],
    tags = ["manual"],
    deps = [
        gemma_requirement("torch"),
        gemma_requirement("transformers"),
        gemma_requirement("accelerate"),
        gemma_requirement("numpy"),
    ],
)

genrule(
    name = "generate_gemma_tensors",
    outs = [
        "gemma_q.npy",
        "gemma_k.npy",
        "gemma_v.npy",
        "gemma_o.npy",
    ],
    cmd = "$(location :dump_gemma_tensors) --out_dir $(RULEDIR)",
    local = True,
    tags = ["manual"],
    tools = [":dump_gemma_tensors"],
)

cocotb_test_suite(
    name = "rvv_ml_ops_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = RVV_ML_OPS_TESTCASES,
    testcases_vname = "RVV_ML_OPS_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["rvv_ml_ops_cocotb_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": ["//tests/cocotb/rvv/ml_ops:rvv_mlop_tests"],
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = ["//tests/cocotb/rvv/ml_ops:rvv_mlop_tests"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = ":rvv_core_mini_axi_model",
)

# This test is used for baseline vector power analysis.
cocotb_test_suite(
    name = "nop_stress_test",
    simulators = [
        "verilator",
    ],
    testcases = [
        "nop_stress_test",
    ],
    testcases_vname = "NOP_STRESS_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["nop_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":nop_test.elf",
        ],
        "size": "medium",
    },
    verilator_model = ":rvv_core_mini_axi_model",
)

coralnpu_v2_binary(
    name = "zvfbf_test",
    srcs = [
        "zvfbf_test.cc",
    ],
)

cocotb_test_suite(
    name = "zvfbf_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "zvfbf_test",
    ],
    testcases_vname = "ZVFBF_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["zvfbf_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":zvfbf_test.elf",
        ],
        "size": "medium",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [":zvfbf_test.elf"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = ":rvv_core_mini_axi_model",
)

coralnpu_v2_binary(
    name = "zfbfmin_test",
    srcs = [
        "zfbfmin_test.cc",
    ],
)

cocotb_test_suite(
    name = "zfbfmin_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = [
        "zfbfmin_test",
    ],
    testcases_vname = "ZFBFMIN_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["zfbfmin_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":zfbfmin_test.elf",
        ],
        "size": "medium",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [":zfbfmin_test.elf"] + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
    verilator_model = ":rvv_core_mini_axi_model",
)

coralnpu_v2_binary(
    name = "ddr_test",
    srcs = [
        "ddr_test.cc",
    ],
)

cocotb_test_suite(
    name = "rvv_highmem_tests_slow",
    simulators = [
        "verilator",
    ],
    testcases = HIGHMEM_TESTCASES,
    testcases_vname = "HIGHMEM_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMiniHighmemAxi",
        "waves": False,
        "seed": "42",
        "test_module": ["rvv_highmem_sim.py"],
        "deps": [
            "//coralnpu_test_utils:core_mini_axi_sim_interface",
            "//coralnpu_test_utils:sim_test_fixture",
            requirement("tqdm"),
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [
            ":wfi_slot_0_highmem.elf",
            ":wfi_slot_1_highmem.elf",
            ":wfi_slot_2_highmem.elf",
            ":wfi_slot_3_highmem.elf",
            "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_highmem.elf",
            "//tests/cocotb/rvv/ml_ops:rvv_matmul_highmem.elf",
        ],
        "size": "large",
        "test_args": ["+CLOCK_NS=2.0"],
    },
    verilator_model = ":rvv_core_mini_highmem_axi_model",
)

template_rule(
    cocotb_test_suite,
    {
        "core_mini_axi_sim_cocotb_slow": {
            "tests_kwargs": dict(
                CORE_MINI_AXI_SIM_COMMON_TEST_KWARGS,
                size = "enormous",
                default_testcase_size = "medium",
                hdl_toplevel = "CoreMiniAxi",
                test_args = ["+CLOCK_NS=2.0"],
            ),
            "vcs_verilog_sources": ["//hdl/chisel/src/coralnpu:core_mini_axi_cc_library_verilog"],
            "verilator_model": ":core_mini_axi_model",
            "testcases": CORE_MINI_AXI_SIM_TESTCASES,
            "testcases_vname": "CORE_MINI_AXI_SIM_TESTCASES",
        },
        "rvv_core_mini_axi_sim_cocotb_slow": {
            "tests_kwargs": dict(
                CORE_MINI_AXI_SIM_COMMON_TEST_KWARGS,
                size = "enormous",
                default_testcase_size = "medium",
                hdl_toplevel = "RvvCoreMiniAxi",
                test_args = ["+CLOCK_NS=2.0"],
            ),
            "vcs_verilog_sources": ["//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_verilog"],
            "verilator_model": ":rvv_core_mini_axi_model",
            "testcases": RVV_CORE_MINI_AXI_SIM_TESTCASES,
            "testcases_vname": "RVV_CORE_MINI_AXI_SIM_TESTCASES",
        },
    },
    simulators = [
        "verilator",
        "vcs",
    ],
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = COCOTB_TEST_BINARY_TARGETS + VCS_COMMON_DATA,
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS + ["+CLOCK_NS=2.0"],
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
    ],
)
