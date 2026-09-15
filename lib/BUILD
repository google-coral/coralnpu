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

load("@rules_java//java:defs.bzl", "java_import")
load("@rules_pkg//pkg:zip.bzl", "pkg_zip")
load("@rules_scala//scala:scala.bzl", "scala_library")

scala_library(
    name = "chisel_lib",
    plugins = [
        "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
    ],
    visibility = ["//visibility:public"],
    exports = [
        "@coralnpu_maven//:com_github_scopt_scopt_2_13",
        "@coralnpu_maven//:com_lihaoyi_geny_2_13",
        "@coralnpu_maven//:com_lihaoyi_os_lib_2_13",
        "@coralnpu_maven//:com_lihaoyi_upickle_2_13",
        "@coralnpu_maven//:com_outr_moduload_2_13",
        "@coralnpu_maven//:com_outr_scribe_2_13",
        "@coralnpu_maven//:com_thoughtworks_paranamer_paranamer",
        "@coralnpu_maven//:io_github_alexarchambault_data_class_2_13",
        "@coralnpu_maven//:net_jcazevedo_moultingyaml_2_13",
        "@coralnpu_maven//:org_apache_commons_commons_lang3",
        "@coralnpu_maven//:org_apache_commons_commons_text",
        "@coralnpu_maven//:org_chipsalliance_chisel_2_13",
        "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
        "@coralnpu_maven//:org_chipsalliance_firtool_resolver_2_13",
        "@coralnpu_maven//:org_json4s_json4s_ast_2_13",
        "@coralnpu_maven//:org_json4s_json4s_core_2_13",
        "@coralnpu_maven//:org_json4s_json4s_native_2_13",
        "@coralnpu_maven//:org_json4s_json4s_scalap_2_13",
        "@coralnpu_maven//:org_scala_lang_scala_reflect",
    ],
    deps = [
        "@coralnpu_maven//:com_github_scopt_scopt_2_13",
        "@coralnpu_maven//:com_lihaoyi_geny_2_13",
        "@coralnpu_maven//:com_lihaoyi_os_lib_2_13",
        "@coralnpu_maven//:com_lihaoyi_upickle_2_13",
        "@coralnpu_maven//:com_outr_moduload_2_13",
        "@coralnpu_maven//:com_outr_scribe_2_13",
        "@coralnpu_maven//:com_thoughtworks_paranamer_paranamer",
        "@coralnpu_maven//:io_github_alexarchambault_data_class_2_13",
        "@coralnpu_maven//:net_jcazevedo_moultingyaml_2_13",
        "@coralnpu_maven//:org_apache_commons_commons_lang3",
        "@coralnpu_maven//:org_apache_commons_commons_text",
        "@coralnpu_maven//:org_chipsalliance_chisel_2_13",
        "@coralnpu_maven//:org_chipsalliance_chisel_plugin_2_13_6",
        "@coralnpu_maven//:org_chipsalliance_firtool_resolver_2_13",
        "@coralnpu_maven//:org_json4s_json4s_ast_2_13",
        "@coralnpu_maven//:org_json4s_json4s_core_2_13",
        "@coralnpu_maven//:org_json4s_json4s_native_2_13",
        "@coralnpu_maven//:org_json4s_json4s_scalap_2_13",
        "@coralnpu_maven//:org_scala_lang_scala_reflect",
    ],
)

# common_cells resources
pkg_zip(
    name = "common_cells_resources_zip",
    srcs = ["@common_cells//:common_cells_files"],
    out = "common_cells_resources.jar",
    package_dir = "external/common_cells",
)

java_import(
    name = "common_cells_resources",
    jars = [":common_cells_resources_zip"],
    visibility = ["//visibility:public"],
)

# cvfpu resources
pkg_zip(
    name = "cvfpu_resources_zip",
    srcs = ["@cvfpu//:cvfpu_files"],
    out = "cvfpu_resources.jar",
    package_dir = "external/cvfpu",
)

java_import(
    name = "cvfpu_resources",
    jars = [":cvfpu_resources_zip"],
    visibility = ["//visibility:public"],
)

# fpu_div_sqrt_mvp resources
pkg_zip(
    name = "fpu_div_sqrt_mvp_resources_zip",
    srcs = ["@fpu_div_sqrt_mvp//:fpu_div_sqrt_mvp_files"],
    out = "fpu_div_sqrt_mvp_resources.jar",
    package_dir = "external/fpu_div_sqrt_mvp",
)

java_import(
    name = "fpu_div_sqrt_mvp_resources",
    jars = [":fpu_div_sqrt_mvp_resources_zip"],
    visibility = ["//visibility:public"],
)

# RVVI resources
pkg_zip(
    name = "rvvi_resources_zip",
    srcs = ["@RVVI//:rvvi_files"],
    out = "rvvi_resources.jar",
    package_dir = "external/RVVI",
)

java_import(
    name = "rvvi_resources",
    jars = [":rvvi_resources_zip"],
    visibility = ["//visibility:public"],
)
