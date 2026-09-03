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
        "-kdb",
        "+vcs+fsdbon",
        "+define+VCS",
        "-debug_access+all",
        "+notimingcheck",
        "-timescale=1ns/1ps",
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
