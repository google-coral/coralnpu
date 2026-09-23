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

load("@bazel_skylib//rules:common_settings.bzl", "bool_flag")
load("@coralnpu_hw//third_party/python:requirements.bzl", "requirement")
load("@rules_python//python:defs.bzl", "py_binary", "py_library", "py_test")
load(":isg_rules.bzl", "isg_batch")

package(default_visibility = ["//visibility:public"])

bool_flag(
    name = "isg_verbose",
    build_setting_default = False,
    visibility = ["//visibility:public"],
)

config_setting(
    name = "isg_verbose_enabled",
    flag_values = {":isg_verbose": "true"},
)

genrule(
    name = "isg_verbose_config_gen",
    outs = ["isg_verbose_config.py"],
    cmd = select({
        ":isg_verbose_enabled": "echo 'ISG_VERBOSE_DEFAULT = True' > $@",
        "//conditions:default": "echo 'ISG_VERBOSE_DEFAULT = False' > $@",
    }),
)

py_library(
    name = "isg_verbose_config",
    srcs = [":isg_verbose_config.py"],
    imports = ["../.."],
)

py_library(
    name = "isg_lib",
    srcs = glob(
        [
            "gen/*.py",
            "isa/*.py",
            "validate/*.py",
        ],
        exclude = ["**/*_test.py"],
    ),
    imports = ["../.."],
)

py_binary(
    name = "isg_gen",
    srcs = ["isg_gen.py"],
    imports = ["../.."],
    deps = [":isg_lib"],
)

py_binary(
    name = "validator",
    srcs = ["validate/validator.py"],
    imports = ["../.."],
    main = "validate/validator.py",
    deps = [":isg_lib"],
)

py_binary(
    name = "postlink",
    srcs = ["validate/postlink.py"],
    imports = ["../.."],
    main = "validate/postlink.py",
    deps = [
        ":isg_lib",
        requirement("pyelftools"),
    ],
)

py_test(
    name = "decode_probe_test",
    srcs = ["isa/decode_probe_test.py"],
    data = ["//hdl/chisel/src/coralnpu:alphabet_core_mini_axi"],
    env = {"ALPHABET_JSON": "$(rlocationpath //hdl/chisel/src/coralnpu:alphabet_core_mini_axi)"},
    main = "isa/decode_probe_test.py",
    deps = [
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_test(
    name = "validator_test",
    srcs = ["validate/validator_test.py"],
    imports = ["../.."],
    main = "validate/validator_test.py",
    deps = [
        ":isg_lib",
    ],
)

py_test(
    name = "generator_test",
    srcs = ["gen/generator_test.py"],
    data = ["//hdl/chisel/src/coralnpu:alphabet_core_mini_axi"],
    env = {"ALPHABET_JSON": "$(rlocationpath //hdl/chisel/src/coralnpu:alphabet_core_mini_axi)"},
    imports = ["../.."],
    main = "gen/generator_test.py",
    deps = [
        ":isg_lib",
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_test(
    name = "encoding_test",
    srcs = ["isa/encoding_test.py"],
    data = ["//hdl/chisel/src/coralnpu:alphabet_core_mini_axi"],
    env = {"ALPHABET_JSON": "$(rlocationpath //hdl/chisel/src/coralnpu:alphabet_core_mini_axi)"},
    imports = ["../.."],
    main = "isa/encoding_test.py",
    deps = [
        ":isg_lib",
        "@bazel_tools//tools/python/runfiles",
    ],
)

py_test(
    name = "postlink_test",
    srcs = ["validate/postlink_test.py"],
    imports = ["../.."],
    main = "validate/postlink_test.py",
    deps = [
        ":isg_lib",
    ],
)

py_test(
    name = "shaping_test",
    srcs = ["gen/shaping_test.py"],
    imports = ["../.."],
    main = "gen/shaping_test.py",
    deps = [
        ":isg_lib",
    ],
)

py_test(
    name = "traps_test",
    srcs = ["gen/traps_test.py"],
    imports = ["../.."],
    main = "gen/traps_test.py",
    deps = [
        ":isg_lib",
    ],
)

isg_batch(
    name = "isg_fresh_regression",
    align_mode = "mixed",
    alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
    batch_size = 16,
    length = 64,
    seed = "20260921_fresh",
    shaping = "distributed",
    trap_rate = 0.05,
)

isg_batch(
    name = "isg_regression",
    alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
    batch_size = 32,
    length = 64,
    seed = "20260921",
)

# Exercises the trap handler (illegal-instruction and ecall stimuli) under
# 3-way co-simulation.
isg_batch(
    name = "isg_trap_regression",
    alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
    batch_size = 16,
    length = 64,
    seed = "20260924_trap",
    trap_rate = 0.1,
)

isg_batch(
    name = "isg_wb_contention",
    alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
    batch_size = 8,
    length = 64,
    seed = "20260922_wb",
    shaping = "writeback_contention",
)

isg_batch(
    name = "isg_lsu_stlf",
    alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
    batch_size = 8,
    length = 64,
    seed = "20260922_stlf",
    shaping = "lsu_stlf",
)

isg_batch(
    name = "isg_rob_saturation",
    alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
    batch_size = 8,
    length = 64,
    seed = "20260922_rob",
    shaping = "rob_saturation",
)

isg_batch(
    name = "isg_fetch_reorder",
    alphabet = "//hdl/chisel/src/coralnpu:alphabet_core_mini_axi",
    batch_size = 8,
    length = 64,
    seed = "20260922_fetch",
    shaping = "fetch_reorder",
)
