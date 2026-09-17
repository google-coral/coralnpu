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

load("@coralnpu_hw//rules:coco_tb.bzl", "cocotb_test_suite")

package(default_visibility = ["//visibility:public"])

# BEGIN_TESTCASES_FOR_transpose_buffer_cocotb_test
TRANSPOSE_BUFFER_TESTCASES = [
    "test_transpose_buffer_randomized",
    "test_transpose_buffer_out_of_order",
    "test_transpose_buffer_memcopy",
]
# END_TESTCASES_FOR_transpose_buffer_cocotb_test

cocotb_test_suite(
    name = "transpose_buffer_cocotb_test",
    simulators = [
        "verilator",
    ],
    testcases = TRANSPOSE_BUFFER_TESTCASES,
    testcases_vname = "TRANSPOSE_BUFFER_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "TransposeBuffer",
        "test_module": ["test_transpose_buffer.py"],
        "waves": True,
        "default_testcase_size": "medium",
        "size": "medium",
    },
    verilator_model = "//hdl/chisel/src/dma:transpose_buffer_model",
)

# BEGIN_TESTCASES_FOR_dma_core_cocotb_test
DMA_CORE_TESTCASES = [
    "test_dma_smoke",
    "test_dma_single_chunk",
    "test_dma_partial_tail",
    "test_dma_multi_chunk",
    "test_dma_multi_chunk_partial",
    "test_dma_back_to_back",
    "test_dma_align_error",
    "test_dma_cfg_error",
    "test_dma_source_integrity",
    "test_dma_randomized",
]
# END_TESTCASES_FOR_dma_core_cocotb_test

cocotb_test_suite(
    name = "dma_core_cocotb_test",
    simulators = [
        "verilator",
    ],
    testcases = DMA_CORE_TESTCASES,
    testcases_vname = "DMA_CORE_TESTCASES",
    tests_kwargs = {
        "hdl_toplevel": "DmaCore",
        "test_module": ["test_dma_core.py"],
        "waves": True,
        "default_testcase_size": "medium",
        "size": "medium",
    },
    verilator_model = "//hdl/chisel/src/dma:dma_core_model",
)
