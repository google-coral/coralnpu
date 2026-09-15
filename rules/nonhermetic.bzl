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

"""Non-hermetic repository rule compatible with OpenTitan requirements."""

NONHERMETIC_ENV_VARS = [
    "XILINX_VIVADO",
    "XILINXD_LICENSE_FILE",
]

NONHERMETIC_BINS = [
    "verilator",
    "vivado",
    "updatemem",
]

def _nonhermetic_repo_impl(rctx):
    env = "\n".join(["    \"{}\": \"{}\",".format(v, rctx.getenv(v, "")) for v in NONHERMETIC_ENV_VARS])
    home = rctx.getenv("HOME", "")

    bins = {name: rctx.which(name) for name in NONHERMETIC_BINS}
    bin_paths = "\n".join(["    \"{}\": \"{}\",".format(name, rctx.path(path).dirname if path != None else "/no-such-path") for name, path in bins.items()])

    rctx.file("env.bzl", "ENV = {{\n{}\n}}\nHOME = \"{}\"\nBIN_PATHS = {{\n{}\n}}\n".format(env, home, bin_paths))
    rctx.file("BUILD.bazel", "exports_files(glob([\"**\"]))\n")

nonhermetic_repo = repository_rule(
    implementation = _nonhermetic_repo_impl,
    attrs = {},
)
