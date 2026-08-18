# Copyright 2024 Google LLC
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

load(
    "@coralnpu_hw//rules:chisel.bzl",
    "chisel_cc_library",
    "chisel_library",
    "chisel_test",
)

chisel_library(
    name = "library",
    srcs = [
        "Library.scala",
    ],
    visibility = ["//visibility:public"],
)

chisel_library(
    name = "index_allocator",
    srcs = ["IndexAllocator.scala"],
    visibility = ["//visibility:public"],
    deps = [":library"],
)

chisel_library(
    name = "common",
    srcs = [
        "CoralNPUArbiter.scala",
        "Fifo.scala",
        "FifoIxO.scala",
        "FifoX.scala",
        "FifoXe.scala",
        "IDiv.scala",
        "MathUtil.scala",
        "Router.scala",
        "Slice.scala",
    ],
    visibility = ["//visibility:public"],
    exports = [
        ":index_allocator",
        ":library",
    ],
    deps = [
        ":index_allocator",
        ":library",
        "@chipsalliance_rocket_chip//:asyncqueue",
    ],
)

chisel_library(
    name = "aligner",
    srcs = [
        "Aligner.scala",
    ],
    resources = [
        "//hdl/verilog/rvv/design:Aligner.sv",
    ],
    visibility = ["//visibility:public"],
)

chisel_test(
    name = "aligner_test",
    srcs = [
        "AlignerTest.scala",
    ],
    deps = [
        ":aligner",
    ],
)

chisel_library(
    name = "scatter_gather",
    srcs = [
        "ScatterGather.scala",
    ],
    visibility = ["//visibility:public"],
)

chisel_library(
    name = "fp",
    srcs = [
        "Fp.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":library",
    ],
)

chisel_library(
    name = "fp_test_utils",
    srcs = [
        "FpTestUtils.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":fp",
    ],
)

chisel_library(
    name = "instruction_buffer",
    srcs = [
        "InstructionBuffer.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":circular_buffer_multi",
        ":library",
    ],
)

chisel_library(
    name = "circular_buffer_multi",
    srcs = [
        "CircularBufferMulti.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":library",
    ],
)

chisel_library(
    name = "sv_generation_utils",
    srcs = [
        "SvGenerationUtils.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [],
)

chisel_test(
    name = "common_test",
    srcs = [
        "CoralNPUArbiterTest.scala",
        "RouterTest.scala",
    ],
    deps = [
        ":common",
    ],
)

chisel_test(
    name = "fp_test",
    srcs = [
        "FpTest.scala",
    ],
    deps = [
        ":fp",
        ":fp_test_utils",
    ],
)

chisel_test(
    name = "instruction_buffer_test",
    size = "large",
    srcs = [
        "InstructionBufferTest.scala",
    ],
    deps = [
        ":instruction_buffer",
    ],
)

chisel_test(
    name = "circular_buffer_multi_test",
    size = "large",
    srcs = [
        "CircularBufferMultiTest.scala",
    ],
    deps = [
        ":circular_buffer_multi",
    ],
)

chisel_test(
    name = "library_test",
    size = "large",
    srcs = [
        "LibraryTest.scala",
    ],
    deps = [
        ":library",
    ],
)

chisel_test(
    name = "gather_test",
    size = "large",
    srcs = [
        "GatherSpec.scala",
    ],
    deps = [
        ":scatter_gather",
    ],
)

chisel_test(
    name = "scatter_test",
    size = "large",
    srcs = [
        "ScatterSpec.scala",
    ],
    deps = [
        ":scatter_gather",
    ],
)

chisel_library(
    name = "fma",
    srcs = [
        "Fma.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":common",
        ":fp",
    ],
)

chisel_test(
    name = "fma_test",
    size = "large",
    srcs = [
        "FmaTest.scala",
    ],
    deps = [
        ":fma",
        ":fp",
    ],
)

chisel_test(
    name = "sv_generation_utils_test",
    srcs = [
        "SvGenerationUtilsTest.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":sv_generation_utils",
    ],
)

chisel_library(
    name = "testing",
    srcs = [
        "TestingUtils.scala",
    ],
    visibility = ["//visibility:public"],
)

chisel_test(
    name = "async_queue_smoke_test",
    srcs = ["AsyncQueueSmokeTest.scala"],
    deps = [
        ":common",
        "@chipsalliance_rocket_chip//:asyncqueue",
    ],
)

chisel_test(
    name = "index_allocator_test",
    size = "large",
    srcs = [
        "IndexAllocatorTest.scala",
    ],
    deps = [
        ":index_allocator",
    ],
)

chisel_library(
    name = "fifo_state",
    srcs = [
        "FIFOState.scala",
    ],
    visibility = ["//visibility:public"],
    deps = [
        ":library",
    ],
)

chisel_test(
    name = "fifo_state_test",
    size = "large",
    srcs = [
        "FIFOStateTest.scala",
    ],
    deps = [
        ":fifo_state",
    ],
)
