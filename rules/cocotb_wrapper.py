# Copyright 2023 Antmicro
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

import argparse
import cocotb_tools
import os
import shutil
from bazel_tools.tools.python.runfiles import runfiles
import sys
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results

cocotb_build_flags = [
    "hdl_library",
    "verilog_sources",
    "vhdl_sources",
    "includes",
    "defines",
    "parameters",
    "build_args",
    "hdl_toplevel",
    "always",
    "build_dir",
    "verbose",
    "waves",
]

cocotb_test_flags = [
    "test_module",
    "hdl_toplevel",
    "hdl_toplevel_library",
    "hdl_toplevel_lang",
    "gpi_interfaces",
    "testcase",
    "seed",
    "test_args",
    "plusargs",
    "extra_env",
    "waves",
    "gui",
    "parameters",
    "build_dir",
    "test_dir",
    "results_xml",
    "verbose",
]


def filter_args(kwargs, keys):
    return {k: v for (k, v) in kwargs.items() if k in keys}


def cocotb_argument_parser():

    class ParseDict(argparse.Action):

        def __call__(self, parser, namespace, values, option_string=None):
            d = getattr(namespace, self.dest, None)
            if not isinstance(d, dict):
                d = dict()
                setattr(namespace, self.dest, d)
            for val in values:
                for item in val.split(" "):
                    if "=" in item:
                        key, value = item.split("=", 1)
                        d[key] = value

    parser = argparse.ArgumentParser(
        description="Runs the Cocotb framework from Bazel"
    )

    parser.add_argument("--sim", default="icarus", help="Default simulator")
    parser.add_argument(
        "--hdl_library",
        default="top",
        help="The library name to compile into"
    )
    parser.add_argument(
        "--verilog_sources",
        nargs="*",
        default=[],
        help="Verilog source files to build"
    )
    parser.add_argument(
        "--vhdl_sources",
        nargs="*",
        default=[],
        help="VHDL source files to build"
    )
    parser.add_argument(
        "--includes",
        nargs="*",
        default=[],
        help="Verilog include directories"
    )
    parser.add_argument(
        "--defines",
        nargs="*",
        default={},
        action=ParseDict,
        help="Defines to set"
    )
    parser.add_argument(
        "--parameters",
        nargs="*",
        default={},
        action=ParseDict,
        help="Verilog parameters or VHDL generics",
    )
    parser.add_argument(
        "--build_args",
        nargs="*",
        default=[],
        help="Extra build arguments for the simulator",
    )
    parser.add_argument(
        "--test_args",
        nargs="*",
        default=[],
        help="Extra test arguments for the simulator",
    )
    parser.add_argument(
        "--hdl_toplevel", default=None, help="Name of the HDL toplevel module"
    )
    parser.add_argument(
        "--always",
        default=False,
        action="store_true",
        help="Name of the HDL toplevel module",
    )
    parser.add_argument(
        "--build_dir",
        default="sim_build",
        help="Directory to run the build step in"
    )
    parser.add_argument(
        "--verbose",
        default=False,
        action="store_true",
        help="Enable verbose messages"
    )
    parser.add_argument(
        "--test_module",
        nargs="*",
        default=[],
        help="Name(s) of the Python module(s) containing the tests to run",
    )
    parser.add_argument(
        "--hdl_toplevel_library",
        help="The library name for HDL toplevel module"
    )
    parser.add_argument(
        "--hdl_toplevel_lang",
        default=None,
        help="Language of the HDL toplevel module"
    )
    parser.add_argument(
        "--gpi_interfaces",
        default=None,
        help=
        "List of GPI interfaces to use, with the first one being the entry point",
    )
    parser.add_argument(
        "--testcase",
        default=None,
        help="Name(s) of a specific testcase(s) to run"
    )
    parser.add_argument(
        "--seed", default=None, help="A specific random seed to use"
    )
    parser.add_argument(
        "--plusargs", default=[], help="'plusargs' to set for the simulator"
    )
    parser.add_argument(
        "--extra_env",
        nargs="*",
        default={},
        action=ParseDict,
        help="Extra environment variables to set",
    )
    parser.add_argument(
        "--waves",
        action="store_true",
        default=None,
        help="Record signal traces"
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        default=None,
        help="Record signal traces"
    )
    parser.add_argument(
        "--test_dir", default=None, help="Directory to run the build step in"
    )
    parser.add_argument(
        "--results_xml",
        default="results.xml",
        help="Name of xUnit XML file to store test results in",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Verilated model binary",
    )
    parser.add_argument(
        "--main_workspace",
        default=None,
        help="Main workspace name of the build",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=None,
        help="Maximum parallel build jobs for the runner",
    )

    return parser


if __name__ == "__main__":
    waves_env = os.environ.get("WAVES", "").lower()
    if waves_env in ["0", "false", "no", "off"]:
        os.environ.pop("WAVES", None)

    parser = cocotb_argument_parser()
    args = parser.parse_args()

    build_flags = filter_args(vars(args), cocotb_build_flags)
    test_flags = filter_args(vars(args), cocotb_test_flags)

    build_args = []
    for build_arg in build_flags['build_args']:
        build_args += build_arg.split(" ")
    build_flags['build_args'] = build_args
    build_flags['always'] = True

    test_args = []
    for test_arg in test_flags['test_args']:
        test_args += test_arg.split(" ")
    test_flags['test_args'] = test_args

    if args.jobs:
        jobs = args.jobs
    else:
        try:
            jobs = len(os.sched_getaffinity(0))
        except (AttributeError, NotImplementedError):
            jobs = os.cpu_count() or 4
    cocotb_tools.runner.MAX_PARALLEL_BUILD_JOBS = max(1, jobs)
    runner = get_runner(args.sim)

    if args.sim == "vcs" and args.model:
        main_ws = args.main_workspace or "coralnpu_hw"
        r = runfiles.Create()
        model_path = args.model
        if model_path.startswith("../"):
            model_path = model_path[3:]
            runfiles_path = r.Rlocation(model_path, source_repo="")
        else:
            runfiles_path = r.Rlocation(
                f"{main_ws}/{model_path}", source_repo=""
            )
            if not runfiles_path:
                runfiles_path = r.Rlocation(
                    f"coralnpu_hw/{model_path}", source_repo=""
                )
            if not runfiles_path:
                runfiles_path = r.Rlocation(model_path, source_repo="")

        if not runfiles_path or not os.path.exists(runfiles_path):
            print(
                f"Error: Could not find VCS model in runfiles: {args.model}",
                file=sys.stderr
            )
            sys.exit(1)

        daidir_path = runfiles_path + ".daidir"

        build_dir = build_flags.get('build_dir', 'sim_build')
        os.makedirs(build_dir, exist_ok=True)

        dest_simv = os.path.join(build_dir, 'simv')
        dest_daidir = os.path.join(build_dir, 'simv.daidir')
        dest_vdb = os.path.join(build_dir, 'simv.vdb')

        if os.path.lexists(dest_simv):
            os.remove(dest_simv)
        if os.path.lexists(dest_daidir):
            if os.path.islink(dest_daidir):
                os.remove(dest_daidir)
            else:
                shutil.rmtree(dest_daidir)
        if os.path.lexists(dest_vdb):
            if os.path.islink(dest_vdb):
                os.remove(dest_vdb)
            else:
                shutil.rmtree(dest_vdb)

        os.symlink(runfiles_path, dest_simv)
        if os.path.exists(daidir_path):
            shutil.copytree(daidir_path, dest_daidir)
            os.chmod(dest_daidir, 0o755)
            for root, dirs, files in os.walk(dest_daidir):
                for d in dirs:
                    os.chmod(os.path.join(root, d), 0o755)
                for f in files:
                    os.chmod(os.path.join(root, f), 0o644)
        else:
            print(
                f"Warning: daidir not found at {daidir_path}", file=sys.stderr
            )

        vdb_path = runfiles_path + ".vdb"
        if os.path.exists(vdb_path):
            shutil.copytree(vdb_path, dest_vdb, dirs_exist_ok=True)
            os.chmod(dest_vdb, 0o755)
            for root, dirs, files in os.walk(dest_vdb):
                for d in dirs:
                    os.chmod(os.path.join(root, d), 0o755)
                for f in files:
                    os.chmod(os.path.join(root, f), 0o644)

        print(f"Using pre-compiled VCS model from {runfiles_path}")

        vcs_lib_dir = r.Rlocation(
            "coralnpu_pip_deps_cocotb/cocotb/libs", source_repo=""
        )
        if not vcs_lib_dir:
            vcs_lib_dir = r.Rlocation(
                f"{main_ws}/external/coralnpu_pip_deps_cocotb/cocotb/libs",
                source_repo=""
            )
        if not vcs_lib_dir:
            vcs_lib_dir = r.Rlocation(
                "external/coralnpu_pip_deps_cocotb/cocotb/libs",
                source_repo=""
            )
        if vcs_lib_dir:
            cur_ld = os.environ.get("LD_LIBRARY_PATH", "")
            os.environ['LD_LIBRARY_PATH'] = "{}:{}".format(
                vcs_lib_dir, cur_ld
            ) if cur_ld else vcs_lib_dir
            if 'extra_env' not in test_flags or not isinstance(
                    test_flags['extra_env'], dict):
                test_flags['extra_env'] = {}
            test_flags['extra_env']['LD_LIBRARY_PATH'] = os.environ[
                'LD_LIBRARY_PATH']

        test_flags['test_args'] = test_flags.get('test_args', [])
        if not any(arg.startswith("-cm_dir")
                   for arg in test_flags['test_args']):
            test_flags['test_args'].extend([
                "-cm_dir", os.path.abspath(build_dir)
            ])

    elif args.sim == "verilator" and args.model:
        main_ws = args.main_workspace or "coralnpu_hw"
        r = runfiles.Create()
        model_path = args.model
        if model_path.startswith("../"):
            model_path = model_path[3:]
            resolved_model = r.Rlocation(model_path, source_repo="")
        else:
            resolved_model = r.Rlocation(
                f"{main_ws}/{model_path}", source_repo=""
            )
            if not resolved_model:
                resolved_model = r.Rlocation(
                    f"coralnpu_hw/{model_path}", source_repo=""
                )
            if not resolved_model:
                resolved_model = r.Rlocation(model_path, source_repo="")

        if not resolved_model or not os.path.exists(resolved_model):
            print(
                f"Error: Could not find Verilator model in runfiles: {args.model}",
                file=sys.stderr
            )
            sys.exit(1)

        sim_build = os.path.dirname(resolved_model)
        test_flags['build_dir'] = sim_build

        verilator_lib_dir = r.Rlocation(
            "coralnpu_pip_deps_cocotb/cocotb/libs", source_repo=""
        )
        if not verilator_lib_dir:
            verilator_lib_dir = r.Rlocation(
                f"{main_ws}/external/coralnpu_pip_deps_cocotb/cocotb/libs",
                source_repo=""
            )
        if not verilator_lib_dir:
            verilator_lib_dir = r.Rlocation(
                "external/coralnpu_pip_deps_cocotb/cocotb/libs",
                source_repo=""
            )
        if verilator_lib_dir:
            cur_ld = os.environ.get("LD_LIBRARY_PATH", "")
            test_flags['extra_env']['LD_LIBRARY_PATH'] = (
                f"{verilator_lib_dir}:{cur_ld}"
                if cur_ld else verilator_lib_dir
            )
    else:
        runner.build(**build_flags)

    # Inject python runfiles fix to PYTHONPATH for all simulator runs.
    #
    # CAVEAT: cocotb_tools.runner overrides the child process PYTHONPATH using the
    # parent's sys.path (self.env["PYTHONPATH"] = os.pathsep.join(sys.path)).
    # Therefore, modifying os.environ["PYTHONPATH"] alone is insufficient as it
    # gets overwritten. We must explicitly update sys.path to ensure the directory
    # is propagated to the simulator VM.
    main_ws = args.main_workspace or "coralnpu_hw"
    r = runfiles.Create()
    if r:
        runfiles_fix_file = r.Rlocation(
            f"{main_ws}/third_party/python_runfiles_fix/sitecustomize.py",
            source_repo=""
        )
        if not runfiles_fix_file:
            runfiles_fix_file = r.Rlocation(
                "coralnpu_hw/third_party/python_runfiles_fix/sitecustomize.py",
                source_repo=""
            )
        if not runfiles_fix_file:
            runfiles_fix_file = r.Rlocation(
                "third_party/python_runfiles_fix/sitecustomize.py",
                source_repo=""
            )
        if runfiles_fix_file:
            runfiles_fix_dir = os.path.dirname(runfiles_fix_file)
            sys.path.insert(0, runfiles_fix_dir)
            os.environ["PYTHONPATH"] = os.pathsep.join([
                runfiles_fix_dir,
                os.environ.get("PYTHONPATH", "")
            ])

    if 'extra_env' in test_flags and isinstance(test_flags['extra_env'], dict):
        extra_env = test_flags['extra_env']
        if 'COCOTB_TEST_FILTER' in extra_env:
            val = extra_env['COCOTB_TEST_FILTER']
            if val == '$TESTBRIDGE_TEST_ONLY':
                tb_filter = os.environ.get('TESTBRIDGE_TEST_ONLY', '')
                if tb_filter:
                    extra_env['COCOTB_TEST_FILTER'] = tb_filter
                else:
                    del extra_env['COCOTB_TEST_FILTER']
            elif not val:
                del extra_env['COCOTB_TEST_FILTER']

        if test_flags.get('testcase'):
            extra_env.pop('COCOTB_TEST_FILTER', None)
            os.environ.pop('COCOTB_TEST_FILTER', None)

    results_xml = runner.test(**test_flags)
    (num_tests, num_failed) = get_results(results_xml)
    sys.exit(1 if (num_failed > 0 or num_tests == 0) else 0)
