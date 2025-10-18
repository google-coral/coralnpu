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


load("@io_bazel_rules_scala//scala:scala.bzl", "scala_binary", "scala_library", "scala_test")
load("@rules_hdl//verilator:defs.bzl", "verilator_cc_library")
load("@rules_hdl//verilog:providers.bzl", "verilog_library")

SCALA_COPTS = [
    "-Ymacro-annotations",
    "-Xplugin:$(execpath @org_chipsalliance_chisel_plugin//jar)",
    "-explaintypes",
    "-feature",
    "-language:reflectiveCalls",
    "-unchecked",
    "-deprecation",
    "-Xcheckinit",
    "-Xlint:infer-any",
    "-Xlint:unused",
]

def chisel_library(
        name,
        srcs = [],
        deps = [],
        exports = [],
        resources = [],
        resource_strip_prefix = "",
        visibility = None,
        allow_warnings = False):
    warn_opts = []
    if not allow_warnings:
        warn_opts += ["-Xfatal-warnings"]
    scala_library(
        name = name,
        srcs = srcs,
        deps = [
            "@coralnpu_hw//lib:chisel_lib",
            "@org_chipsalliance_chisel_plugin//jar",
        ] + deps,
        resources = resources,
        resource_strip_prefix = resource_strip_prefix,
        exports = exports,
        scalacopts = SCALA_COPTS + warn_opts,
        visibility = visibility,
    )

def chisel_binary(
        name,
        main_class,
        srcs = [],
        deps = [],
        visibility = None):
    scala_binary(
        name = name,
        srcs = srcs,
        main_class = main_class,
        deps = [
            "@coralnpu_hw//lib:chisel_lib",
            "@org_chipsalliance_chisel_plugin//jar",
        ] + deps,
        scalacopts = SCALA_COPTS,
        visibility = visibility,
    )

def chisel_test(
        name,
        srcs = [],
        deps = [],
        args = [],
        tags = [],
        size = "medium",
        visibility = None):
    scalatest_name = name + "_scalatest"
    scala_test(
        name = scalatest_name,
        srcs = srcs,
        deps = [
            "@coralnpu_hw//lib:chisel_lib",
            "@org_chipsalliance_chisel_plugin//jar",
            "@org_scalatest_scalatest//jar",
            "@edu_berkeley_cs_firrtl//jar",
            "@org_antlr_antlr4_runtime//jar",
            "@net_java_dev_jna//jar",
        ] + deps,
        data = [
            "@coralnpu_hw//third_party/llvm-firtool:firtool",
        ],
        env = {
            # Stop verilator from using ccache, this causes CI issues.
            "OBJCACHE": "",
            "CHISEL_FIRTOOL_PATH": "third_party/llvm-firtool",
        },
        args = args,
        tags = tags + ["manual"],
        size = size,
        scalacopts = SCALA_COPTS,
        visibility = visibility,
    )

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
        extra_outs = []):
    gen_binary_name = name + "_emit_verilog_binary"
    chisel_binary(
        name = gen_binary_name,
        deps = [chisel_lib],
        main_class = emit_class,
    )
    if verilog_file_path == "":
        verilog_file_path = module_name + ".sv"

    gen_flags = " ".join(gen_flags)
    native.genrule(
        name = name + "_emit_verilog",
        srcs = [],
        outs = [verilog_file_path] + extra_outs,
        cmd = "CHISEL_FIRTOOL_PATH=$$(dirname $(execpath @coralnpu_hw//third_party/llvm-firtool:firtool)) ./$(location " + gen_binary_name + ") --target-dir=$(RULEDIR) " + gen_flags,
        tools = [
            ":{}".format(gen_binary_name),
            "@coralnpu_hw//third_party/llvm-firtool:firtool",
        ],
    )

    verilog_library(
        name = name + "_verilog",
        srcs = [verilog_file_path],
        deps = verilog_deps,
    )

    # Most use cases seem to be SystemC - so let's
    # give that the unmodified name.
    verilator_cc_library(
        name = "{}".format(name),
        module = ":{}_verilog".format(name),
        module_top = module_name,
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
        visibility = ["//visibility:public"],
        # TODO(derekjchow): Re-enable the default -Wall?
        vopts = vopts + ["--pins-bv", "2"],
        systemc = False,
    )
