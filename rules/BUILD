# Copyright 2025 Google LLC
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

load("@bazel_skylib//rules:common_settings.bzl", "bool_flag")

package(default_visibility = ["//visibility:public"])

exports_files(glob(["*.bzl"]))

exports_files([
    "default.vlt.tpl",
    "chisel_test_runner.sh",
    "vcs_model_wrapper.sh.template",
    # Sourced by cocotb rules. Must be referenced via fully qualified label:
    # "@coralnpu_hw//rules:sim_runner.py" to support multi-workspace execution.
    "sim_runner.py",
])

# Enable Spike co-simulation for UVM tests
# specifying --//rules:uvm_run_spike_cosim=true
bool_flag(
    name = "uvm_run_spike_cosim",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)
