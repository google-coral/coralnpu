# Copyright 2023 Google LLC
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

"""CoralNPU HW dependent repositories."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(
    "@rules_foreign_cc//foreign_cc:repositories.bzl",
    "rules_foreign_cc_dependencies",
)
load(
    "@rules_hdl//dependency_support:dependency_support.bzl",
    rules_hdl_dependency_support = "dependency_support",
)

def coralnpu_deps():
    """Full coralnpu dependent repositories

    Including chisel and systemC test code
    """
    rules_foreign_cc_dependencies()
    rules_hdl_dependency_support()

    http_archive(
        name = "accellera_systemc",
        build_file = "@coralnpu_hw//third_party/systemc:systemc.BUILD",
        sha256 = "bfb309485a8ad35a08ee78827d1647a451ec5455767b25136e74522a6f41e0ea",
        strip_prefix = "systemc-2.3.4",
        urls = [
            "https://github.com/accellera-official/systemc/archive/refs/tags/2.3.4.tar.gz",
        ],
    )

    http_archive(
        name = "riscv_isa_sim",
        build_file = "@coralnpu_hw//third_party:spike.BUILD",
        sha256 = "850f3c736f98536e306b7cf070b07996fb557014e2150353ec0118efac14674d",
        strip_prefix = "riscv-isa-sim-fd72ee2d3e0d1703451c446d467387ff0576e492",
        patches = [
            "@coralnpu_hw//third_party/spike:0001-Add-mpause.patch",
            "@coralnpu_hw//third_party/spike:0002-Coral-Deviations.patch",
            "@coralnpu_hw//third_party/spike:0003-Dump-GPRs-on-EBREAK.patch",
            "@coralnpu_hw//third_party/spike:0004-Add-custom-CoralNPU-CSRs-and-update-MVENDORID-MARCHI.patch",
            "@coralnpu_hw//third_party/spike:0005-Force-logging-in-vcompress.patch",
            "@coralnpu_hw//third_party/spike:0006-Hardwire-misa-as-read-only-WARL.patch",
        ],
        patch_args = ["-p1"],
        urls = [
            "https://github.com/riscv-software-src/riscv-isa-sim/archive/fd72ee2d3e0d1703451c446d467387ff0576e492.tar.gz",
        ],
    )
