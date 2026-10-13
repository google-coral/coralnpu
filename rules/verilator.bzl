"""Bazel functions for Verilator."""

load("@coralnpu_hw//rules:coco_tb.bzl", "verilator_make_parallelism", "verilator_resource_estimator")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
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
active_compilation_units = set()
target_prefixes = ("VM_CLASSES_", "VM_SUPPORT_", "VM_GLOBAL_")

for entry in os.scandir(raw):
    if entry.is_file() and entry.name.endswith("_classes.mk"):
        with open(entry.path, "r", errors="replace") as f:
            in_target = False
            for line in f:
                line = line.strip()
                if "#" in line:
                    line = line[:line.index("#")].strip()
                if not line:
                    continue
                if "=" in line:
                    in_target = any(line.startswith(p) for p in target_prefixes)
                    line = line.split("=", 1)[1].strip()
                if in_target:
                    for tok in line.replace(chr(92), " ").split():
                        tok = tok.strip()
                        if tok and tok != chr(92):
                            active_compilation_units.add(tok)

for entry in os.scandir(raw):
    if not entry.is_file():
        continue
    name = entry.name
    if name.endswith((".h", ".hh", ".hpp")):
        shutil.move(entry.path, os.path.join(hdr, name))
    elif name.endswith((".cpp", ".cc", ".cxx")):
        base = name.rsplit(".", 1)[0]
        if not active_compilation_units or base in active_compilation_units:
            shutil.move(entry.path, os.path.join(cpp, name))
        else:
            shutil.move(entry.path, os.path.join(hdr, name))
' "$RAW_DIR" "$1" "$2"
"""

_UVM_VERILATOR_COMPILE_SCRIPT = """
set -e
RAW_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'verilator_raw')"
trap 'rm -rf "$RAW_DIR"' EXIT
mkdir -p "$1" "$2" "$3"
VERILATOR_ROOT="$4" "$5" "${@:6}" -Mdir "$RAW_DIR"
python3 -c '
import glob, os, re, shutil, sys
raw, cpp_fast, cpp_slow, hdr = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# 1. Inline #include "foo.cpp" inside Verilator --output-groups *_vm_*.cpp files
vm_files = sorted(glob.glob(os.path.join(raw, "*_vm_*.cpp")))
included_files = set()
for vf in vm_files:
    out_lines = []
    with open(vf, "r", encoding="utf-8") as fp:
        for line in fp:
            m = re.match(r"^#include\\s+\\"([^\\"]+\\.cpp)\\"", line.strip())
            if m:
                inc_name = m.group(1)
                inc_path = os.path.join(raw, inc_name)
                if os.path.exists(inc_path):
                    included_files.add(inc_name)
                    with open(inc_path, "r", encoding="utf-8") as inc_fp:
                        out_lines.append(inc_fp.read())
                    continue
            out_lines.append(line)
    with open(vf, "w", encoding="utf-8") as fp:
        fp.writelines(out_lines)

for inc_name in included_files:
    inc_path = os.path.join(raw, inc_name)
    if os.path.exists(inc_path):
        os.remove(inc_path)

# 2. Group remaining ungrouped *Slow.cpp files into batches of 4
leftover_slow = sorted([
    f for f in os.listdir(raw)
    if f.endswith("Slow.cpp") and "_vm_" not in f
])
batch_size = 4
for idx in range(0, len(leftover_slow), batch_size):
    batch = leftover_slow[idx:idx + batch_size]
    if len(batch) > 1:
        merged_path = os.path.join(raw, f"Vtop_vm_extra_Slow_{idx // batch_size}.cpp")
        with open(merged_path, "w", encoding="utf-8") as out_fp:
            for fname in batch:
                fpath = os.path.join(raw, fname)
                with open(fpath, "r", encoding="utf-8") as in_fp:
                    out_fp.write(in_fp.read() + "\\n")
                os.remove(fpath)

# 3. Distribute fast .cpp, slow .cpp, and .h files
for entry in os.scandir(raw):
    if entry.is_file():
        if entry.name.endswith((".cpp", ".cc", ".cxx")):
            if "Slow" in entry.name:
                shutil.move(entry.path, os.path.join(cpp_slow, entry.name))
            else:
                shutil.move(entry.path, os.path.join(cpp_fast, entry.name))
        elif entry.name.endswith((".h", ".hh", ".hpp")):
            shutil.move(entry.path, os.path.join(hdr, entry.name))
' "$RAW_DIR" "$1" "$2" "$3"
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

    # 2. Collect CcInfo dependencies
    all_cc_deps = [dep for dep in ctx.attr.deps if CcInfo in dep]
    if ctx.attr._verilator_runtime and CcInfo in ctx.attr._verilator_runtime:
        all_cc_deps.append(ctx.attr._verilator_runtime)

    # 3. Codegen Action: Run Verilator to generate C++ code into cpp_fast_dir, cpp_slow_dir, and hdr_dir
    cpp_fast_dir = ctx.actions.declare_directory(ctx.label.name + "_cpp_fast")
    cpp_slow_dir = ctx.actions.declare_directory(ctx.label.name + "_cpp_slow")
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
    verilator_flags.extend([
        "--output-split",
        "20000",
        "--output-split-cfuncs",
        "2000",
        "--output-groups",
        str(min(verilator_make_parallelism, 32)),
    ])
    verilator_flags.append(vlt_file.path)
    verilator_flags.extend(verilog_paths)

    ctx.actions.run_shell(
        outputs = [cpp_fast_dir, cpp_slow_dir, hdr_dir],
        tools = [ctx.executable._verilator_bin],
        inputs = depset(
            verilog_inputs,
            transitive = [
                depset(ctx.files._verilator),
                depset(ctx.files._uvm_lib),
            ],
        ),
        command = _UVM_VERILATOR_COMPILE_SCRIPT,
        arguments = [
            cpp_fast_dir.path,
            cpp_slow_dir.path,
            hdr_dir.path,
            verilator_root,
            ctx.executable._verilator_bin.path,
        ] + verilator_flags,
        mnemonic = "VerilatorCodegen",
        progress_message = "Verilating SystemVerilog to C++ for %s" % ctx.label,
        resource_set = verilator_resource_estimator,
    )

    common_compile_flags = [
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
    ] + ctx.attr.copts

    # 4a. Compile fast generated C++ files with opt_fast (-O2)
    compilation_context, fast_compilation_outputs = cc_common.compile(
        name = ctx.label.name + "_fast",
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [cpp_fast_dir],
        public_hdrs = [hdr_dir],
        quote_includes = [hdr_dir.path],
        user_compile_flags = [ctx.attr.opt_fast] + common_compile_flags,
        compilation_contexts = [dep[CcInfo].compilation_context for dep in all_cc_deps],
    )

    # 4b. Compile slow/cold generated C++ files with -O0
    _, slow_compilation_outputs = cc_common.compile(
        name = ctx.label.name + "_slow",
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [cpp_slow_dir],
        public_hdrs = [hdr_dir],
        quote_includes = [hdr_dir.path],
        user_compile_flags = common_compile_flags + ["-O0"],
        compilation_contexts = [dep[CcInfo].compilation_context for dep in all_cc_deps],
    )

    compilation_outputs = cc_common.merge_compilation_outputs(
        compilation_outputs = [fast_compilation_outputs, slow_compilation_outputs],
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
        str(min(verilator_make_parallelism, 32)),
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
        linkopts = kwargs.get("linkopts", []) + ["-lpthread", "-latomic", "-ldl", "-lstdc++", "-lm"],
        **binary_kwargs
    )
