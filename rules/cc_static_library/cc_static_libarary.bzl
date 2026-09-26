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

"""Provides a rule that outputs a monolithic static library."""

load(
    "@bazel_tools//tools/cpp:toolchain_utils.bzl",
    "find_cpp_toolchain",
    "use_cpp_toolchain",
)
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _cc_static_library_impl(ctx):
    output_lib = ctx.actions.declare_file("lib{}.a".format(ctx.attr.name))
    output_flags = ctx.actions.declare_file("lib{}.link".format(ctx.attr.name))

    cc_toolchain = find_cpp_toolchain(ctx)

    lib_sets = []
    for dep in ctx.attr.deps:
        lib_sets.append(dep[CcInfo].linking_context.linker_inputs)
    input_depset = depset(transitive = lib_sets)

    unique_flags = {}
    for inp in input_depset.to_list():
        for flag in inp.user_link_flags:
            unique_flags[flag] = None
    link_flags = unique_flags.keys()

    libs = []
    for inp in input_depset.to_list():
        for lib in inp.libraries:
            if lib.pic_static_library:
                libs.append(lib.pic_static_library)
            elif lib.static_library:
                libs.append(lib.static_library)

    script_file = ctx.actions.declare_file("lib{}_merge.sh".format(ctx.attr.name))
    script_lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        "WORK_DIR=$(mktemp -d)",
        'trap "rm -rf \\"$WORK_DIR\\"" EXIT',
        "ROOT_DIR=$PWD",
        'AR_EXEC="{}"'.format(cc_toolchain.ar_executable),
        'if [[ "$AR_EXEC" != /* ]]; then AR_EXEC="$ROOT_DIR/$AR_EXEC"; fi',
        "INDEX=0",
    ]
    for lib in libs:
        script_lines.extend([
            'DIR="$WORK_DIR/lib_$INDEX"',
            'mkdir -p "$DIR"',
            '(cd "$DIR" && "$AR_EXEC" x "$ROOT_DIR/{}")'.format(lib.path),
            "INDEX=$((INDEX + 1))",
        ])
    script_lines.extend([
        "rm -f {}".format(output_lib.path),
        'find "$WORK_DIR" -name "*.o" | sort | xargs "$AR_EXEC" rcs {}'.format(
            output_lib.path,
        ),
    ])
    ctx.actions.write(
        output = script_file,
        content = "\n".join(script_lines) + "\n",
        is_executable = True,
    )

    ctx.actions.run(
        executable = script_file,
        inputs = libs + cc_toolchain.all_files.to_list(),
        outputs = [output_lib],
        mnemonic = "ArMerge",
        progress_message = "Merging static library {}".format(output_lib.path),
    )
    ctx.actions.write(
        output = output_flags,
        content = "\n".join(link_flags) + "\n",
    )
    return [
        DefaultInfo(files = depset([output_flags, output_lib])),
    ]

cc_static_library = rule(
    implementation = _cc_static_library_impl,
    attrs = {
        "deps": attr.label_list(),
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
        ),
    },
    toolchains = use_cpp_toolchain(),
)
