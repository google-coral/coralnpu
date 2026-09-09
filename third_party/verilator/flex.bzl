# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Build rule for generating C or C++ sources with Flex."""

def _genlex_impl(ctx):
    """Implementation for genlex rule."""
    if ctx.attr.prefix:
        prefix = ctx.attr.prefix
    else:
        prefix = ctx.file.src.basename.partition(".")[0]

    args = ctx.actions.args()
    args.add("-o", ctx.outputs.out)
    outputs = [ctx.outputs.out]
    if ctx.outputs.header_out:
        args.add("--header-file=%s" % ctx.outputs.header_out.path)
        outputs.append(ctx.outputs.header_out)
    args.add("-P", prefix)
    args.add_all(ctx.attr.lexopts)
    args.add(ctx.file.src)

    ctx.actions.run(
        executable = ctx.executable._flex,
        env = {
            "M4": ctx.executable._m4.path,
        },
        arguments = [args],
        inputs = ctx.files.src + ctx.files.includes,
        tools = [ctx.executable._m4],
        outputs = outputs,
        mnemonic = "Flex",
        progress_message = "Generating %s from %s" % (
            ctx.outputs.out.short_path,
            ctx.file.src.short_path,
        ),
    )

genlex = rule(
    implementation = _genlex_impl,
    doc = "Generate C/C++-language sources from a lex file using Flex.",
    attrs = {
        "header_out": attr.output(
            mandatory = False,
            doc = "The generated header file",
        ),
        "includes": attr.label_list(
            allow_files = True,
            doc = "A list of headers that are included by the .lex file",
        ),
        "lexopts": attr.string_list(
            doc = "A list of options to be added to the flex command line.",
        ),
        "out": attr.output(mandatory = True, doc = "The generated source file"),
        "prefix": attr.string(
            doc = "External symbol prefix for Flex.",
            default = "yy",
        ),
        "src": attr.label(
            mandatory = True,
            allow_single_file = [".l", ".ll", ".lex", ".lpp"],
            doc = "The .lex source file for this rule",
        ),
        "_flex": attr.label(
            default = "@com_github_westes_flex//:flex",
            executable = True,
            cfg = "exec",
        ),
        "_m4": attr.label(
            default = "@org_gnu_m4//:m4",
            executable = True,
            cfg = "exec",
        ),
    },
)
