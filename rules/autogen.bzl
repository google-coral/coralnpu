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

load("@rules_scala//scala:scala.bzl", "scala_library")

def _scm_info_src(ctx):
    out_source = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.run(
        outputs = [
            out_source,
        ],
        inputs = [
            ctx.executable._tool,
            ctx.version_file,
        ],
        arguments = [
            "-o",
            out_source.path,
            "-i",
            ctx.version_file.path,
        ],
        executable = ctx.executable._tool,
    )

    return [
        DefaultInfo(files = depset([out_source])),
    ]

autogen_scm_info_src = rule(
    implementation = _scm_info_src,
    attrs = {
        "_tool": attr.label(
            default = "//utils:scm_info",
            executable = True,
            cfg = "exec",
        ),
    },
)

def autogen_scm_info(name):
    """Generates a Scala library named `name` that defines SCM info."""

    scm_info_src_target = name + ".scala"
    autogen_scm_info_src(name = scm_info_src_target)

    scala_library(
        name = name,
        srcs = [scm_info_src_target],
    )
