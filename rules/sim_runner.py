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
"""Helper runner script to execute cocotb_wrapper inside a dynamic py_binary."""

import argparse
import os
import runpy
import shlex
import sys
from bazel_tools.tools.python.runfiles import runfiles


def main():
    r = runfiles.Create()
    if not r:
        sys.stderr.write("Error: Failed to create runfiles utility.\n")
        sys.exit(1)

    # Extract custom runner arguments safely.
    parser = argparse.ArgumentParser()
    parser.add_argument("--test_module_path")
    parser.add_argument("--status_file")
    args, unknown = parser.parse_known_args()

    test_module_path = args.test_module_path
    status_file_path = args.status_file
    sys.argv = [sys.argv[0]] + unknown

    # Convert all paths in sys.path to absolute paths before putting them in PYTHONPATH.
    # Cocotb changes the current working directory to sim_build during simulation,
    # so relative paths in PYTHONPATH would resolve incorrectly.
    os.environ["PYTHONPATH"] = os.pathsep.join(
        os.path.abspath(p) if p else os.getcwd() for p in sys.path
    )

    # Convert relative paths in +fsdbfile+ to absolute paths because cocotb changes CWD to sim_build.
    execroot = os.getcwd()
    for i, arg in enumerate(sys.argv):
        if arg == "--test_args" and i + 1 < len(sys.argv):
            test_args_str = sys.argv[i + 1]
            parts = shlex.split(test_args_str)
            new_parts = []
            for p in parts:
                if p.startswith("+fsdbfile+"):
                    path = p[len("+fsdbfile+"):]
                    if not os.path.isabs(path):
                        p = "+fsdbfile+" + os.path.abspath(
                            os.path.join(execroot, path)
                        )
                new_parts.append(p)
            sys.argv[i + 1] = shlex.join(new_parts)
            break

    # Resolve the test module path dynamically using runfiles.
    if test_module_path:
        module_abs_path = r.Rlocation(test_module_path)
        if not module_abs_path:
            sys.stderr.write(
                f"Error: Could not resolve test module path in runfiles: {test_module_path}\n"
            )
            sys.exit(1)

        abs_dir = os.path.dirname(module_abs_path)
        sys.path.insert(0, abs_dir)
        os.environ["PYTHONPATH"
                   ] = abs_dir + os.pathsep + os.environ.get("PYTHONPATH", "")

        module_name = os.path.basename(module_abs_path)
        if module_name.endswith(".py"):
            module_name = module_name[:-3]

        # Add translated --test_module back to sys.argv for cocotb_wrapper
        sys.argv.extend(["--test_module", module_name])

    # Resolve the VPI library file to find its directory
    resolved_file = None
    try:
        import cocotb
        cocotb_dir = os.path.dirname(cocotb.__file__)
        vcs_lib_dir = os.path.join(cocotb_dir, "libs")
        candidate = os.path.join(vcs_lib_dir, "libcocotbvpi_vcs.so")
        if os.path.exists(candidate):
            resolved_file = candidate
    except ImportError:
        pass

    # Workaround: set LD_LIBRARY_PATH if resolved
    if resolved_file:
        vcs_lib_dir = os.path.dirname(resolved_file)
        old_ld_path = os.environ.get("LD_LIBRARY_PATH")
        if old_ld_path:
            os.environ["LD_LIBRARY_PATH"] = f"{vcs_lib_dir}:{old_ld_path}"
        else:
            os.environ["LD_LIBRARY_PATH"] = vcs_lib_dir

    wrapper_path = r.Rlocation("coralnpu_hw/rules/cocotb_wrapper.py")
    if not wrapper_path:
        wrapper_path = r.Rlocation("rules/cocotb_wrapper.py")
    if not wrapper_path:
        sys.stderr.write(
            "Error: Could not find rules/cocotb_wrapper.py in runfiles\n"
        )
        sys.exit(1)

    exit_code = 0
    try:
        # Execute the wrapper script using run_path
        runpy.run_path(wrapper_path, run_name="__main__")
    except SystemExit as e:
        if isinstance(e.code, int):
            exit_code = e.code
        elif e.code is not None:
            exit_code = 1
    except Exception as e:
        # Propagate unexpected setup/infrastructure exceptions without writing status file.
        raise e

    if status_file_path:
        with open(status_file_path, "w") as f:
            f.write(f"{exit_code}\n")

    if exit_code > 128:
        sys.exit(exit_code)


if __name__ == "__main__":
    main()
