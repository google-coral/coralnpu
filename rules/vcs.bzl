# Copyright 2024 Google LLC
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

"""Bazel functions for VCS."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@coralnpu_hw//rules:verilog.bzl", "collect_verilog_files")
load("@rules_hdl//verilog:providers.bzl", "VerilogInfo")
load("//rules:uvm_denylist.bzl", "SPIKE_DENYLIST")

def _has_compile_time_coverage(command):
    """Returns True if the given VCS command enables code coverage (-cm)."""
    for arg in command:
        if arg == "-cm" or arg.startswith("-cm="):
            return True
    return False

def _vcs_testbench_test_impl(ctx):
    all_files = collect_verilog_files(ctx.attr.deps).to_list()

    vcs_binary_output = ctx.actions.declare_file(ctx.attr.module)
    vcs_daidir_output = ctx.actions.declare_directory(
        ctx.attr.module + ".daidir",
    )

    verilog_files = []
    for file in all_files:
        if file.extension in ["dat", "mem"]:
            continue
        verilog_files.append(file)

    command = [
        "vcs",
        "-full64",
        "-sverilog",
    ]
    verilog_dirs = dict()
    for file in verilog_files:
        verilog_dirs[file.dirname] = None
    for verilog_file in verilog_files:
        command.append(verilog_file.path)
    command.append("-o")
    command.append(vcs_binary_output.path)

    ctx.actions.run_shell(
        outputs = [vcs_binary_output, vcs_daidir_output],
        inputs = verilog_files,
        command = " ".join(command),
        use_default_shell_env = True,
        execution_requirements = {"no-sandbox": "1"},
    )

    return [DefaultInfo(
        runfiles = ctx.runfiles(files = [vcs_daidir_output]),
        executable = vcs_binary_output,
    )]

_vcs_testbench_test = rule(
    _vcs_testbench_test_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label(
            doc = "The verilog target to create a test bench for.",
            providers = [VerilogInfo],
            mandatory = True,
        ),
        "module": attr.string(
            doc = "The name of the verilog module to verilate.",
            mandatory = True,
        ),
    },
    test = True,
)

def vcs_testbench_test(name, tags = [], **kwargs):
    _vcs_testbench_test(name = name, tags = ["vcs"] + tags, **kwargs)

def _vcs_binary_impl(ctx):
    verilog_files = collect_verilog_files(ctx.attr.verilog_deps, ctx.files.verilog_srcs).to_list()

    libs = []
    objects = []
    cflags = []
    headers_depsets = []

    for dep in ctx.attr.deps:
        # 1. Gather include paths and headers depset
        compilation_context = dep[CcInfo].compilation_context
        headers_depsets.append(compilation_context.headers)
        for include in compilation_context.quote_includes.to_list():
            cflags += ["-cflags", "-I" + include]
        for include in compilation_context.system_includes.to_list():
            cflags += ["-cflags", "-I" + include]

        # 2. Gather static libraries and object files
        transitive_linker_inputs = depset([], transitive = [dep[CcInfo].linking_context.linker_inputs])
        for link in transitive_linker_inputs.to_list():
            for library in link.libraries:
                if library.pic_static_library:
                    libs.append(library.pic_static_library)
                elif library.static_library:
                    libs.append(library.static_library)
                if library.pic_objects:
                    for obj in library.pic_objects:
                        objects.append(obj)
                elif library.objects:
                    for obj in library.objects:
                        objects.append(obj)

    vcs_binary_output = ctx.actions.declare_file(ctx.attr.name)
    vcs_simv_output = ctx.actions.declare_file(ctx.attr.name + "_simv")
    vcs_daidir_output = ctx.actions.declare_directory(ctx.attr.name + "_simv.daidir")

    script = ctx.actions.declare_file(ctx.attr.name + "_vcs_link.sh")

    script_content = [
        "#!/bin/bash",
        "set -e",
        "mkdir -p stripped_libs",
    ]

    stripped_libs = []
    for lib in libs:
        stripped_path = "stripped_libs/" + lib.basename
        script_content.append("cp -f %s %s" % (lib.path, stripped_path))
        script_content.append("chmod +w %s" % stripped_path)
        script_content.append("objcopy --remove-section=.sframe %s" % stripped_path)
        stripped_libs.append(stripped_path)

    stripped_objects = []
    for obj in objects:
        stripped_path = "stripped_libs/" + obj.basename
        script_content.append("cp -f %s %s" % (obj.path, stripped_path))
        script_content.append("chmod +w %s" % stripped_path)
        script_content.append("objcopy --remove-section=.sframe %s" % stripped_path)
        stripped_objects.append(stripped_path)

    vcs_command = [
        "vcs",
        "-full64",
        "-sverilog",
        "-q",
        "+define+VCS",
        "-debug_access+all",
        "+notimingcheck",
        "-timescale=1ns/1ps",
        "-Mdir=" + vcs_simv_output.path + ".csrc",
        "-cflags",
        "-I..",
        "-o",
        vcs_simv_output.path,
    ] + cflags + ctx.attr.build_args

    # Append coverage metrics requested via --//rules:vcs_coverage_types unless
    # the target already compiles with its own -cm flag.
    coverage_types = ctx.attr._vcs_coverage_types[BuildSettingInfo].value
    if coverage_types and not _has_compile_time_coverage(vcs_command):
        vcs_command.extend(["-cm", "+".join(coverage_types)])
    coverage_enabled = _has_compile_time_coverage(vcs_command)

    package_files = []
    other_files = []
    for file in verilog_files:
        if file.basename.endswith("pkg.sv") or file.basename.endswith("Pkg.sv") or file.basename.startswith("defs_"):
            package_files.append(file)
        else:
            other_files.append(file)
    sorted_verilog_files = package_files + other_files

    for file in sorted_verilog_files:
        vcs_command.append(file.path)

    for file in ctx.files.srcs:
        vcs_command.append(file.path)

    for lib_path in stripped_libs:
        vcs_command.append(lib_path)

    for obj_path in stripped_objects:
        vcs_command.append(obj_path)

    script_content.append(" ".join(vcs_command))

    ctx.actions.write(script, "\n".join(script_content), is_executable = True)

    # Generate user-facing runner script!
    runner_content = [
        "#!/bin/bash",
        'SIMV_ARGS=("-q" "-suppress=ASLR_DETECTED_INFO" "-no_save")',
        'for arg in "$@"; do',
        '  if [[ "$arg" == --binary=* ]]; then',
        '    val="${arg#*=}"',
        '    SIMV_ARGS+=("+binary=$val")',
        '  elif [[ "$arg" == --cycles=* ]]; then',
        '    val="${arg#*=}"',
        '    SIMV_ARGS+=("+cycles=$val")',
        '  elif [[ "$arg" == --trace ]]; then',
        '    SIMV_ARGS+=("+trace")',
        "  else",
        '    SIMV_ARGS+=("$arg")',
        "  fi",
        "done",
    ]
    if coverage_enabled:
        runner_content.append("# Detect a user-supplied -cm_dir (accepts \"-cm_dir path\" and \"-cm_dir=path\").")
        runner_content.append("USER_CM_DIR=0")
        runner_content.append('for arg in "${SIMV_ARGS[@]}"; do')
        runner_content.append('  case "$arg" in')
        runner_content.append("    -cm_dir|-cm_dir=*) USER_CM_DIR=1 ;;")
        runner_content.append("  esac")
        runner_content.append("done")
    runner_content.append('RUNNER_DIR=$(dirname "$0")')
    if coverage_enabled:
        runner_content += [
            "",
            "# Code coverage is compiled into this simv (-cm). VCS derives the default",
            "# coverage database from argv[0], which points into bazel-out; a leftover",
            "# database there from an earlier build makes the simv abort at startup",
            "# with Error-[MON-ICDF] (Incompatible Code Coverage Directory).",
            "# Remove any stale database and redirect -cm_dir to a writable per-run",
            "# directory instead (override with VCS_COVERAGE_DIR to accumulate runs).",
            'rm -rf "$RUNNER_DIR/%s_simv.vdb"' % ctx.attr.name,
            'COV_DB_DIR=""',
            'if [[ "$USER_CM_DIR" -eq 0 ]]; then',
            "  COV_DB_DIR=\"${VCS_COVERAGE_DIR:-${TEST_TMPDIR:-$PWD}/" + ctx.attr.name + "_coverage.$$_$(date +%s)}\"",
            '  SIMV_ARGS+=("-cm_dir" "$COV_DB_DIR")',
            "fi",
        ]
    runner_content.append("# Filter out Synopsys noise!")
    runner_content += [
        '"$RUNNER_DIR/%s_simv" "${SIMV_ARGS[@]}" 2>&1 | grep -v -E \\' % ctx.attr.name,
        '  -e "^Chronologic VCS simulator" \\',
        '  -e "^Contains Synopsys proprietary" \\',
        '  -e "^Compiler version" \\',
        '  -e "^Notice: timing checks" \\',
        '  -e "^\\*Verdi\\*" \\',
        '  -e "^FSDB Dumper for VCS" \\',
        '  -e "^\\(C\\) 1996" \\',
        '  -e "^Time: 0 ps" \\',
        '  -e "^CPU Time:" \\',
        '  -e "^[A-Za-z]{3} [A-Za-z]{3} [ 0-9]{2}" \\',
        '  -e "^           V C S   S i m u l a t i o n" || true',
    ]
    if coverage_enabled:
        runner_content += [
            'if [[ -n "$COV_DB_DIR" ]]; then',
            '  echo "VCS coverage database written under: $COV_DB_DIR"',
            '  echo "Coverage report: urg -dir \\"$COV_DB_DIR\\"/<simv>.vdb -report \\"$COV_DB_DIR\\"/urgReport"',
            "fi",
        ]
    ctx.actions.write(vcs_binary_output, "\n".join(runner_content), is_executable = True)

    headers_depset = depset([], transitive = headers_depsets)
    ctx.actions.run(
        inputs = depset(verilog_files + ctx.files.srcs + libs + objects, transitive = [headers_depset]),
        outputs = [vcs_simv_output, vcs_daidir_output],
        executable = script,
        use_default_shell_env = True,
        execution_requirements = {"no-sandbox": "1"},
        progress_message = "[VCS Link] Linking %s" % ctx.label,
    )

    return [DefaultInfo(
        files = depset([vcs_binary_output]),
        runfiles = ctx.runfiles(files = [vcs_simv_output, vcs_daidir_output]),
        executable = vcs_binary_output,
    )]

_vcs_binary = rule(
    _vcs_binary_impl,
    attrs = {
        "verilog_srcs": attr.label_list(allow_files = True),
        "srcs": attr.label_list(allow_files = True),
        "verilog_deps": attr.label_list(
            doc = "Verilog library dependencies",
            providers = [VerilogInfo],
        ),
        "deps": attr.label_list(
            doc = "C++ static library dependencies",
            providers = [CcInfo],
        ),
        "build_args": attr.string_list(allow_empty = True),
        "_vcs_coverage_types": attr.label(
            doc = "Coverage metrics flag (--//rules:vcs_coverage_types).",
            default = Label("//rules:vcs_coverage_types"),
        ),
        "_cc_toolchain": attr.label(
            doc = "CC compiler.",
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    executable = True,
)

def vcs_binary(name, tags = [], **kwargs):
    _vcs_binary(name = name, tags = ["vcs"] + tags, **kwargs)

def _rlocation_path(workspace_name, file):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    else:
        return workspace_name + "/" + file.short_path

def _vcs_model_impl(ctx):
    all_sources = []
    for src in ctx.attr.verilog_sources:
        if VerilogInfo in src:
            all_sources.extend(collect_verilog_files([src]).to_list())
        else:
            all_sources.extend(src[DefaultInfo].files.to_list())

    sv_files = []
    c_files = []
    extra_libs = []

    for f in all_sources:
        if f.extension in ["sv", "v"]:
            sv_files.append(f)
        elif f.extension in ["c", "cc", "cpp", "cxx"]:
            c_files.append(f)
        elif f.extension in ["a", "o"]:
            extra_libs.append(f)

    # Separate SV files: interfaces first, then packages/defs, then rest
    if_files = []
    pkg_files = []
    other_sv = []
    for f in sv_files:
        if f.basename.endswith("_if.sv"):
            if_files.append(f)
        elif f.basename.endswith("pkg.sv") or f.basename.endswith("Pkg.sv") or f.basename.startswith("defs_"):
            pkg_files.append(f)
        else:
            other_sv.append(f)
    sorted_sv_files = if_files + pkg_files + other_sv

    libs = list(extra_libs)
    objects = []
    cflags = []
    headers_depsets = []

    for f in ctx.files.coralnpu_mpact_lib:
        if f.extension == "a":
            libs.append(f)
        elif f.extension == "o":
            objects.append(f)

    for dep in ctx.attr.deps:
        if CcInfo in dep:
            compilation_context = dep[CcInfo].compilation_context
            headers_depsets.append(compilation_context.headers)
            for inc in compilation_context.includes.to_list():
                cflags += ["-cflags", "-I" + inc]
            for inc in compilation_context.quote_includes.to_list():
                cflags += ["-cflags", "-I" + inc]
            for inc in compilation_context.system_includes.to_list():
                cflags += ["-cflags", "-I" + inc]

            transitive_linker_inputs = depset([], transitive = [dep[CcInfo].linking_context.linker_inputs])
            for link in transitive_linker_inputs.to_list():
                for library in link.libraries:
                    if library.pic_static_library:
                        libs.append(library.pic_static_library)
                    elif library.static_library:
                        libs.append(library.static_library)
                    if library.pic_objects:
                        for obj in library.pic_objects:
                            objects.append(obj)
                    elif library.objects:
                        for obj in library.objects:
                            objects.append(obj)

    unique_libs = []
    seen_libs = {}
    for lib in libs:
        if lib.path not in seen_libs:
            seen_libs[lib.path] = True
            unique_libs.append(lib)

    unique_objects = []
    seen_objs = {}
    for obj in objects:
        if obj.path not in seen_objs:
            seen_objs[obj.path] = True
            unique_objects.append(obj)

    vcs_binary_output = ctx.actions.declare_file(ctx.attr.name)
    vcs_simv_output = ctx.actions.declare_file(ctx.attr.name + "_simv")
    vcs_daidir_output = ctx.actions.declare_directory(ctx.attr.name + "_simv.daidir")

    script = ctx.actions.declare_file(ctx.attr.name + "_vcs_compile.sh")

    script_content = [
        "#!/bin/bash",
        "set -e",
        "mkdir -p stripped_libs",
    ]

    stripped_libs = []
    for i, lib in enumerate(unique_libs):
        stripped_path = "stripped_libs/%d_%s" % (i, lib.basename)
        script_content.append("cp -f %s %s" % (lib.path, stripped_path))
        script_content.append("chmod +w %s" % stripped_path)
        script_content.append("objcopy --remove-section=.sframe %s 2>/dev/null || true" % stripped_path)
        stripped_libs.append(stripped_path)

    stripped_objects = []
    for i, obj in enumerate(unique_objects):
        stripped_path = "stripped_libs/%d_%s" % (i, obj.basename)
        script_content.append("cp -f %s %s" % (obj.path, stripped_path))
        script_content.append("chmod +w %s" % stripped_path)
        script_content.append("objcopy --remove-section=.sframe %s 2>/dev/null || true" % stripped_path)
        stripped_objects.append(stripped_path)

    vcs_command = [
        "vcs",
        "-full64",
        "-sverilog",
        "-q",
        "+define+VCS",
        "-debug_access+all",
        "+notimingcheck",
        "-timescale=1ns/1ps",
        "-Mdir=" + vcs_simv_output.path + ".csrc",
        "-cpp",
        "clang++",
        "-cflags",
        "-std=c++17",
        "-cflags",
        "-I.",
        "-cflags",
        "-I..",
        "-LDFLAGS",
        "\"-lstdc++ -lm -lpthread -latomic -ldl\"",
        "-o",
        vcs_simv_output.path,
    ]

    if ctx.attr.hdl_toplevel:
        vcs_command.extend(["-top", ctx.attr.hdl_toplevel])

    for inc_file in ctx.files.include_dirs:
        vcs_command.append("+incdir+" + inc_file.path)
    vcs_command.append("+incdir+.")
    vcs_command.append("+incdir+tests/uvm")
    vcs_command.append("+incdir+tests/uvm/common")

    vcs_command += cflags
    vcs_command += ctx.attr.cflags

    for f in sorted_sv_files:
        vcs_command.append(f.path)

    for f in c_files:
        vcs_command.append(f.path)

    for lib_path in stripped_libs:
        vcs_command.append(lib_path)

    for obj_path in stripped_objects:
        vcs_command.append(obj_path)

    script_content.append(" ".join(vcs_command))
    ctx.actions.write(script, "\n".join(script_content), is_executable = True)

    runner_content = [
        "#!/bin/bash",
        'SIMV_ARGS=("-q" "-suppress=ASLR_DETECTED_INFO" "-no_save")',
        'for arg in "$@"; do',
        '  if [[ "$arg" == --binary=* ]]; then',
        '    val="${arg#*=}"',
        '    SIMV_ARGS+=("+binary=$val")',
        '  elif [[ "$arg" == --cycles=* ]]; then',
        '    val="${arg#*=}"',
        '    SIMV_ARGS+=("+cycles=$val")',
        '  elif [[ "$arg" == --trace ]]; then',
        '    SIMV_ARGS+=("+trace")',
        "  else",
        '    SIMV_ARGS+=("$arg")',
        "  fi",
        "done",
        'RUNNER_DIR=$(dirname "$0")',
        'exec "$RUNNER_DIR/%s_simv" "${SIMV_ARGS[@]}"' % ctx.attr.name,
    ]
    ctx.actions.write(vcs_binary_output, "\n".join(runner_content), is_executable = True)

    headers_depset = depset([], transitive = headers_depsets)
    action_inputs = depset(
        all_sources + unique_libs + unique_objects + ctx.files.coralnpu_mpact_lib + ctx.files.deps,
        transitive = [headers_depset],
    )

    ctx.actions.run(
        inputs = action_inputs,
        outputs = [vcs_simv_output, vcs_daidir_output],
        executable = script,
        use_default_shell_env = True,
        execution_requirements = {"no-sandbox": "1"},
        progress_message = "[VCS Compile] Compiling VCS model %s" % ctx.label,
    )

    return [
        DefaultInfo(
            files = depset([vcs_binary_output]),
            runfiles = ctx.runfiles(files = [vcs_simv_output, vcs_daidir_output]),
            executable = vcs_binary_output,
        ),
        OutputGroupInfo(
            all_files = depset([vcs_binary_output, vcs_simv_output, vcs_daidir_output]),
        ),
    ]

_vcs_model = rule(
    _vcs_model_impl,
    attrs = {
        "verilog_sources": attr.label_list(allow_files = True),
        "include_dirs": attr.label_list(allow_files = True),
        "hdl_toplevel": attr.string(mandatory = True),
        "cflags": attr.string_list(default = []),
        "coralnpu_mpact_lib": attr.label(allow_files = True),
        "deps": attr.label_list(
            doc = "Dependencies (CcInfo, VerilogInfo, DefaultInfo)",
            providers = [[CcInfo], [VerilogInfo], [DefaultInfo]],
        ),
        "_cc_toolchain": attr.label(
            doc = "CC compiler.",
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    executable = True,
)

def vcs_model(name, tags = [], **kwargs):
    _vcs_model(name = name, tags = ["vcs"] + tags, **kwargs)

def _vcs_batch_uvm_impl(ctx):
    runfiles = []
    run_spike_flag = ctx.attr.run_spike[BuildSettingInfo].value

    model_binary = None
    for f in ctx.files.model:
        if not f.path.endswith(".log") and not f.path.endswith(".daidir"):
            model_binary = f
            break

    if not model_binary:
        fail("Model binary could not be found")

    ws = "coralnpu_hw"
    runner = ctx.actions.declare_file(ctx.label.name)
    runfiles.extend(ctx.files.coralnpu_tests + [model_binary])

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
                "UVM_SPIKE_RLOCATION": "SPIKE" if run_spike_flag else "",
            },
        ),
    ]

_vcs_batch_uvm_test = rule(
    doc = """Performs batch testing of the UVM VCS model.""",
    implementation = _vcs_batch_uvm_impl,
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

def vcs_batch_uvm_test(name, tags = [], **kwargs):
    _vcs_batch_uvm_test(name = name, tags = ["vcs"] + tags, **kwargs)
