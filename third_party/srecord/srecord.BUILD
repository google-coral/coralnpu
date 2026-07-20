# Copyright 2025 Google LLC

load("@rules_foreign_cc//foreign_cc:defs.bzl", "cmake")

filegroup(
    name = "all_srcs",
    srcs = glob(["**"]),
)

cmake(
    name = "srecord",
    cache_entries = {
        "CMAKE_CXX_STANDARD": "17",
    },
    env = {
        "LDFLAGS": "-lstdc++",
    },
    generate_args = [
        "-G Ninja",
    ],
    install = True,
    lib_source = ":all_srcs",
    out_binaries = ["srec_cat"],
    visibility = ["//visibility:public"],
)
