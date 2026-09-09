# SPDX-License-Identifier: Apache-2.0
# Copyright 2018 the rules_m4 authors
# Copyright 2021 the rules_hdl authors

"""Loads gnulib, used by GNU tools like m4 and bison."""

_CONFIG_HEADER = """
#include "lib/config.in.h"
#include "lib/arg-nonnull.h"

#ifdef BAZEL_VERSION_INFO
#include "bazel_version_info.h"
#else
#define PACKAGE_VERSION "redacted"
#define VERSION "redacted"
#endif

#define PRODUCT "redacted"
#define PACKAGE "redacted"
#define PACKAGE_BUGREPORT "redacted"
#define PACKAGE_COPYRIGHT_YEAR 2100
#define PACKAGE_NAME "redacted"
#define PACKAGE_STRING "redacted"
#define PACKAGE_TARNAME "redacted"
#define PACKAGE_URL "redacted"


#define RENAME_OPEN_FILE_WORKS 0
#define HAVE_TMPFILE 1
#define HAVE_SIGNAL_H 1
#define RETSIGTYPE void
"""

_CONFIG_FOOTER = """
#include <stdlib.h>

#define SYSCMD_SHELL "/bin/sh"

#if HAVE_DECL_PROGRAM_INVOCATION_SHORT_NAME
extern char *program_invocation_short_name;
#endif

#if HAVE_DECL_PROGRAM_INVOCATION_NAME
extern char *program_invocation_name;
#endif

#if HAVE_SECURE_GETENV
char *secure_getenv(char const *name);
#endif
"""

_TIMEVAR_H = """
#ifndef _TIMEVAR_H
#define _TIMEVAR_H 1

#ifdef  __cplusplus
extern "C" {
#endif

#define timevar_init() (void)0
#define timevar_push(x) (void)0
#define timevar_pop(x) (void)0
#define timevar_start(x) (void)0
#define timevar_stop(x) (void)0
#define timevar_get(x, y) (void)0
#define timevar_print(x) (void)0

static int timevar_enabled = 0;

#ifdef  __cplusplus
}
#endif

#endif
"""

def __org_gnu_gnulib(ctx):
    ctx.download_and_extract(
        url = [
            "https://github.com/coreutils/gnulib/archive/dbc5605c3b37a14d7c7e56fcf6c305d542e73210.zip",
        ],
        sha256 = "6ddb29e4f6219409254c9a86782da9b941f9fb00d6e417325994b0770aa13c63",
        stripPrefix = "gnulib-dbc5605c3b37a14d7c7e56fcf6c305d542e73210",
    )

    ctx.file("WORKSPACE", "workspace(name = {name})\n".format(name = repr(ctx.name)))
    ctx.template("BUILD.bazel", Label("@coralnpu_hw//third_party/verilator/gnulib:gnulib.BUILD"), executable = False)

    ctx.template("lib/config.in.h", Label("@coralnpu_hw//third_party/verilator/gnulib:config.in.h"), executable = False)
    ctx.template("config-darwin/config.h", Label("@coralnpu_hw//third_party/verilator/gnulib:config-darwin.h"), substitutions = {
        "{GNULIB_CONFIG_FOOTER}": _CONFIG_FOOTER,
        "{GNULIB_CONFIG_HEADER}": _CONFIG_HEADER,
    }, executable = False)
    ctx.template("config-linux/config.h", Label("@coralnpu_hw//third_party/verilator/gnulib:config-linux.h"), substitutions = {
        "{GNULIB_CONFIG_FOOTER}": _CONFIG_FOOTER,
        "{GNULIB_CONFIG_HEADER}": _CONFIG_HEADER,
    }, executable = False)

    # gnulib inspects inner details of FILE* based on hard-coded structs defined
    # for a handful of target platforms. Disable the whole mess so M4 can be
    # built with musl libc.
    ctx.file("lib/fpending.c", "#include <stdio.h>\nsize_t __fpending(FILE *fp) { return 1; }")
    ctx.file("lib/freadahead.c", "#include <stdio.h>\nsize_t freadahead(FILE *fp) { return 1; }")

    # Stub out the sandbox-escaping charset alias loader.
    ctx.template("lib/localcharset.c", "lib/localcharset.c", substitutions = {
        "get_charset_aliases (void)": '''
get_charset_aliases (void) { return ""; }
#define LIBDIR ""
static const char * _replaced_get_charset_aliases (void) _GL_UNUSED;
static const char * _replaced_get_charset_aliases (void)
''',
    }, executable = False)

    # Stub out timevar.h as it depends on custom timevar.def
    ctx.file("lib/timevar.h", _TIMEVAR_H)

    # Fix a mismatch between _Noreturn and __attribute_noreturn__ when
    # building with a C11-aware GCC.
    ctx.template("lib/obstack.c", "lib/obstack.c", substitutions = {
        "static _Noreturn void": "static _Noreturn __attribute_noreturn__ void",
    })

    ctx.patch(Label("@coralnpu_hw//third_party/verilator/gnulib:stop_using_sigstksz.patch"))

_org_gnu_gnulib = repository_rule(
    __org_gnu_gnulib,
)

def org_gnu_gnulib():
    _org_gnu_gnulib(name = "org_gnu_gnulib")
