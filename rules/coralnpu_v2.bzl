# Copyright 2025 Google LLC
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

load("//rules:linker.bzl", "generate_linker_script")

"""Rules to build CoralNPU SW objects"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")

CORALNPU_V2_PLATFORM = "//platforms:coralnpu_v2"
CORALNPU_V2_SEMIHOSTING_PLATFORM = "//platforms:coralnpu_v2_semihosting"

def _coralnpu_v2_transition_impl(_settings, attr):
    if attr.semihosting:
        return {"//command_line_option:platforms": CORALNPU_V2_SEMIHOSTING_PLATFORM}
    else:
        return {"//command_line_option:platforms": CORALNPU_V2_PLATFORM}

_coralnpu_v2_transition = transition(
    implementation = _coralnpu_v2_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _coralnpu_v2_rule(**kwargs):
    """CoralNPU-specific transition rule.

    A wrapper over rule() for creating rules that trigger
    the transition to the coralnpu platform config.

    Args:
      **kwargs: params forwarded to the implementation.
    Returns:
      CoralNPU transition rule.
    """
    attrs = kwargs.pop("attrs", {})
    attrs["_allowlist_function_transition"] = attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    )

    return rule(
        cfg = _coralnpu_v2_transition,
        attrs = attrs,
        **kwargs
    )

def _coralnpu_v2_binary_impl(ctx):
    """Implements compilation for coralnpu executables.

    This rule compiles and links provided input into an executable
    suitable for use on the CoralNPU core. Generates an ELF.

    Args:
      ctx: context for the rules.
        srcs: Input source files.
        deps: Target libraries that the binary depends upon.
        hdrs: Header files that are local to the binary.
        copts: Flags to pass along to the compiler.
        defines: Preprocessor definitions.
        linkopts: Flags to pass along to the linker.

    Output:
        OutputGroupsInfo to allow definition of filegroups
        containing the output ELF and BIN.
    """
    cc_toolchain = find_cc_toolchain(ctx)
    if type(cc_toolchain) != 'CcToolchainInfo':
        cc_toolchain = cc_toolchain.cc
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compilation_contexts = []
    linking_contexts = []
    for dep in ctx.attr.deps:
        if CcInfo in dep:
            compilation_contexts.append(dep[CcInfo].compilation_context)
            linking_contexts.append(dep[CcInfo].linking_context)

    sources = []
    headers = []
    for src in ctx.files.srcs:
        if src.extension in ["h", "hh", "hpp"]:
            headers.append(src)
        else:
            sources.append(src)

    (_compilation_context, compilation_outputs) = cc_common.compile(
        actions = ctx.actions,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        name = ctx.label.name,
        srcs = sources,
        compilation_contexts = compilation_contexts,
        private_hdrs = headers + ctx.files.hdrs,
        user_compile_flags = ctx.attr.copts,
        defines = ctx.attr.defines,
    )
    linking_outputs = cc_common.link(
        name = "{}.elf".format(ctx.label.name),
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        user_link_flags = ctx.attr.linkopts + [
            "-Wl,-T,{}".format(ctx.file.linker_script.path),
        ],
        additional_inputs = depset([ctx.file.linker_script] + ctx.files.linker_script_includes),
        output_type = "executable",
    )

    out_bin = ctx.actions.declare_file("{}.bin".format(ctx.label.name))
    objcopy_tool = cc_toolchain.objcopy_executable

    ctx.actions.run(
        outputs = [out_bin],
        inputs = [linking_outputs.executable] + cc_toolchain.all_files.to_list(),
        executable = objcopy_tool,
        arguments = [
            "-O",
            "binary",
            linking_outputs.executable.path,
            out_bin.path,
        ],
        mnemonic = "ObjCopy",
    )

    out_vmem = None
    if ctx.attr.enable_vmem:
        out_vmem = ctx.actions.declare_file("{}.vmem".format(ctx.label.name))
        word_size = ctx.attr.word_size

        srec_cat_files = ctx.attr._srec_cat[DefaultInfo].files.to_list()
        srec_cat_bin = None
        for f in srec_cat_files:
            if f.path.endswith("/bin/srec_cat"):
                srec_cat_bin = f
                break
        if not srec_cat_bin:
            fail("Could not find srec_cat binary in @srecord//:srecord outputs")

        ctx.actions.run(
            outputs = [out_vmem],
            inputs = [out_bin],
            executable = srec_cat_bin,
            tools = srec_cat_files,
            arguments = [
                out_bin.path,
                "-binary",
                "-byte-swap",
                str(word_size // 8),
                "-fill",
                "0xff",
                "-within",
                out_bin.path,
                "-binary",
                "-range-pad",
                str(word_size // 8),
                "-o",
                out_vmem.path,
                "-vmem",
                str(word_size),
            ],
            mnemonic = "SrecCat",
        )

    all_outputs = [linking_outputs.executable, out_bin]
    output_groups = {
        "all_files": depset(all_outputs),
        "elf_file": depset([linking_outputs.executable]),
        "bin_file": depset([out_bin]),
    }
    if out_vmem:
        all_outputs.append(out_vmem)
        output_groups["vmem_file"] = depset([out_vmem])
        output_groups["all_files"] = depset(all_outputs)

    return [
        DefaultInfo(
            files = depset(all_outputs),
        ),
        OutputGroupInfo(**output_groups),
    ]

_coralnpu_v2_binary = _coralnpu_v2_rule(
    implementation = _coralnpu_v2_binary_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "deps": attr.label_list(allow_empty = True, providers = [CcInfo]),
        "hdrs": attr.label_list(allow_files = [".h"], allow_empty = True),
        "copts": attr.string_list(),
        "defines": attr.string_list(),
        "linkopts": attr.string_list(),
        "linker_script": attr.label(allow_single_file = True),
        "linker_script_includes": attr.label_list(default = [], allow_files = True),
        "semihosting": attr.bool(),
        "word_size": attr.int(default = 32),
        "enable_vmem": attr.bool(default = True),
        "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
        "_srec_cat": attr.label(default = Label("@srecord//:srecord"), cfg = "exec"),
    },
    fragments = ["cpp"],
    toolchains = ["@rules_cc//cc:toolchain_type"],
)

def coralnpu_v2_binary(
        name,
        srcs,
        tags = [],
        semihosting = False,
        itcm_size_kbytes = 8,
        dtcm_size_kbytes = 32,
        word_size = 32,
        linker_script = None,
        stack_size_bytes = 128,
        heap_size = "",
        heap_location = "DTCM",
        enable_vmem = True,
        crt = None,
        **kwargs):
    """A helper macro for generating binary artifacts for the CoralNPU V2 core.

    This macro uses the coralnpu_v2 toolchain, libgloss-htif,
    and a generated coralnpu linker script to build coralnpu binaries.

    Args:
      name: The name of this rule.
      srcs: The c source files.
      tags: build tags.
      semihosting: Enable htif-style semihosting
      itcm_size_kbytes: Size of ITCM in KBytes.
      dtcm_size_kbytes: Size of DTCM in KBytes.
      stack_size_bytes: Size of stack in bytes.
      heap_size: Size of heap (e.g. "1K", "128M").
      heap_location: Memory region for heap ("DTCM", "EXTMEM", "DDR").
      enable_vmem: Whether to generate a VMEM file.
      crt: Optional label for custom CRT. If not provided, uses default CRT.
      **kwargs: Additional arguments forward to cc_binary.
    Emits rules:
      filegroup              named: <name>.bin
        Containing the binary output for the target.
      filegroup              named: <name>.elf
        Containing all elf output for the target.
    """

    deps = kwargs.pop("deps", [])
    if crt != None:
        if crt:
            deps.append(crt)
    elif semihosting:
        deps.append("//toolchain/crt:crt_semihosting")
    else:
        deps.append("//toolchain/crt")

# See cache_size_param/hw/coralnpu/toolchain/BUILD.bazel for default linker script.
    if linker_script == None:
        _DEFAULT_ITCM_SIZE_KBYTES = 8
        _DEFAULT_DTCM_SIZE_KBYTES = 32
        _DEFAULT_STACK_SIZE_BYTES = 128
        _DEFAULT_HEAP_SIZE = ""
        _DEFAULT_HEAP_LOCATION = "DTCM"

        linker_script_suffix = ""
        if itcm_size_kbytes != _DEFAULT_ITCM_SIZE_KBYTES or \
           dtcm_size_kbytes != _DEFAULT_DTCM_SIZE_KBYTES or \
           stack_size_bytes != _DEFAULT_STACK_SIZE_BYTES or \
           heap_size != _DEFAULT_HEAP_SIZE or \
           heap_location != _DEFAULT_HEAP_LOCATION:
            linker_script_suffix = "_ITCM%dKB_DTCM%dKB_STACK%d_HEAP%s%s" % (
                itcm_size_kbytes, dtcm_size_kbytes, stack_size_bytes, heap_size, heap_location)

        linker_script_name = name + linker_script_suffix + "_linker_script"
        linker_script_output_file = name + linker_script_suffix + ".ld"

        generate_linker_script(
            name = linker_script_name,
            src = "@coralnpu_hw//toolchain:coralnpu_tcm.ld.tpl",
            out = linker_script_output_file,
            itcm_size_kbytes = itcm_size_kbytes,
            dtcm_size_kbytes = dtcm_size_kbytes,
            stack_size_bytes = stack_size_bytes,
            heap_size = heap_size,
            heap_location = heap_location,
        )
        linker_script = ":" + linker_script_output_file

    _coralnpu_v2_binary(
        name = name,
        srcs = srcs,
        linker_script = linker_script,
        semihosting = semihosting,
        tags = tags,
        deps = deps,
        word_size = word_size,
        enable_vmem = enable_vmem,
        **kwargs
    )

    native.filegroup(
        name = "{}.elf".format(name),
        srcs = [name],
        output_group = "elf_file",
        tags = tags,
    )

    native.filegroup(
        name = "{}.vmem".format(name),
        srcs = [name],
        output_group = "vmem_file",
        tags = tags,
    )

    native.filegroup(
        name = "{}.bin".format(name),
        srcs = [name],
        output_group = "bin_file",
        tags = tags,
    )
