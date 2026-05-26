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
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def coralnpu_repos():
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
        urls = ["https://github.com/abseil/abseil-cpp/releases/download/20250127.1/abseil-cpp-20250127.1.tar.gz"],
        sha256 = "b396401fd29e2e679cace77867481d388c807671dc2acc602a0259eeb79b7811",
        strip_prefix = "abseil-cpp-20250127.1",
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
            "https://github.com/bazelbuild/rules_java/releases/download/7.12.5/rules_java-7.12.5.tar.gz",
        ],
        sha256 = "17b18cb4f92ab7b94aa343ce78531b73960b1bed2ba166e5b02c9fdf0b0ac270",
    )

    http_archive(
        name = "com_google_protobuf",
        strip_prefix = "protobuf-29.6",
        sha256 = "877bf9f880631aa31daf2c09896276985696728137fcd43cc534a28c5566d9ba",
        url = "https://github.com/protocolbuffers/protobuf/releases/download/v29.6/protobuf-29.6.tar.gz",
    )

    http_archive(
        name = "rules_pkg",
        urls = [
            "https://mirror.bazel.build/github.com/bazelbuild/rules_pkg/releases/download/1.2.0/rules_pkg-1.2.0.tar.gz",
            "https://github.com/bazelbuild/rules_pkg/releases/download/1.2.0/rules_pkg-1.2.0.tar.gz",
        ],
        sha256 = "b5c9184a23bb0bcff241981fd9d9e2a97638a1374c9953bb1808836ce711f990",
    )

    http_archive(
        name = "rules_proto",
        urls = ["https://github.com/bazelbuild/rules_proto/archive/f7a30f6f80006b591fa7c437fe5a951eb10bcbcf.zip"],
        sha256 = "a4382f78723af788f0bc19fd4c8411f44ffe0a72723670a34692ffad56ada3ac",
        strip_prefix = "rules_proto-f7a30f6f80006b591fa7c437fe5a951eb10bcbcf",
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
        urls = ["https://github.com/pybind/pybind11_bazel/releases/download/v2.11.1/pybind11_bazel-2.11.1.tar.gz"],
        strip_prefix = "pybind11_bazel-2.11.1",
        sha256 = "e8355ee56c2ff772334b4bfa22be17c709e5573f6d1d561c7176312156c27bd4",
    )

    http_archive(
        name = "freertos",
        urls = ["https://github.com/FreeRTOS/FreeRTOS-Kernel/archive/refs/tags/V11.1.0.tar.gz"],
        sha256 = "0e21928b3bcc4f9bcaf7333fb1c8c0299d97e2ec9e13e3faa2c5a7ac8a3bc573",
        strip_prefix = "FreeRTOS-Kernel-11.1.0",
        build_file = "@coralnpu_hw//third_party/freertos:freertos.BUILD",
    )

def coralnpu_repos2():
    """Coralnpu repos are split into two functions; this is to import repositories in order"""

    http_archive(
        name = "pybind11",
        build_file = "@pybind11_bazel//:pybind11.BUILD",
        strip_prefix = "pybind11-3.0.1",
        urls = ["https://github.com/pybind/pybind11/archive/v3.0.1.zip"],
        sha256 = "20fb420fe163d0657a262a8decb619b7c3101ea91db35f1a7227e67c426d4c7e",
    )
    http_archive(
        name = "pybind11_abseil",
        strip_prefix = "pybind11_abseil-54b34dd0e8afb8a4febb9508c69410e708b43515",
        urls = ["https://github.com/pybind/pybind11_abseil/archive/54b34dd0e8afb8a4febb9508c69410e708b43515.tar.gz"],
        sha256 = "26328a74f367208ae8d490dc640030111df4ba0869619c6445bb4a1c5964e2a7",
    )
    http_archive(
        name = "rules_hdl",
        sha256 = "1b560fe7d4100486784d6f2329e82a63dd37301e185ba77d0fd69b3ecc299649",
        strip_prefix = "bazel_rules_hdl-7a1ba0e8d229200b4628e8a676917fc6b8e165d1",
        urls = [
            "https://github.com/hdl/bazel_rules_hdl/archive/7a1ba0e8d229200b4628e8a676917fc6b8e165d1.tar.gz",
        ],
        patches = [
            "@coralnpu_hw//third_party/rules_hdl:0001-Use-systemc-in-verilator-and-support-verilator-in-co.patch",
            "@coralnpu_hw//third_party/rules_hdl:0002-Update-cocotb-script-to-support-newer-version.patch",
            "@coralnpu_hw//third_party/rules_hdl:0003-Export-vdb-via-undeclared-test-outputs.patch",
            "@coralnpu_hw//third_party/rules_hdl:0004-More-jobs-for-cocotb.patch",
            "@coralnpu_hw//third_party/rules_hdl:0005-Use-num_failed-for-exit-code.patch",
            "@coralnpu_hw//third_party/rules_hdl:0006-Separate-build-from-test-for-Verilator.patch",
            "@coralnpu_hw//third_party/rules_hdl:0007-Suppress-skywater-pdk-loading.patch",
            "@coralnpu_hw//third_party/rules_hdl:0008-Use-glob-for-verilator_bin-data-files.patch",
            "@coralnpu_hw//third_party/rules_hdl:0009-Suppress-Verilator-C-warnings.patch",
            "@coralnpu_hw//third_party/rules_hdl:0010-Remove-latomic-on-macOS.patch",
        ],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "io_bazel_rules_scala",
        sha256 = "e734eef95cf26c0171566bdc24d83bd82bdaf8ca7873bec6ce9b0d524bdaf05d",
        strip_prefix = "rules_scala-6.6.0",
        url = "https://github.com/bazelbuild/rules_scala/releases/download/v6.6.0/rules_scala-v6.6.0.tar.gz",
    )

    http_archive(
        name = "rules_foreign_cc",
        sha256 = "2a4d07cd64b0719b39a7c12218a3e507672b82a97b98c6a89d38565894cf7c51",
        strip_prefix = "rules_foreign_cc-0.9.0",
        url = "https://github.com/bazelbuild/rules_foreign_cc/archive/refs/tags/0.9.0.tar.gz",
    )

    native.new_local_repository(
        name = "llvm_firtool",
        path = "tools/firtool",
        build_file = "@coralnpu_hw//third_party/llvm-firtool:BUILD.bazel",
    )

    http_archive(
        name = "libsystemctlm_soc",
        urls = [
            "https://github.com/Xilinx/libsystemctlm-soc/archive/79d624f3c7300a2ead97ca35e683c38f0b6f5021.zip",
        ],
        strip_prefix = "libsystemctlm-soc-79d624f3c7300a2ead97ca35e683c38f0b6f5021",
        sha256 = "5c9d08bd33eb6738e3b4a0dda81e24a6d30067e8149bada6ae05aedcab5b786c",
        build_file = "@coralnpu_hw//third_party/libsystemctlm-soc:BUILD.bazel",
    )

    http_archive(
        name = "chipsalliance_rocket_chip",
        build_file = "@coralnpu_hw//third_party/rocket_chip:BUILD.bazel",
        urls = ["https://github.com/chipsalliance/rocket-chip/archive/f517abbf41abb65cea37421d3559f9739efd00a9.zip"],
        sha256 = "e77bb13328e919ca43ba83a1c110b5314900841125b9ff22813a4b9fe73672a2",
        strip_prefix = "rocket-chip-f517abbf41abb65cea37421d3559f9739efd00a9",
    )

    http_archive(
        name = "chipsalliance_diplomacy",
        urls = ["https://github.com/chipsalliance/diplomacy/archive/6590276fa4dac315ae7c7c01371b954c5687a473.zip"],
        sha256 = "3f536b2eba360eb71a542d2a201eabe3a45cfa86302f14d1d565def0ed43ee20",
        strip_prefix = "diplomacy-6590276fa4dac315ae7c7c01371b954c5687a473",
        build_file_content = """
exports_files(["diplomacy/src/diplomacy/nodes/HeterogeneousBag.scala"])
        """,
    )

    http_archive(
        name = "srecord",
        urls = ["https://sourceforge.net/projects/srecord/files/srecord/1.65/srecord-1.65.0-Source.tar.gz/download"],
        type = "tar.gz",
        sha256 = "81c3d07cf15ce50441f43a82cefd0ac32767c535b5291bcc41bd2311d1337644",
        strip_prefix = "srecord-1.65.0-Source",
        build_file = "@coralnpu_hw//third_party/srecord:srecord.BUILD",
        patches = [
            "@coralnpu_hw//third_party/srecord:0001-Disable-docs-and-tests.patch",
        ],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "riscv-tests",
        urls = ["https://github.com/riscv-software-src/riscv-tests/archive/fd4e6cdd033d9075632be9dd207c848181ca474c.zip"],
        sha256 = "e7d84eaa149b57c0e5ff69a76c80f35f4ee64c5dc985dbba5c287adf8b56ec5d",
        strip_prefix = "riscv-tests-fd4e6cdd033d9075632be9dd207c848181ca474c",
        patches = [
            "@coralnpu_hw//third_party/riscv-tests:0001-Find-env-from-environment.patch",
        ],
        patch_args = ["-p1"],
        build_file_content = """
package(default_visibility = ["//visibility:public"])
exports_files(glob(["**"]))
filegroup(
    name = "all_srcs",
    srcs = glob([
        "**/*",
    ]),
)
        """,
    )

def cvfpu_repos():
    http_archive(
        name = "cvfpu",
        urls = ["https://github.com/openhwgroup/cvfpu/archive/58ca3c376beb914b2b80b811d4b270c063d4e6f7.zip"],
        sha256 = "1c31ca538f7624fe0abf082d784553ed5afe0cf209f34c26209fa2f9c4878521",
        build_file = "@coralnpu_hw//third_party/cvfpu:BUILD.bazel",
        strip_prefix = "cvfpu-58ca3c376beb914b2b80b811d4b270c063d4e6f7",
        patches = [
            "@coralnpu_hw//third_party/cvfpu:0001-Fix-max_num_lanes-issue-in-DC.patch",
            "@coralnpu_hw//third_party/cvfpu:0002-Remove-SVH-includes.patch",
            "@coralnpu_hw//third_party/cvfpu:0003-Fill-in-unreachable-state-in-fpnew_divsqrt_th_32-fsm.patch",
            "@coralnpu_hw//third_party/cvfpu:0004-Remove-ternary-operator-from-pkg-causing-dc-crash.patch",
            "@coralnpu_hw//third_party/cvfpu:0005-Fix-fsm-complete.patch",
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
    http_archive(
        name = "lowrisc_opentitan_gh",
        urls = ["https://github.com/lowRISC/opentitan/archive/0e3cf62211004443d6d29f8f6120882376da499a.zip"],
        sha256 = "5de3d4ba7a2d02ea58f189f0d9bc46051368dc138a7f8c0fb89af78dcd43a0f8",
        strip_prefix = "opentitan-0e3cf62211004443d6d29f8f6120882376da499a",
        patches = [
            "@coralnpu_hw//fpga:0001-Export-hw-ip_templates.patch",
            "@coralnpu_hw//fpga:0002-Use-hermetic-verilator-in-fusesoc-build.patch",
        ],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "ispyocto",
        urls = ["https://opensecura.googlesource.com/3p/ip/isp/+archive/d53dc0e0ce2605cea2e3b3fc5b97e9dd40f8d55a.tar.gz"],
        build_file = "@coralnpu_hw//fpga/ip/ispyocto:ispyocto.BUILD",
        sha256 = "",
        patch_cmds = [
            "rm -f ispyocto/BUILD axi2sramcrs/BUILD ispyocto/rtl/ispyocto_filelist.txt",
        ],
    )

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
    http_archive(
        name = "com_google_mpact-riscv",
        sha256 = "b88d38251c716cd8cb6e9dbdd73161074924a3d40de18873d714eef98ad5529f",
        strip_prefix = "mpact-riscv-cd69512240fb2957be2771aeb71fd994bac7b247",
        url = "https://github.com/google/mpact-riscv/archive/cd69512240fb2957be2771aeb71fd994bac7b247.tar.gz",
        patches = [
            "@coralnpu_hw//third_party:mpact-riscv-openat.patch",
        ],
        patch_args = ["-p1"],
    )

    http_archive(
        name = "coralnpu_mpact",
        urls = ["https://github.com/google-coral/coralnpu-mpact/archive/a1d219efd49a36b8744af29df23ab06dd6c021c6.zip"],
        sha256 = "23cf70ac2ca31f9c56fc140959298524d5db2f003fe4fdfe3552081048cbf934",
        strip_prefix = "coralnpu-mpact-a1d219efd49a36b8744af29df23ab06dd6c021c6",
    )
