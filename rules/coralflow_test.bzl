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

load("@rules_pkg//pkg:tar.bzl", "pkg_tar")
load(
    "//rules:coco_tb.bzl",
    "vcs_cocotb_test",
    "verilator_cocotb_test",
)
load(
    "//tests/cocotb:build_defs.bzl",
    "VCS_TEST_ARGS",
)

_TOPLEVEL_MODELS = {
    "CoreMiniAxi": (
        "//tests/cocotb:core_mini_axi_model",
        "//tests/cocotb:core_mini_axi_vcs_model",
    ),
    "RvvCoreMiniAxi": (
        "//tests/cocotb:rvv_core_mini_axi_model",
        "//tests/cocotb:rvv_core_mini_axi_vcs_model",
    ),
    "RvvCoreMiniHighmemAxi": (
        "//tests/cocotb:rvv_core_mini_highmem_axi_model",
        "//tests/cocotb:rvv_core_mini_highmem_axi_vcs_model",
    ),
    "RvvCoreMini_ITCM512KB_DTCM512KBAxi": (
        "//tests/cocotb:rvv_core_mini_itcm512kb_dtcm512kb_axi_model",
        "//tests/cocotb:rvv_core_mini_itcm512kb_dtcm512kb_axi_vcs_model",
    ),
    "VmeCoreMiniAxi": (
        "//tests/cocotb:vme_core_mini_axi_model",
        "//tests/cocotb:vme_core_mini_axi_vcs_model",
    ),
}

_SIZE_ORDER = {
    "small": 0,
    "medium": 1,
    "large": 2,
    "enormous": 3,
}

_VCS_SIZE_UPGRADE = {
    "medium": "large",
    "large": "enormous",
}

def _unique(items):
    return list({item: None for item in items}.keys())

def _parse_testcase(tc, default_size):
    if type(tc) == "tuple":
        return tc[0], tc[1]
    return tc, default_size

def _filter_testcases(testcases, backend, exclude_testcases):
    if not testcases:
        return testcases
    excluded = exclude_testcases.get(backend, [])
    if not excluded:
        return testcases
    return [
        tc
        for tc in testcases
        if _parse_testcase(tc, None)[0] not in excluded
    ]

def _effective_size(default_size, testcases):
    if not testcases:
        return default_size
    best = default_size
    for tc in testcases:
        _, tc_size = _parse_testcase(tc, default_size)
        if _SIZE_ORDER.get(tc_size, 1) > _SIZE_ORDER.get(best, 1):
            best = tc_size
    return best

def _emit_rtl_target(
        name,
        sim,
        rule_fn,
        model,
        hdl_toplevel,
        test_modules,
        testcases,
        excluded_testcases,
        size,
        deps,
        data,
        base_test_args,
        test_tags,
        extra_env,
        kwargs):
    if testcases != None and not testcases:
        return
    single_kwargs = dict(kwargs)
    single_kwargs.pop("timeout", None)
    env = list(extra_env)
    if testcases:
        env.append("CORALFLOW_TESTCASE=" + ",".join([
            _parse_testcase(tc, size)[0]
            for tc in testcases
        ]))
    if excluded_testcases:
        env.append("CORALFLOW_EXCLUDE_TESTCASE=" + ",".join(excluded_testcases))
    target_size = _effective_size(size, testcases)
    if sim == "vcs":
        target_size = _VCS_SIZE_UPGRADE.get(target_size, target_size)
    rule_fn(
        name = "{}_{}".format(name, sim),
        model = model,
        hdl_toplevel = hdl_toplevel,
        test_module = test_modules,
        testcase = [],
        waves = False,
        seed = "42",
        size = target_size,
        deps = deps,
        data = data,
        test_args = base_test_args,
        tags = test_tags,
        extra_env = env,
        **single_kwargs
    )

def _emit_py_test_target(
        name,
        backend,
        srcs,
        main_src,
        data,
        deps,
        fixture_dep,
        testcases,
        excluded_testcases,
        size,
        highmem_env,
        base_tags,
        tags,
        kwargs):
    if testcases != None and not testcases:
        return
    py_kwargs = dict(kwargs)
    py_kwargs.pop("timeout", None)
    py_env = {
        "CORALFLOW_TARGET": backend,
        "CORALFLOW_HIGHMEM": highmem_env,
    }
    if testcases:
        py_env["CORALFLOW_TESTCASE"] = ",".join([
            _parse_testcase(tc, size)[0]
            for tc in testcases
        ])
    if excluded_testcases:
        py_env["CORALFLOW_EXCLUDE_TESTCASE"] = ",".join(excluded_testcases)
    native.py_test(
        name = "{}_{}".format(name, backend),
        srcs = srcs,
        main = main_src,
        data = data,
        env = py_env,
        size = size,
        deps = _unique(deps + [fixture_dep]),
        tags = _unique(base_tags + tags),
        **py_kwargs
    )

def _emit_fpga_target(
        name,
        srcs,
        main_src,
        data,
        deps,
        tags,
        kwargs):
    fpga_kwargs = dict(kwargs)
    fpga_kwargs.pop("timeout", None)
    fpga_kwargs.pop("shard_count", None)
    fpga_tags = _unique(["nexus_fpga", "manual"] + tags)
    native.py_binary(
        name = name + "_nexus_fpga",
        srcs = srcs,
        main = main_src,
        data = data,
        env = {
            "CORALFLOW_TARGET": "nexus_fpga",
            # Physical Nexus FPGA bitstream (chip_nexus.bin) is Highmem by default.
            "CORALFLOW_HIGHMEM": "1",
        },
        deps = _unique(deps + [
            "//coralnpu_test_utils/sim_backends:fpga_test_fixture",
        ]),
        tags = fpga_tags,
        **fpga_kwargs
    )

    pkg_tar(
        name = name + "_nexus_fpga_files",
        srcs = _unique(srcs + data + [
            "//sw/utils:metrics",
            "//sw/utils/nexus_loader:nexus_loader",
            "//coralnpu_test_utils:ftdi_spi_master.py",
            "//coralnpu_test_utils:spi_constants.py",
            "//coralnpu_test_utils/coralflow:base_fixture.py",
            "//coralnpu_test_utils/coralflow:runner.py",
            "//coralnpu_test_utils/sim_backends:common_utils.py",
            "//coralnpu_test_utils/sim_backends:fpga_test_fixture.py",
        ]),
        mode = "0644",
        modes = {
            "sw/utils/nexus_loader/nexus_loader": "0755",
        },
        strip_prefix = "/",
        tags = fpga_tags,
    )

    pkg_tar(
        name = name + "_nexus_fpga_pkg",
        srcs = ["//coralnpu_test_utils/coralflow:run_fpga_pkg.sh"],
        deps = [":" + name + "_nexus_fpga_files"],
        mode = "0755",
        remap_paths = {
            "/run_fpga_pkg.sh": "run.sh",
        },
        tags = fpga_tags,
    )

def coralflow_test(
        name,
        srcs,
        main = None,
        elf = None,
        deps = [],
        data = [],
        targets = None,
        hdl_toplevel = "RvvCoreMiniAxi",
        highmem = False,
        testcases = None,
        exclude_testcases = {},
        test_args = [],
        size = "medium",
        tags = [],
        **kwargs):
    """Generates multi-backend test targets for a single-source CoralFlow test.

    Expands into:
    - :{name}_npusim: Fast functional ISS test (py_test).
    - :{name}_verilator: Verilator RTL simulation.
    - :{name}_vcs: VCS RTL simulation.
    - :{name}_uvm: UVM + Spike co-simulation.
    - :{name}_nexus_fpga & :{name}_nexus_fpga_pkg: Physical FPGA runner and standalone tarball.

    Args:
      exclude_testcases: Optional dict mapping backend name (e.g. "uvm", "npusim")
        to a list of testcase names to skip on that backend.
    """
    if targets == None:
        if highmem:
            targets = ["npusim", "verilator", "vcs", "nexus_fpga"]
        else:
            targets = ["npusim", "verilator", "vcs", "uvm", "nexus_fpga"]

    actual_toplevel = (
        "RvvCoreMiniHighmemAxi" if (highmem and hdl_toplevel == "RvvCoreMiniAxi") else hdl_toplevel
    )
    if actual_toplevel not in _TOPLEVEL_MODELS:
        fail("Unsupported hdl_toplevel '{}' for coralflow_test. Supported: {}".format(
            actual_toplevel,
            sorted(_TOPLEVEL_MODELS.keys()),
        ))
    verilator_model, vcs_model = _TOPLEVEL_MODELS[actual_toplevel]

    common_data = _unique(list(data) + ([elf] if elf else []))
    base_deps = _unique(list(deps) + [
        "//coralnpu_test_utils/coralflow",
    ])
    is_highmem_map = highmem or actual_toplevel in (
        "RvvCoreMiniHighmemAxi",
        "RvvCoreMini_ITCM512KB_DTCM512KBAxi",
    )
    highmem_env = "1" if is_highmem_map else "0"
    main_src = main if main else (srcs[0] if len(srcs) == 1 else None)
    test_module_names = [s if s.endswith(".py") else s + ".py" for s in srcs]
    rtl_deps = _unique(base_deps + [
        "//coralnpu_test_utils/sim_backends:verilator_test_fixture",
    ])

    if "npusim" in targets:
        _emit_py_test_target(
            name = name,
            backend = "npusim",
            srcs = srcs,
            main_src = main_src,
            data = common_data,
            deps = base_deps,
            fixture_dep = "//coralnpu_test_utils/sim_backends:mpact_npusim_test_fixture",
            testcases = _filter_testcases(testcases, "npusim", exclude_testcases),
            excluded_testcases = exclude_testcases.get("npusim", []),
            size = "small",
            highmem_env = highmem_env,
            base_tags = ["npusim", "fast"],
            tags = tags,
            kwargs = kwargs,
        )

    if "nexus_fpga" in targets:
        _emit_fpga_target(
            name = name,
            srcs = srcs,
            main_src = main_src,
            data = common_data,
            deps = base_deps,
            tags = tags,
            kwargs = kwargs,
        )

    if "verilator" in targets:
        _emit_rtl_target(
            name = name,
            sim = "verilator",
            rule_fn = verilator_cocotb_test,
            model = verilator_model,
            hdl_toplevel = actual_toplevel,
            test_modules = test_module_names,
            testcases = _filter_testcases(testcases, "verilator", exclude_testcases),
            excluded_testcases = exclude_testcases.get("verilator", []),
            size = size,
            deps = rtl_deps,
            data = common_data,
            base_test_args = list(test_args),
            test_tags = _unique(["verilator", "rtl"] + tags),
            extra_env = [
                "CORALFLOW_TARGET=verilator",
                "CORALFLOW_HIGHMEM=" + highmem_env,
            ],
            kwargs = kwargs,
        )

    if "vcs" in targets:
        _emit_rtl_target(
            name = name,
            sim = "vcs",
            rule_fn = vcs_cocotb_test,
            model = vcs_model,
            hdl_toplevel = actual_toplevel,
            test_modules = test_module_names,
            testcases = _filter_testcases(testcases, "vcs", exclude_testcases),
            excluded_testcases = exclude_testcases.get("vcs", []),
            size = size,
            deps = rtl_deps,
            data = _unique(common_data + [
                "//tests/cocotb:coverage_exclude.cfg",
                "//tests/cocotb:xprop.cfg",
            ]),
            base_test_args = VCS_TEST_ARGS + list(test_args),
            test_tags = _unique(["vcs", "rtl", "vcs_cocotb_single_test"] + tags),
            extra_env = [
                "CORALFLOW_TARGET=vcs",
                "CORALFLOW_HIGHMEM=" + highmem_env,
            ],
            kwargs = kwargs,
        )

    if "uvm" in targets:
        uvm_testcases = _filter_testcases(testcases, "uvm", exclude_testcases)
        if actual_toplevel == "VmeCoreMiniAxi":
            uvm_sim_dep = select({
                "//tests/uvm:use_vcs_uvm": ["//tests/uvm:uvm_sim_vcs_vme"],
                "//conditions:default": ["//tests/uvm:uvm_sim_verilator_vme"],
            })
        else:
            uvm_sim_dep = select({
                "//tests/uvm:use_vcs_uvm": ["//tests/uvm:uvm_sim_vcs_dut"],
                "//conditions:default": ["//tests/uvm:uvm_sim_verilator_dut"],
            })
        _emit_py_test_target(
            name = name,
            backend = "uvm",
            srcs = srcs,
            main_src = main_src,
            data = _unique(common_data) + uvm_sim_dep,
            deps = base_deps,
            fixture_dep = "//coralnpu_test_utils/sim_backends:uvm_test_fixture",
            testcases = uvm_testcases,
            excluded_testcases = exclude_testcases.get("uvm", []),
            size = _effective_size(size, uvm_testcases),
            highmem_env = highmem_env,
            base_tags = ["uvm", "rtl"],
            tags = tags,
            kwargs = kwargs,
        )
