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

"""Build setting selecting VCS code coverage metrics."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _vcs_coverage_types_impl(ctx):
    return [BuildSettingInfo(value = ctx.build_setting_value)]

vcs_coverage_types = rule(
    implementation = _vcs_coverage_types_impl,
    build_setting = config.string_list(flag = True),
    doc = """VCS code coverage metrics compiled into vcs_binary targets.

Set on the command line, e.g.:

  bazel build //tests/vcs_sim:foo \\
      --//rules:vcs_coverage_types=line+cond+fsm+branch+tgl+assert

Repeated flags accumulate; values are joined with "+" before being passed to
"vcs -cm".""",
)
