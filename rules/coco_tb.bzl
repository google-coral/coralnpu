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

"""Convenience wrapper for Verilator driven cocotb."""

load("@coralnpu_host_cpus//:defs.bzl", "MAKE_JOBS")
load("@coralnpu_hw//rules:sram_backdoor.bzl", "SRAM_BACKDOOR_TOPLEVELS")
load("@coralnpu_hw//rules:verilog.bzl", "collect_verilog_files")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_hdl//cocotb:cocotb.bzl", "cocotb_test")
load("@rules_hdl//verilog:providers.bzl", "VerilogInfo")
load("@rules_python//python:defs.bzl", "py_binary", "py_library")

# Number of CPUs reserved per Verilate action in Bazel's local scheduler.
# Sourced from `nproc` at workspace-fetch time so we don't oversubscribe
# small hosts (a hardcoded 8 was blocking 6-core boxes from scheduling
# more than one action at a time).
verilator_make_parallelism = MAKE_JOBS

VcsSimulationInfo = provider(
    doc = "Contains outputs of a VCS simulation run",
    fields = {
        "log_file": "File: The simulation log file",
        "status_file": "File: The simulation status file",
        "fsdb_file": "File: The FSDB waveform file (optional)",
    },
)

def verilator_resource_estimator(os, input_size):
    # Cap the scheduler reservation at 4 so multiple actions can still run
    # in parallel on larger hosts; the `make -j` inside the action is free
    # to use more threads if the scheduler hands them over.
    return {"cpu": min(verilator_make_parallelism, 4), "memory": 4096}

def _verilator_cocotb_model_impl(ctx):
    hdl_toplevel = ctx.attr.hdl_toplevel
    outdir_name = hdl_toplevel + "_build"

    cc_toolchain = find_cc_toolchain(ctx)
    compiler_executable = cc_toolchain.compiler_executable
    ar_executable = cc_toolchain.ar_executable
    ld_executable = cc_toolchain.ld_executable

    # Collect DPI/C++ dependencies
    dpi_srcs_dict = {}
    dpi_includes = []
    dpi_files_dict = {}
    verilog_srcs = []

    def add_dpi_src(f):
        if type(f) == "File" and f.extension in ["cc", "cpp", "cxx", "c", "a", "o"]:
            dpi_srcs_dict[f.path] = "$PWD/" + f.path
            dpi_files_dict[f.path] = f

    def add_dpi_file(f):
        if type(f) == "File":
            dpi_files_dict[f.path] = f

    # We need to collect CC sources transitively
    for dep in ctx.attr.deps:
        if CcInfo in dep:
            cc_info = dep[CcInfo]

            # Transitive includes
            for inc in cc_info.compilation_context.includes.to_list():
                dpi_includes.append("-I" + inc)
            for inc in cc_info.compilation_context.quote_includes.to_list():
                dpi_includes.append("-I" + inc)
            for inc in cc_info.compilation_context.system_includes.to_list():
                dpi_includes.append("-I" + inc)

            # Transitive headers
            for f in cc_info.compilation_context.headers.to_list():
                add_dpi_file(f)

            # Transitive sources
            # Bazel rules often put sources in DefaultInfo
            for f in dep[DefaultInfo].files.to_list():
                add_dpi_src(f)
                if f.extension in ["h", "hh", "hpp"]:
                    add_dpi_file(f)

            # Check transitive linker inputs for sources that might be hidden
            # This is necessary for targets that don't have sources in DefaultInfo
            for li in cc_info.linking_context.linker_inputs.to_list():
                for lib in li.libraries:
                    if lib.static_library:
                        add_dpi_file(lib.static_library)
                    if lib.pic_static_library:
                        add_dpi_file(lib.pic_static_library)
                    if lib.objects:
                        for obj in lib.objects:
                            add_dpi_file(obj)

        if VerilogInfo in dep:
            verilog_srcs.append(dep[VerilogInfo].dag)

    # Collect all input files for the action and their paths
    all_inputs_dict = {}
    verilog_paths = []

    def add_input(f):
        if type(f) == "File":
            all_inputs_dict[f.path] = f
            return True
        return False

    for f in dpi_files_dict.values():
        add_input(f)

    # Process verilog sources collected from deps and direct attributes
    for f in verilog_srcs:
        if type(f) == "File":
            if add_input(f):
                verilog_paths.append(f.path)
        elif hasattr(f, "to_list"):  # It's a depset from VerilogInfo.dag
            for node in f.to_list():
                for s in node.srcs:
                    if add_input(s):
                        verilog_paths.append(s.path)

    if ctx.attr.verilog_source:
        f = ctx.file.verilog_source
        add_input(f)
        verilog_paths.append(f.path)

    for f in ctx.files.verilog_sources:
        add_input(f)
        verilog_paths.append(f.path)

    vlt_file = ctx.actions.declare_file(hdl_toplevel + ".vlt")
    ctx.actions.expand_template(
        output = vlt_file,
        template = ctx.file.vlt_tpl,
        substitutions = {"{HDL_TOPLEVEL}": hdl_toplevel},
    )
    add_input(vlt_file)

    output_file = ctx.actions.declare_file(outdir_name + "/" + hdl_toplevel)
    make_log = ctx.actions.declare_file(outdir_name + "/make.log")
    outdir = output_file.dirname

    # The @verilator runfiles live at <bin>.runfiles/<canonical>,
    # where <canonical> is the verilator repo's canonical name (e.g.
    # 'rules_hdl++hdl_deps+verilator'). Resolve via the verilator target's
    # workspace_root rather than hardcoding it.
    verilator_canonical = ctx.executable._verilator_bin.owner.workspace_name
    verilator_root = "$PWD/{}.runfiles/{}".format(
        ctx.executable._verilator_bin.path,
        verilator_canonical,
    )
    cocotb_lib_path = "$PWD/{}".format(ctx.files._cocotb_verilator_lib[0].dirname)

    # Prepend $PWD to paths for verilator to find them in the sandbox
    verilog_sources_str = " ".join(["$PWD/" + p if not p.startswith("/") else p for p in verilog_paths])

    verilator_cmd = " ".join("""
        VERILATOR_ROOT={verilator_root} {verilator} \
            -cc \
            --exe \
            -Mdir {outdir} \
            --top-module {hdl_toplevel} \
            --vpi \
            --prefix Vtop \
            -o {hdl_toplevel} \
            -LDFLAGS "-Wl,-rpath {cocotb_lib_path} -L{cocotb_lib_path} -lcocotbvpi_verilator" \
            {trace} \
            {cflags} \
            -I. -Ihdl/verilog {dpi_includes} \
            $PWD/{verilator_cpp} \
            $PWD/{vlt_file} \
            {dpi_srcs} \
            {verilog_sources}
    """.strip().split("\n")).format(
        verilator = ctx.executable._verilator_bin.path,
        verilator_root = verilator_root,
        outdir = outdir,
        hdl_toplevel = hdl_toplevel,
        cocotb_lib_path = cocotb_lib_path,
        cflags = " ".join(ctx.attr.cflags),
        dpi_includes = " ".join({inc: None for inc in dpi_includes}.keys()),  # Unique includes
        verilator_cpp = ctx.files._cocotb_verilator_cpp[0].path,
        vlt_file = vlt_file.path,
        dpi_srcs = " ".join(dpi_srcs_dict.values()),
        verilog_sources = verilog_sources_str,
        trace = "--trace" if ctx.attr.trace else "",
    )

    def _abs(p):
        return p if p.startswith("/") else "$PWD/" + p

    make_cmd = "PATH=`dirname {ld}`:$PATH make -j {parallelism} -C {outdir} -f Vtop.mk {trace} CXX={cxx} AR={ar} LINK={cxx} > {make_log} 2>&1".format(
        outdir = outdir,
        cocotb_lib_path = cocotb_lib_path,
        make_log = make_log.path,
        trace = "VM_TRACE=1" if ctx.attr.trace else "",
        ar = _abs(ar_executable),
        ld = _abs(ld_executable),
        cxx = _abs(compiler_executable),
        parallelism = verilator_make_parallelism,
    )

    script = " && ".join([verilator_cmd.strip(), make_cmd])

    ctx.actions.run_shell(
        outputs = [output_file, make_log],
        tools = ctx.files._verilator_bin,
        inputs = depset(
            [f for f in all_inputs_dict.values()],
            transitive = [
                depset(ctx.files._verilator),
                depset(ctx.files._cocotb_verilator_lib),
                depset(ctx.files._cocotb_verilator_cpp),
                cc_toolchain.all_files,
            ],
        ),
        command = script,
        mnemonic = "Verilate",
        resource_set = verilator_resource_estimator,
    )

    return [
        DefaultInfo(
            files = depset([output_file, make_log]),
            runfiles = ctx.runfiles(files = [output_file, make_log]),
            executable = output_file,
        ),
        OutputGroupInfo(
            all_files = depset([output_file, make_log]),
        ),
    ]

def _vcs_cocotb_model_impl(ctx):
    hdl_toplevel = ctx.attr.hdl_toplevel
    outdir_name = ctx.attr.name + "_vcs_build"

    verilog_files = collect_verilog_files(ctx.attr.verilog_sources).to_list()

    output_simv = ctx.actions.declare_file(outdir_name + "/simv")
    output_daidir = ctx.actions.declare_directory(outdir_name + "/simv.daidir")
    output_vdb = ctx.actions.declare_directory(outdir_name + "/simv.vdb")

    vcs_lib = None
    for f in ctx.files._vcs_libs:
        if f.basename == "libcocotbvpi_vcs.so":
            vcs_lib = f
            break
    if not vcs_lib:
        fail("Could not find libcocotbvpi_vcs.so in _vcs_libs")

    # Expand location in build_args
    expanded_build_args = [ctx.expand_location(arg, ctx.attr.data) for arg in ctx.attr.build_args]

    # We need absolute paths for files we pass explicitly (sources, includes, libs)
    # because we will CD into a subdirectory.
    includes_args = ["+incdir+$EXECROOT/" + inc for inc in ctx.attr.includes]
    defines_args = ["+define+{}={}".format(name, value) for name, value in ctx.attr.defines.items()]
    parameters_args = ["-pvalue+{}.{}={}".format(hdl_toplevel, name, value) for name, value in ctx.attr.parameters.items()]
    sources_args = ["$EXECROOT/" + f.path for f in verilog_files]

    vcs_opts = [
        "-full64",
        "+acc+3",
        "-sverilog",
        "-LDFLAGS",
        "-Wl,--no-as-needed",
        "-q",
        "-suppress=VPI-CT-NS,SV-LCM-PPWI",
    ]

    load_arg = "-load {}:vlog_startup_routines_bootstrap".format(vcs_lib.basename)

    wrapper = ctx.actions.declare_file(ctx.attr.name + "_vcs_compile.sh")

    ctx.actions.expand_template(
        template = ctx.file._template,
        output = wrapper,
        substitutions = {
            "%{OUTDIR_NAME}%": outdir_name,
            "%{VCS_OPTS}%": " ".join(vcs_opts),
            "%{LOAD_ARG}%": load_arg,
            "%{BUILD_ARGS}%": " ".join(expanded_build_args),
            "%{INCLUDES}%": " ".join(includes_args),
            "%{DEFINES}%": " ".join(defines_args),
            "%{PARAMETERS}%": " ".join(parameters_args),
            "%{HDL_TOPLEVEL}%": hdl_toplevel,
            "%{SOURCES}%": " ".join(sources_args),
            "%{OUTPUT_SIMV}%": output_simv.path,
            "%{OUTPUT_DAIDIR}%": output_daidir.path,
            "%{OUTPUT_VDB}%": output_vdb.path,
            "%{VCS_LIB_DIR}%": vcs_lib.dirname,
        },
    )

    inputs = verilog_files + ctx.files._vcs_libs + ctx.files.data + [wrapper]

    ctx.actions.run_shell(
        outputs = [output_simv, output_daidir, output_vdb],
        inputs = depset(inputs),
        command = "bash {}".format(wrapper.path),
        mnemonic = "VcsCompile",
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(
            files = depset([output_simv]),
            runfiles = ctx.runfiles(files = [output_simv, output_daidir, output_vdb]),
            executable = output_simv,
        ),
    ]

vcs_cocotb_model = rule(
    doc = """Builds a VCS model for cocotb.
    """,
    implementation = _vcs_cocotb_model_impl,
    attrs = {
        "verilog_sources": attr.label_list(providers = [VerilogInfo], allow_files = True),
        "hdl_toplevel": attr.string(mandatory = True),
        "build_args": attr.string_list(default = []),
        "defines": attr.string_dict(default = {}),
        "includes": attr.string_list(default = []),
        "parameters": attr.string_dict(default = {}),
        "data": attr.label_list(allow_files = True, default = []),
        "_vcs_libs": attr.label(
            default = "@coralnpu_pip_deps_cocotb//:cocotb_libs",
            allow_files = True,
        ),
        "_template": attr.label(
            default = "//rules:vcs_model_wrapper.sh.template",
            allow_single_file = True,
        ),
    },
    executable = True,
)

verilator_cocotb_model = rule(
    doc = """Builds a verilator model for cocotb.

    This rule takes a verilog source file and a toplevel module name and
    builds a verilator model that can be used with cocotb.

    It returns a DefaultInfo provider with an executable that can be run
    to execute the simulation.

    Attributes:
        verilog_source: The verilog source file to build the model from.
        hdl_toplevel: The name of the toplevel module.
        cflags: A list of flags to pass to the compiler.
        deps: Additional C++/DPI dependencies (CcInfo).
    """,
    implementation = _verilator_cocotb_model_impl,
    attrs = {
        "verilog_source": attr.label(allow_single_file = True, mandatory = False),
        "verilog_sources": attr.label_list(allow_files = [".v", ".sv"]),
        "hdl_toplevel": attr.string(mandatory = True),
        "cflags": attr.string_list(default = []),
        "deps": attr.label_list(providers = [[CcInfo], [VerilogInfo]]),
        "trace": attr.bool(default = False),
        "vlt_tpl": attr.label(
            default = "@coralnpu_hw//rules:default.vlt.tpl",
            allow_single_file = True,
        ),
        "_verilator": attr.label(
            default = "@verilator//:verilator",
            executable = True,
            cfg = "exec",
        ),
        "_verilator_bin": attr.label(
            default = "@verilator//:verilator_bin",
            executable = True,
            cfg = "exec",
        ),
        "_cocotb_verilator_lib": attr.label(
            default = "@coralnpu_pip_deps_cocotb//:cocotb_libs",
            allow_files = True,
        ),
        "_cocotb_verilator_cpp": attr.label(
            default = "@coralnpu_pip_deps_cocotb//:verilator_srcs",
            allow_files = True,
        ),
    },
    executable = True,
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
)

def verilator_cocotb_test(
        name,
        model,
        hdl_toplevel,
        test_module,
        deps = [],
        data = [],
        **kwargs):
    """Runs a cocotb test with a verilator model.

    This is a wrapper around the cocotb_test rule that is specific to
    verilator.

    Args:
        name: The name of the test.
        model: The verilator_cocotb_model target to use.
        hdl_toplevel: The name of the toplevel module.
        test_module: The python module that contains the test.
        deps: Additional dependencies for the test.
        data: Data dependencies for the test.
        **kwargs: Additional arguments to pass to the cocotb_test rule.
    """
    tags = kwargs.pop("tags", [])
    tags.append("cpu:2")
    kwargs.update(
        hdl_toplevel_lang = "verilog",
        sim_name = "verilator",
        sim = [
            "@verilator//:verilator",
            "@verilator//:verilator_bin",
        ],
        tags = tags,
    )

    # Wrap in py_library so we can forward data
    py_library(
        name = name + "_test_data",
        srcs = [],
        deps = deps + [
            requirement("cocotb"),
            requirement("numpy"),
            requirement("pytest"),
        ],
        data = data,
        tags = tags,
    )

    extra_env = list(kwargs.pop("extra_env", []))
    extra_env.append("COCOTB_TEST_FILTER=$TESTBRIDGE_TEST_ONLY")
    kwargs["extra_env"] = extra_env

    cocotb_test(
        name = name,
        model = model,
        hdl_toplevel = hdl_toplevel,
        test_module = test_module,
        deps = [
            ":{}_test_data".format(name),
        ],
        **kwargs
    )

def _verilator_cocotb_test_suite(
        name,
        model,
        testcases = [],
        testcases_vname = "",
        tests_kwargs = {},
        **kwargs):
    """Runs a cocotb test with a verilator model.

    This is a wrapper around the cocotb_test rule that is specific to
    verilator.

    Args:
        name: The name of the test.
        model: The verilator_cocotb_model target to use.
        testcases: A list of testcases to run. A test will be generated for each
          testcase.
        tests_kwargs: A dictionary of arguments to pass to the cocotb_test rule.
        **kwargs: Additional arguments to pass to the cocotb_test rule.
    """
    all_tests_kwargs = dict(tests_kwargs)
    all_tests_kwargs.update(kwargs)

    default_tc_size = all_tests_kwargs.pop("default_testcase_size", "")

    if testcases:
        test_targets = []
        for tc in testcases:
            tc_size = default_tc_size
            if type(tc) == "tuple":
                tc, tc_size = tc

            tc_tests_kwargs = dict(all_tests_kwargs)
            if tc_size:
                tc_tests_kwargs.update({"size": tc_size})
                tc_tests_kwargs.pop("timeout", "")
            tags = list(tc_tests_kwargs.pop("tags", []))
            tags.append("verilator_cocotb_single_test")
            verilator_cocotb_test(
                name = "{}_{}".format(name, tc),
                model = model,
                testcase = [tc],
                tags = tags,
                **tc_tests_kwargs
            )
            test_targets.append(":{}_{}".format(name, tc))

    # Generate a meta-target for all tests.
    meta_target_kwargs = dict(all_tests_kwargs)
    tags = list(meta_target_kwargs.pop("tags", []))
    tags.append("manual")
    tags.append("verilator_cocotb_test_suite")
    if testcases_vname:
        tags.append("testcases_vname={}".format(testcases_vname))
    verilator_cocotb_test(
        name = name,
        model = model,
        tags = tags,
        **meta_target_kwargs
    )

def _vcs_simulation_run_impl(ctx):
    log_file = ctx.actions.declare_file(ctx.attr.name + ".log")
    fsdb_file = ctx.actions.declare_file(ctx.attr.name + ".fsdb")
    status_file = ctx.actions.declare_file(ctx.attr.name + ".status")
    # CAVEAT: If code coverage (-cm) is ever enabled for netlist targets,
    # you MUST also declare <name>.vdb here in outputs and include it in DefaultInfo!

    args = ctx.actions.args()
    args.add("--sim", "vcs")
    args.add("--hdl_toplevel_lang", "verilog")

    # CRITICAL: These arguments mirror _get_test_command in @rules_hdl//cocotb:cocotb.bzl.
    # If standard cocotb tests receive new CLI arguments or flags, they must be added here.
    args.add("--model", ctx.executable.model.short_path)
    args.add("--main_workspace", ctx.workspace_name)
    if ctx.attr.testcase:
        args.add("--testcase", ctx.attr.testcase)

    # Dynamically resolve runfiles path of test module
    test_module_file = ctx.file.test_module_file
    if test_module_file:
        if test_module_file.short_path.startswith("../"):
            test_module_path = test_module_file.short_path[3:]
        else:
            test_module_path = ctx.workspace_name + "/" + test_module_file.short_path
        args.add("--test_module_path", test_module_path)

    args.add("--status_file", status_file.path)

    if ctx.attr.hdl_toplevel:
        args.add("--hdl_toplevel", ctx.attr.hdl_toplevel)
    combined_test_args = []
    for arg in ctx.attr.test_args:
        if not arg.startswith("+fsdbfile+"):
            combined_test_args.append(arg)
    if ctx.attr.waves:
        combined_test_args.append("+fsdbfile+" + fsdb_file.path)
    args.add("--test_args", " ".join(combined_test_args))

    # Shell command:
    # 1. Clean status file.
    # 2. Run simulation runner.
    # 3. Detect transient license failures (fail build immediately).
    # 4. Touch output targets to satisfy Bazel declared output constraint.
    # 5. Fail the build if the status file is missing (setup crash).
    # 6. Fail the build if simulator crashed (exit code > 128).
    command = """
rm -f "{status}"
runner="$1"; shift;
"$runner" "$@" > "{log}" 2>&1
exit_code=$?
if grep -q -i -E "Failed to obtain license|License checkout failed|flexnet licensing error|No such feature exists" "{log}"; then
  echo "VCS License/Infra failure detected. Failing build to avoid caching." >&2
  exit 1
fi
touch "{log}" "{fsdb}"
if [ ! -f "{status}" ]; then
  echo "Error: Simulation status file was not created (runner crashed during setup)." >&2
  exit 1
fi
if [ $exit_code -gt 128 ]; then
  echo "Simulator crashed with exit code $exit_code" >&2
  exit $exit_code
fi
exit 0
""".format(
        log = log_file.path,
        fsdb = fsdb_file.path,
        status = status_file.path,
    )

    inputs = []
    if ctx.file.test_module_file:
        inputs.append(ctx.file.test_module_file)

    env = {}
    for k, v in ctx.attr.extra_env.items():
        env[k] = v
    if ctx.attr.seed:
        env["RANDOM_SEED"] = ctx.attr.seed

    # Safely forward executable and arguments to run_shell to avoid shell word-splitting.
    ctx.actions.run_shell(
        outputs = [log_file, fsdb_file, status_file],
        inputs = inputs,
        tools = [ctx.executable.runner, ctx.executable.model],
        arguments = [ctx.executable.runner.path, args],
        command = command,
        # Required to inherit VCS licensing environment variables (e.g. LM_LICENSE_FILE) from host.
        use_default_shell_env = True,
        env = env,
        mnemonic = "VcsSimulationRun",
    )
    return [
        DefaultInfo(
            files = depset([fsdb_file]),
            runfiles = ctx.runfiles(files = [fsdb_file, log_file, status_file]),
        ),
        VcsSimulationInfo(
            log_file = log_file,
            status_file = status_file,
            fsdb_file = fsdb_file,
        ),
    ]

vcs_simulation_run = rule(
    implementation = _vcs_simulation_run_impl,
    doc = "Executes a VCS simulation build action producing wave and log artifacts.",
    attrs = {
        "runner": attr.label(executable = True, cfg = "exec"),
        "model": attr.label(allow_single_file = True, executable = True, cfg = "exec"),
        "testcase": attr.string(),
        "test_module_file": attr.label(allow_single_file = True),
        "hdl_toplevel": attr.string(),
        "extra_env": attr.string_dict(),
        "test_args": attr.string_list(),
        "seed": attr.string(),
        "waves": attr.bool(default = True),
    },
)

def _vcs_simulation_test_impl(ctx):
    exe = ctx.actions.declare_file(ctx.attr.name + "_test_checker.sh")
    sim_info = ctx.attr.run_target[VcsSimulationInfo]
    log_file = sim_info.log_file
    status_file = sim_info.status_file

    # Write a script that checks the status file
    script_content = """#!/bin/bash
status_val=$(cat "{status}")
if [ -z "$status_val" ] || [ "$status_val" -ne 0 ]; then
  echo "Simulation failed with exit code ${{status_val:-unknown}}"
  echo "--- Simulation Log ---"
  cat "{log}"
  exit 1
fi
echo "Simulation passed."
exit 0
""".format(
        status = status_file.short_path,
        log = log_file.short_path,
    )

    ctx.actions.write(
        output = exe,
        content = script_content,
        is_executable = True,
    )
    return [
        DefaultInfo(
            files = depset([exe]),
            runfiles = ctx.runfiles(files = [exe, log_file, status_file]),
            executable = exe,
        ),
    ]

vcs_simulation_test = rule(
    implementation = _vcs_simulation_test_impl,
    doc = "Inspects simulation logs to verify test status and report results.",
    attrs = {
        "run_target": attr.label(mandatory = True, providers = [VcsSimulationInfo]),
    },
    test = True,
)

def vcs_simulation_split_test(
        name,
        hdl_toplevel,
        test_module,
        deps = [],
        data = [],
        verilog_model_files = [],
        verilog_sources = [],  # buildifier: disable=unused-variable
        model = None,
        extra_env = [],
        test_args = [],
        **kwargs):
    """Instantiates split build and test targets for VCS cocotb simulation.

    NOTE: This split flow is for gate-level power analysis where FSDB waveforms
    must be Bazel build outputs. For standard testing, use vcs_cocotb_test.

    WARNING: Keep in sync with vcs_cocotb_test / @rules_hdl:
    1. CLI Flags: _vcs_simulation_run_impl must manually forward new flags.
    2. Coverage: If using -cm, declare <name>.vdb output in vcs_simulation_run.
    3. Failures: Simulation runs as a build action; failures are BUILD failures.

    Args:
        name: Name of the test target.
        hdl_toplevel: Name of the top-level HDL module.
        test_module: Python module containing tests.
        deps: Python libraries.
        data: Data files.
        verilog_model_files: Verilog simulation models.
        verilog_sources: Verilog sources (ignored).
        model: Compiled VCS model.
        extra_env: Environment variables.
        test_args: Simulator arguments.
        **kwargs: Additional arguments.
    """

    # Pop common attributes to forward to helper targets
    testonly = kwargs.pop("testonly", False)
    visibility = kwargs.pop("visibility", None)

    tags = list(kwargs.pop("tags", []))
    if "vcs" not in tags:
        tags.append("vcs")
    if "cpu:2" not in tags:
        tags.append("cpu:2")

    run_tags = list(tags)
    if "manual" not in run_tags:
        run_tags.append("manual")
    if "requires-network" not in run_tags:
        run_tags.append("requires-network")

    # Check local without removing it from kwargs so it gets forwarded to vcs_simulation_test
    local = kwargs.get("local", False)
    if local and "local" not in run_tags:
        run_tags.append("local")

    if "size" not in kwargs:
        kwargs["size"] = "medium"

    seed = kwargs.pop("seed", "")
    if type(seed) == "list":
        seed = seed[0] if seed else ""
    waves = kwargs.pop("waves", True)

    full_data = list(data) + list(verilog_model_files)
    if model:
        full_data.append(model)

    # TODO: The underlying vcs_simulation_run rule only supports a single
    # test_module_file. If a list of modules is provided, we only pick the first
    # one. This diverges from vcs_cocotb_test, which supports multiple test
    # modules. If multiple modules are needed for split/netlist tests in the
    # future, the underlying rule must be updated to support a list.
    tm_label = test_module[0] if type(test_module) == "list" else test_module
    full_data.append(tm_label)

    py_library(
        name = name + "_sim_runner_lib",
        srcs = [],
        deps = [
            requirement("cocotb"),
            requirement("numpy"),
            requirement("pytest"),
            "@rules_hdl//cocotb:cocotb_wrapper",
            "@bazel_tools//tools/python/runfiles",
        ],
        tags = run_tags,
        testonly = testonly,
        visibility = visibility,
    )

    py_binary(
        name = name + "_sim_runner",
        srcs = ["@coralnpu_hw//rules:sim_runner.py"],
        main = "@coralnpu_hw//rules:sim_runner.py",
        deps = deps + [":" + name + "_sim_runner_lib"],
        data = full_data,
        tags = run_tags,
        testonly = testonly,
        visibility = visibility,
    )

    env_dict = {}
    for entry in extra_env:
        if "=" in entry:
            k, v = entry.split("=", 1)
            env_dict[k] = v

    # Pop testcase so it is not forwarded to vcs_simulation_test
    tc = kwargs.pop("testcase", "")
    if type(tc) == "list":
        tc = tc[0] if tc else ""

    # Discard compilation/build attributes that are not needed by the run-only test target.
    # vcs_simulation_test is a strict rule and will fail at load-time if custom
    # compilation attributes (like build_args or defines) are forwarded to it.
    kwargs.pop("build_args", None)
    kwargs.pop("defines", None)

    vcs_simulation_run(
        name = name + "_run",
        runner = ":" + name + "_sim_runner",
        model = model,
        testcase = tc,
        test_module_file = tm_label,
        hdl_toplevel = hdl_toplevel,
        extra_env = env_dict,
        test_args = test_args,
        seed = str(seed),
        waves = waves,
        tags = run_tags,
        testonly = testonly,
        visibility = visibility,
    )

    vcs_simulation_test(
        name = name,
        run_target = ":" + name + "_run",
        tags = tags,
        testonly = testonly,
        visibility = visibility,
        **kwargs
    )

def vcs_cocotb_test(
        name,
        hdl_toplevel,
        test_module,
        deps = [],
        data = [],
        verilog_model_files = [],
        model = None,
        **kwargs):
    """Runs a cocotb test with a vcs model.

    This is a wrapper around the cocotb_test rule that is specific to
    vcs.

    Args:
        name: The name of the test.
        hdl_toplevel: The name of the toplevel module.
        test_module: The python module that contains the test.
        deps: Additional dependencies for the test.
        data: Data dependencies for the test.
        verilog_model_files: Labels of Verilog model files to pass to VCS with -v.
        model: Target of precompiled VCS model.
        **kwargs: Additional arguments to pass to the cocotb_test rule.

    CRITICAL DIVERGENCE WARNING:
    If you introduce new runtime arguments, environment variables, or CLI flags
    to this function or its underlying @rules_hdl rule, you MUST also update
    _vcs_simulation_run_impl above to ensure the split-test flow remains in sync!
    """
    testonly = kwargs.pop("testonly", False)
    visibility = kwargs.pop("visibility", None)

    if "size" not in kwargs:
        kwargs["size"] = "medium"

    tags = list(kwargs.pop("tags", []))
    tags.append("vcs")
    tags.append("cpu:2")
    kwargs.update(
        hdl_toplevel_lang = "verilog",
        sim_name = "vcs",
        sim = [],
        tags = tags,
    )

    # Wrap in py_library to forward data.
    # Pass 'verilog_model_files' to 'data' as simulator runtime deps, not Python libs.
    py_library(
        name = name + "_test_data",
        srcs = [],
        deps = deps + [
            requirement("cocotb"),
            requirement("numpy"),
            requirement("pytest"),
        ],
        data = data,
        tags = tags,
        testonly = testonly,
        visibility = visibility,
    )

    extra_env = list(kwargs.pop("extra_env", []))
    extra_env.append("COCOTB_TEST_FILTER=$TESTBRIDGE_TEST_ONLY")
    kwargs["extra_env"] = extra_env

    # Resolve labels to paths and prefix with -v for VCS.
    # Prepend '../' because Cocotb runs from 'sim_build/', so we must go up one level to reach the execution root.
    build_args = list(kwargs.pop("build_args", []))
    for f in verilog_model_files:
        # Note that $(execpath) expands to a space-separated list if the label contains multiple files.
        # VCS expects a separate -v flag for each file. This implementation assumes each entry in
        # verilog_model_files is a single-file label. If filegroups are needed, the expansion logic
        # should probably be moved into the cocotb_test rule implementation in rules_hdl.
        build_args.extend(["-v", "../$(execpath {})".format(f)])
    kwargs["build_args"] = build_args

    if model:
        kwargs["model"] = model
        data = data + [model]
        kwargs.pop("verilog_sources", None)

    cocotb_test(
        name = name,
        hdl_toplevel = hdl_toplevel,
        test_module = test_module,
        deps = [
            ":{}_test_data".format(name),
        ],
        # The 'data' dependencies are now being passed both to the py_library (test_data) and directly to
        # cocotb_test. While this works, it's redundant. Since Patch 0011 adds data support to cocotb_test,
        # we should eventually consolidate data handling there.
        data = data + verilog_model_files,
        testonly = testonly,
        visibility = visibility,
        **kwargs
    )

def _vcs_cocotb_test_suite(
        name,
        verilog_sources,
        testcases = [],
        testcases_vname = "",
        tests_kwargs = {},
        add_ci_tags = True,
        name_fsdb_after_test = False,
        model = None,
        split_build_test = False,
        **kwargs):
    """Runs a cocotb test with a vcs model.

    This is a wrapper around the cocotb_test rule that is specific to
    vcs.

    Args:
        name: The name of the test.
        verilog_sources: The verilog sources to use for the test.
        testcases: A list of testcases to run. A test will be generated for each
          testcase.
        testcases_vname: Variable name of testcases for tagging.
        tests_kwargs: A dictionary of arguments to pass to the cocotb_test rule.
        add_ci_tags: Whether to add CI suite tags.
        name_fsdb_after_test: Whether to name FSDB file after testcase.
        model: Target of precompiled VCS model.
        split_build_test: Whether to split execution into build and test targets.
        **kwargs: Additional arguments to pass to the cocotb_test rule.
    """
    all_tests_kwargs = dict(tests_kwargs)
    all_tests_kwargs.update(kwargs)

    default_tc_size = all_tests_kwargs.pop("default_testcase_size", "")

    hdl_toplevel = all_tests_kwargs.get("hdl_toplevel")
    if not hdl_toplevel:
        fail("hdl_toplevel must be specified in tests_kwargs")

    if not model:
        model = name + "_vcs_model"
        model_build_args = list(kwargs.get("build_args", []))
        for f in kwargs.get("verilog_model_files", []):
            model_build_args.extend(["-v", "../$(execpath {})".format(f)])
        vcs_cocotb_model(
            name = model,
            verilog_sources = verilog_sources,
            hdl_toplevel = hdl_toplevel,
            build_args = model_build_args,
            defines = kwargs.get("defines", {}),
            includes = kwargs.get("includes", []),
            parameters = kwargs.get("parameters", {}),
            data = kwargs.get("data", []) + kwargs.get("verilog_model_files", []),
            tags = ["manual"] + list(kwargs.get("tags", [])),
        )
        model = ":" + model

    if testcases:
        test_targets = []
        for tc in testcases:
            tc_size = default_tc_size
            if type(tc) == "tuple":
                tc, tc_size = tc

            tc_tests_kwargs = dict(all_tests_kwargs)
            if tc_size:
                tc_tests_kwargs.update({"size": tc_size})
                tc_tests_kwargs.pop("timeout", "")
            tags = list(tc_tests_kwargs.pop("tags", []))
            if add_ci_tags:
                tags.append("vcs_cocotb_single_test")
            if testcases_vname:
                tags.append("testcases_vname={}".format(testcases_vname))

            test_args = tc_tests_kwargs.pop("test_args", [""])

            # Fix spacing issue by separating arguments properly
            clean_test_args = [arg for arg in test_args if arg]
            clean_test_args.extend(["-cm_name", str(tc)])

            # Apply correct VCS syntax for fsdb
            if name_fsdb_after_test:
                clean_test_args.append("+fsdbfile+{}_{}.fsdb".format(name, tc))

            if split_build_test:
                # DIVERGENCE Anchor: Ensure keyword arguments passed here match vcs_cocotb_test below
                vcs_simulation_split_test(
                    name = "{}_{}".format(name, tc),
                    testcase = [tc],
                    tags = tags,
                    test_args = clean_test_args,
                    verilog_sources = verilog_sources,
                    model = model,
                    **tc_tests_kwargs
                )
            else:
                vcs_cocotb_test(
                    name = "{}_{}".format(name, tc),
                    testcase = [tc],
                    tags = tags,
                    test_args = clean_test_args,
                    verilog_sources = verilog_sources,
                    model = model,
                    **tc_tests_kwargs
                )
            test_targets.append(":{}_{}".format(name, tc))

    # Generate a meta-target for all tests.
    meta_target_kwargs = dict(all_tests_kwargs)
    tags = list(meta_target_kwargs.pop("tags", []))
    tags.append("manual")
    if add_ci_tags:
        tags.append("vcs_cocotb_test_suite")
    if testcases_vname:
        tags.append("testcases_vname={}".format(testcases_vname))

    # Also handle the meta-target FSDB naming
    if name_fsdb_after_test:
        meta_test_args = meta_target_kwargs.pop("test_args", [""])
        clean_meta_test_args = [arg for arg in meta_test_args if arg]
        clean_meta_test_args.append("+fsdbfile+{}.fsdb".format(name))
        meta_target_kwargs["test_args"] = clean_meta_test_args

    if split_build_test:
        # DIVERGENCE Anchor: Ensure keyword arguments passed here match vcs_cocotb_test below
        vcs_simulation_split_test(
            name = name,
            tags = tags,
            verilog_sources = verilog_sources,
            model = model,
            **meta_target_kwargs
        )
    else:
        vcs_cocotb_test(
            name = name,
            tags = tags,
            verilog_sources = verilog_sources,
            model = model,
            **meta_target_kwargs
        )

def cocotb_test_suite(name, testcases, simulators = ["verilator"], coverage = False, coverage_cfg = None, debug_access = False, **kwargs):
    """Runs a cocotb test with a verilator or vcs model.

    This is a wrapper around the cocotb_test rule that is specific to
    verilator.

    Args:
        name: The name of the test.
        simulators: A list of simulators to run the test with.
          Supported simulators are "verilator" and "vcs".
        **kwargs: Additional arguments to pass to the cocotb_test rule.
          These can be prefixed with the simulator name to apply them to
          only that simulator.
    """

    # Pop tests_kwargs from kwargs, if it exists.
    tests_kwargs = kwargs.pop("tests_kwargs", {})
    testcases_vname = kwargs.pop("testcases_vname", "")
    name_fsdb_after_test = kwargs.pop("name_fsdb_after_test", False)
    for sim in simulators:
        sim_kwargs = {}
        sim_tests_kwargs = {}

        # 1. Start with clean (non-sim-specific) arguments
        for key, value in tests_kwargs.items():
            is_sim_specific = False
            for s in simulators:
                if key.startswith(s + "_"):
                    is_sim_specific = True
                    break
            if not is_sim_specific:
                sim_tests_kwargs[key] = value

        for key, value in kwargs.items():
            is_sim_specific = False
            for s in simulators:
                if key.startswith(s + "_"):
                    is_sim_specific = True
                    break
            if not is_sim_specific:
                sim_kwargs[key] = value

        # 2. Add sim-specific arguments (matching the longest prefix)
        for key, value in tests_kwargs.items():
            best_match = None
            for s in simulators:
                if key.startswith(s + "_"):
                    if best_match == None or len(s) > len(best_match):
                        best_match = s
            if best_match == sim:
                sim_tests_kwargs[key.replace(sim + "_", "", 1)] = value

        for key, value in kwargs.items():
            best_match = None
            for s in simulators:
                if key.startswith(s + "_"):
                    if best_match == None or len(s) > len(best_match):
                        best_match = s
            if best_match == sim:
                sim_kwargs[key.replace(sim + "_", "", 1)] = value

        if coverage and sim in ["vcs", "vcs_netlist"]:
            build_args = list(sim_kwargs.get("build_args", []))
            if "-cm" not in build_args:
                build_args.extend([
                    "-cm",
                    "line+cond+tgl+branch+assert",
                ])
                if coverage_cfg:
                    build_args.extend([
                        "-cm_hier",
                        "../$(execpath {})".format(coverage_cfg),
                    ])
            sim_kwargs["build_args"] = build_args

            test_args = list(sim_tests_kwargs.get("test_args", sim_kwargs.get("test_args", [])))
            if "-cm" not in test_args:
                test_args.extend([
                    "-cm",
                    "line+cond+tgl+branch+assert",
                ])
            sim_tests_kwargs["test_args"] = test_args

            if coverage_cfg:
                data = list(sim_kwargs.get("data", []))
                if coverage_cfg not in data:
                    data.append(coverage_cfg)
                sim_kwargs["data"] = data

        if sim in ["vcs", "vcs_netlist"]:
            build_args = list(sim_kwargs.get("build_args", []))
            if debug_access:
                if "-debug_access+all" not in build_args:
                    build_args.append("-debug_access+all")
            elif "-debug_access+r+w+wn+f+fn+cbk" not in build_args:
                build_args.append("-debug_access+r+w+wn+f+fn+cbk")
            sim_kwargs["build_args"] = build_args

        if sim == "verilator":
            model = sim_kwargs.pop("model", None)
            if not model:
                fail("verilator_model must be specified for verilator tests")
            _verilator_cocotb_test_suite(
                name = name,
                model = model,
                testcases = testcases,
                testcases_vname = testcases_vname,
                tests_kwargs = sim_tests_kwargs,
                **sim_kwargs
            )
        elif sim == "vcs_netlist":
            verilog_sources = sim_kwargs.pop("verilog_sources", [])
            if not verilog_sources:
                fail("vcs_netlist_verilog_sources must be specified for vcs_netlist tests")
            _vcs_cocotb_test_suite(
                name = "{}_{}".format(sim, name),
                verilog_sources = verilog_sources,
                testcases = testcases,
                testcases_vname = testcases_vname,
                tests_kwargs = sim_tests_kwargs,
                add_ci_tags = False,
                name_fsdb_after_test = name_fsdb_after_test,
                **sim_kwargs
            )
        elif sim == "vcs":
            verilog_sources = sim_kwargs.pop("verilog_sources", [])
            if not verilog_sources:
                fail("vcs_verilog_sources must be specified for vcs tests")

            # CoreMiniAxi and Chisel Subsystem tests require sram_backdoor compilation
            hdl_toplevel = sim_tests_kwargs.get("hdl_toplevel", sim_kwargs.get("hdl_toplevel", ""))
            if hdl_toplevel in SRAM_BACKDOOR_TOPLEVELS:
                build_args = list(sim_kwargs.pop("build_args", []))
                if "-I../hdl/verilog" not in build_args:
                    build_args.extend(["-CFLAGS", "-I../hdl/verilog"])

                if "../hdl/verilog/sram_backdoor.cc" not in build_args:
                    build_args.append("../hdl/verilog/sram_backdoor.cc")
                sim_kwargs["build_args"] = build_args

                data = list(sim_kwargs.pop("data", []))
                has_dpi_files = False
                for item in data:
                    if str(item).endswith("hdl/verilog:dpi_files"):
                        has_dpi_files = True
                        break
                if not has_dpi_files:
                    data.append("@coralnpu_hw//hdl/verilog:dpi_files")
                sim_kwargs["data"] = data

            _vcs_cocotb_test_suite(
                name = "{}_{}".format(sim, name),
                verilog_sources = verilog_sources,
                testcases = testcases,
                testcases_vname = testcases_vname,
                tests_kwargs = sim_tests_kwargs,
                name_fsdb_after_test = name_fsdb_after_test,
                **sim_kwargs
            )
        else:
            fail("Unknown simulator: {}".format(sim))

def vcs_test_macro_smoke_test(name, verilog_sources, **kwargs):
    """Smoke test to ensure vcs_cocotb_test and vcs_simulation_split_test signatures match.

    This macro instantiates both flows with dummy targets to catch signature
    mismatches at Bazel load time. Targets are marked 'manual' to avoid execution.
    """
    tags = kwargs.pop("tags", [])
    if "manual" not in tags:
        tags.append("manual")

    # Define a dummy model to pass to both tests
    vcs_cocotb_model(
        name = name + "_dummy_model",
        verilog_sources = verilog_sources,
        hdl_toplevel = kwargs.get("hdl_toplevel"),
        tags = tags,
    )

    # Test regular flow
    vcs_cocotb_test(
        name = name + "_regular_smoke",
        model = ":" + name + "_dummy_model",
        tags = tags,
        **kwargs
    )

    # Test split flow
    vcs_simulation_split_test(
        name = name + "_split_smoke",
        model = ":" + name + "_dummy_model",
        verilog_sources = verilog_sources,
        tags = tags,
        **kwargs
    )
