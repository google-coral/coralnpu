"""Bazel functions for Verilator."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@coralnpu_hw//rules:coco_tb.bzl", "verilator_make_parallelism", "verilator_resource_estimator")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//rules:uvm_denylist.bzl", "SPIKE_DENYLIST")
load("//rules:verilog.bzl", "VerilogInfo")

_VERILATOR_COMPILE_SCRIPT = """
set -e
RAW_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'verilator_raw')"
trap 'rm -rf "$RAW_DIR"' EXIT
mkdir -p "$1" "$2"
VERILATOR_ROOT="$3" "$4" "${@:5}" -Mdir "$RAW_DIR"
python3 -c '
import os, shutil, sys
raw, cpp, hdr = sys.argv[1], sys.argv[2], sys.argv[3]
for entry in os.scandir(raw):
    if entry.is_file():
        if entry.name.endswith((".cpp", ".cc", ".cxx")):
            shutil.move(entry.path, os.path.join(cpp, entry.name))
        elif entry.name.endswith((".h", ".hh", ".hpp")):
            shutil.move(entry.path, os.path.join(hdr, entry.name))
' "$RAW_DIR" "$1" "$2"
"""

def _uvm_verilator_cc_library_impl(ctx):
    hdl_toplevel = ctx.attr.hdl_toplevel

    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    # 1. Collect Verilog/SystemVerilog sources and inputs
    verilog_paths = []
    verilog_inputs = []
    seen_verilog_paths = {}

    def add_input(f):
        if type(f) == "File":
            verilog_inputs.append(f)

    all_dags = [dep[VerilogInfo].dag for dep in ctx.attr.deps if VerilogInfo in dep]
    merged_dag = depset(transitive = all_dags, order = "postorder")
    for node in merged_dag.to_list():
        for s in node.srcs + node.hdrs:
            add_input(s)
            if s.extension in ["v", "sv"] and s.path not in seen_verilog_paths:
                seen_verilog_paths[s.path] = True
                verilog_paths.append(s.path)

    for f in ctx.files.verilog_sources:
        add_input(f)
        if f.extension in ["v", "sv"] and f.path not in seen_verilog_paths:
            seen_verilog_paths[f.path] = True
            verilog_paths.append(f.path)

    for dep in ctx.attr.deps:
        if CcInfo not in dep and VerilogInfo not in dep:
            for f in dep[DefaultInfo].files.to_list():
                add_input(f)

    vlt_file = ctx.actions.declare_file(hdl_toplevel + ".vlt")
    ctx.actions.expand_template(
        output = vlt_file,
        template = ctx.file.vlt_tpl,
        substitutions = {"{HDL_TOPLEVEL}": hdl_toplevel},
    )
    add_input(vlt_file)

    # 2. Codegen Action: Run Verilator to generate C++ code into cpp_dir and hdr_dir
    cpp_dir = ctx.actions.declare_directory(ctx.label.name + "_cpp")
    hdr_dir = ctx.actions.declare_directory(ctx.label.name + "_h")

    verilator_canonical = ctx.executable._verilator_bin.owner.workspace_name
    verilator_root = "{}.runfiles/{}".format(
        ctx.executable._verilator_bin.path,
        verilator_canonical,
    )

    uvm_lib_path = ctx.attr._uvm_lib.label.workspace_root

    verilator_flags = [
        "-j",
        str(verilator_make_parallelism),
        "-cc",
        "--main",
        "--top-module",
        hdl_toplevel,
        "--vpi",
        "--prefix",
        "Vtop",
        "-I" + uvm_lib_path + "/src",
        uvm_lib_path + "/src/uvm_pkg.sv",
    ]
    for inc in ctx.files.include_dirs:
        verilator_flags.append("-I" + inc.path)
    for flag in ctx.attr.cflags:
        for arg in flag.split(" "):
            if arg:
                verilator_flags.append(arg)
    verilator_flags.extend(["--output-groups", "0"])
    verilator_flags.append(vlt_file.path)
    verilator_flags.extend(verilog_paths)

    ctx.actions.run_shell(
        outputs = [cpp_dir, hdr_dir],
        tools = [ctx.executable._verilator_bin],
        inputs = depset(
            verilog_inputs,
            transitive = [
                depset(ctx.files._verilator),
                depset(ctx.files._uvm_lib),
            ],
        ),
        command = _VERILATOR_COMPILE_SCRIPT,
        arguments = [
            cpp_dir.path,
            hdr_dir.path,
            verilator_root,
            ctx.executable._verilator_bin.path,
        ] + verilator_flags,
        mnemonic = "VerilatorCodegen",
        progress_message = "Verilating SystemVerilog to C++ for %s" % ctx.label,
        resource_set = verilator_resource_estimator,
    )

    # 3. Collect CcInfo dependencies
    all_cc_deps = [dep for dep in ctx.attr.deps if CcInfo in dep]
    if ctx.attr._verilator_runtime and CcInfo in ctx.attr._verilator_runtime:
        all_cc_deps.append(ctx.attr._verilator_runtime)

    # 4. Compile generated C++ files using Bazel C++ toolchain
    compilation_context, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [cpp_dir],
        public_hdrs = [hdr_dir],
        quote_includes = [hdr_dir.path],
        user_compile_flags = [
            ctx.attr.opt_fast,
            "-std=c++20",
            "-DVERILATOR=1",
            "-DVL_TIME_CONTEXT",
            "-DVM_TIMING=1",
            "-DVM_VPI=1",
            "-DVM_COVERAGE=0",
            "-DVM_SC=0",
            "-DVM_TRACE=0",
            "-DVM_TRACE_FST=0",
            "-DVM_TRACE_VCD=0",
            "-DVM_TRACE_SAIF=0",
            "-faligned-new",
            "-Wno-bool-operation",
            "-Wno-c++11-narrowing",
            "-Wno-overloaded-virtual",
            "-Wno-parentheses-equality",
            "-Wno-shadow",
            "-Wno-sign-compare",
            "-Wno-tautological-compare",
            "-Wno-uninitialized",
            "-Wno-unused-but-set-parameter",
            "-Wno-unused-but-set-variable",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
            "-Wno-vla-cxx-extension",
        ] + ctx.attr.copts,
        compilation_contexts = [dep[CcInfo].compilation_context for dep in all_cc_deps],
    )

    # 5. Create linking context (static library) with alwayslink = True
    linking_context, linking_output = cc_common.create_linking_context_from_compilation_outputs(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = [dep[CcInfo].linking_context for dep in all_cc_deps],
        name = ctx.label.name,
        alwayslink = True,
        disallow_dynamic_library = True,
    )

    output_files = []
    if linking_output.library_to_link.static_library != None:
        output_files.append(linking_output.library_to_link.static_library)
    if linking_output.library_to_link.pic_static_library != None:
        output_files.append(linking_output.library_to_link.pic_static_library)

    return [
        DefaultInfo(
            files = depset(output_files),
        ),
        CcInfo(
            compilation_context = compilation_context,
            linking_context = linking_context,
        ),
    ]

_uvm_verilator_cc_library = rule(
    doc = """Builds a static library from Verilated SystemVerilog for UVM simulation.""",
    implementation = _uvm_verilator_cc_library_impl,
    attrs = {
        "verilog_sources": attr.label_list(allow_files = True),
        "include_dirs": attr.label_list(allow_files = True),
        "hdl_toplevel": attr.string(mandatory = True),
        "cflags": attr.string_list(default = []),
        "copts": attr.string_list(default = []),
        "opt_fast": attr.string(default = "-O2"),
        "deps": attr.label_list(providers = [[DefaultInfo], [CcInfo], [VerilogInfo]]),
        "vlt_tpl": attr.label(
            default = "@coralnpu_hw//rules:default.vlt.tpl",
            allow_single_file = True,
        ),
        "_verilator": attr.label(
            default = "@verilator//:verilator",
            executable = True,
            cfg = "exec",
        ),
        "_verilator_bin": attr.label(
            default = "@verilator//:verilator_bin",
            executable = True,
            cfg = "exec",
        ),
        "_verilator_runtime": attr.label(
            default = "@verilator//:verilator_runtime",
        ),
        "_uvm_lib": attr.label(
            default = "@uvm//:all_srcs",
            allow_files = True,
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    fragments = ["cpp"],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
)

def _verilator_cc_library_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    verilog_inputs = []
    verilog_paths = []
    runfiles = []

    if VerilogInfo in ctx.attr.module:
        for node in ctx.attr.module[VerilogInfo].dag.to_list():
            for f in node.srcs + node.hdrs:
                verilog_inputs.append(f)
                if f.extension in ["v", "sv"]:
                    verilog_paths.append(f.path)
            for f in node.data:
                if f.extension in ["dat", "mem"]:
                    runfiles.append(f)
                else:
                    verilog_inputs.append(f)
                    verilog_paths.append(f.path)

    cpp_dir = ctx.actions.declare_directory(ctx.label.name + "_cpp")
    hdr_dir = ctx.actions.declare_directory(ctx.label.name + "_h")

    verilator_canonical = ctx.executable._verilator_bin.owner.workspace_name
    verilator_root = "{}.runfiles/{}".format(
        ctx.executable._verilator_bin.path,
        verilator_canonical,
    )

    prefix = "V" + ctx.attr.module_top
    verilator_flags = [
        "-j",
        str(verilator_make_parallelism),
        "--no-std",
        "--output-groups",
        "0",
    ]
    if ctx.attr.systemc:
        verilator_flags.append("--sc")
    else:
        verilator_flags.append("--cc")

    verilator_flags.extend([
        "--top-module",
        ctx.attr.module_top,
        "--prefix",
        prefix,
    ])

    if ctx.attr.trace:
        verilator_flags.append("--trace-fst")

    for opt in ctx.attr.vopts:
        verilator_flags.append(opt)

    verilator_flags.extend(verilog_paths)

    ctx.actions.run_shell(
        outputs = [cpp_dir, hdr_dir],
        tools = [ctx.executable._verilator_bin],
        inputs = depset(
            verilog_inputs,
            transitive = [
                depset(ctx.files._verilator),
            ],
        ),
        command = _VERILATOR_COMPILE_SCRIPT,
        arguments = [
            cpp_dir.path,
            hdr_dir.path,
            verilator_root,
            ctx.executable._verilator_bin.path,
        ] + verilator_flags,
        mnemonic = "VerilatorCompile",
        progress_message = "[Verilator] Compiling SystemVerilog to C++ for %s" % ctx.label,
        resource_set = verilator_resource_estimator,
    )

    defines = []
    if ctx.attr.systemc:
        defines.append("VM_SC")
    if ctx.attr.trace:
        defines.append("VM_TRACE")

    copts = [
        "-Wno-sign-compare",
        "-Wno-unused-variable",
        "-Wno-unused-parameter",
        "-Wno-unused-but-set-variable",
        "-Wno-bool-operation",
        "-Wno-tautological-compare",
        "-std=c++17",
    ] + ctx.attr.copts

    all_cc_deps = list(ctx.attr.deps)
    if ctx.attr._libverilator and CcInfo in ctx.attr._libverilator:
        all_cc_deps.append(ctx.attr._libverilator)
    if ctx.attr._zlib and CcInfo in ctx.attr._zlib:
        all_cc_deps.append(ctx.attr._zlib)
    if ctx.attr._svdpi and CcInfo in ctx.attr._svdpi:
        all_cc_deps.append(ctx.attr._svdpi)
    if ctx.attr.systemc and ctx.attr._systemc and CcInfo in ctx.attr._systemc:
        all_cc_deps.append(ctx.attr._systemc)

    compilation_contexts = [dep[CcInfo].compilation_context for dep in all_cc_deps]

    compilation_context, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [cpp_dir],
        public_hdrs = [hdr_dir],
        quote_includes = [hdr_dir.path],
        defines = defines,
        user_compile_flags = copts,
        compilation_contexts = compilation_contexts,
    )

    linking_contexts = [dep[CcInfo].linking_context for dep in all_cc_deps]

    linking_context, linking_output = cc_common.create_linking_context_from_compilation_outputs(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        name = ctx.label.name,
        disallow_dynamic_library = True,
    )

    output_files = []
    if linking_output.library_to_link.static_library != None:
        output_files.append(linking_output.library_to_link.static_library)
    if linking_output.library_to_link.pic_static_library != None:
        output_files.append(linking_output.library_to_link.pic_static_library)

    return [
        DefaultInfo(
            files = depset(output_files),
            runfiles = ctx.runfiles(files = runfiles),
        ),
        CcInfo(
            compilation_context = compilation_context,
            linking_context = linking_context,
        ),
    ]

verilator_cc_library = rule(
    doc = """Builds a C++ or SystemC static library from Verilog using Verilator.""",
    implementation = _verilator_cc_library_impl,
    attrs = {
        "module": attr.label(
            doc = "The top level module target to verilate.",
            providers = [VerilogInfo],
            mandatory = True,
        ),
        "module_top": attr.string(
            doc = "The name of the verilog module to verilate.",
            mandatory = True,
        ),
        "trace": attr.bool(
            doc = "Enable tracing for Verilator",
            default = True,
        ),
        "vopts": attr.string_list(
            doc = "Additional command line options to pass to Verilator",
            default = ["-Wall"],
        ),
        "systemc": attr.bool(
            doc = "Enable SystemC support",
            default = True,
        ),
        "copts": attr.string_list(
            doc = "List of additional compilation flags",
            default = [],
        ),
        "deps": attr.label_list(
            providers = [CcInfo],
            default = [],
        ),
        "_verilator": attr.label(
            default = "@verilator//:verilator",
            executable = True,
            cfg = "exec",
        ),
        "_verilator_bin": attr.label(
            default = "@verilator//:verilator_bin",
            executable = True,
            cfg = "exec",
        ),
        "_libverilator": attr.label(
            default = "@verilator//:libverilator",
        ),
        "_zlib": attr.label(
            default = "@net_zlib//:zlib",
        ),
        "_svdpi": attr.label(
            default = "@verilator//:svdpi",
        ),
        "_systemc": attr.label(
            default = "@accellera_systemc//:systemc",
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    provides = [CcInfo, DefaultInfo],
    fragments = ["cpp"],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
)

def verilator_model(
        name,
        hdl_toplevel,
        verilog_sources = [],
        include_dirs = [],
        cflags = [],
        copts = [],
        opt_fast = "-O2",
        deps = [],
        vlt_tpl = "@coralnpu_hw//rules:default.vlt.tpl",
        coralnpu_mpact_lib = None,
        **kwargs):
    """Builds a standalone Verilator simulation model binary."""
    lib_name = name + "_lib"
    all_deps = list(deps)
    if coralnpu_mpact_lib:
        target = coralnpu_mpact_lib
        if target == ":coralnpu_cosim_lib_static_archive" or "coralnpu_cosim_lib_static" in str(target):
            target = "@coralnpu_mpact//sim/cosim:coralnpu_cosim_lib"
        if target not in all_deps:
            all_deps.append(target)

    _uvm_verilator_cc_library(
        name = lib_name,
        hdl_toplevel = hdl_toplevel,
        verilog_sources = verilog_sources,
        include_dirs = include_dirs,
        cflags = cflags,
        copts = copts,
        opt_fast = opt_fast,
        deps = all_deps,
        vlt_tpl = vlt_tpl,
        tags = kwargs.get("tags", []),
        testonly = kwargs.get("testonly", False),
        visibility = ["//visibility:private"],
    )

    binary_kwargs = {k: v for k, v in kwargs.items() if k != "linkopts"}
    native.cc_binary(
        name = name,
        deps = [":" + lib_name],
        linkopts = kwargs.get("linkopts", []) + ["-lpthread", "-latomic", "-lstdc++", "-lm"],
        **binary_kwargs
    )

def _rlocation_path(ws, f):
    if f.short_path.startswith("../"):
        return f.short_path[len("../"):]
    return ws + "/" + f.short_path

def _verilator_batch_uvm_impl(ctx):
    runfiles = []
    run_spike_flag = ctx.attr.run_spike[BuildSettingInfo].value

    model_binary = None
    for f in ctx.files.model:
        if not f.path.endswith(".log"):
            model_binary = f
            break

    if not model_binary:
        fail("Model binary could not be found")

    spike_bin = None
    for f in ctx.files._spike:
        if f.basename == "spike":
            spike_bin = f
            break

    if run_spike_flag and not spike_bin:
        fail("Spike cosimulation enabled, but spike binary could not be found")

    ws = ctx.workspace_name
    runner = ctx.actions.declare_file(ctx.label.name)
    runfiles.extend(ctx.files.coralnpu_tests + [model_binary])
    if run_spike_flag:
        runfiles.append(spike_bin)
        spike_rloc = _rlocation_path(ws, spike_bin)
    else:
        spike_rloc = ""

    ctx.actions.symlink(output = runner, target_file = ctx.executable._runner, is_executable = True)

    coralnpu_elfs_fmt = []
    for file, label, timeout in zip(ctx.files.coralnpu_tests, ctx.attr.labels, ctx.attr.timeouts):
        enable_spike = run_spike_flag
        if enable_spike and label in SPIKE_DENYLIST:
            print("Warning: skipping spike cosim for {}, because it is listed in SPIKE_DENYLIST".format(label))
            enable_spike = False
        coralnpu_elfs_fmt.append("{}\t{}\t{}\t{}".format(_rlocation_path(ws, file), label, timeout, enable_spike))

    model_default_runfiles = ctx.attr.model[DefaultInfo].default_runfiles if ctx.attr.model[DefaultInfo].default_runfiles else ctx.runfiles()

    return [
        DefaultInfo(
            executable = runner,
            runfiles = ctx.runfiles(
                files = runfiles,
                collect_default = True,
            ).merge(ctx.attr._runner[DefaultInfo].default_runfiles).merge(model_default_runfiles),
        ),
        RunEnvironmentInfo(
            environment = {
                "UVM_MODEL_RLOCATION": _rlocation_path(ws, model_binary),
                "UVM_CORALNPU_ELFS": "\n".join(coralnpu_elfs_fmt),
                "UVM_SPIKE_RLOCATION": spike_rloc,
            },
        ),
    ]

verilator_batch_uvm_test = rule(
    doc = """Performs batch testing of the UVM Verilator model.""",
    implementation = _verilator_batch_uvm_impl,
    attrs = {
        "model": attr.label(allow_files = True),
        "coralnpu_tests": attr.label_list(allow_files = True),
        "timeouts": attr.int_list(mandatory = True),
        "labels": attr.string_list(mandatory = True),
        "run_spike": attr.label(
            providers = [BuildSettingInfo],
        ),
        "_spike": attr.label(
            default = Label("@riscv_isa_sim//:riscv_isa_sim"),
            allow_files = True,
        ),
        "_runner": attr.label(
            default = Label("//utils:uvm_batch_runner"),
            executable = True,
            cfg = "target",
        ),
    },
    test = True,
)
