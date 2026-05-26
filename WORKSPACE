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

workspace(name = "coralnpu_hw")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

load(
    "//rules:repos.bzl",
    "cvfpu_repos",
    "fpga_repos",
    "coralnpu_repos",
    "coralnpu_repos2",
    "rvvi_repos",
    "tflite_repos",
    "mpact_repos",
)
load("//rules:host_cpus.bzl", "host_cpus")

host_cpus(name = "coralnpu_host_cpus")

http_archive(
    name = "rules_cc",
    sha256 = "69ceb454b9b29e0aba7da81c72e96ecafd81d2044be883b46398b1c77ca7fff9",
    strip_prefix = "rules_cc-0.2.9",
    url = "https://github.com/bazelbuild/rules_cc/releases/download/0.2.9/rules_cc-0.2.9.tar.gz",
)

load("@rules_cc//cc:repositories.bzl", "rules_cc_dependencies", "rules_cc_toolchains")

rules_cc_dependencies()

register_toolchains(
    "//toolchain/host_clang:host_clang_toolchain_def",
)

rules_cc_toolchains()

coralnpu_repos()

load("@com_google_protobuf//:protobuf_deps.bzl", "protobuf_deps")

protobuf_deps()

load("@rules_pkg//:deps.bzl", "rules_pkg_dependencies")
rules_pkg_dependencies()

load("@rules_python//python:repositories.bzl", "py_repositories")

py_repositories()

load("@rules_python//python:repositories.bzl", "python_register_toolchains")

python_register_toolchains(
    name = "python311",
    python_version = "3.11.6",
)
load("@pybind11_bazel//:python_configure.bzl", "python_configure")
python_configure(
    name = "local_config_python",
    python_version = "3",
    python_interpreter_target = "@python311_x86_64-unknown-linux-gnu//:python",
)
coralnpu_repos2()

# Scala setup
load("@io_bazel_rules_scala//:scala_config.bzl", "scala_config")

scala_config(scala_version = "2.13.12")

load("@io_bazel_rules_scala//scala:scala.bzl", "rules_scala_setup", "rules_scala_toolchain_deps_repositories")

rules_scala_setup()

rules_scala_toolchain_deps_repositories(fetch_sources = True)

load("@io_bazel_rules_scala//scala:toolchains.bzl", "scala_register_toolchains")

scala_register_toolchains()

load("@io_bazel_rules_scala//testing:scalatest.bzl", "scalatest_repositories", "scalatest_toolchain")

scalatest_repositories()

scalatest_toolchain()

load("@rules_proto//proto:repositories.bzl", "rules_proto_dependencies", "rules_proto_toolchains")

rules_proto_dependencies()

rules_proto_toolchains()

load("//rules:deps.bzl", "coralnpu_deps")

coralnpu_deps()

cvfpu_repos()

rvvi_repos()

fpga_repos()

load("@lowrisc_opentitan_gh//rules:nonhermetic.bzl", "nonhermetic_repo")

nonhermetic_repo(name = "nonhermetic")

load("@rules_python//python:pip.bzl", "pip_parse")

pip_parse(
    name = "ot_python_deps",
    python_interpreter_target = "@python311_x86_64-unknown-linux-gnu//:python",
    requirements_lock = "@lowrisc_opentitan_gh//:python-requirements.txt",
)

load("//third_party/python:requirements.bzl", "install_deps")

install_deps()

# OpenTitan's requirements need this, but for some reason do not provide it.
http_archive(
    name = "ot_python_deps_importlib_metadata",
    build_file_content = """
package(default_visibility = ["//visibility:public"])
py_library(
    name = "pkg",
    srcs = glob(["**/*.py"]),
    data = [] + glob(["**/*"], exclude=["**/* *", "**/*.dist-info/RECORD", "**/*.py", "**/*.pyc"]),
    imports = ["."],
    tags = ["pypi_name=importlib_metadata","pypi_version=8.7.0"],
)
""",
    sha256 = "e5dd1551894c77868a30651cef00984d50e1002d06942a7101d34870c5f02afd",
    type = "zip",
    urls = [
        "https://files.pythonhosted.org/packages/20/b0/36bd937216ec521246249be3bf9855081de4c5e06a0c9b4219dbeda50373/importlib_metadata-8.7.0-py3-none-any.whl",
    ],
)

load("@ot_python_deps//:requirements.bzl", ot_install_deps = "install_deps")

ot_install_deps()

http_archive(
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
    sha256 = "c9c85f8361e9d02d64474c51e3b3730ba09807cf4610d6d002c49a270458b49c",
    strip_prefix = "toolchain_kelvin_v2",
    urls = [
        "https://storage.googleapis.com/shodan-public-artifacts/toolchain_kelvin_tar_files/toolchain_kelvin_v2-2025-09-11.tar.gz",
    ],
)

register_toolchains(
    "//toolchain:cc_coralnpu_v2_toolchain",
    "//toolchain:cc_coralnpu_v2_semihosting_toolchain",
)

tflite_repos()

load("@tflite_micro//tensorflow:workspace.bzl", tf_micro_workspace = "workspace")

tf_micro_workspace()

pip_parse(
    name = "tflm_pip_deps",
    python_interpreter_target = "@python311_x86_64-unknown-linux-gnu//:python",
    requirements_lock = "@tflite_micro//third_party:python_requirements.txt",
)

load("@tflm_pip_deps//:requirements.bzl", "install_deps")

install_deps()

http_archive(
    name = "bazel_features",
    sha256 = "07bd2b18764cdee1e0d6ff42c9c0a6111ffcbd0c17f0de38e7f44f1519d1c0cd",
    strip_prefix = "bazel_features-1.32.0",
    url = "https://github.com/bazel-contrib/bazel_features/releases/download/v1.32.0/bazel_features-v1.32.0.tar.gz",
)

load("@bazel_features//:deps.bzl", "bazel_features_deps")

bazel_features_deps()

load("@rules_cc//cc:extensions.bzl", "compatibility_proxy_repo")

compatibility_proxy_repo()

mpact_repos()

load("@com_google_mpact-riscv//:repos.bzl", "mpact_riscv_repos")
mpact_riscv_repos()

load("@com_google_mpact-riscv//:dep_repos.bzl", "mpact_riscv_dep_repos")
mpact_riscv_dep_repos()

load("@com_google_mpact-riscv//:deps.bzl", "mpact_riscv_deps")
mpact_riscv_deps()

load("@coralnpu_hw//rules:check_folder.bzl", "check_folder")

check_folder(
    name = "internal_check",
    directory = "internal",
    root_file = "//:BUILD.bazel",
)
local_repository(
    name = "synthesis_internal",
    path = "../synthesis_internal",
)

# riscv-vector-tests for RVV compliance testing
new_local_repository(
    name = "riscv_vector_tests",
    path = "/Users/ust/riscv-vector-tests",
    build_file_content = """
package(default_visibility = ["//visibility:public"])
filegroup(name = "all_configs", srcs = glob(["configs/**/*.toml"]))
filegroup(name = "all_headers", srcs = glob(["env/**/*.h", "macros/**/*.h"]))
exports_files(glob(["**"]))
""",
)
