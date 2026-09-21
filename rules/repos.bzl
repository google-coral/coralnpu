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

# CoralNPU repositories
#

load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("@coralnpu_hw//third_party/verilator:gnulib.bzl", "org_gnu_gnulib")
load(
    "//rules:repo_defs.bzl",
    "define_fpga_repos",
    "define_mpact_repos",
    "define_pybind11_abseil",
    "define_sim_repos",
)

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

def coralnpu_repos():
    rules_hdl_compat(
        name = "rules_hdl",
    )

    define_sim_repos()

    http_archive(
        name = "bazel_skylib",
        sha256 = "3b5b49006181f5f8ff626ef8ddceaa95e9bb8ad294f7b5d7b11ea9f7ddaf8c59",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/bazel-skylib/releases/download/1.9.0/bazel-skylib-1.9.0.tar.gz",
            "https://github.com/bazelbuild/bazel-skylib/releases/download/1.9.0/bazel-skylib-1.9.0.tar.gz",
        ],
    )

    http_archive(
        name = "com_google_absl",
        urls = ["https://github.com/abseil/abseil-cpp/archive/refs/tags/20260526.0.tar.gz"],
        sha256 = "6e1aee535473414164bf83e4ebc40240dec71a4701f8a642d906e95bea1aea0c",
        strip_prefix = "abseil-cpp-20260526.0",
    )

    http_archive(
        name = "com_google_googletest",
        sha256 = "7b42b4d6ed48810c5362c265a17faebe90dc2373c885e5216439d37927f02926",
        strip_prefix = "googletest-1.15.2",
        urls = [
            "https://github.com/google/googletest/releases/download/v1.15.2/googletest-1.15.2.tar.gz",
        ],
    )

    http_archive(
        name = "rules_java",
        urls = [
            "https://github.com/bazelbuild/rules_java/releases/download/8.14.0/rules_java-8.14.0.tar.gz",
        ],
        sha256 = "bbe7d94360cc9ed4607ec5fd94995fd1ec41e84257020b6f09e64055281ecb12",
    )

    http_archive(
        name = "com_google_protobuf",
        strip_prefix = "protobuf-35.1",
        sha256 = "f0b6838e7522a8da96126d487068c959bc624926368f3024ac8fd03abd0a1ac4",
        url = "https://github.com/protocolbuffers/protobuf/releases/download/v35.1/protobuf-35.1.tar.gz",
        repo_mapping = {
            "@abseil-cpp": "@com_google_absl",
        },
    )

    http_archive(
        name = "com_googlesource_code_re2",
        sha256 = "87f6029d2f6de8aa023654240a03ada90e876ce9a4676e258dd01ea4c26ffd67",
        strip_prefix = "re2-2025-11-05",
        url = "https://github.com/google/re2/releases/download/2025-11-05/re2-2025-11-05.tar.gz",
        repo_mapping = {
            "@abseil-cpp": "@com_google_absl",
        },
    )

    http_archive(
        name = "rules_pkg",
        urls = [
            "https://github.com/bazelbuild/rules_pkg/releases/download/1.2.0/rules_pkg-1.2.0.tar.gz",
        ],
        sha256 = "b5c9184a23bb0bcff241981fd9d9e2a97638a1374c9953bb1808836ce711f990",
    )

    http_archive(
        name = "rules_proto",
        urls = ["https://github.com/bazelbuild/rules_proto/releases/download/7.1.0/rules_proto-7.1.0.tar.gz"],
        sha256 = "14a225870ab4e91869652cfd69ef2028277fc1dc4910d65d353b62d6e0ae21f4",
        strip_prefix = "rules_proto-7.1.0",
    )

    http_archive(
        name = "rules_python",
        sha256 = "690e0141724abb568267e003c7b6d9a54925df40c275a870a4d934161dc9dd53",
        strip_prefix = "rules_python-0.40.0",
        url = "https://github.com/bazelbuild/rules_python/releases/download/0.40.0/rules_python-0.40.0.tar.gz",
        patches = ["@coralnpu_hw//rules:rules_python_airgap.patch"],
        patch_args = ["-p0"],
    )

    http_archive(
        name = "pybind11_bazel",
        urls = ["https://github.com/pybind/pybind11_bazel/releases/download/v2.13.6/pybind11_bazel-2.13.6.tar.gz"],
        strip_prefix = "pybind11_bazel-2.13.6",
        sha256 = "cae680670bfa6e82703c03f2a3c995408cdcbf43616d7bdd198ef45d3c327731",
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

def coralnpu_repos2():
    """Coralnpu repos are split into two functions; this is to import repositories in order"""
    http_archive(
        name = "pybind11",
        build_file = "@pybind11_bazel//:pybind11-BUILD.bazel",
        strip_prefix = "pybind11-3.0.1",
        urls = ["https://github.com/pybind/pybind11/archive/v3.0.1.zip"],
        sha256 = "20fb420fe163d0657a262a8decb619b7c3101ea91db35f1a7227e67c426d4c7e",
    )
    define_pybind11_abseil()

    verilator_repos()

    http_archive(
        name = "rules_scala",
        sha256 = "f526a27aab750f8ece83e2003c792cbfd1e76106b5bc175e2664a76781de55c5",
        strip_prefix = "rules_scala-7.2.6",
        url = "https://github.com/bazelbuild/rules_scala/releases/download/v7.2.6/rules_scala-v7.2.6.tar.gz",
    )

    http_archive(
        name = "rules_foreign_cc",
        sha256 = "2a4d07cd64b0719b39a7c12218a3e507672b82a97b98c6a89d38565894cf7c51",
        strip_prefix = "rules_foreign_cc-0.9.0",
        url = "https://github.com/bazelbuild/rules_foreign_cc/archive/refs/tags/0.9.0.tar.gz",
    )

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
        ],
        patch_args = ["-p1"],
    )

def fpga_repos():
    define_fpga_repos()

def tflite_repos():
    http_archive(
        name = "tflite_micro",
        url = "https://github.com/tensorflow/tflite-micro/archive/b75c6ff4e2270047f2b48fa01f833c8101c31f43.zip",
        sha256 = "ac3e675b71c55529a32d19a8cf0912413c1d1b9a551512e2665883a1666fb0ba",
        strip_prefix = "tflite-micro-b75c6ff4e2270047f2b48fa01f833c8101c31f43",
        patches = [
            "@coralnpu_hw//third_party/tflite-micro:Tflite-Micro-CoralNPU-integration.patch",
            "@coralnpu_hw//third_party/tflite-micro:0001-Remove-xtensa-and-hifi-kernels.patch",
        ],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "hedron_compile_commands",
        sha256 = "bacabfe758676fdc19e4bea7c4a3ac99c7e7378d259a9f1054d341c6a6b44ff6",
        strip_prefix = "bazel-compile-commands-extractor-1266d6a25314d165ca78d0061d3399e909b7920e",
        url = "https://github.com/hedronvision/bazel-compile-commands-extractor/archive/1266d6a25314d165ca78d0061d3399e909b7920e.tar.gz",
    )

def mpact_repos():
    define_mpact_repos()
