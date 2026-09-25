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

"""Repository definitions for non-BCR external dependencies managed via Bzlmod."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("//rules:check_folder.bzl", "check_folder")
load("//rules:nonhermetic.bzl", "nonhermetic_repo")
load("//third_party/patches:patches.bzl", "MPACT_RISCV_PATCHES")

def define_coralnpu_toolchain():
    """Defines the prebuilt CoralNPU V2 GCC cross compiler toolchain."""
    maybe(
        http_archive,
        name = "toolchain_coralnpu_v2",
        build_file_content = """
licenses(["notice"])
exports_files(glob(["**"]))
package(default_visibility = ["//visibility:public"])
filegroup(
    name = "all_files",
    srcs = glob(["**"]),
)
""",
        sha256 = "de06690c2da5cd783d76b2998208bd4db4dcdc22dec146c7b0a5ee1af40d3db7",
        strip_prefix = "toolchain_coralnpu_v2",
        urls = [
            "https://storage.googleapis.com/shodan-public-artifacts/toolchain_coralnpu_v2-2026-06-29.tar.xz",
        ],
    )

def define_pybind11_abseil():
    """Defines pybind11_abseil repository."""
    maybe(
        http_archive,
        name = "pybind11_abseil",
        strip_prefix = "pybind11_abseil-54b34dd0e8afb8a4febb9508c69410e708b43515",
        urls = ["https://github.com/pybind/pybind11_abseil/archive/54b34dd0e8afb8a4febb9508c69410e708b43515.tar.gz"],
        sha256 = "26328a74f367208ae8d490dc640030111df4ba0869619c6445bb4a1c5964e2a7",
    )

def _svdpi_repo_impl(rctx):
    rctx.download(
        url = "https://raw.githubusercontent.com/verilator/verilator/v5.028/include/vltstd/svdpi.h",
        output = "include/svdpi.h",
        sha256 = "2528c8e529b66dd8e795c8a0fee326166cc51f7dee8fc6a0c6c930534fc780a6",
    )
    rctx.symlink("include/svdpi.h", "file/svdpi.h")
    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

cc_library(
    name = "svdpi",
    hdrs = ["include/svdpi.h"],
    includes = ["include"],
)

filegroup(
    name = "file",
    srcs = ["file/svdpi.h"],
)
""")

svdpi_repo = repository_rule(
    implementation = _svdpi_repo_impl,
)

def define_mpact_repos():
    """Defines MPACT and CoralNPU-MPACT dependencies."""
    maybe(
        http_archive,
        name = "rules_license",
        sha256 = "26d4021f6898e23b82ef953078389dd49ac2b5618ac564ade4ef87cced147b38",
        urls = ["https://github.com/bazelbuild/rules_license/releases/download/1.0.0/rules_license-1.0.0.tar.gz"],
    )

    maybe(
        http_archive,
        name = "com_google_mpact-riscv",
        sha256 = "38faef26745f34a82de0daf3b65a207c8d2ecf825f37484a4a27132512583574",
        strip_prefix = "mpact-riscv-cb68bd4a2cb80dea24d9760dc6397b5854ea41bd",
        url = "https://github.com/google/mpact-riscv/archive/cb68bd4a2cb80dea24d9760dc6397b5854ea41bd.tar.gz",
        patches = MPACT_RISCV_PATCHES,
        patch_args = ["-p1"],
    )

    maybe(
        http_archive,
        name = "coralnpu_mpact",
        urls = ["https://github.com/google-coral/coralnpu-mpact/archive/e2a26e6d983f13d4c10875e4e5878a6171c04a06.zip"],
        sha256 = "426328af9681929b262147538e61c7b6545bebf70e4db2d483c94d9613ac5909",
        strip_prefix = "coralnpu-mpact-e2a26e6d983f13d4c10875e4e5878a6171c04a06",
        workspace_file = "@coralnpu_hw//third_party/coralnpu_mpact:WORKSPACE",
        patches = [
            "@coralnpu_hw//third_party/coralnpu_mpact:0002-Patch-mpact_riscv-WORKSPACE.patch",
            "@coralnpu_hw//third_party/coralnpu_mpact:0003-Hardwire-mtvec-direct-mode.patch",
            "@coralnpu_hw//third_party/coralnpu_mpact:0004-Fix-mpact-riscv-includes.patch",
            "@coralnpu_hw//third_party/coralnpu_mpact:0005-coralnpu-mepc-mask.patch",
            "@coralnpu_hw//third_party/coralnpu_mpact:0006-Fix-svdpi-includes.patch",
        ],
        patch_args = ["-p1"],
    )

    maybe(
        http_archive,
        name = "com_google_mpact-sim",
        sha256 = "e4115bbe5c5039d442378da745fc7401c79f9e52df590191d872354c7a999c58",
        strip_prefix = "mpact-sim-4a9e8505f3a02719b076fdee5a838217d770ad89",
        url = "https://github.com/google/mpact-sim/archive/4a9e8505f3a02719b076fdee5a838217d770ad89.tar.gz",
    )

    maybe(
        http_archive,
        name = "com_github_serge1_elfio",
        build_file = "@com_google_mpact-sim//:external/BUILD.elfio",
        sha256 = "caf49f3bf55a9c99c98ebea4b05c79281875783802e892729eea0415505f68c4",
        strip_prefix = "elfio-3.12",
        urls = ["https://github.com/serge1/ELFIO/releases/download/Release_3.12/elfio-3.12.tar.gz"],
    )

    maybe(
        http_file,
        name = "org_antlr_tool",
        sha256 = "bc13a9c57a8dd7d5196888211e5ede657cb64a3ce968608697e4f668251a8487",
        urls = ["https://www.antlr.org/download/antlr-4.13.1-complete.jar"],
        downloaded_file_path = "antlr-4.13.1-complete.jar",
    )

    maybe(
        http_archive,
        name = "org_antlr4_cpp_runtime",
        add_prefix = "antlr4-runtime",
        build_file = "@com_google_mpact-sim//:external/BUILD.antlr4",
        sha256 = "d350e09917a633b738c68e1d6dc7d7710e91f4d6543e154a78bb964cfd8eb4de",
        strip_prefix = "runtime/src",
        urls = ["https://www.antlr.org/download/antlr4-cpp-runtime-4.13.1-source.zip"],
    )

    maybe(
        http_file,
        name = "cc_static_library_external",
        downloaded_file_path = "cc_static_libarary.bzl",
        sha256 = "1287ce9f7e5fe31ad1b5937781531e4ab3f4656edabf650cca9ca720ceb31806",
        urls = ["https://raw.githubusercontent.com/project-oak/oak/fcceea755f0274d3a0eb7c0461b30af3dc28e40a/cc/build_defs.bzl"],
    )

    maybe(
        svdpi_repo,
        name = "svdpi_h_file",
    )

def _tflm_pip_deps_compat_impl(rctx):
    rctx.file("WORKSPACE", "workspace(name = 'tflm_pip_deps')\n")
    rctx.file("BUILD.bazel", "package(default_visibility = ['//visibility:public'])\n")
    rctx.file("requirements.bzl", """
def requirement(name):
    clean_name = name.replace("-", "_").replace(".", "_").lower()
    return "@coralnpu_pip_deps_" + clean_name + "//:pkg"

all_requirements = []
""")

tflm_pip_deps_compat = repository_rule(
    implementation = _tflm_pip_deps_compat_impl,
)

def _ot_python_deps_compat_impl(rctx):
    rctx.file("WORKSPACE", "workspace(name = 'ot_python_deps')\n")
    rctx.file("BUILD.bazel", "package(default_visibility = ['//visibility:public'])\n")
    rctx.file("requirements.bzl", """
def requirement(name):
    clean_name = name.replace("-", "_").replace(".", "_").lower()
    return "@coralnpu_pip_deps_" + clean_name + "//:pkg"

all_requirements = [
    requirement("argcomplete"),
    requirement("attrs"),
    requirement("edalize"),
    requirement("fastjsonschema"),
    requirement("fusesoc"),
    requirement("hjson"),
    requirement("jinja2"),
    requirement("mako"),
    requirement("markupsafe"),
    requirement("okonomiyaki"),
    requirement("packaging"),
    requirement("pyelftools"),
    requirement("pyparsing"),
    requirement("pyyaml"),
    requirement("simplesat"),
]
""")

ot_python_deps_compat = repository_rule(
    implementation = _ot_python_deps_compat_impl,
)

def _python311_compat_impl(rctx):
    rctx.file("WORKSPACE", "workspace(name = 'python311_x86_64-unknown-linux-gnu')\n")
    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])
alias(
    name = "python",
    actual = "@@rules_python++python+python_3_11_6_x86_64-unknown-linux-gnu//:python",
)
alias(
    name = "files",
    actual = "@@rules_python++python+python_3_11_6_x86_64-unknown-linux-gnu//:files",
)
""")

python311_compat = repository_rule(
    implementation = _python311_compat_impl,
)

def _flatbuffers_repo_impl(rctx):
    rctx.download_and_extract(
        url = ["https://github.com/google/flatbuffers/archive/v23.5.26.tar.gz"],
        sha256 = "1cce06b17cddd896b6d73cc047e36a254fb8df4d7ea18a46acf16c4c0cd3f3f3",
        stripPrefix = "flatbuffers-23.5.26",
    )
    rctx.delete("BUILD.bazel")
    rctx.delete("BUILD")
    rctx.symlink(
        Label("@tflite_micro//third_party/flatbuffers:BUILD.oss"),
        "BUILD.bazel",
    )
    rctx.delete("build_defs.bzl")
    rctx.symlink(
        Label("@tflite_micro//third_party/flatbuffers:build_defs.bzl"),
        "build_defs.bzl",
    )

flatbuffers_repo = repository_rule(
    implementation = _flatbuffers_repo_impl,
)

def define_tflite_repos():
    """Defines TensorFlow Lite Micro and its dependencies."""
    maybe(
        tflm_pip_deps_compat,
        name = "tflm_pip_deps",
    )

    maybe(
        http_archive,
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

    maybe(
        http_archive,
        name = "hedron_compile_commands",
        sha256 = "bacabfe758676fdc19e4bea7c4a3ac99c7e7378d259a9f1054d341c6a6b44ff6",
        strip_prefix = "bazel-compile-commands-extractor-1266d6a25314d165ca78d0061d3399e909b7920e",
        url = "https://github.com/hedronvision/bazel-compile-commands-extractor/archive/1266d6a25314d165ca78d0061d3399e909b7920e.tar.gz",
    )

    maybe(
        flatbuffers_repo,
        name = "flatbuffers",
    )

    maybe(
        http_archive,
        name = "gemmlowp",
        sha256 = "43146e6f56cb5218a8caaab6b5d1601a083f1f31c06ff474a4378a7d35be9cfb",
        strip_prefix = "gemmlowp-fda83bdc38b118cc6b56753bd540caa49e570745",
        urls = [
            "https://storage.googleapis.com/mirror.tensorflow.org/github.com/google/gemmlowp/archive/fda83bdc38b118cc6b56753bd540caa49e570745.zip",
            "https://github.com/google/gemmlowp/archive/fda83bdc38b118cc6b56753bd540caa49e570745.zip",
        ],
        patches = ["@tflite_micro//third_party/gemmlowp:remove-pthreads-as-default.patch"],
        patch_args = ["-p1"],
    )

    maybe(
        http_archive,
        name = "ruy",
        sha256 = "da5ec0cc07472bdb21589b0b51c8f3d7f75d2ed6230b794912adf213838d289a",
        strip_prefix = "ruy-54774a7a2cf85963777289193629d4bd42de4a59",
        urls = [
            "https://storage.googleapis.com/mirror.tensorflow.org/github.com/google/ruy/archive/54774a7a2cf85963777289193629d4bd42de4a59.zip",
            "https://github.com/google/ruy/archive/54774a7a2cf85963777289193629d4bd42de4a59.zip",
        ],
        build_file = "@tflite_micro//third_party/ruy:BUILD",
        patches = ["@tflite_micro//third_party/ruy:remove-pthreads-as-default.patch"],
        patch_args = ["-p1"],
    )

    maybe(
        http_archive,
        name = "kissfft",
        strip_prefix = "kissfft-130",
        sha256 = "ac2259f84e372a582270ed7c7b709d02e6ca9c7206e40bb58de6ef77f6474872",
        urls = [
            "https://github.com/mborgerding/kissfft/archive/refs/tags/v130.zip",
        ],
        build_file = "@tflite_micro//third_party/kissfft:BUILD.bazel",
        patches = ["@tflite_micro//third_party/kissfft:kissfft.patch"],
        patch_args = ["-p1"],
    )

def define_fpga_repos():
    """Defines OpenTitan and FPGA IP repositories."""
    maybe(
        http_archive,
        name = "lowrisc_opentitan_gh",
        urls = ["https://github.com/lowRISC/opentitan/archive/0e3cf62211004443d6d29f8f6120882376da499a.zip"],
        sha256 = "5de3d4ba7a2d02ea58f189f0d9bc46051368dc138a7f8c0fb89af78dcd43a0f8",
        strip_prefix = "opentitan-0e3cf62211004443d6d29f8f6120882376da499a",
        patches = [
            "@coralnpu_hw//fpga:0001-Export-hw-ip_templates.patch",
            "@coralnpu_hw//fpga:0002-Use-hermetic-verilator-in-fusesoc-build.patch",
            "@coralnpu_hw//fpga:0003-Support-vivado-elab-in-fusesoc-build.patch",
        ],
        patch_args = ["-p1"],
    )

    maybe(
        http_archive,
        name = "ispyocto",
        urls = ["https://opensecura.googlesource.com/3p/ip/isp/+archive/d53dc0e0ce2605cea2e3b3fc5b97e9dd40f8d55a.tar.gz"],
        build_file = "@coralnpu_hw//fpga/ip/ispyocto:ispyocto.BUILD",
        sha256 = "",
        patch_cmds = [
            "rm -f ispyocto/BUILD axi2sramcrs/BUILD ispyocto/rtl/ispyocto_filelist.txt",
        ],
    )

    maybe(
        nonhermetic_repo,
        name = "nonhermetic",
    )

def define_internal_check(root_file = "@coralnpu_hw//:BUILD.bazel"):
    """Defines internal_check repository based on local internal folder."""
    maybe(
        check_folder,
        name = "internal_check",
        directory = "internal",
        root_file = root_file,
    )

def _synthesis_internal_repository_impl(rctx):
    path = rctx.path(rctx.attr.path)
    if path.exists and len(path.readdir()) > 0:
        for entry in path.readdir():
            rctx.symlink(entry, entry.basename)

    # ALWAYS ensure dummy packages exist so Bazel loading phase never crashes on missing BUILD files.
    if not path.get_child("libs").exists or not path.get_child("libs").get_child("gf12lpp").exists or not path.get_child("libs").get_child("gf12lpp").get_child("BUILD").exists:
        rctx.file("BUILD.bazel", "exports_files(glob(['**']))\n")
        rctx.file("libs/BUILD.bazel", "exports_files(glob(['**']))\n")
        rctx.file("libs/gf12lpp/BUILD.bazel", "exports_files(glob(['**']))\n")
        rctx.file("libs/gf22/BUILD.bazel", "exports_files(glob(['**']))\n")
        rctx.file("libs/tsmc12ffc/BUILD.bazel", "exports_files(glob(['**']))\n")

synthesis_internal_repository = repository_rule(
    implementation = _synthesis_internal_repository_impl,
    local = True,
    attrs = {
        "path": attr.string(default = "/edacloud/nfs/cerebrahw/cerebrahw-libs-west4"),
    },
)

def define_synthesis_internal():
    """Defines synthesis_internal repository with dummy fallback packages."""
    maybe(
        synthesis_internal_repository,
        name = "synthesis_internal",
        path = "/edacloud/nfs/cerebrahw/cerebrahw-libs-west4",
    )

def define_sim_repos():
    """Defines simulation, hardware modeling, and shared third-party dependencies."""
    maybe(
        http_archive,
        name = "uvm",
        urls = ["https://github.com/chipsalliance/uvm-verilator/archive/refs/tags/uvm-2020-3.2.tar.gz"],
        sha256 = "9647bfe69439340f1f5c8c969b9814aed06cde9fe4c355111bd5e7cd325c0e0f",
        strip_prefix = "uvm-verilator-uvm-2020-3.2",
        build_file = "@coralnpu_hw//third_party/verilator:uvm.BUILD",
        patch_args = ["-p1"],
        patches = [
            "@coralnpu_hw//third_party/verilator:0002-uvm-optional-reg-tlm2.patch",
        ],
    )

    maybe(
        http_archive,
        name = "freertos",
        urls = ["https://github.com/FreeRTOS/FreeRTOS-Kernel/archive/refs/tags/V11.1.0.tar.gz"],
        sha256 = "0e21928b3bcc4f9bcaf7333fb1c8c0299d97e2ec9e13e3faa2c5a7ac8a3bc573",
        strip_prefix = "FreeRTOS-Kernel-11.1.0",
        build_file = "@coralnpu_hw//third_party/freertos:freertos.BUILD",
    )

    maybe(
        http_archive,
        name = "llvm_firtool",
        urls = ["https://repo1.maven.org/maven2/org/chipsalliance/llvm-firtool/1.114.0/llvm-firtool-1.114.0.jar"],
        build_file = "@coralnpu_hw//third_party/llvm-firtool:BUILD.bazel",
        sha256 = "f93a831e6b5696df2e3327626df3cc183e223bf0c9c0fddf9ae9e51f502d0492",
    )

    maybe(
        http_archive,
        name = "libsystemctlm_soc",
        urls = [
            "https://github.com/Xilinx/libsystemctlm-soc/archive/79d624f3c7300a2ead97ca35e683c38f0b6f5021.zip",
        ],
        strip_prefix = "libsystemctlm-soc-79d624f3c7300a2ead97ca35e683c38f0b6f5021",
        sha256 = "5c9d08bd33eb6738e3b4a0dda81e24a6d30067e8149bada6ae05aedcab5b786c",
        build_file = "@coralnpu_hw//third_party/libsystemctlm-soc:BUILD.bazel",
    )

    maybe(
        http_archive,
        name = "chipsalliance_rocket_chip",
        build_file = "@coralnpu_hw//third_party/rocket_chip:BUILD.bazel",
        urls = ["https://github.com/chipsalliance/rocket-chip/archive/f517abbf41abb65cea37421d3559f9739efd00a9.zip"],
        sha256 = "e77bb13328e919ca43ba83a1c110b5314900841125b9ff22813a4b9fe73672a2",
        strip_prefix = "rocket-chip-f517abbf41abb65cea37421d3559f9739efd00a9",
    )

    maybe(
        http_archive,
        name = "chipsalliance_diplomacy",
        urls = ["https://github.com/chipsalliance/diplomacy/archive/6590276fa4dac315ae7c7c01371b954c5687a473.zip"],
        sha256 = "3f536b2eba360eb71a542d2a201eabe3a45cfa86302f14d1d565def0ed43ee20",
        strip_prefix = "diplomacy-6590276fa4dac315ae7c7c01371b954c5687a473",
        build_file_content = """
exports_files(["diplomacy/src/diplomacy/nodes/HeterogeneousBag.scala"])
        """,
    )

    maybe(
        http_archive,
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

    maybe(
        http_archive,
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

    maybe(
        http_archive,
        name = "accellera_systemc",
        build_file = "@coralnpu_hw//third_party/systemc:systemc.BUILD",
        sha256 = "bfb309485a8ad35a08ee78827d1647a451ec5455767b25136e74522a6f41e0ea",
        strip_prefix = "systemc-2.3.4",
        urls = [
            "https://github.com/accellera-official/systemc/archive/refs/tags/2.3.4.tar.gz",
        ],
    )

    maybe(
        http_archive,
        name = "riscv_isa_sim",
        build_file = "@coralnpu_hw//third_party:spike.BUILD",
        sha256 = "064f4c1f22005899fa5106b822bfdc7034ffc9babc2f5821771589047f028a66",
        strip_prefix = "riscv-isa-sim-93a10ae685ac85bd3d8a62054f8f180a4f76fc82",
        patches = [
            "@coralnpu_hw//third_party/spike:0001-Add-mpause.patch",
            "@coralnpu_hw//third_party/spike:0002-Coral-Deviations.patch",
            "@coralnpu_hw//third_party/spike:0003-Dump-GPRs-on-EBREAK.patch",
            "@coralnpu_hw//third_party/spike:0004-Add-custom-CoralNPU-CSRs-and-update-MVENDORID-MARCHI.patch",
            "@coralnpu_hw//third_party/spike:0005-Force-logging-in-vcompress.patch",
            "@coralnpu_hw//third_party/spike:0006-Hardwire-misa-as-read-only-WARL.patch",
            "@coralnpu_hw//third_party/spike:0007-Rename-yield-macro-avoid-boost-std-conflict.patch",
            "@coralnpu_hw//third_party/spike:0008-Link-libstdc-explicitly-in-LIBS.patch",
        ],
        patch_args = ["-p1"],
        urls = [
            "https://github.com/riscv-software-src/riscv-isa-sim/archive/93a10ae685ac85bd3d8a62054f8f180a4f76fc82.tar.gz",
        ],
    )
