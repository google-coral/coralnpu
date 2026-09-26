"""
Transition rule to add CC=clang and -I. to the compile actions.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _clang_transition_impl(_settings, _attr):
    return {
        "//command_line_option:platforms": "//toolchain/host_clang:host_clang_platform",
        "//command_line_option:copt": ["-I."],
    }

_clang_transition = transition(
    implementation = _clang_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:copt",
    ],
)

def _mpact_transition_impl(ctx):
    # Transitioned attributes are always lists, even for 1:1 transitions
    dep = ctx.attr.dep[0]

    # Symlink all default outputs to satisfy the requirement that the rule
    # must create its own outputs.
    outputs = []
    for f in dep[DefaultInfo].files.to_list():
        out = ctx.actions.declare_file(f.basename)
        ctx.actions.symlink(output = out, target_file = f)
        outputs.append(out)

    providers = [
        DefaultInfo(files = depset(outputs), runfiles = dep[DefaultInfo].data_runfiles),
    ]
    if CcInfo in dep:
        providers.append(dep[CcInfo])
    return providers

mpact_binary = rule(
    implementation = _mpact_transition_impl,
    attrs = {
        "dep": attr.label(cfg = _clang_transition),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
