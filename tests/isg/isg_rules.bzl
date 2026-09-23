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

load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_python//python:defs.bzl", "py_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")
load("//rules:vcs.bzl", "vcs_batch_uvm_test")
load("//rules:verilator.bzl", "verilator_batch_uvm_test")

def isg_program(
        name,
        alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
        seed = None,
        batch_index = 0,
        batch_size = 32,
        length = 64,
        trap_rate = 0.0,
        align_mode = "natural",
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
        trap_rate: Probability of generating trap stimulus instructions.
        align_mode: Alignment mode for memory accesses ("natural" or "straddle").
        binary_macro: Starlark macro used to compile assembly into an ELF.
        tags: List of Bazel tags to propagate.
        **kwargs: Additional keyword arguments passed to binary_macro.
    """
    asm_file = name + ".S"

    trap_arg = "--traps-enabled" if trap_rate > 0.0 else ""

    gen_tags = list(tags)
    if seed == None or seed == "random" or seed == "":
        seed_arg = "--seed=random"
        if "no-cache" not in gen_tags:
            gen_tags.append("no-cache")
    else:
        seed_arg = "--seed='{}'".format(seed)

    native.genrule(
        name = name + "_gen_asm",
        srcs = [alphabet],
        outs = [asm_file],
        cmd = """
$(location //tests/isg:isg_gen) \
  --alphabet=$(location {alphabet}) \
  {seed_arg} \
  --batch-index={batch_index} \
  --batch-size={batch_size} \
  --length={length} \
  --trap-rate={trap_rate} \
  --align-mode={align_mode} \
  --output=$@ && \
$(location //tests/isg:validator) --assembly=$@ {trap_flag}
""".format(
            alphabet = alphabet,
            seed_arg = seed_arg,
            batch_index = str(batch_index),
            batch_size = str(batch_size),
            length = str(length),
            trap_rate = str(trap_rate),
            align_mode = align_mode,
            trap_flag = trap_arg,
        ),
        tools = [
            "//tests/isg:isg_gen",
            "//tests/isg:validator",
        ],
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
        trap_rate = 0.0,
        align_mode = "natural",
        binary_macro = coralnpu_v2_binary,
        tags = [],
        **kwargs):
    """Generates a batch of ISG programs and registers a batch UVM regression test.

    Args:
        name: Base name of the generated test batch.
        alphabet: Target providing the hardware alphabet JSON file.
        seed: Base seed for the pseudo-random generator across the batch.
        batch_size: Number of programs to generate in the batch (up to 1000).
        length: Number of payload instructions per program.
        trap_rate: Probability of generating trap stimulus instructions.
        align_mode: Alignment mode for memory accesses ("natural" or "straddle").
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
    labels = []
    timeouts = []

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
            trap_rate = trap_rate,
            align_mode = align_mode,
            binary_macro = binary_macro,
            tags = batch_tags,
            **kwargs
        )
        elf_targets.append(":{}.elf".format(prog_name))
        asm_targets.append(":{}.S".format(prog_name))
        labels.append("//{}:{}".format(native.package_name(), prog_name))
        timeouts.append(100000)

    native.filegroup(
        name = name + "_elfs",
        srcs = elf_targets,
        tags = batch_tags,
    )

    trap_args = ["--traps-enabled"] if trap_rate > 0.0 else []

    # Re-check invariants on the linked ELFs (decode against the hardware
    # alphabet and verify encoded fields).
    postlink_src = Label("//tests/isg:validate/postlink.py")
    py_test(
        name = name + "_postlink_test",
        srcs = [postlink_src],
        main = postlink_src,
        args = ["--alphabet=$(rootpath {})".format(alphabet)] + trap_args +
               ["$(rootpath {})".format(e) for e in elf_targets],
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

    verilator_batch_uvm_test(
        name = "verilator_uvm_regression_" + name,
        model = "//tests/uvm:uvm_sim_verilator",
        coralnpu_tests = elf_targets,
        timeouts = timeouts,
        labels = labels,
        run_spike = "@coralnpu_hw//rules:uvm_run_spike_cosim",
        tags = batch_tags + ["verilator-uvm-regression", "verilator-uvm-regression-coralnpu-tests"],
    )

    vcs_batch_uvm_test(
        name = "vcs_uvm_regression_" + name,
        model = "//tests/uvm:uvm_sim_vcs",
        coralnpu_tests = elf_targets,
        timeouts = timeouts,
        labels = labels,
        run_spike = "@coralnpu_hw//rules:uvm_run_spike_cosim",
        tags = batch_tags + ["vcs", "vcs-uvm-regression", "vcs-uvm-regression-coralnpu-tests"],
    )
