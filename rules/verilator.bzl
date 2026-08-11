"""Bazel functions for Verilator."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@coralnpu_host_cpus//:defs.bzl", "MAKE_JOBS")
load("@coralnpu_hw//rules:coco_tb.bzl", "verilator_make_parallelism", "verilator_resource_estimator")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_hdl//verilator:defs.bzl", "verilator_cc_library")
load("@rules_hdl//verilog:providers.bzl", "VerilogInfo", "verilog_library")

# List of targets to exclude from Spike co-simulation (e.g. tests requiring external IRQs)
SPIKE_DENYLIST = [
    "//hw_sim:mailbox_example",
    "//tests/cocotb/exceptions:store_fault_0",
    "//tests/cocotb/rvv:rvv_add",
    "//tests/cocotb/rvv:rvv_load",
    "//tests/cocotb/rvv:vstart_store",
    "//tests/cocotb:loop",
    "//tests/cocotb:registers",
    "//tests/cocotb:software_interrupt_test",
    "//tests/cocotb:stress_test",
    "//tests/cocotb:wfi_slot_0",
    "//tests/cocotb:wfi_slot_1",
    "//tests/cocotb:wfi_slot_2",
    "//tests/cocotb:wfi_slot_3",
    "//tests/cocotb/exceptions:vfwadd_trap",
    "//tests/cocotb/exceptions:vfwsub_trap",
    "//tests/cocotb/exceptions:vfwmul_trap",
]

def _verilator_model_impl(ctx):
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

    # Collect all input files for the action and their paths
    all_inputs_dict = {}
    verilog_paths = []

    def add_input(f):
        if type(f) == "File":
            all_inputs_dict[f.path] = f
            return True
        return False

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

    for f in ctx.files.verilog_sources:
        add_input(f)
        verilog_paths.append(f.path)

    for f in ctx.files.deps:
        add_input(f)

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

    uvm_lib_path = "$PWD/{}".format(ctx.files._uvm_lib[0].dirname)
    coralnpu_mpact_lib_path = "$PWD/{}".format(ctx.files.coralnpu_mpact_lib[0].path)

    # Prepend $PWD to paths for verilator to find them in the sandbox
    verilog_sources_str = " ".join(["$PWD/" + p if not p.startswith("/") else p for p in verilog_paths])

    include_dirs_str = " ".join(["-I" + p.path for p in ctx.files.include_dirs])

    verilator_canonical = ctx.executable._verilator_bin.owner.workspace_name
    verilator_root = "$PWD/{}.runfiles/{}".format(
        ctx.executable._verilator_bin.path,
        verilator_canonical,
    )

    verilator_include_dir = None
    for f in ctx.files._verilator:
        # This assumes verilated.mk is present in the include/ directory
        if f.basename == "verilated.mk":
            verilator_include_dir = f
            break

    verilator_cmd = " ".join("""
        VERILATOR_ROOT={verilator_root} {verilator} \
            -cc \
            --exe \
            --main \
            -Mdir {outdir} \
            --top-module {hdl_toplevel} \
            --vpi \
            --prefix Vtop \
            -o {hdl_toplevel} \
            {include_dirs_str} \
            -LDFLAGS "-lstdc++" \
            -LDFLAGS "-lm" \
            -I"{uvm_lib_path}/src" \
	        "{uvm_lib_path}/src/uvm_pkg.sv" \
	        "{uvm_lib_path}/src/dpi/uvm_dpi.cc" \
            "{coralnpu_mpact_lib_path}" \
            {cflags} \
            -I. -Ihdl/verilog {dpi_includes} \
            $PWD/{vlt_file} \
            {dpi_srcs} \
            {verilog_sources}
    """.strip().split("\n")).format(
        verilator = ctx.executable._verilator_bin.path,
        verilator_root = verilator_root,
        outdir = outdir,
        hdl_toplevel = hdl_toplevel,
        include_dirs_str = include_dirs_str,
        uvm_lib_path = uvm_lib_path,
        coralnpu_mpact_lib_path = coralnpu_mpact_lib_path,
        cflags = " ".join(ctx.attr.cflags),
        dpi_includes = " ".join({inc: None for inc in dpi_includes}.keys()),  # Unique includes
        vlt_file = vlt_file.path,
        dpi_srcs = " ".join(dpi_srcs_dict.values()),
        verilog_sources = verilog_sources_str,
    )

    make_cmd = "PATH=`dirname {ld}`:$PATH make -j {parallelism} -C {outdir} -f Vtop.mk CXX={cxx} AR={ar} LINK={cxx} > {make_log} 2>&1".format(
        outdir = outdir,
        make_log = make_log.path,
        ar = ar_executable,
        ld = ld_executable,
        cxx = compiler_executable,
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
                depset(ctx.files._uvm_lib),
                depset(ctx.files.coralnpu_mpact_lib),
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

verilator_model = rule(
    doc = """Builds a standalone Verilator model.

    This rule takes a verilog source files and a toplevel module name and
    builds a verilator model.

    It returns a DefaultInfo provider with an executable that can be run
    to execute the simulation.

    Attributes:
        hdl_toplevel: The name of the toplevel module.
        verilog_sources: The verilog source file(s) to build the model from.
        cflags: A list of flags to pass to the compiler.
        deps: Additional C++/DPI dependencies.
        include_dirs: Directories to be included during build using `+incdir`.
    """,
    implementation = _verilator_model_impl,
    attrs = {
        "verilog_sources": attr.label_list(allow_files = [".v", ".sv"]),
        "include_dirs": attr.label_list(allow_files = True),
        "hdl_toplevel": attr.string(mandatory = True),
        "cflags": attr.string_list(default = []),
        "deps": attr.label_list(providers = [[DefaultInfo], [CcInfo], [VerilogInfo]]),
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
        "_uvm_lib": attr.label(
            default = "@uvm-verilator//:all_srcs",
            allow_files = True,
        ),
        "coralnpu_mpact_lib": attr.label(
            allow_files = True,
        ),
    },
    executable = True,
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
)

def _rlocation_path(ws, f):
    if f.short_path.startswith("../"):
        return f.short_path[len("../"):]
    return ws + "/" + f.short_path

def _verilator_batch_uvm_impl(ctx):
    runfiles = []
    run_spike_flag = ctx.attr.run_spike[BuildSettingInfo].value

    model_binary = None
    for f in ctx.files.model:
        if not f.path.endswith(".log"):
            model_binary = f
            break

    if not model_binary:
        fail("Model binary could not be found")

    spike_bin = None
    for f in ctx.files._spike:
        if f.basename == "spike":
            spike_bin = f
            break

    if run_spike_flag and not spike_bin:
        fail("Spike cosimulation enabled, but spike binary could not be found")

    ws = "coralnpu_hw"
    runner = ctx.actions.declare_file(ctx.label.name)
    runfiles.extend(ctx.files.coralnpu_tests + [model_binary])
    if run_spike_flag:
        runfiles.append(spike_bin)
        spike_rloc = _rlocation_path(ws, spike_bin)
    else:
        spike_rloc = ""

    ctx.actions.symlink(output = runner, target_file = ctx.executable._runner, is_executable = True)

    coralnpu_elfs_fmt = []
    for file, label, timeout in zip(ctx.files.coralnpu_tests, ctx.attr.labels, ctx.attr.timeouts):
        enable_spike = run_spike_flag
        if enable_spike and label in SPIKE_DENYLIST:
            print("Warning: skipping spike cosim for {}, because it is listed in SPIKE_DENYLIST".format(label))
            enable_spike = False
        coralnpu_elfs_fmt.append("{}\t{}\t{}\t{}".format(_rlocation_path(ws, file), label, timeout, enable_spike))

    return [
        DefaultInfo(
            executable = runner,
            runfiles = ctx.runfiles(
                files = runfiles,
                collect_default = True,
            ).merge(ctx.attr._runner[DefaultInfo].default_runfiles),
        ),
        RunEnvironmentInfo(
            environment = {
                "UVM_MODEL_RLOCATION": _rlocation_path(ws, model_binary),
                "UVM_CORALNPU_ELFS": "\n".join(coralnpu_elfs_fmt),
                "UVM_SPIKE_RLOCATION": spike_rloc,
            },
        ),
    ]

verilator_batch_uvm_test = rule(
    doc = """Performs batch testing of the UVM Verilator model.""",
    implementation = _verilator_batch_uvm_impl,
    attrs = {
        "model": attr.label(allow_files = True),
        "coralnpu_tests": attr.label_list(allow_files = True),
        "timeouts": attr.int_list(mandatory = True),
        "labels": attr.string_list(mandatory = True),
        "run_spike": attr.label(
            providers = [BuildSettingInfo],
        ),
        "_spike": attr.label(
            default = Label("@riscv_isa_sim//:riscv_isa_sim"),
            allow_files = True,
        ),
        "_runner": attr.label(
            default = Label("//utils:uvm_batch_runner"),
            executable = True,
            cfg = "target",
        ),
    },
    test = True,
)
