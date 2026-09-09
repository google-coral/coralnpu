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

"""Verilog packaging rules"""

VerilogInfo = provider(
    doc = "Contains DAG info per node in a struct.",
    fields = {
        "dag": "A depset of the DAG entries to propagate upwards.",
        "plis": "a depset of VerilogInterfaceInfo",
    },
)

def make_dag_entry(srcs, hdrs, data, deps, label):
    """Create a new DAG entry for use in VerilogInfo."""
    return struct(
        srcs = tuple(srcs),
        hdrs = tuple(hdrs),
        data = tuple(data),
        deps = tuple(deps),
        label = label,
    )

def make_verilog_info(
        new_entries = (),
        old_infos = ()):
    """Return a new VerilogInfo that merges other VerilogInfo and new DAG entries."""
    return VerilogInfo(
        dag = depset(
            direct = new_entries,
            order = "postorder",
            transitive = [x.dag for x in old_infos if hasattr(x, "dag")],
        ),
    )

def _verilog_library_impl(ctx):
    verilog_info = make_verilog_info(
        new_entries = [make_dag_entry(
            srcs = ctx.files.srcs,
            data = ctx.files.data,
            hdrs = ctx.files.hdrs,
            deps = ctx.attr.deps,
            label = ctx.label,
        )],
        old_infos = [dep[VerilogInfo] for dep in ctx.attr.deps if VerilogInfo in dep],
    )
    return [
        verilog_info,
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.hdrs)),
    ]

verilog_library = rule(
    doc = "Define a Verilog module.",
    implementation = _verilog_library_impl,
    attrs = {
        "data": attr.label_list(
            doc = "Compile data read by sources.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "The list of other libraries to be linked.",
            providers = [
                VerilogInfo,
            ],
        ),
        "hdrs": attr.label_list(
            doc = "Verilog or SystemVerilog headers.",
            allow_files = [".vh", ".svh"],
        ),
        "srcs": attr.label_list(
            doc = "Verilog or SystemVerilog sources.",
            allow_files = [".v", ".sv"],
        ),
    },
)

def collect_verilog_files(targets, files = None):
    """Collects Verilog files transitively from targets and direct files.

    Args:
        targets: A target or list of targets.
        files: A list of Files.

    Returns:
        A depset of Files.
    """
    if files == None:
        files = []
    if type(targets) != "list":
        targets = [targets]

    transitive_dags = []
    raw_files_depsets = []
    for target in targets:
        if VerilogInfo in target:
            transitive_dags.append(target[VerilogInfo].dag)
        else:
            raw_files_depsets.append(target.files)

    transitive_srcs = depset([], transitive = transitive_dags)

    flat_srcs = []
    for verilog_info_struct in transitive_srcs.to_list():
        flat_srcs.extend(verilog_info_struct.srcs)
        flat_srcs.extend(verilog_info_struct.hdrs)

    if raw_files_depsets:
        flat_srcs.extend(depset(transitive = raw_files_depsets).to_list())

    flat_srcs.extend(files)

    return depset(flat_srcs)

def _verilog_zip_bundle_impl(ctx):
    # Gather all sources
    all_srcs = collect_verilog_files(ctx.attr.lib).to_list()

    # Build up zip command
    zipper_args = ["cf", ctx.outputs.zip.path]
    for f in all_srcs:
        zipper_args.append(f.path)

    # Run zip command.
    ctx.actions.run(
        inputs = all_srcs,
        outputs = [ctx.outputs.zip],
        executable = ctx.executable._zipper,
        arguments = zipper_args,
        progress_message = "Creating zip...",
        mnemonic = "zipper",
    )

verilog_zip_bundle = rule(
    implementation = _verilog_zip_bundle_impl,
    attrs = {
        "lib": attr.label(
            doc = "The verilog_library to bundle.",
            providers = [VerilogInfo],
        ),
        "_zipper": attr.label(
            default = Label("@bazel_tools//tools/zip:zipper"),
            cfg = "host",
            executable = True,
        ),
    },
    outputs = {
        "zip": "%{name}.zip",
    },
)
