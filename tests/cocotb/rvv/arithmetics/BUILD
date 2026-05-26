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

load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:utils.bzl", "template_rule")
load("//tests/cocotb/rvv/arithmetics:rvv_arithmetic.bzl", "rvv_arithmetic_test", "rvv_reduction_test", "rvv_widen_arithmetic_test")

package(default_visibility = ["//visibility:public"])

MATH_OPS = [
    "add",
    "sub",
    "mul",
    "div",
    "and",
    "or",
    "xor",
    "min",
    "max",
    "sadd",
    "ssub",
    "aadd",
    "asub",
    "smul",
    "mulh",
    "rem",
    "macc",
    "nmsac",
    "madd",
    "nmsub",
    "sll",
    "srl",
    "sra",
    "ssra",
    "ssrl",
]

REDUCTION_OPS = [
    "redsum",
    "redmin",
    "redmax",
    "redand",
    "redor",
    "redxor",
]

FLOAT_MATH_OPS = [
    "fadd",
    "fsub",
    "fmul",
    "fdiv",
]

FLOAT_REDUCTION_OPS = [
    "fredusum",
    "fredmin",
    "fredmax",
]

# tuple format DTYPE (sew, sign, dtype, vl)
DTYPES = [
    ("8", "i", "int8", "16"),
    ("16", "i", "int16", "8"),
    ("32", "i", "int32", "4"),
    ("8", "u", "uint8", "16"),
    ("16", "u", "uint16", "8"),
    ("32", "u", "uint32", "4"),
]

FLOAT_DTYPES = [
    ("32", "f", "float", "4"),
]

WIDEN_DTYPES = [
    ("i", "int8", "int16", "8", "16", "8", "256"),
    ("i", "int16", "int32", "16", "32", "4", "256"),
    ("u", "uint8", "uint16", "8", "16", "8", "256"),
    ("u", "uint16", "uint32", "16", "32", "4", "256"),
]

MATH_OP_TYPE_PAIRS = [
    (op, sew, sign, dtype, vl)
    for op in MATH_OPS
    for (sew, sign, dtype, vl) in DTYPES
]

FLOAT_MATH_OP_TYPE_PAIRS = [
    (op, sew, sign, dtype, vl)
    for op in FLOAT_MATH_OPS
    for (sew, sign, dtype, vl) in FLOAT_DTYPES
]

MATH_WIDEN_OP_TYPE_PAIRS = [
    (op, sign, in_dtype, out_dtype, in_sew, out_sew, vl_step, num_test_values)
    for op in ["add", "sub", "mul"]
    for (sign, in_dtype, out_dtype, in_sew, out_sew, vl_step, num_test_values) in WIDEN_DTYPES
]

REDUCTION_OP_TYPE_PAIRS = [
    (op, sew, sign, dtype, vl)
    for op in REDUCTION_OPS
    for (sew, sign, dtype, vl) in DTYPES
]

FLOAT_REDUCTION_OP_TYPE_PAIRS = [
    (op, sew, sign, dtype, vl)
    for op in FLOAT_REDUCTION_OPS
    for (sew, sign, dtype, vl) in FLOAT_DTYPES
]

# Division has different op code for signed and usigned
template_rule(
    rvv_arithmetic_test,
    {
        "template_{}_{}_m1".format(op, dtype): {
            "dtype": dtype,
            "sew": sew,
            "sign": sign,
            "num_operands": vl,
            "math_op": [
                op + "u" if op in ["div", "min", "max", "sadd", "ssub", "aadd", "asub", "mulh", "rem"] and sign == "u" else op
            ][0],
            "extra_args": ", 0" if op in ["aadd", "asub", "smul", "ssra", "ssrl"] else "",
            "defines": "\n".join([
                "#define TEST_TERNARY" if op in ["macc", "nmsac", "madd", "nmsub"] else "",
                "#define SHIFT_OP" if op in ["sll", "srl", "sra", "ssra", "ssrl"] else "",
                "#define SIGN_i 1",
                "#define SIGN_u 0",
                "#define SIGN_f 2",
            ]),
            "in_data_size": "16",
            "out_data_size": "16",
        }
        for (op, sew, sign, dtype, vl) in MATH_OP_TYPE_PAIRS + FLOAT_MATH_OP_TYPE_PAIRS
        if not (op == "smul" and sign == "u")
        and not (op in ["sra", "ssra"] and sign == "u")
        and not (op in ["srl", "ssrl"] and sign == "i")
    },
)

template_rule(
    rvv_reduction_test,
    {
        "template_{}_{}_m1".format(op, dtype): {
            "dtype": dtype,
            "sew": sew,
            "sign": sign,
            "num_operands": vl,
            # redmin and redmax have different operators for signed/unsigned
            "reduction_op": op + "u" if ((op == "redmin" or op == "redmax") and dtype[0] == "u") else op,
            "in_data_size": "16",
            "out_data_size": "16",
        }
        for (op, sew, sign, dtype, vl) in REDUCTION_OP_TYPE_PAIRS + FLOAT_REDUCTION_OP_TYPE_PAIRS
    },
)

template_rule(
    rvv_widen_arithmetic_test,
    {
        "template_widen_{}_{}_{}".format(op, in_dtype, out_dtype): {
            "in_dtype": in_dtype,
            "out_dtype": out_dtype,
            "in_sew": in_sew,
            "out_sew": out_sew,
            "sign": sign,
            "step_operands": vl_step,
            "math_op": op + "u" if sign == "u" else op,
            "num_test_values": num_test_values,
        }
        for (op, sign, in_dtype, out_dtype, in_sew, out_sew, vl_step, num_test_values) in MATH_WIDEN_OP_TYPE_PAIRS
    },
)

template_rule(
    coralnpu_v2_binary,
    {
        "rvv_{}_{}_m1".format(op, dtype): {
            "srcs": ["template_{}_{}_m1".format(op, dtype)],
        }
        for (op, _, sign, dtype, _) in MATH_OP_TYPE_PAIRS + REDUCTION_OP_TYPE_PAIRS + FLOAT_MATH_OP_TYPE_PAIRS + FLOAT_REDUCTION_OP_TYPE_PAIRS
        if not (op == "smul" and sign == "u")
        and not (op in ["sra", "ssra"] and sign == "u")
        and not (op in ["srl", "ssrl"] and sign == "i")
    },
)


template_rule(
    coralnpu_v2_binary,
    {
        "rvv_widen_{}_{}_{}".format(op, in_dtype, out_dtype): {
            "srcs": ["template_widen_{}_{}_{}".format(op, in_dtype, out_dtype)],
        }
        for (op, _, in_dtype, out_dtype, _, _, _, _) in MATH_WIDEN_OP_TYPE_PAIRS
    },
)

template_rule(
    coralnpu_v2_binary,
    {
        "vnclip_test": {
            "srcs": ["vnclip_test.cc"],
        },
        "vnclipu_test": {
            "srcs": ["vnclipu_test.cc"],
        },
        "vnsra_test": {
            "srcs": ["vnsra_test.cc"],
        },
        "vnsrl_test": {
            "srcs": ["vnsrl_test.cc"],
        },
    },
)

SAME_TYPE_BINARY_VX_CASES = [
    ("vadd_vx_test", "Vadd", ["TEST_INT"]),
    ("vsadd_vx_test", "Vsadd", ["TEST_INT"]),
    ("vsub_vx_test", "Vsub", ["TEST_INT"]),
    ("vssub_vx_test", "Vssub", ["TEST_INT"]),
    ("vrsub_vx_test", "Vrsub", ["TEST_INT"]),
    ("vmul_vx_test", "Vmul", ["TEST_INT"]),
    ("vmulh_vx_test", "Vmulh", ["TEST_INT"]),
    ("vmin_vx_test", "Vmin", ["TEST_INT"]),
    ("vmax_vx_test", "Vmax", ["TEST_INT"]),
    ("vand_vx_test", "Vand", ["TEST_INT"]),
    ("vor_vx_test", "Vor", ["TEST_INT"]),
    ("vxor_vx_test", "Vxor", ["TEST_INT"]),
    ("vaadd_vx_test", "Vaadd", ["TEST_INT"]),
    ("vaaddu_vx_test", "Vaadd", ["UNSIGNED_ONLY", "TEST_INT"]),
    ("vasub_vx_test", "Vasub", ["TEST_INT"]),
    ("vasubu_vx_test", "Vasub", ["UNSIGNED_ONLY", "TEST_INT"]),
    ("vsmul_vx_test", "Vsmul", ["SIGNED_ONLY", "TEST_INT"]),
    ("vdiv_vx_test", "Vdiv", ["TEST_INT"]),
    ("vrem_vx_test", "Vrem", ["TEST_INT"]),
    ("vfadd_vf_test", "Vfadd", ["TEST_FLOAT"]),
    ("vfsub_vf_test", "Vfsub", ["TEST_FLOAT"]),
    ("vfmul_vf_test", "Vfmul", ["TEST_FLOAT"]),
    ("vfdiv_vf_test", "Vfdiv", ["TEST_FLOAT"]),
]

SAME_TYPE_TERNARY_VX_CASES = [
    ("vmacc_vx_test", "Vmacc", ["TEST_INT", "TEST_TERNARY"]),
    ("vnmsac_vx_test", "Vnmsac", ["TEST_INT", "TEST_TERNARY"]),
    ("vmadd_vx_test", "Vmadd", ["TEST_INT", "TEST_TERNARY"]),
    ("vnmsub_vx_test", "Vnmsub", ["TEST_INT", "TEST_TERNARY"]),
]

SAME_TYPE_IMMEDIATE_VX_CASES = [
    ("vadd_vi_test", "VaddVi", ["TEST_INT", "TEST_VI"]),
    ("vsadd_vi_test", "VsaddVi", ["TEST_INT", "TEST_VI"]),
    ("vand_vi_test", "VandVi", ["TEST_INT", "TEST_VI"]),
    ("vor_vi_test", "VorVi", ["TEST_INT", "TEST_VI"]),
    ("vxor_vi_test", "VxorVi", ["TEST_INT", "TEST_VI"]),
    ("vsll_vi_test", "VsllVi", ["TEST_INT", "TEST_VI"]),
    ("vsrl_vi_test", "VsrlVi", ["UNSIGNED_ONLY", "TEST_INT", "TEST_VI"]),
    ("vsra_vi_test", "VsraVi", ["SIGNED_ONLY", "TEST_INT", "TEST_VI"]),
    ("vssrl_vi_test", "VssrlVi", ["UNSIGNED_ONLY", "TEST_INT", "TEST_VI"]),
    ("vssra_vi_test", "VssraVi", ["SIGNED_ONLY", "TEST_INT", "TEST_VI"]),
    ("vrsub_vi_test", "VrsubVi", ["TEST_INT", "TEST_VI"]),
]

WIDENING_BINARY_VX_CASES = [
    ("vwadd_vx_test", "Vwadd", ["TEST_INT", "TEST_WIDEN_VX"]),
    ("vwaddu_vx_test", "Vwadd", ["UNSIGNED_ONLY", "TEST_INT", "TEST_WIDEN_VX"]),
    ("vwsub_vx_test", "Vwsub", ["TEST_INT", "TEST_WIDEN_VX"]),
    ("vwsubu_vx_test", "Vwsub", ["UNSIGNED_ONLY", "TEST_INT", "TEST_WIDEN_VX"]),
    ("vwmul_vx_test", "Vwmul", ["SIGNED_ONLY", "TEST_INT", "TEST_WIDEN_VX"]),
    ("vwmulu_vx_test", "Vwmul", ["UNSIGNED_ONLY", "TEST_INT", "TEST_WIDEN_VX"]),
]

WIDENING_BINARY_WV_CASES = [
    ("vwadd_wv_test", "VwaddW", ["TEST_INT", "TEST_WIDEN_WV"]),
    ("vwaddu_wv_test", "VwaddW", ["UNSIGNED_ONLY", "TEST_INT", "TEST_WIDEN_WV"]),
    ("vwsub_wv_test", "VwsubW", ["TEST_INT", "TEST_WIDEN_WV"]),
    ("vwsubu_wv_test", "VwsubW", ["UNSIGNED_ONLY", "TEST_INT", "TEST_WIDEN_WV"]),
]

WIDENING_BINARY_WX_CASES = [
    ("vwadd_wx_test", "VwaddW", ["TEST_INT", "TEST_WIDEN_WX"]),
    ("vwaddu_wx_test", "VwaddW", ["UNSIGNED_ONLY", "TEST_INT", "TEST_WIDEN_WX"]),
    ("vwsub_wx_test", "VwsubW", ["TEST_INT", "TEST_WIDEN_WX"]),
    ("vwsubu_wx_test", "VwsubW", ["UNSIGNED_ONLY", "TEST_INT", "TEST_WIDEN_WX"]),
]

SPECIAL_BINARY_CASES = [
    ("vmerge_vv_test", "Vmerge", ["TEST_INT", "TEST_MERGE"]),
    ("vmv_v_v_test", "Vmv", ["TEST_INT", "TEST_VMV"]),
]

CARRY_CASES = [
    ("vadc_vvm_test", "Vadc", ["TEST_INT", "TEST_CARRY"]),
    ("vadc_vxm_test", "Vadc", ["TEST_INT", "TEST_CARRY_VX"]),
    ("vsbc_vvm_test", "Vsbc", ["TEST_INT", "TEST_CARRY"]),
    ("vsbc_vxm_test", "Vsbc", ["TEST_INT", "TEST_CARRY_VX"]),
]

MADV_CASES = [
    ("vmadc_vvm_test", "Vmadc", ["TEST_INT", "TEST_MADV"]),
    ("vmadc_vxm_test", "Vmadc", ["TEST_INT", "TEST_MADV_VX"]),
    ("vmadc_vv_test", "Vmadc", ["TEST_INT", "TEST_MADV_NO_M"]),
    ("vmadc_vx_test", "Vmadc", ["TEST_INT", "TEST_MADV_NO_M_VX"]),
    ("vmsbc_vvm_test", "Vmsbc", ["TEST_INT", "TEST_MADV"]),
    ("vmsbc_vxm_test", "Vmsbc", ["TEST_INT", "TEST_MADV_VX"]),
    ("vmsbc_vv_test", "Vmsbc", ["TEST_INT", "TEST_MADV_NO_M"]),
    ("vmsbc_vx_test", "Vmsbc", ["TEST_INT", "TEST_MADV_NO_M_VX"]),
]

EXTENSION_CASES = [
    ("vsext_vf2_test", "VsextF2", ["SIGNED_ONLY", "TEST_INT", "TEST_EXT", "EXT_FACTOR=2"]),
    ("vsext_vf4_test", "VsextF4", ["SIGNED_ONLY", "TEST_INT", "TEST_EXT", "EXT_FACTOR=4"]),
    ("vzext_vf2_test", "VzextF2", ["UNSIGNED_ONLY", "TEST_INT", "TEST_EXT", "EXT_FACTOR=2"]),
    ("vzext_vf4_test", "VzextF4", ["UNSIGNED_ONLY", "TEST_INT", "TEST_EXT", "EXT_FACTOR=4"]),
]

COMPARISON_VV_CASES = [
    ("vmseq_vv_test", "Vmseq", ["TEST_INT", "TEST_COMP_VV"]),
    ("vmsne_vv_test", "Vmsne", ["TEST_INT", "TEST_COMP_VV"]),
    ("vmslt_vv_test", "Vmslt", ["TEST_INT", "TEST_COMP_VV"]),
    ("vmsle_vv_test", "Vmsle", ["TEST_INT", "TEST_COMP_VV"]),
]

COMPARISON_VX_CASES = [
    ("vmseq_vx_test", "Vmseq", ["TEST_INT", "TEST_COMP_VX"]),
    ("vmsne_vx_test", "Vmsne", ["TEST_INT", "TEST_COMP_VX"]),
    ("vmslt_vx_test", "Vmslt", ["TEST_INT", "TEST_COMP_VX"]),
    ("vmsle_vx_test", "Vmsle", ["TEST_INT", "TEST_COMP_VX"]),
    ("vmsgt_vx_test", "Vmsgt", ["TEST_INT", "TEST_COMP_VX"]),
    ("vmsge_vx_test", "Vmsge", ["TEST_INT", "TEST_COMP_VX"]),
]

[
    coralnpu_v2_binary(
        name = name,
        srcs = ["rvv_vx_arithmetics.cc"],
        defines = ["VX_FUNCTION={}".format(fn)] + extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util",
        ],
    )
    for name, fn, extra_defines in SAME_TYPE_BINARY_VX_CASES + SAME_TYPE_TERNARY_VX_CASES + WIDENING_BINARY_VX_CASES
]

[
    coralnpu_v2_binary(
        name = name,
        srcs = ["rvv_vx_arithmetics.cc"],
        defines = ["VI_FUNCTION={}".format(fn)] + extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util",
        ],
    )
    for name, fn, extra_defines in SAME_TYPE_IMMEDIATE_VX_CASES
]

[
    coralnpu_v2_binary(
        name = name,
        srcs = ["rvv_widen_wide_arithmetics.cc"],
        defines = ["WV_FUNCTION={}".format(fn)] + extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util",
        ],
    )
    for name, fn, extra_defines in WIDENING_BINARY_WV_CASES + WIDENING_BINARY_WX_CASES
]

[
    coralnpu_v2_binary(
        name = name,
        srcs = ["rvv_vx_arithmetics.cc"],
        defines = ["CARRY_FUNCTION={}".format(fn)] + extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util",
        ],
    )
    for name, fn, extra_defines in CARRY_CASES + MADV_CASES
]

[
    coralnpu_v2_binary(
        name = name,
        srcs = ["rvv_vx_arithmetics.cc"],
        defines = ["EXT_FUNCTION={}".format(fn)] + extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util",
        ],
    )
    for name, fn, extra_defines in EXTENSION_CASES
]

[
    coralnpu_v2_binary(
        name = name,
        srcs = ["rvv_vx_arithmetics.cc"],
        defines = ["COMP_FUNCTION={}".format(fn)] + extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util",
        ],
    )
    for name, fn, extra_defines in COMPARISON_VV_CASES + COMPARISON_VX_CASES
]

[
    coralnpu_v2_binary(
        name = name,
        srcs = ["rvv_vx_arithmetics.cc"],
        defines = extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util",
        ],
    )
    for name, _, extra_defines in SPECIAL_BINARY_CASES
]

filegroup(
    name = "rvv_same_type_binary_vx_cases",
    srcs = ["{}.elf".format(name) for name, _, _ in (
        SAME_TYPE_BINARY_VX_CASES +
        SAME_TYPE_TERNARY_VX_CASES +
        SAME_TYPE_IMMEDIATE_VX_CASES +
        WIDENING_BINARY_VX_CASES +
        WIDENING_BINARY_WV_CASES +
        WIDENING_BINARY_WX_CASES +
        SPECIAL_BINARY_CASES +
        CARRY_CASES +
        MADV_CASES +
        EXTENSION_CASES +
        COMPARISON_VV_CASES +
        COMPARISON_VX_CASES
    )],
)

MIXED_SIGN_SAME_WIDTH_BINARY_CASES = [
    ("Vsll", ["TEST_INT"]),
    ("Vsra", ["SIGNED_ONLY", "TEST_INT"]),
    ("Vsrl", ["UNSIGNED_ONLY", "TEST_INT"]),
    ("Vmulhsu", ["SIGNED_ONLY", "TEST_INT"]),
]

[
    coralnpu_v2_binary(
        name = "{}_vx_test".format(fn.lower()),
        srcs = ["rvv_vx_arithmetics.cc"],
        defines = [
            "VX_FUNCTION={}".format(fn),
            "FORCE_X_UNSIGNED",
        ] + extra_defines,
        deps = [
            "//coralnpu_test_utils:rvv_cpp_util"
        ],
    )
    for fn, extra_defines in MIXED_SIGN_SAME_WIDTH_BINARY_CASES
]

filegroup(
    name = "rvv_mixed_sign_same_width_type_binary_vx_cases",
    srcs = [
        "{}_vx_test.elf".format(fn.lower())
        for fn, _ in MIXED_SIGN_SAME_WIDTH_BINARY_CASES],
)

filegroup(
    name = "rvv_arith_tests",
    srcs = [
        ":rvv_{}_{}_m1.elf".format(op, dtype)
        for (op, _, sign, dtype, _) in MATH_OP_TYPE_PAIRS + REDUCTION_OP_TYPE_PAIRS + FLOAT_MATH_OP_TYPE_PAIRS + FLOAT_REDUCTION_OP_TYPE_PAIRS
        if not (op == "smul" and sign == "u")
        and not (op in ["sra", "ssra"] and sign == "u")
        and not (op in ["srl", "ssrl"] and sign == "i")
    ] + [
        "rvv_widen_{}_{}_{}.elf".format(op, in_dtype, out_dtype)
        for (op, _, in_dtype, out_dtype, _, _, _, _) in MATH_WIDEN_OP_TYPE_PAIRS
    ] + [
        "vnclip_test.elf",
        "vnclipu_test.elf",
        "vnsra_test.elf",
        "vnsrl_test.elf",
        ":rvv_same_type_binary_vx_cases",
        ":rvv_mixed_sign_same_width_type_binary_vx_cases",
    ],
)
