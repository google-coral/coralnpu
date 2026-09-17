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

load(
    "@coralnpu_hw//rules:chisel.bzl",
    "chisel_cc_library",
    "chisel_library",
)
load("@coralnpu_hw//rules:coco_tb.bzl", "verilator_cocotb_model")
load(
    "//tests/cocotb:build_defs.bzl",
    "VERILATOR_BUILD_ARGS",
)

package(default_visibility = ["//visibility:public"])

chisel_library(
    name = "dma",
    srcs = [
        "DmaCore.scala",
        "DmaCsr.scala",
        "DmaDescriptors.scala",
        "DmaDrainEngine.scala",
        "DmaFillEngine.scala",
        "TransposeBuffer.scala",
    ],
    deps = [
        "//hdl/chisel/src/bus",
        "//hdl/chisel/src/common",
    ],
)

chisel_cc_library(
    name = "dma_core_cc_library",
    chisel_lib = ":dma",
    emit_class = "dma.DmaCoreEmitter",
    module_name = "DmaCore",
)

verilator_cocotb_model(
    name = "dma_core_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "DmaCore",
    trace = True,
    verilog_source = "//hdl/chisel/src/dma:DmaCore.sv",
)

chisel_cc_library(
    name = "dma_csr_cc_library",
    chisel_lib = ":dma",
    emit_class = "dma.DmaCsrEmitter",
    module_name = "DmaCsr",
)

chisel_cc_library(
    name = "transpose_buffer_cc_library",
    chisel_lib = ":dma",
    emit_class = "dma.TransposeBufferEmitter",
    module_name = "TransposeBuffer",
)

verilator_cocotb_model(
    name = "transpose_buffer_model",
    cflags = VERILATOR_BUILD_ARGS,
    hdl_toplevel = "TransposeBuffer",
    trace = True,
    verilog_source = "//hdl/chisel/src/dma:TransposeBuffer.sv",
)
