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

"""CoralFlow: Unified multi-backend Bazel test macro for CoralNPU."""

load("//rules:coco_tb.bzl", "verilator_cocotb_test")

def coralflow_test(
        name,
        srcs,
        elf,
        highmem_elf = None,
        deps = [],
        data = [],
        targets = ["npusim", "verilator", "uvm", "nexus_fpga"],
        hdl_toplevel = "RvvCoreMiniAxi",
        highmem = False,
        testcases = None,
        size = "medium",
        tags = [],
        **kwargs):
    """Generates multi-backend test targets for a single-source CoralFlow test.

    Expands into:
    - :{name}_npusim: Fast functional ISS test (py_test).
    - :{name}_verilator: Cycle-accurate discrete-event RTL simulation (verilator_cocotb_test).
    - :{name}_uvm: Autonomous UVM co-simulation with Spike lock-step verification (py_test, manual).
    - :{name}_nexus_fpga: Hardware runner (py_binary, manual).
    """
    common_data = data + [elf]
    base_deps = deps + [
        "//coralnpu_test_utils/coralflow",
    ]
    highmem_env = "1" if highmem else "0"

    # 1. NPUSim Target (Behavioral ISS)
    if "npusim" in targets:
        native.py_test(
            name = name + "_npusim",
            srcs = srcs,
            main = srcs[0] if len(srcs) == 1 else None,
            data = common_data,
            env = {
                "CORALFLOW_TARGET": "npusim",
                "CORALFLOW_HIGHMEM": highmem_env,
            },
            size = "small",
            deps = base_deps + [
                "//coralnpu_test_utils/sim_backends:mpact_npusim_test_fixture",
            ],
            tags = ["npusim", "fast"] + tags,
            **kwargs
        )

    # 2. Nexus FPGA Target (Hardware execution)
    if "nexus_fpga" in targets:
        fpga_data = common_data + ([highmem_elf] if highmem_elf else [])
        native.py_binary(
            name = name + "_nexus_fpga",
            srcs = srcs,
            main = srcs[0] if len(srcs) == 1 else None,
            data = fpga_data,
            env = {
                "CORALFLOW_TARGET": "nexus_fpga",
                "CORALFLOW_HIGHMEM": highmem_env,
            },
            deps = base_deps + [
                "//coralnpu_test_utils/sim_backends:fpga_test_fixture",
            ],
            tags = ["nexus_fpga", "manual"] + tags,
            **kwargs
        )

    # 3. Verilator Target (Cycle-accurate RTL simulation)
    if "verilator" in targets:
        # Determine HDL toplevel model and Verilator model based on highmem
        actual_toplevel = "RvvCoreMiniHighmemAxi" if highmem else hdl_toplevel
        verilator_model = (
            "//tests/cocotb:rvv_core_mini_highmem_axi_model" if highmem else "//tests/cocotb:rvv_core_mini_axi_model"
        )

        test_module_names = [s if s.endswith(".py") else s + ".py" for s in srcs]

        verilator_cocotb_test(
            name = name + "_verilator",
            model = verilator_model,
            hdl_toplevel = actual_toplevel,
            test_module = test_module_names,
            testcase = testcases if testcases else [],
            waves = False,
            size = size,
            deps = base_deps + [
                "//coralnpu_test_utils/sim_backends:verilator_test_fixture",
            ],
            data = common_data,
            tags = ["verilator", "rtl"] + tags,
            extra_env = [
                "CORALFLOW_TARGET=verilator",
                "CORALFLOW_HIGHMEM=" + highmem_env,
            ],
            **kwargs
        )

    # 4. UVM Target (Autonomous UVM + Spike co-simulation)
    if "uvm" in targets:
        native.py_test(
            name = name + "_uvm",
            srcs = srcs,
            main = srcs[0] if len(srcs) == 1 else None,
            data = common_data + [
                "//tests/uvm:uvm_sim_verilator",
            ],
            env = {
                "CORALFLOW_TARGET": "uvm",
                "CORALFLOW_HIGHMEM": highmem_env,
            },
            size = size,
            deps = base_deps + [
                "//coralnpu_test_utils/sim_backends:uvm_test_fixture",
            ],
            tags = ["uvm", "rtl", "manual"] + tags,
            **kwargs
        )
