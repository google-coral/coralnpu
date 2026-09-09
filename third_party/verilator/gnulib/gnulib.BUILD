# SPDX-License-Identifier: Apache-2.0
# Copyright 2018 the rules_m4 authors
# Copyright 2021 the rules_hdl authors

""" gnulib """

load("@coralnpu_hw//third_party/verilator:copy.bzl", "copy")
load("@rules_cc//cc:defs.bzl", "cc_library")

licenses(["restricted"])  # GPL-2.0-or-later

exports_files(["COPYING"])

cc_library(
    name = "config_h",
    hdrs = select({
        "@bazel_tools//src/conditions:darwin": [
            "config-darwin/config.h",
        ],
        "//conditions:default": [
            "config-linux/config.h",
        ],
    }),
    includes = select({
        "@bazel_tools//src/conditions:darwin": [
            "config-darwin",
        ],
        "//conditions:default": [
            "config-linux",
        ],
    }),
    visibility = ["//:__pkg__"],
)

copy(
    name = "textstyle_h",
    src = "lib/textstyle.in.h",
    out = "lib/textstyle.h",
)

_GNULIB_HDRS = [
    "lib/textstyle.h",
] + glob([
    "lib/*.h",
    "lib/bitset/*.h",
    "lib/glthread/*.h",
])

_GNULIB_SRCS = [
    "lib/argmatch.c",
    "lib/asnprintf.c",
    "lib/basename-lgpl.c",
    "lib/bitrotate.c",
    "lib/bitset.c",
    "lib/bitsetv.c",
    "lib/c-stack.c",
    "lib/c-strcasecmp.c",
    "lib/clean-temp.c",
    "lib/cloexec.c",
    "lib/close-stream.c",
    "lib/closein.c",
    "lib/closeout.c",
    "lib/concat-filename.c",
    "lib/dup-safer.c",
    "lib/error.c",
    "lib/execute.c",
    "lib/exitfail.c",
    "lib/fatal-signal.c",
    "lib/fd-safer.c",
    "lib/filenamecat-lgpl.c",
    "lib/filenamecat.c",
    "lib/fopen-safer.c",
    "lib/fpending.c",
    "lib/freadahead.c",
    "lib/fstrcmp.c",
    "lib/gethrxtime.c",
    "lib/gettime.c",
    "lib/gl_array_list.c",
    "lib/gl_avltree_oset.c",
    "lib/gl_linkedhash_list.c",
    "lib/hash.c",
    "lib/localcharset.c",
    "lib/malloca.c",
    "lib/mbchar.c",
    "lib/mbfile.c",
    "lib/mbswidth.c",
    "lib/memchr2.c",
    "lib/mkstemp-safer.c",
    "lib/obstack.c",
    "lib/obstack_printf.c",
    "lib/pipe-safer.c",
    "lib/printf-args.c",
    "lib/printf-frexp.c",
    "lib/printf-frexpl.c",
    "lib/printf-parse.c",
    "lib/progname.c",
    "lib/quotearg.c",
    "lib/regex.c",
    "lib/spawn-pipe.c",
    "lib/strverscmp.c",
    "lib/tmpdir.c",
    "lib/vasnprintf.c",
    "lib/vasprintf.c",
    "lib/verror.c",
    "lib/version-etc-fsf.c",
    "lib/version-etc.c",
    "lib/wait-process.c",
    "lib/xalloc-die.c",
    "lib/xasprintf.c",
    "lib/xconcat-filename.c",
    "lib/xhash.c",
    "lib/xmalloc.c",
    "lib/xmalloca.c",
    "lib/xmemdup0.c",
    "lib/xprintf.c",
    "lib/xstrndup.c",
    "lib/xvasprintf.c",
] + glob([
    "lib/bitset/*.c",
    "lib/glthread/*.c",
])

_GNULIB_DARWIN_SRCS = [
    "lib/secure_getenv.c",
    "lib/isnanl.c",
]

_GNULIB_LINUX_SRCS = [
    "lib/binary-io.c",
    "lib/c-ctype.c",
    "lib/getprogname.c",
    "lib/gl_list.c",
    "lib/gl_oset.c",
    "lib/gl_xlist.c",
    "lib/gl_xoset.c",
    "lib/secure_getenv.c",
    "lib/sig-handler.c",
    "lib/xsize.c",
]

cc_library(
    name = "gnulib",
    # Include _GNULIB_HDRS in the sources list to work around a bug in C++
    # strict header inclusion checking when building without a sandbox.
    #
    # https://github.com/bazelbuild/bazel/issues/3828
    # https://github.com/bazelbuild/bazel/issues/6337
    srcs = _GNULIB_SRCS + _GNULIB_HDRS + select({
        "@bazel_tools//src/conditions:darwin": _GNULIB_DARWIN_SRCS,
        "//conditions:default": _GNULIB_LINUX_SRCS,
    }),
    hdrs = _GNULIB_HDRS,
    copts = ["-DHAVE_CONFIG_H"],
    strip_include_prefix = "lib",
    textual_hdrs = [
        "lib/regex_internal.c",
        "lib/regcomp.c",
        "lib/regexec.c",
        "lib/printf-frexp.c",
        "lib/isnan.c",
    ],
    visibility = ["//visibility:public"],
    deps = [":config_h"],
)
