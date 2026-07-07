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

load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:coco_tb.bzl", "cocotb_test_suite")
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_BUILD_ARGS",
    "VCS_DEFINES",
    "VCS_TEST_ARGS",
)

package(default_visibility = ["//visibility:public"])

# Enable native bf16<->fp32 conversion (Zvfbfmin: VFWCVTBF16 / VFNCVTBF16). The
# RvvCoreMiniAxi core synthesizes these instructions (--enableVectorBf16=True),
# but the toolchain's default -march (rv32imf_zve32f_zicsr_zifencei_zbb) omits
# zvfbfmin, so the compiler will not emit them. These copts override -march for 
# just these targets, which makes rvv_math.h take its native-conversion path (the
# later -march on the command line wins). Drop this for fall back the the 
# integer-only conversion path with no behavioral change.
BF16_NATIVE_COPTS = ["-march=rv32imf_zve32f_zvfbfmin_zicsr_zifencei_zbb"]

coralnpu_v2_binary(
    name = "rvv_math_test",
    srcs = ["rvv_math_runner.cc"],
    hdrs = [
        "rvv_math.h",
        "//sw/utils:utils.h",
    ],
    copts = BF16_NATIVE_COPTS,
    dtcm_size_kbytes = 512,
    itcm_size_kbytes = 512,
)

coralnpu_v2_binary(
    name = "sigmoid_bf16_test",
    srcs = [
        "sigmoid_bf16_kernel.cc",
        "sigmoid_bf16_runner.cc",
    ],
    hdrs = [
        "rvv_math.h",
        "//sw/utils:utils.h",
    ],
    copts = BF16_NATIVE_COPTS,
    dtcm_size_kbytes = 512,
    itcm_size_kbytes = 512,
)

coralnpu_v2_binary(
    name = "softmax_bf16_test",
    srcs = [
        "softmax_bf16_kernel.cc",
        "softmax_bf16_runner.cc",
    ],
    hdrs = [
        "rvv_math.h",
        "//sw/utils:utils.h",
    ],
    copts = BF16_NATIVE_COPTS,
    dtcm_size_kbytes = 512,
    itcm_size_kbytes = 512,
)

RVV_MATH_TESTCASES = ["rvv_math_test"]
cocotb_test_suite(
    name = "rvv_math_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = RVV_MATH_TESTCASES,
    testcases_vname = "RVV_MATH_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
        "waves": False,
        "seed": "42",
        "tags": ["manual"],
        "test_module": ["rvv_math_cocotb_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [":rvv_math_test.elf"],
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":rvv_math_test.elf",
        "//tests/cocotb:xprop.cfg",
        "@coralnpu_hw//hdl/verilog:dpi_files",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:alu_cc_library_emit_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_itcm512kb_dtcm512kb_axi_model",
)

SIGMOID_BF16_TESTCASES = ["sigmoid_bf16_test"]
cocotb_test_suite(
    name = "sigmoid_bf16_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = SIGMOID_BF16_TESTCASES,
    testcases_vname = "SIGMOID_BF16_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
        "waves": False,
        "seed": "42",
        "tags": ["manual"],
        "test_module": ["sigmoid_bf16_cocotb_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [":sigmoid_bf16_test.elf"],
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":sigmoid_bf16_test.elf",
        "//tests/cocotb:xprop.cfg",
        "@coralnpu_hw//hdl/verilog:dpi_files",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:alu_cc_library_emit_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_itcm512kb_dtcm512kb_axi_model",
)

SOFTMAX_BF16_TESTCASES = ["softmax_bf16_test"]
cocotb_test_suite(
    name = "softmax_bf16_cocotb_test",
    simulators = [
        "verilator",
        "vcs",
    ],
    testcases = SOFTMAX_BF16_TESTCASES,
    testcases_vname = "SOFTMAX_BF16_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
        "waves": False,
        "seed": "42",
        "tags": ["manual"],
        "test_module": ["softmax_bf16_cocotb_test.py"],
        "deps": [
            "//coralnpu_test_utils:sim_test_fixture",
            "@bazel_tools//tools/python/runfiles",
        ],
        "data": [":softmax_bf16_test.elf"],
        "size": "enormous",
    },
    vcs_build_args = VCS_BUILD_ARGS,
    vcs_data = [
        ":softmax_bf16_test.elf",
        "//tests/cocotb:xprop.cfg",
        "@coralnpu_hw//hdl/verilog:dpi_files",
    ],
    vcs_defines = VCS_DEFINES,
    vcs_test_args = VCS_TEST_ARGS,
    vcs_verilog_sources = ["//hdl/chisel/src/coralnpu:alu_cc_library_emit_verilog"],
    verilator_model = "//tests/cocotb:rvv_core_mini_itcm512kb_dtcm512kb_axi_model",
)

