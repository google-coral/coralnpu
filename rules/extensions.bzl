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

"""Module extension for coralnpu dependencies."""

load("//rules:host_cpus.bzl", "host_cpus")
load(
    "//rules:repo_defs.bzl",
    "define_coralnpu_toolchain",
    "define_fpga_repos",
    "define_internal_check",
    "define_mpact_repos",
    "define_pybind11_abseil",
    "define_sim_repos",
    "define_synthesis_internal",
    "define_tflite_repos",
    "ot_python_deps_compat",
    "python311_compat",
)
load("//rules:repos.bzl", "cvfpu_repos", "rules_hdl_compat", "rvvi_repos", "verilator_repos")
load("//third_party/python:requirements.bzl", "install_deps")

def _coralnpu_deps_ext_impl(_ctx):
    # Call non-conflicting legacy repo definitions
    host_cpus(name = "coralnpu_host_cpus")
    cvfpu_repos()
    rvvi_repos()
    verilator_repos()
    rules_hdl_compat(name = "rules_hdl")

    # Call shared repo definitions
    define_coralnpu_toolchain()
    define_pybind11_abseil()
    define_mpact_repos()
    define_tflite_repos()
    define_fpga_repos()
    define_internal_check()
    define_synthesis_internal()
    define_sim_repos()

    # Bzlmod compatibility repos
    ot_python_deps_compat(name = "ot_python_deps")
    python311_compat(name = "python311_x86_64-unknown-linux-gnu")

    # Install hermetic Python wheel repos (coralnpu_pip_deps_*)
    install_deps()

coralnpu_deps_ext = module_extension(implementation = _coralnpu_deps_ext_impl)
