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
"""Standalone Bazel runfiles shim for FPGA test packages."""

import os
import sys


class Runfiles:
    """Minimal Runfiles implementation for unpacked FPGA test packages."""

    def Rlocation(self, path: str, source_repo: str | None = None) -> str:
        del source_repo
        if not path:
            return path
        stripped = path.removeprefix("coralnpu_hw/")
        if os.path.exists(path):
            return os.path.abspath(path)
        return os.path.abspath(stripped)

    rlocation = Rlocation


def Create(*_args, **_kwargs) -> Runfiles:
    return Runfiles()


runfiles = sys.modules[__name__]
