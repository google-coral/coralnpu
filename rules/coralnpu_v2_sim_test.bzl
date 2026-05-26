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

"""Macro to build and run a CoralNPU V2 binary on the Verilator SoC simulation."""

load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")


def _sim_test_impl(ctx):
    runner_target = ctx.attr._runner_highmem if ctx.attr.highmem else ctx.attr._runner
    runner = runner_target[DefaultInfo].files_to_run.executable
    elf = ctx.file.elf
    sim_timeout = ctx.attr.sim_timeout

    trace_arg = ""
    if ctx.attr.trace:
        trace_arg = "--trace=$TEST_UNDECLARED_OUTPUTS_DIR/sim_trace.fst"

    highmem_arg = ""
    if ctx.attr.highmem:
        highmem_arg = "--highmem"

    loader_arg = "--loader=" + ctx.attr.loader

    # Generate a wrapper script that invokes the test runner with the ELF path.
    script = ctx.actions.declare_file(ctx.label.name + "_run.sh")
    ctx.actions.write(
        output=script,
        content="""\
#!/bin/bash
exec {runner} {elf} --sim_timeout {timeout} {trace_arg} {highmem_arg} \
    --itcm_size_kbytes {itcm_size} --dtcm_size_kbytes {dtcm_size} {loader_arg}
""".format(
            runner=runner.short_path,
            elf=elf.short_path,
            timeout=sim_timeout,
            trace_arg=trace_arg,
            highmem_arg=highmem_arg,
            itcm_size=ctx.attr.itcm_size_kbytes,
            dtcm_size=ctx.attr.dtcm_size_kbytes,
            loader_arg=loader_arg,
        ),
        is_executable=True,
    )

    runfiles = ctx.runfiles(files=[elf])
    runfiles = runfiles.merge(runner_target[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable=script,
            runfiles=runfiles,
        )
    ]


_sim_test = rule(
    implementation=_sim_test_impl,
    test=True,
    attrs={
        "elf": attr.label(
            allow_single_file=[".elf"],
            mandatory=True,
        ),
        "sim_timeout": attr.int(default=30),
        "trace": attr.bool(default=False),
        "highmem": attr.bool(default=False),
        "itcm_size_kbytes": attr.int(default=8),
        "dtcm_size_kbytes": attr.int(default=32),
        "loader": attr.string(
            default = "backdoor",
            values = ["backdoor", "spi"],
            doc = (
                "ELF delivery path: 'backdoor' uses sram_load_elf inside the " +
                "simulator (fast, default); 'spi' streams the ELF over the " +
                "spi2tlul bridge (kept for spi2tlul-loader regression cover)."
            ),
        ),
        "_runner": attr.label(
            default="//utils/coralnpu_soc_loader:sim_test_runner",
            executable=True,
            cfg="target",
        ),
        "_runner_highmem": attr.label(
            default="//utils/coralnpu_soc_loader:sim_test_runner_highmem",
            executable=True,
            cfg="target",
        ),
    },
)


def coralnpu_v2_sim_test(
    name,
    srcs,
    sim_timeout=30,
    trace=False,
    highmem=False,
    loader="backdoor",
    size="large",
    tags=[],
    **kwargs,
):
    """Builds a coralnpu_v2_binary and runs it on the Verilator SoC simulation.

    The test passes if the binary prints a line matching PASS/TEST PASSED
    to the UART, and fails if it prints FAIL/TEST FAILED/ERROR/ABORT,
    or if no result is detected within sim_timeout seconds.

    Args:
      name: Name of the test target.
      srcs: C/C++ source files for the binary.
      sim_timeout: Seconds to wait for a test result after loading (default 30).
      trace: Whether to enable FST tracing (default False).
      highmem: Whether to use the 1M/1M highmem configuration (default False).
      size: Bazel test size (default "large").
      tags: Additional tags.
      **kwargs: Additional arguments forwarded to coralnpu_v2_binary
                (deps, copts, defines, hdrs, itcm_size_kbytes, etc).
    """

    binary_name = name + "_binary"

    if highmem:
        if "itcm_size_kbytes" not in kwargs:
            kwargs["itcm_size_kbytes"] = 1024
        if "dtcm_size_kbytes" not in kwargs:
            kwargs["dtcm_size_kbytes"] = 1024

    coralnpu_v2_binary(name=binary_name, srcs=srcs, tags=tags + ["manual"], **kwargs)

    _sim_test(
        name=name,
        elf=":{}.elf".format(binary_name),
        sim_timeout=sim_timeout,
        trace=trace,
        highmem=highmem,
        loader=loader,
        itcm_size_kbytes=kwargs.get("itcm_size_kbytes", 1024 if highmem else 8),
        dtcm_size_kbytes=kwargs.get("dtcm_size_kbytes", 1024 if highmem else 32),
        size=size,
        tags=tags + ["exclusive"],
        timeout="long",
    )
