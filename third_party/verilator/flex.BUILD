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

""" flex

!!! DO NOT DEPEND ON THIS PACKAGE DIRECTLY !!!
This package exists only to support the genlex rule, and all users should use
that if possible rather than using the binary directly through a genrule.
"""

load("@coralnpu_hw//third_party/verilator:pseudo_configure.bzl", "pseudo_configure")
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")

package(default_visibility = ["//visibility:private"])

licenses(["notice"])  # BSD

exports_files(["LICENSE"])

VERSION = "2.6.4"

# Generate the skel.c file.  The generated file is included in the Flex
# distribution, but we have local patches that require regeneration.  This
# follows the command at line 94 of src/Makefile.am.
genrule(
    name = "skel_c",
    srcs = [
        "src/flex.skl",
        "src/mkskel.sh",
        "src/flexint.h",
        "src/tables_shared.h",
        "src/tables_shared.c",
    ],
    outs = ["src/skel.c"],
    cmd = ("$(location src/mkskel.sh) `dirname $(location src/flex.skl)` " +
           "$(location @org_gnu_m4//:m4) " + VERSION + " > $@"),
    tools = [
        "@org_gnu_m4//:m4",
    ],
)

# Generate the stage1scan.c file.  This follows the non-ENABLE_BOOTSTRAP command
# at line 102 of src/Makefile.am.
genrule(
    name = "stage1scan",
    srcs = ["src/scan.c"],
    outs = ["src/stage1scan.c"],
    cmd = """sed 's|^\\(#line .*\\)"'$$(basename $< | sed 's|[][\\\\.*]|\\\\&|g')'"|\\1"$@"|g' $< > $@""",
)

# These need to be a separate rule, as cc_binary does not support textual_hdrs,
# and many of these headers are not standalone.
cc_library(
    name = "flex_internal_headers",
    textual_hdrs = [
        "src/config.h",
        "src/flexdef.h",
        "src/flexint.h",
        "src/gettext.h",
        "src/options.h",
        "src/parse.h",
        "src/scanopt.h",
        "src/tables.h",
        "src/tables_shared.h",
        "src/version.h",
    ],
)

# Allows users to '#include <FlexLexer.h>' correctly in their own code.
cc_library(
    name = "FlexLexer",
    hdrs = ["src/FlexLexer.h"],
    includes = ["src"],
    visibility = ["//visibility:public"],
)

exports_files(
    ["src/FlexLexer.h"],
    visibility = ["//dependency_support/com_github_westes_flex/v2_5_35:__pkg__"],
)

# The "flex" binary.  This should only be used through genlex rules, not with
# genrules.
cc_binary(
    name = "flex",
    srcs = [
        "src/buf.c",
        "src/ccl.c",
        "src/dfa.c",
        "src/ecs.c",
        "src/filter.c",
        "src/gen.c",
        "src/main.c",
        "src/misc.c",
        "src/nfa.c",
        "src/options.c",
        "src/parse.c",
        "src/regex.c",
        "src/scanflags.c",
        "src/scanopt.c",
        "src/skel.c",
        "src/stage1scan.c",
        "src/sym.c",
        "src/tables.c",
        "src/tables_shared.c",
        "src/tblcmp.c",
        "src/yylex.c",
    ],
    copts = [
        "-DHAVE_CONFIG_H",
        "-DLOCALEDIR='\"" + "this_LOCALEDIR_does_not_exist" + "\"'",
        "-w",
    ],
    includes = ["src"],
    visibility = ["//visibility:public"],
    deps = [
        ":flex_internal_headers",
    ],
)

pseudo_configure(
    name = "config_h",
    src = "src/config.h.in",
    out = "src/config.h",
    defs = [
        "HAVE_ALLOCA",
        "HAVE_ALLOCA_H",
        "HAVE_DLFCN_H",
        "HAVE_DUP2",
        "HAVE_FORK",
        "HAVE_INTTYPES_H",
        "HAVE_LIBM",
        "HAVE_LIMITS_H",
        "HAVE_MALLOC",
        "HAVE_MALLOC_H",
        "HAVE_MEMORY_H",
        "HAVE_MEMSET",
        "HAVE_NETINET_IN_H",
        "HAVE_POW",
        "HAVE_PTHREAD_H",
        "HAVE_REALLOC",
        "HAVE_REGCOMP",
        "HAVE_REGEX_H",
        "HAVE_STDBOOL_H",
        "HAVE_STDINT_H",
        "HAVE_STDLIB_H",
        "HAVE_STRCASECMP",
        "HAVE_STRCHR",
        "HAVE_STRDUP",
        "HAVE_STRINGS_H",
        "HAVE_STRING_H",
        "HAVE_STRTOL",
        "HAVE_SYS_STAT_H",
        "HAVE_SYS_TYPES_H",
        "HAVE_SYS_WAIT_H",
        "HAVE_UNISTD_H",
        "HAVE_VFORK",
        "HAVE_WORKING_FORK",
        "HAVE_WORKING_VFORK",
        "HAVE__BOOL",
        "STDC_HEADERS",
    ],
    mappings = {
        "LT_OBJDIR": '".libs"',
        "M4": '"M4_environment_variable_must_be_set"',
        "PACKAGE": '"flex"',
        "PACKAGE_BUGREPORT": '"NA"',
        "PACKAGE_NAME": '"the fast lexical analyser generator"',
        "PACKAGE_STRING": '"the fast lexical analyser generator 2.6.4"',
        "PACKAGE_TARNAME": '"flex"',
        "PACKAGE_URL": '""',
        "PACKAGE_VERSION": '"2.6.4"',
        "VERSION": '"2.6.4"',
    },
)
