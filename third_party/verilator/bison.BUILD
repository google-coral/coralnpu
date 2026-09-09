# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

""" bison """

load("@coralnpu_hw//third_party/verilator:copy.bzl", "copy", "touch")
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")

package(default_visibility = ["//visibility:private"])

licenses(["restricted"])

exports_files(["LICENSE"])

PKG_DATA_DIR = "./data"

LOCALE_DIR = "/dev/null"

# In order to use bison properly in a shell command, set the env variable
# BISON_PKGDATADIR=[workspace dir]/bison/data in any shell command you invoke
# bison in.  If you use the genyacc rule, Bazel should do this for for you.
# You will also need to set M4 to the location of m4, which is
# generally $(location @org_gnu_m4//:m4) in a Bazel genrule.

filegroup(
    name = "bison_runtime_data",
    srcs = glob(["data/**/*"]),
    output_licenses = ["unencumbered"],
    visibility = ["//visibility:public"],
)

alias(
    name = "data",
    actual = ":bison_runtime_data",
    visibility = ["//visibility:public"],
)

cc_library(
    name = "bison_src_headers",
    textual_hdrs = glob(["src/*.h"]) + [
        "src/scan-skel.c",
        "src/scan-gram.c",
        "src/scan-code.c",
    ],
)

# Bison ONLY (non-GNUlib) stuff
copy(
    name = "get-errno_c",
    src = "lib/get-errno.c",
    out = "bison-lib/get-errno.c",
)

copy(
    name = "get-errno_h",
    src = "lib/get-errno.h",
    out = "bison-lib/get-errno.h",
)

copy(
    name = "path-join_c",
    src = "lib/path-join.c",
    out = "bison-lib/path-join.c",
)

copy(
    name = "path-join_h",
    src = "lib/path-join.h",
    out = "bison-lib/path-join.h",
)

touch(
    name = "configmake_h",
    out = "bison-lib/configmake.h",
    contents = dict(
        LIBDIR = '"/usr/local/lib"',
    ),
)

touch(
    name = "bazel_version_info",
    out = "bison-lib/bazel_version_info.h",
    contents = dict(
        PACKAGE_VERSION = '"3.5"',
        VERSION = '"3.5"',
    ),
)

# Note: This target is used by the Bazel "genyacc" rule, as well as by the
# explictly-declared dependencies.
cc_binary(
    name = "bison",
    srcs = [
        "bison-lib/bazel_version_info.h",
        "bison-lib/configmake.h",
        "bison-lib/get-errno.c",
        "bison-lib/get-errno.h",
        "bison-lib/path-join.c",
        "bison-lib/path-join.h",
        "src/AnnotationList.c",
        "src/InadequacyList.c",
        "src/Sbitset.c",
        "src/assoc.c",
        "src/closure.c",
        "src/complain.c",
        "src/conflicts.c",
        "src/derives.c",
        "src/files.c",
        "src/fixits.c",
        "src/getargs.c",
        "src/gram.c",
        "src/graphviz.c",
        "src/ielr.c",
        "src/lalr.c",
        "src/location.c",
        "src/lr0.c",
        "src/main.c",
        "src/muscle-tab.c",
        "src/named-ref.c",
        "src/nullable.c",
        "src/output.c",
        "src/parse-gram.c",
        "src/print.c",
        "src/print-graph.c",
        "src/print-xml.c",
        "src/reader.c",
        "src/reduce.c",
        "src/relation.c",
        "src/scan-code-c.c",
        "src/scan-gram-c.c",
        "src/scan-skel-c.c",
        "src/state.c",
        "src/symlist.c",
        "src/symtab.c",
        "src/tables.c",
        "src/uniqstr.c",
    ],
    copts = [
        "-Wno-vla",
        "-DHAVE_CONFIG_H",
        "-DPKGDATADIR='\"" + PKG_DATA_DIR + "\"'",
        "-DLOCALEDIR='\"" + LOCALE_DIR + "\"'",
        "-DM4='\"m4\"'",
        "-DM4_GNU_OPTION='\"--gnu\"'",
        # This is defined in gnulib's stdio.h, but we don't need anything else
        # from that file.
        "-D_GL_ATTRIBUTE_FORMAT_PRINTF(A,B)=",
        "-DBAZEL_VERSION_INFO",
    ],
    data = [":bison_runtime_data"],
    includes = [
        ".",
        "bison-lib",
        "lib",
    ],
    output_licenses = ["unencumbered"],
    visibility = ["//visibility:public"],
    deps = [
        ":bison_src_headers",
        "@org_gnu_gnulib//:gnulib",
    ],
)
