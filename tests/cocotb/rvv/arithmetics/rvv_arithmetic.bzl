"""Generate a rvv test script using the template below"""

def rvv_arithmetic_test(**kwargs):
    rvv_arithmetic_template(
        source_file = "{name}.cc".format(**kwargs),
        **kwargs
    )

def rvv_reduction_test(**kwargs):
    rvv_reduction_template(
        source_file = "{name}.cc".format(**kwargs),
        **kwargs
    )

def rvv_widen_arithmetic_test(**kwargs):
    rvv_widen_arithmetic_template(
        source_file = "{name}.cc".format(**kwargs),
        **kwargs
    )

def rvv_arithmetic_template_impl(ctx):
    sign = ctx.attr.sign
    sew = ctx.attr.sew
    dtype = ctx.attr.dtype
    op_suffix = "{sign}{sew}m1".format(sign = sign, sew = sew)
    scalar_type = dtype if dtype == "float" else (dtype + "_t")
    vec_type = "v{sign}{sew}m1_t".format(
        sign = "int" if sign == "i" else ("uint" if sign == "u" else "float"),
        sew = sew,
    )
    is_shift = ctx.attr.math_op in ["sll", "srl", "sra", "ssra", "ssrl"]
    v2_sign = "uint" if is_shift else ("int" if sign == "i" else ("uint" if sign == "u" else "float"))
    v2_sign_char = "u" if is_shift else sign
    vec_type_v2 = "v{sign}{sew}m1_t".format(
        sign = v2_sign,
        sew = sew,
    )
    op_suffix_v2 = "{sign}{sew}m1".format(sign = v2_sign_char, sew = sew)
    scalar_type_v2 = "uint{sew}_t".format(sew = sew) if is_shift else scalar_type
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.source_file,
        substitutions = {
            "{SCALAR_TYPE}": scalar_type,
            "{SCALAR_TYPE_V2}": scalar_type_v2,
            "{VEC_TYPE}": vec_type,
            "{VEC_TYPE_V2}": vec_type_v2,
            "{OP_SUFFIX}": op_suffix,
            "{OP_SUFFIX_V2}": op_suffix_v2,
            "{DTYPE}": ctx.attr.dtype,
            "{IN_DATA_SIZE}": ctx.attr.in_data_size,
            "{OUT_DATA_SIZE}": ctx.attr.out_data_size,
            "{MATH_OP}": ctx.attr.math_op,
            "{NUM_OPERANDS}": ctx.attr.num_operands,
            "{SEW}": ctx.attr.sew,
            "{SIGN}": ctx.attr.sign,
            "{EXTRA_ARGS}": ctx.attr.extra_args,
            "{DEFINES}": ctx.attr.defines,
        },
    )

def rvv_reduction_template_impl(ctx):
    sign = ctx.attr.sign
    sew = ctx.attr.sew
    dtype = ctx.attr.dtype
    op_suffix = "{sign}{sew}m1".format(sign = sign, sew = sew)
    scalar_type = dtype if dtype == "float" else (dtype + "_t")
    vec_type = "v{sign}{sew}m1_t".format(
        sign = "int" if sign == "i" else ("uint" if sign == "u" else "float"),
        sew = sew,
    )
    s_mv_v_fn = "__riscv_v{mv}mv_v_{s}_{suffix}".format(
        mv = "f" if sign == "f" else "",
        s = "f" if sign == "f" else "x",
        suffix = op_suffix,
    )
    v_mv_s_fn = "__riscv_v{mv}mv_{s}_s_{suffix}_{s_short}".format(
        mv = "f" if sign == "f" else "",
        s = "f" if sign == "f" else "x",
        suffix = op_suffix,
        s_short = "f32" if (sign == "f" and sew == "32") else op_suffix.split("m")[0],
    )
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.source_file,
        substitutions = {
            "{SCALAR_TYPE}": scalar_type,
            "{VEC_TYPE}": vec_type,
            "{OP_SUFFIX}": op_suffix,
            "{S_MV_V_FN}": s_mv_v_fn,
            "{V_MV_S_FN}": v_mv_s_fn,
            "{DTYPE}": ctx.attr.dtype,
            "{IN_DATA_SIZE}": ctx.attr.in_data_size,
            "{OUT_DATA_SIZE}": ctx.attr.out_data_size,
            "{REDUCTION_OP}": ctx.attr.reduction_op,
            "{NUM_OPERANDS}": ctx.attr.num_operands,
            "{SEW}": ctx.attr.sew,
            "{SIGN}": ctx.attr.sign,
        },
    )

def rvv_widen_arithmetic_template_impl(ctx):
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.source_file,
        substitutions = {
            "{IN_DTYPE}": ctx.attr.in_dtype,
            "{OUT_DTYPE}": ctx.attr.out_dtype,
            "{IN_SEW}": ctx.attr.in_sew,
            "{OUT_SEW}": ctx.attr.out_sew,
            "{STEP_OPERANDS}": ctx.attr.step_operands,
            "{MATH_OP}": ctx.attr.math_op,
            "{SIGN}": ctx.attr.sign,
            "{NUM_TEST_VALUES}": ctx.attr.num_test_values,
        },
    )

rvv_arithmetic_template = rule(
    implementation = rvv_arithmetic_template_impl,
    attrs = {
        "dtype": attr.string(mandatory = True),
        "in_data_size": attr.string(mandatory = True),
        "out_data_size": attr.string(mandatory = True),
        "math_op": attr.string(mandatory = True),
        "num_operands": attr.string(mandatory = True),
        "sew": attr.string(mandatory = True),
        "sign": attr.string(mandatory = True),
        "extra_args": attr.string(default = ""),
        "defines": attr.string(default = ""),
        "_template": attr.label(
            default = ":rvv_arithmetic_template.cc",
            allow_single_file = True,
        ),
        "source_file": attr.output(mandatory = True),
    },
)

rvv_reduction_template = rule(
    implementation = rvv_reduction_template_impl,
    attrs = {
        "dtype": attr.string(mandatory = True),
        "in_data_size": attr.string(mandatory = True),
        "out_data_size": attr.string(mandatory = True),
        "reduction_op": attr.string(mandatory = True),
        "num_operands": attr.string(mandatory = True),
        "sew": attr.string(mandatory = True),
        "sign": attr.string(mandatory = True),
        "_template": attr.label(
            default = ":rvv_reduction_template.cc",
            allow_single_file = True,
        ),
        "source_file": attr.output(mandatory = True),
    },
)

rvv_widen_arithmetic_template = rule(
    implementation = rvv_widen_arithmetic_template_impl,
    attrs = {
        "in_dtype": attr.string(mandatory = True),
        "out_dtype": attr.string(mandatory = True),
        "math_op": attr.string(mandatory = True),
        "step_operands": attr.string(mandatory = True),
        "in_sew": attr.string(mandatory = True),
        "out_sew": attr.string(mandatory = True),
        "sign": attr.string(mandatory = True),
        "num_test_values": attr.string(mandatory = True),
        "_template": attr.label(
            default = ":rvv_widen_arithmetic_template.cc",
            allow_single_file = True,
        ),
        "source_file": attr.output(mandatory = True),
    },
)
