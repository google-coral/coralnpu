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

"""VCStatic lint rules."""

load("//rules:verilog.bzl", "VerilogInfo", "collect_verilog_files")

def _vcstatic_lint_impl(ctx):
    # Create f file
    f_file = ctx.actions.declare_file(ctx.attr.name + "_files.f")
    verilog_files = collect_verilog_files(ctx.attr.package).to_list()
    f_file_content = ["+define+SIMULATION"]
    for f in verilog_files:
        f_file_content = f_file_content + [f.path]
    f_file_content = "\n".join(f_file_content) + "\n"
    ctx.actions.write(f_file, f_file_content)

    # Generate the lint script from template
    vc_static_script = ctx.actions.declare_file(
        ctx.attr.name + "_vc_shell.prj",
    )
    report_violations = ctx.actions.declare_file(ctx.attr.name + "_lint.rpt")

    ctx.actions.expand_template(
        template = ctx.attr._lint_script.files.to_list()[0],
        output = vc_static_script,
        substitutions = {
            "{F_FILE}": f_file.path,
            "{MODULE_TO_LINT}": ctx.attr.module,
            "{REPORT_VIOLATIONS_FILE}": report_violations.path,
            "{BLACKBOX_DESIGNS}": " ".join(ctx.attr.blackbox_designs),
            "{BLACKBOX_FILES}": " ".join(ctx.attr.blackbox_files),
            "{GOAL}": ctx.attr.goal,
            "{LINT_TAGS}": " ".join(ctx.attr.lint_tags),
            "{WAIVE_TAGS}": " ".join(ctx.attr.waive_tags),
        },
    )

    # Run lint
    command = [
        "vc_static_shell",
        "-file",
        vc_static_script.path,
    ]
    ctx.actions.run_shell(
        outputs = [report_violations],
        inputs = [vc_static_script, f_file] + verilog_files,
        command = " ".join(command),
        use_default_shell_env = True,
    )

    return [DefaultInfo(files = depset([report_violations]))]

_vcstatic_lint = rule(
    _vcstatic_lint_impl,
    attrs = {
        "package": attr.label(
            doc = "The verilog target to create a test bench for.",
            providers = [VerilogInfo],
            mandatory = True,
        ),
        "module": attr.string(
            doc = "The name of the verilog module to lint.",
            mandatory = True,
        ),
        "blackbox_designs": attr.string_list(
            doc = "Verilog designs to mark as blackboxes.",
            allow_empty = True,
        ),
        "blackbox_files": attr.string_list(
            doc = "Verilog files to mark as blackboxes.",
            allow_empty = True,
        ),
        "goal": attr.string(
            doc = "Lint goal to execute.",
            default = "lint_rtl_check",
        ),
        "lint_tags": attr.string_list(
            doc = "Additional lint tags to enable.",
            allow_empty = True,
        ),
        "waive_tags": attr.string_list(
            doc = "Lint tags to waive.",
            allow_empty = True,
        ),
        "_lint_script": attr.label(
            doc = "Template file to use to generate vc_static script",
            allow_files = True,
            default = Label("//rules/lint:vc_shell.prj.tpl"),
        ),
    },
)

def vcstatic_lint(name, tags = [], **kwargs):
    _vcstatic_lint(name = name, tags = ["vcs"] + tags, **kwargs)
