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
"""Bazel Python Runfiles Resolution Fix for Unsandboxed / Manifest-only Runs.

This workaround was introduced to fix a regression first exposed in our tree on
June 4, 2026, by commit 19640911d6ad8416fab524981a1b07dea8be09e8 ("vcs: Pre-compiled
model sharing & license queuing", Change-Id: I2e466d496a6233b2250e97f5cfaf8d4958dba276). That
commit integrated pre-compiled VCS models by using the Bazel runfiles library in rules_hdl's
cocotb runner, which subsequently crashed in unsandboxed and manifest-only (e.g. EDACloud) runs.

THE PROBLEM:
When running Python targets under Bazel, the runfiles library (`rules_python` or
`bazel_tools`) needs to resolve the location of runfiles (e.g. data dependencies).
To do this, it looks at the caller's stack frame to determine the "source repository"
(the repo where the calling code lives) by inspecting the file path of the caller
and trying to match it against known workspace names.

However, when running:
1. Unsandboxed (`--spawn_strategy=local` or similar, or when running outside of Bazel sandbox).
2. Manifest-only (e.g. CI or remote execution, which uses `--nobuild_runfile_links` to avoid creating a
   heavy symlink tree of runfiles and instead uses a text manifest file).

In these modes, the files are executed from paths that do not match the expected Bazel sandbox
structure (e.g., they might be run directly from `/tmp/...` or from their source paths without
the `external/` or `main_workspace/` directory prefixes).
As a result, `rules_python`'s stack-frame inspection fails to find a matching repository name,
throwing:
    `ValueError: Cannot find repository name for path ...`

WHY IT AFFECTS COCOTB TESTS SPECIFICALLY:
In `rules_hdl`, cocotb tests are run by `cocotb_wrapper.py` which sets up the environment and
launches the simulator. The simulator loads the cocotb VPI library, which initializes a *new*
Python VM in-process. This child Python VM runs the actual test script.
Because `cocotb_wrapper.py` starts a new Python process (or rather, the simulator does via C++),
any monkeypatching applied to `cocotb_wrapper.py` itself does not propagate to the child Python VM.
The child Python VM runs the test script, which calls `r.Rlocation()` to find simulation assets.
If running under `--nobuild_runfile_links` (default in some CI/remote execution environments), these
`r.Rlocation` calls fail with `ValueError`.

THE SOLUTION:
We inject this `sitecustomize.py` script into the `PYTHONPATH` of the simulator process.
Python automatically imports `sitecustomize` (if present in `PYTHONPATH`) during startup.
This script monkeypatches `rules_python.python.runfiles.runfiles.Create` (and the `bazel_tools`
equivalent) to override the default behavior.
Specifically, when `Create()` is called without arguments, it tries to guess the caller repo.
We intercept this and pass `source_repo=""` (empty string) to `Create()`.
Passing `source_repo=""` tells the runfiles library to skip stack-frame repository lookup
and instead resolve paths relative to the main workspace (which is correct for our tests as
they are all in the main repository).

WHEN CAN WE REMOVE THIS PATCH:
Although rules_python 0.35.0 attempted to fix this traceback (Issue #1631) for cases where
the Rlocation call is in the same directory as the main file, it does not resolve our case.
This is because in rules_hdl cocotb simulations, the main file (the simulator binary) and
the test scripts calling Rlocation reside in different directories, and run across a process
boundary (simulator binary launching Python VM).

This patch can be removed when:
1. rules_hdl is updated to a version that avoids stack-frame runfiles resolution inside
   the simulator process (e.g. by passing the resolved paths from the parent process), or
2. rules_hdl properly sets up the repository mapping environment variables for the child
   Python VM so that rules_python can resolve the repository without stack-frame inspection, or
3. rules_python is updated to a version that gracefully falls back (e.g., to source_repo="")
   instead of raising ValueError when stack-frame inspection fails.
"""

import sys


def patch_runfiles():
    try:
        modules_to_patch = []
        try:
            from bazel_tools.tools.python.runfiles import runfiles as bazel_runfiles
            modules_to_patch.append(bazel_runfiles)
        except ImportError:
            pass

        try:
            from rules_python.python.runfiles import runfiles as rules_runfiles
            modules_to_patch.append(rules_runfiles)
        except ImportError:
            pass

        try:
            from python.runfiles import runfiles as python_runfiles
            modules_to_patch.append(python_runfiles)
        except ImportError:
            pass

        for runfiles_mod in modules_to_patch:
            if hasattr(runfiles_mod, 'Runfiles'):
                cls = runfiles_mod.Runfiles
                for method_name in ['Rlocation', 'rlocation']:
                    if hasattr(cls, method_name):
                        orig_method = getattr(cls, method_name)

                        # We use a default argument `_orig=orig_method` to bind the correct
                        # original method to the closure, preventing issues if we patch multiple times
                        # or if the variable scopes clash.
                        def patched(
                            self, path, source_repo=None, _orig=orig_method
                        ):
                            if source_repo is None:
                                source_repo = ""
                            return _orig(self, path, source_repo=source_repo)

                        setattr(cls, method_name, patched)
    except Exception:
        pass


patch_runfiles()
