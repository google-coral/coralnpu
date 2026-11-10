# Copyright 2023 Google LLC
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

"""chisel build rules"""

load("@coralnpu_host_cpus//:defs.bzl", "NUM_CPUS")
load("@rules_scala//scala:scala.bzl", "scala_binary", "scala_library", "scala_test")
load("//rules:verilator.bzl", "verilator_cc_library")
load("//rules:verilog.bzl", "verilog_library")

SCALA_COPTS = [
    "-Ymacro-annotations",
    "-explaintypes",
    "-feature",
    "-language:reflectiveCalls",
    "-unchecked",
    "-deprecation",
    "-Xcheckinit",
    "-Xlint:infer-any",
    "-Xlint:unused",
]

_CHISEL_RUN_CPUS = min(NUM_CPUS, 2)

_CHISEL_RUN_JVM_FLAGS = [
    "-XX:ActiveProcessorCount={}".format(_CHISEL_RUN_CPUS),
]

def _chisel_emit_resource_estimator(_os, _input_size):
    return {"cpu": _CHISEL_RUN_CPUS, "memory": 2048}

def _chisel_emit_verilog_impl(ctx):
    rule_dir = ctx.bin_dir.path
    if ctx.label.package:
        rule_dir = rule_dir + "/" + ctx.label.package
    args = ["--target-dir=" + rule_dir]
    for flag in ctx.attr.gen_flags:
        for tok in flag.split(" "):
            if tok:
                args.append(tok)
    ctx.actions.run(
        outputs = ctx.outputs.outs,
        executable = ctx.executable.gen_binary,
        arguments = args,
        tools = [
            ctx.attr._firtool[DefaultInfo].files_to_run,
        ],
        env = {
            "CHISEL_FIRTOOL_PATH": ctx.executable._firtool.dirname,
        },
        mnemonic = "ChiselEmitVerilog",
        progress_message = "[Chisel] Emitting SystemVerilog for %s" % ctx.label,
        resource_set = _chisel_emit_resource_estimator,
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset(ctx.outputs.outs))]

_chisel_emit_verilog = rule(
    implementation = _chisel_emit_verilog_impl,
    attrs = {
        "gen_binary": attr.label(
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
        "gen_flags": attr.string_list(default = []),
        "outs": attr.output_list(mandatory = True),
        "_firtool": attr.label(
            default = Label("@coralnpu_hw//third_party/llvm-firtool:firtool"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def chisel_library(
        name,
        srcs = [],
        deps = [],
        exports = [],
        resources = [],
        resource_strip_prefix = "",
        visibility = None,
        allow_warnings = False,
        scalacopts = []):
    warn_opts = []
    if not allow_warnings:
        warn_opts += ["-Xfatal-warnings"]
    scala_library(
        name = name,
        srcs = srcs,
        deps = [
            "@coralnpu_hw//lib:chisel_lib",
            "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
        ] + deps,
        plugins = [
            "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
        ],
        resources = resources,
        resource_strip_prefix = resource_strip_prefix,
        exports = exports,
        scalacopts = SCALA_COPTS + warn_opts + scalacopts,
        visibility = visibility,
    )

def chisel_binary(
        name,
        main_class,
        srcs = [],
        deps = [],
        tags = [],
        visibility = None):
    scala_binary(
        name = name,
        srcs = srcs,
        main_class = main_class,
        deps = [
            "@coralnpu_hw//lib:chisel_lib",
            "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
            "@coralnpu_hw//lib:common_cells_resources",
            "@coralnpu_hw//lib:cvfpu_resources",
            "@coralnpu_hw//lib:fpu_div_sqrt_mvp_resources",
            "@coralnpu_hw//lib:rvvi_resources",
        ] + deps,
        plugins = [
            "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
        ],
        jvm_flags = _CHISEL_RUN_JVM_FLAGS,
        scalacopts = SCALA_COPTS,
        tags = tags,
        visibility = visibility,
    )

def chisel_test(
        name,
        srcs = [],
        deps = [],
        args = [],
        tags = [],
        size = "medium",
        timeout = None,
        visibility = None):
    scalatest_name = name + "_scalatest"
    kwargs = {}
    if timeout:
        kwargs["timeout"] = timeout
    scala_test(
        name = scalatest_name,
        srcs = srcs,
        deps = [
            "@coralnpu_hw//lib:chisel_lib",
            "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
            "@coralnpu_maven//:org_scalatest_scalatest_2_13",
            "@coralnpu_maven//:edu_berkeley_cs_firrtl_2_13",
            "@coralnpu_maven//:org_antlr_antlr4_runtime",
            "@coralnpu_maven//:net_java_dev_jna_jna",
        ] + deps,
        plugins = [
            "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
        ],
        data = [
            "@coralnpu_hw//third_party/llvm-firtool:firtool",
        ],
        env = {
            # Stop verilator from using ccache, this causes CI issues.
            "OBJCACHE": "",
            "CHISEL_FIRTOOL_PATH": "third_party/llvm-firtool",
        },
        args = args,
        jvm_flags = _CHISEL_RUN_JVM_FLAGS,
        tags = tags + ["manual"],
        size = size,
        scalacopts = SCALA_COPTS,
        visibility = visibility,
        **kwargs
    )

    sh_tags = list(tags)
    if not any([t.startswith("cpu:") for t in sh_tags]):
        sh_tags.append("cpu:{}".format(_CHISEL_RUN_CPUS))
    native.sh_test(
        name = name,
        srcs = ["@coralnpu_hw//rules:chisel_test_runner.sh"],
        data = [
            ":{}".format(scalatest_name),
            "@verilator//:verilator_bin",
            "@verilator//:verilator_lib",
            "@coralnpu_hw//third_party/llvm-firtool:firtool",
        ],
        env = {
            # Stop verilator from using ccache, this causes CI issues.
            "OBJCACHE": "",
            "CHISEL_FIRTOOL_PATH": "third_party/llvm-firtool",
        },
        size = size,
        tags = sh_tags,
        visibility = visibility,
        **kwargs
    )

def chisel_cc_library(
        name,
        chisel_lib,
        emit_class,
        module_name,
        verilog_deps = [],
        verilog_file_path = "",
        vopts = [],
        gen_flags = [],
        extra_outs = [],
        tags = []):
    gen_binary_name = name + "_emit_verilog_binary"
    chisel_binary(
        name = gen_binary_name,
        deps = [chisel_lib],
        main_class = emit_class,
        tags = tags,
    )
    if verilog_file_path == "":
        verilog_file_path = module_name + ".sv"

    _chisel_emit_verilog(
        name = name + "_emit_verilog",
        gen_binary = ":{}".format(gen_binary_name),
        gen_flags = gen_flags,
        outs = [verilog_file_path] + extra_outs,
        tags = tags,
    )

    verilog_library(
        name = name + "_verilog",
        srcs = [verilog_file_path],
        deps = verilog_deps,
        tags = tags,
    )

    # Most use cases seem to be SystemC - so let's
    # give that the unmodified name.
    verilator_cc_library(
        name = "{}".format(name),
        module = ":{}_verilog".format(name),
        module_top = module_name,
        tags = tags,
        visibility = ["//visibility:public"],
        # TODO(derekjchow): Re-enable the default -Wall?
        vopts = vopts + ["--pins-bv", "2"],
        systemc = True,
    )

    # Regular C++ Verilator output.
    # Append _cc to the library name to differentiate
    # from SystemC.
    verilator_cc_library(
        name = "{}_cc".format(name),
        module = ":{}_verilog".format(name),
        module_top = module_name,
        tags = tags,
        visibility = ["//visibility:public"],
        # TODO(derekjchow): Re-enable the default -Wall?
        vopts = vopts + ["--pins-bv", "2"],
        systemc = False,
    )
