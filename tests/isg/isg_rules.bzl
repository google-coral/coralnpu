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

"""Bazel rules and macros for CoralNPU Constrained-Random ISG."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@coralnpu_host_cpus//:defs.bzl", "VERILATOR_THREADS")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_python//python:defs.bzl", "py_test")
load("//rules:coralflow_test.bzl", "coralflow_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")

def _isg_asm_gen_impl(ctx):
    out = ctx.outputs.out
    alphabet = ctx.file.alphabet

    # Resolve effective seed:
    # 1. Command-line build setting flag --//tests/isg:isg_seed=<val> (if != "default")
    # 2. Command-line make variable --define isg_seed=<val> (if set and != "default")
    # 3. Target rule attribute ctx.attr.seed
    seed = ctx.attr.seed
    if ctx.attr._seed_flag:
        flag_val = ctx.attr._seed_flag[BuildSettingInfo].value
        if flag_val and flag_val != "default":
            seed = flag_val
        elif "isg_seed" in ctx.var and ctx.var["isg_seed"] != "default":
            seed = ctx.var["isg_seed"]
    trap_arg = "--traps-enabled" if ctx.attr.traps_enabled else ""
    verbose = False
    if ctx.attr._verbose_flag:
        verbose = bool(ctx.attr._verbose_flag[BuildSettingInfo].value)
    if not verbose and ctx.var.get("isg_verbose", "").lower() in ("1", "true"):
        verbose = True
    verbose_arg = "--verbose" if verbose else ""

    if seed == "" or seed == "random":
        seed_arg = "--seed=random"
    else:
        quoted_seed = "'" + seed.replace("'", "'\\''") + "'"
        seed_arg = "--seed=" + quoted_seed

    align_arg = "--align-mode={}".format(ctx.attr.align_mode) if ctx.attr.align_mode else ""

    cmd = """
"{isg_gen}" \
  --alphabet="{alphabet}" \
  {seed_arg} \
  --batch-index={batch_index} \
  --batch-size={batch_size} \
  --length={length} \
  --shaping={shaping} \
  --trap-rate={trap_rate} \
  {align_arg} \
  --output="{output}" {verbose_flag} && \
"{validator}" --assembly="{output}" {trap_flag} {verbose_flag}
""".format(
        isg_gen = ctx.executable._isg_gen.path,
        alphabet = alphabet.path,
        seed_arg = seed_arg,
        batch_index = ctx.attr.batch_index,
        batch_size = ctx.attr.batch_size,
        length = ctx.attr.length,
        shaping = ctx.attr.shaping,
        trap_rate = ctx.attr.trap_rate,
        align_arg = align_arg,
        output = out.path,
        validator = ctx.executable._validator.path,
        trap_flag = trap_arg,
        verbose_flag = verbose_arg,
    )

    ctx.actions.run_shell(
        inputs = [alphabet],
        outputs = [out],
        command = cmd,
        tools = [ctx.executable._isg_gen, ctx.executable._validator],
        progress_message = "Generating and validating ISG assembly %s (seed=%s, idx=%d)" % (out.short_path, seed if seed else "random", ctx.attr.batch_index),
        mnemonic = "IsgAsmGen",
    )

    return [DefaultInfo(files = depset([out]))]

isg_asm_gen = rule(
    implementation = _isg_asm_gen_impl,
    attrs = {
        "alphabet": attr.label(mandatory = True, allow_single_file = True),
        "seed": attr.string(default = ""),
        "batch_index": attr.int(default = 0),
        "batch_size": attr.int(default = 32),
        "length": attr.int(default = 64),
        "shaping": attr.string(default = "uniform"),
        "trap_rate": attr.string(default = "0.0"),
        "align_mode": attr.string(default = ""),
        "traps_enabled": attr.bool(default = False),
        "out": attr.output(mandatory = True),
        "_seed_flag": attr.label(default = Label("//tests/isg:isg_seed")),
        "_verbose_flag": attr.label(default = Label("//tests/isg:isg_verbose")),
        "_isg_gen": attr.label(
            default = Label("//tests/isg:isg_gen"),
            executable = True,
            cfg = "exec",
        ),
        "_validator": attr.label(
            default = Label("//tests/isg:validator"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _traps_enabled(trap_rate, shaping):
    return trap_rate > 0.0 or shaping == "trap_storm"

def isg_program(
        name,
        alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
        seed = None,
        batch_index = 0,
        batch_size = 32,
        length = 64,
        shaping = "uniform",
        trap_rate = 0.0,
        align_mode = None,
        binary_macro = coralnpu_v2_binary,
        tags = [],
        **kwargs):
    """Generates an ISG straight-line assembly file and compiles it to an ELF.

    Args:
        name: Name of the generated target.
        alphabet: Target providing the hardware alphabet JSON file.
        seed: Seed for the pseudo-random generator.
        batch_index: Index of this program within the batch.
        batch_size: Total number of programs in the batch.
        length: Number of payload instructions in the program.
        shaping: Dispatch-pressure shaping mode.
        trap_rate: Probability of generating trap stimulus instructions.
        align_mode: Optional alignment mode for memory accesses ("natural", "unaligned", "straddle", or "mixed").
        binary_macro: Starlark macro used to compile assembly into an ELF.
        tags: List of Bazel tags to propagate.
        **kwargs: Additional keyword arguments passed to binary_macro.
    """
    asm_file = name + ".S"

    gen_tags = list(tags)
    if seed == None or seed == "random" or seed == "":
        actual_seed = "random"
        if "no-cache" not in gen_tags:
            gen_tags.append("no-cache")
    else:
        actual_seed = seed

    isg_asm_gen(
        name = name + "_gen_asm",
        alphabet = alphabet,
        seed = actual_seed,
        batch_index = batch_index,
        batch_size = batch_size,
        length = length,
        shaping = shaping,
        trap_rate = str(trap_rate),
        align_mode = align_mode if align_mode != None else "",
        traps_enabled = _traps_enabled(trap_rate, shaping),
        out = asm_file,
        tags = gen_tags,
    )

    binary_macro(
        name = name,
        srcs = [":" + asm_file],
        tags = tags,
        **kwargs
    )

def isg_batch(
        name,
        alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
        seed = None,
        batch_size = 32,
        length = 64,
        shaping = "uniform",
        trap_rate = 0.0,
        align_mode = None,
        binary_macro = coralnpu_v2_binary,
        tags = [],
        **kwargs):
    """Generates a batch of ISG programs and registers batch and individual CoralFlow test suites.

    Args:
        name: Base name of the generated test batch.
        alphabet: Target providing the hardware alphabet JSON file.
        seed: Base seed for the pseudo-random generator across the batch.
        batch_size: Number of programs to generate in the batch (up to 1000).
        length: Number of payload instructions per program.
        shaping: Dispatch-pressure shaping mode.
        trap_rate: Probability of generating trap stimulus instructions.
        align_mode: Optional alignment mode for memory accesses ("natural", "unaligned", "straddle", or "mixed").
        binary_macro: Starlark macro used to compile assembly into an ELF.
        tags: List of Bazel tags to propagate.
        **kwargs: Additional keyword arguments passed to binary_macro.
    """
    batch_tags = list(tags)
    if seed == None or seed == "random" or seed == "":
        if "no-cache" not in batch_tags:
            batch_tags.append("no-cache")

    elf_targets = []
    asm_targets = []

    if batch_size > 1000:
        fail("isg_batch supports at most 1000 programs (3-digit program index)")
    for i in range(batch_size):
        idx_str = ("00" + str(i))[-3:]
        prog_name = "%s_%s" % (name, idx_str)
        isg_program(
            name = prog_name,
            alphabet = alphabet,
            seed = seed,
            batch_index = i,
            batch_size = batch_size,
            length = length,
            shaping = shaping,
            trap_rate = trap_rate,
            align_mode = align_mode,
            binary_macro = binary_macro,
            tags = batch_tags,
            **kwargs
        )
        elf_targets.append(":{}.elf".format(prog_name))
        asm_targets.append(":{}.S".format(prog_name))

        # Register individual test target for single-program debugging and reproduction.
        # Tagged "manual" so wildcard sweeps (bazel test //...) only run the batch runner.
        coralflow_test(
            name = prog_name,
            size = "medium",
            srcs = ["isg_coralflow_test.py"],
            data = [":{}.elf".format(prog_name)],
            hdl_toplevel = "CoreMiniAxi",
            uvm_batch = False,
            targets = [
                "verilator",
                "vcs",
                "uvm",
            ],
            deps = [
                Label("//tests/isg:isg_verbose_config"),
                "@bazel_tools//tools/python/runfiles",
            ],
            tags = batch_tags + ["manual", "isg-single-test"],
        )

    native.filegroup(
        name = name + "_elfs",
        srcs = elf_targets,
        tags = batch_tags,
    )

    trap_args = ["--traps-enabled"] if _traps_enabled(trap_rate, shaping) else []

    # Re-check invariants on the linked ELFs (decode against the hardware
    # alphabet and verify encoded fields).
    postlink_src = Label("//tests/isg:validate/postlink.py")
    verbose_args = select({
        "//tests/isg:isg_verbose_enabled": ["--verbose"],
        "//conditions:default": [],
    })
    py_test(
        name = name + "_postlink_test",
        srcs = [postlink_src],
        main = postlink_src,
        args = ["--alphabet=$(rootpath {})".format(alphabet)] + trap_args +
               ["$(rootpath {})".format(e) for e in elf_targets] + verbose_args,
        data = [alphabet] + elf_targets,
        deps = [
            Label("//tests/isg:isg_lib"),
            requirement("pyelftools"),
        ],
        tags = batch_tags,
    )

    # Check that each linked payload is exactly the generated source: one word
    # per source line, each decoding to the source mnemonic.
    payload_elf_src = Label("//tests/isg:validate/payload_elf_test.py")
    pair_args = []
    for asm, elf in zip(asm_targets, elf_targets):
        pair_args += ["$(rootpath {})".format(asm), "$(rootpath {})".format(elf)]
    py_test(
        name = name + "_payload_elf_test",
        srcs = [payload_elf_src],
        main = payload_elf_src,
        args = ["--alphabet=$(rootpath {})".format(alphabet)] + trap_args +
               pair_args,
        data = [alphabet] + asm_targets + elf_targets,
        deps = [
            Label("//tests/isg:isg_lib"),
            requirement("pyelftools"),
        ],
        tags = batch_tags,
    )

    sim_tags = list(batch_tags)
    if not any([t.startswith("cpu:") for t in sim_tags]):
        sim_tags.append("cpu:{}".format(VERILATOR_THREADS))

    # Keep uvm_batch = False: batching still happens across all backends
    # because isg_coralflow_test.py registers a single @coralflow_test
    # (isg_batch_test) that calls fixture.run_batch(elf_paths) directly,
    # executing all ELFs in one simulator invocation (+REGRESSION_LIST on UVM,
    # in-process soft resets on Verilator/VCS). Setting uvm_batch = True would
    # inject CORALFLOW_UVM_BATCH=1, causing coralflow_main() to discard
    # isg_batch_test and bypass ISG_ELF_FILTER and ISG_VERBOSE.
    coralflow_test(
        name = name,
        size = "large",
        srcs = ["isg_coralflow_test.py"],
        data = elf_targets,
        hdl_toplevel = "CoreMiniAxi",
        uvm_batch = False,
        targets = [
            "verilator",
            "vcs",
            "uvm",
        ],
        deps = [
            Label("//tests/isg:isg_verbose_config"),
            "@bazel_tools//tools/python/runfiles",
        ],
        tags = sim_tags,
    )

def isg_ci_tranche(
        name = "isg_ci_50",
        alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
        batch_size = 50,
        length = 64,
        shaping = "distributed",
        trap_rate = 0.05,
        align_mode = "mixed",
        seed = "ci_tranche",
        binary_macro = coralnpu_v2_binary,
        tags = [],
        **kwargs):
    """Instantiates a CI tranche of ISG programs (default 50 binaries) with mixed shaping & alignment."""
    isg_batch(
        name = name,
        alphabet = alphabet,
        batch_size = batch_size,
        length = length,
        shaping = shaping,
        trap_rate = trap_rate,
        align_mode = align_mode,
        seed = seed,
        binary_macro = binary_macro,
        tags = tags,
        **kwargs
    )
