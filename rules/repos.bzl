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

"""Repository rules and definitions for CoralNPU Bzlmod dependencies."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@coralnpu_hw//third_party/verilator:gnulib.bzl", "org_gnu_gnulib")

def _rules_hdl_compat_impl(rctx):
    rctx.file("WORKSPACE", "workspace(name = 'rules_hdl')\n")
    rctx.file("BUILD.bazel", "package(default_visibility = ['//visibility:public'])\n")
    rctx.file("verilog/BUILD.bazel", "package(default_visibility = ['//visibility:public'])\nexports_files(['providers.bzl'])\n")
    rctx.file("verilog/providers.bzl", """# Compatibility forwarding for rules_hdl
load(
    "@coralnpu_hw//rules:verilog.bzl",
    _VerilogInfo = "VerilogInfo",
    _verilog_library = "verilog_library",
)

VerilogInfo = _VerilogInfo
verilog_library = _verilog_library
""")

rules_hdl_compat = repository_rule(
    implementation = _rules_hdl_compat_impl,
    local = True,
)

def verilator_repos():
    http_archive(
        name = "verilator",
        build_file = "@coralnpu_hw//third_party/verilator:verilator.BUILD.bazel",
        urls = ["https://github.com/verilator/verilator/archive/refs/tags/v5.052.tar.gz"],
        sha256 = "8c8d2e11e6ad32f641dd250742a94195ddecb912e2e2dabe2f42ddbbb99c1092",
        strip_prefix = "verilator-5.052",
        patch_args = ["-p1"],
        patches = [
            "@coralnpu_hw//third_party/verilator:0001-Remove-autodetect-of-VERILATOR_ROOT.patch",
        ],
    )

    http_archive(
        name = "net_zlib",
        sha256 = "f5cc4ab910db99b2bdbba39ebbdc225ffc2aa04b4057bc2817f1b94b6978cfc3",
        strip_prefix = "zlib-1.2.11",
        urls = [
            "https://github.com/madler/zlib/archive/v1.2.11.zip",
        ],
        build_file = "@coralnpu_hw//third_party/verilator:zlib.BUILD",
    )

    http_archive(
        name = "org_gnu_m4",
        urls = [
            "https://ftp.gnu.org/gnu/m4/m4-1.4.18.tar.xz",
            "https://ftpmirror.gnu.org/m4/m4-1.4.18.tar.xz",
        ],
        strip_prefix = "m4-1.4.18",
        sha256 = "f2c1e86ca0a404ff281631bdc8377638992744b175afb806e25871a24a934e07",
        build_file = "@coralnpu_hw//third_party/verilator:m4.BUILD",
    )

    http_archive(
        name = "com_github_westes_flex",
        urls = [
            "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz",
        ],
        strip_prefix = "flex-2.6.4",
        sha256 = "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995",
        build_file = "@coralnpu_hw//third_party/verilator:flex.BUILD",
    )

    http_archive(
        name = "org_gnu_bison",
        urls = [
            "https://ftp.gnu.org/gnu/bison/bison-3.5.tar.xz",
            "https://ftpmirror.gnu.org/bison/bison-3.5.tar.xz",
        ],
        strip_prefix = "bison-3.5",
        sha256 = "55e4a023b1b4ad19095a5f8279f0dc048fa29f970759cea83224a6d5e7a3a641",
        build_file = "@coralnpu_hw//third_party/verilator:bison.BUILD",
    )

    org_gnu_gnulib()

def cvfpu_repos():
    http_archive(
        name = "cvfpu",
        urls = ["https://github.com/openhwgroup/cvfpu/archive/bb65bdedd07711dfd41c621382f940a5cbb93046.zip"],
        sha256 = "0723e6a6feb8e033679d2f9145f99ee4fb26c80e67b3662a8eec9b61bd30f6cc",
        build_file = "@coralnpu_hw//third_party/cvfpu:BUILD.bazel",
        strip_prefix = "cvfpu-bb65bdedd07711dfd41c621382f940a5cbb93046",
        patches = [
            "@coralnpu_hw//third_party/cvfpu:0001-Fix-max_num_lanes-issue-in-DC.patch",
            "@coralnpu_hw//third_party/cvfpu:0002-Remove-SVH-includes.patch",
            "@coralnpu_hw//third_party/cvfpu:0003-Fill-in-unreachable-state-in-fpnew_divsqrt_th_32-fsm.patch",
            "@coralnpu_hw//third_party/cvfpu:0004-Remove-ternary-operator-from-pkg-causing-dc-crash.patch",
            "@coralnpu_hw//third_party/cvfpu:0005-Fix-fsm-complete.patch",
            "@coralnpu_hw//third_party/cvfpu:0006-Fix-syn-tool-compatibility-issues.patch",
            "@coralnpu_hw//third_party/cvfpu:0007-Fix-nan-boxing-divsqrt.patch",
            "@coralnpu_hw//third_party/cvfpu:0008-Fix-num-lanes-multifmt-slice.patch",
            "@coralnpu_hw//third_party/cvfpu:0009-Rebalance-fpnew-fma-pipeline-stages.patch",
            "@coralnpu_hw//third_party/cvfpu:0010-Move-LZA-leading-zero-counter-to-norm-stage.patch",
        ],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "common_cells",
        sha256 = "4d27dfb483e856556812bac7760308ea1b576adc4bd172d08f7421cea488e5ab",
        urls = ["https://github.com/pulp-platform/common_cells/archive/6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea.zip"],
        strip_prefix = "common_cells-6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea",
        build_file = "@coralnpu_hw//third_party/common_cells:BUILD.bazel",
    )

    http_archive(
        name = "fpu_div_sqrt_mvp",
        sha256 = "27bd475637d51215416acf6fdb78e613569f8de0b90040ccc0e3e4679572d8c4",
        urls = ["https://github.com/pulp-platform/fpu_div_sqrt_mvp/archive/86e1f558b3c95e91577c41b2fc452c86b04e85ac.zip"],
        build_file = "@coralnpu_hw//third_party/fpu_div_sqrt_mvp:BUILD.bazel",
        strip_prefix = "fpu_div_sqrt_mvp-86e1f558b3c95e91577c41b2fc452c86b04e85ac",
    )

def rvvi_repos():
    http_archive(
        name = "RVVI",
        # Reflects tag 20240403.0 (before it's update)
        urls = ["https://github.com/riscv-verification/RVVI/archive/5786f0d39b84f3fd15ef75b792bdea4281941afe.zip"],
        sha256 = "18090eed44752f88e84d7631dc525c130ba6c6a5143d7cc2004dc2ca3641eaa2",
        strip_prefix = "RVVI-5786f0d39b84f3fd15ef75b792bdea4281941afe",
        build_file = "@coralnpu_hw//third_party/RVVI:BUILD.bazel",
        patches = [
            "@coralnpu_hw//third_party/RVVI:0001-Rename-name-queue-to-avoid-conflict.patch",
            "@coralnpu_hw//third_party/RVVI:0002-Add-rvviTrace-matrix-tile-interface.patch",
        ],
        patch_args = ["-p1"],
    )
