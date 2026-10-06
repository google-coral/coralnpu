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
"""Test runner decorator and async event loop bridge for CoralFlow."""

from __future__ import annotations

import argparse
import asyncio
import functools
import importlib
import os
import sys
import time
from typing import Any, Callable, Coroutine

_ASYNC_FIXTURE_METHODS = {
    "check_memory_accessible",
    "load_elf_and_lookup_symbols",
    "read",
    "read_word",
    "reset_hardware",
    "run_to_fault",
    "run_to_halt",
    "soft_reset",
    "write",
    "write_ptr",
    "write_word",
}


class _AsyncFixtureWrapper:
    """Transparent wrapper allowing synchronous fixture methods to be awaited."""

    def __init__(self, fixture: Any):
        self._fixture = fixture

    def __getattr__(self, name: str) -> Any:
        attr = getattr(self._fixture, name)
        if name in _ASYNC_FIXTURE_METHODS and callable(attr):
            if asyncio.iscoroutinefunction(attr):
                return attr

            async def _async_call(*args: Any, **kwargs: Any) -> Any:
                return attr(*args, **kwargs)

            return _async_call
        return attr


def is_cocotb_simulation() -> bool:
    """Returns True if executing inside a Cocotb discrete-event simulation environment."""
    return "COCOTB_SIM" in os.environ or "cocotb" in sys.modules


def get_target_environment() -> str:
    """Determines current execution target from environment or defaults."""
    if "CORALFLOW_TARGET" in os.environ:
        return os.environ["CORALFLOW_TARGET"].lower().strip()
    return "verilator" if is_cocotb_simulation() else "npusim"


def _parse_fpga_cli_args(argv: list[str] | None = None) -> dict[str, Any]:
    """Parses optional FPGA CLI flags (--usb-serial, --highmem, --lowmem, --verify)."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument(
        "--usb-serial", "--usb_serial", dest="usb_serial", default=None
    )
    mem_group = parser.add_mutually_exclusive_group()
    mem_group.add_argument("--highmem", action="store_true", default=None)
    mem_group.add_argument("--lowmem", action="store_true", default=None)
    parser.add_argument("--verify", action="store_true", default=None)
    ns, _ = parser.parse_known_args(sys.argv[1:] if argv is None else argv)
    cli_kwargs: dict[str, Any] = {}
    if ns.usb_serial:
        cli_kwargs["usb_serial"] = ns.usb_serial
    if ns.highmem:
        cli_kwargs["highmem"] = True
    elif ns.lowmem:
        cli_kwargs["highmem"] = False
    if ns.verify:
        cli_kwargs["verify"] = True
    return cli_kwargs


async def _create_fixture(target: str, **kwargs: Any) -> Any:
    """Dynamically instantiates and initializes the fixture for the requested target.

    Dynamic imports ensure CoralFlow does not statically depend on EDA simulators
    or physical hardware libraries.
    """
    normalized_target = target.lower().strip()
    if normalized_target == "nexus_fpga":
        for k, v in _parse_fpga_cli_args().items():
            kwargs.setdefault(k, v)

    if "highmem" not in kwargs:
        if "CORALFLOW_HIGHMEM" in os.environ:
            if normalized_target in (
                    "npusim",
                    "verilator",
                    "vcs",
                    "rtl",
                    "nexus_fpga",
            ):
                kwargs["highmem"] = os.environ["CORALFLOW_HIGHMEM"].strip(
                ) in (
                    "1",
                    "true",
                    "True",
                )
        elif normalized_target == "nexus_fpga":
            kwargs["highmem"] = True

    if normalized_target == "npusim":
        mod = importlib.import_module(
            "coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture"
        )
        return await mod.MpactNpuSimTestFixture.Create(**kwargs)

    elif normalized_target in ("verilator", "vcs", "rtl"):
        mod = importlib.import_module(
            "coralnpu_test_utils.sim_backends.verilator_test_fixture"
        )
        return await mod.VerilatorTestFixture.Create(**kwargs)

    elif normalized_target == "uvm":
        mod = importlib.import_module(
            "coralnpu_test_utils.sim_backends.uvm_test_fixture"
        )
        return await mod.UvmTestFixture.Create(**kwargs)

    elif normalized_target == "nexus_fpga":
        mod = importlib.import_module(
            "coralnpu_test_utils.sim_backends.fpga_test_fixture"
        )
        if "usb_serial" not in kwargs:
            kwargs["usb_serial"] = (
                os.environ.get("CORALNPU_FPGA_SERIAL")
                or os.environ.get("FPGA_USB_SERIAL", "")
            )
        inst = mod.FpgaTestFixture.create(**kwargs)
        return _AsyncFixtureWrapper(inst)

    else:
        raise ValueError(
            f"Unknown target environment: '{target}'. "
            "Supported targets are: 'npusim', 'verilator', 'uvm', 'nexus_fpga'."
        )


_TARGET_METADATA = {
    "npusim": "Behavioral ISS",
    "verilator": "Discrete-Event RTL Sim",
    "vcs": "Discrete-Event RTL Sim",
    "rtl": "Discrete-Event RTL Sim",
    "uvm": "Spike Lock-Step RTL",
    "nexus_fpga": "Physical FPGA Silicon",
}


def _resolve_test_name(test_func: Callable[..., Any]) -> str:
    """Returns a clean module.function name for the test coroutine."""
    func_name = getattr(test_func, "__qualname__", test_func.__name__)
    mod = getattr(test_func, "__module__", "")
    if mod and mod != "__main__":
        return f"{mod}.{func_name}"
    if sys.argv and sys.argv[0]:
        script = os.path.splitext(os.path.basename(sys.argv[0]))[0]
        return f"{script}.{func_name}"
    return func_name


def _format_and_print_banner(
    test_name: str,
    target: str,
    passed: bool,
    duration_sec: float,
    fixture: Any = None,
    error: Exception | None = None,
    dut: Any = None,
) -> None:
    """Prints a standardized universal CoralFlow execution banner to stdout and logs."""
    normalized_target = target.lower().strip()
    backend_desc = _TARGET_METADATA.get(normalized_target, "Target Backend")

    cycles = None
    if passed and fixture and hasattr(fixture, "get_cycle_count"):
        try:
            cycles = fixture.get_cycle_count()
        except Exception:
            pass

    status_str = "PASSED" if passed else "FAILED"
    banner_lines = [
        "=" * 88,
        f"[CORALFLOW] TEST {status_str}: {test_name}",
        "-" * 88,
        f"  Target Backend   : {normalized_target} ({backend_desc})",
        f"  Status           : {status_str}",
        f"  Wall Time        : {duration_sec:.2f}s",
    ]
    if cycles is not None:
        banner_lines.append(f"  Core Cycles      : {cycles:,} cycles")

    if error is not None:
        err_cls = error.__class__.__name__
        first_line = str(error).strip().splitlines()[0] if str(error).strip(
        ) else "Test failed"
        banner_lines.append(f"  Failure Reason   : {err_cls}: {first_line}")

    banner_lines.append("=" * 88)
    banner = "\n" + "\n".join(banner_lines) + "\n"

    if dut is not None and hasattr(dut, "_log") and hasattr(dut._log, "info"):
        try:
            dut._log.info(banner)
            return
        except Exception:
            pass
    print(banner, flush=True)


async def _close_fixture(fixture: Any) -> None:
    """Safely closes a fixture after test execution."""
    if fixture is not None and hasattr(fixture, "close") and callable(
            fixture.close):
        res = fixture.close()
        if asyncio.iscoroutine(res):
            await res


def coralflow_test(*args: Any, **fixture_kwargs: Any) -> Any:
    """Decorator enabling an asynchronous test coroutine to run interchangeably across backends.

    Can be used as `@coralflow_test` or `@coralflow_test(highmem=True)`.
    """

    def decorator(test_func: Callable[..., Coroutine[Any, Any, None]]) -> Any:
        test_name = _resolve_test_name(test_func)

        if is_cocotb_simulation():
            import cocotb  # Lazy import only inside simulation

            @cocotb.test()
            @functools.wraps(test_func)
            async def cocotb_wrapper(dut: Any) -> None:
                target = os.environ.get("CORALFLOW_TARGET",
                                        "verilator").lower().strip()
                fixture = await _create_fixture(
                    target, dut=dut, **fixture_kwargs
                )
                start_time = time.perf_counter()
                try:
                    await test_func(fixture)
                    duration = time.perf_counter() - start_time
                    _format_and_print_banner(
                        test_name=test_name,
                        target=target,
                        passed=True,
                        duration_sec=duration,
                        fixture=fixture,
                        dut=dut,
                    )
                except Exception as e:
                    duration = time.perf_counter() - start_time
                    _format_and_print_banner(
                        test_name=test_name,
                        target=target,
                        passed=False,
                        duration_sec=duration,
                        fixture=fixture,
                        error=e,
                        dut=dut,
                    )
                    raise
                finally:
                    await _close_fixture(fixture)

            return cocotb_wrapper

        else:

            @functools.wraps(test_func)
            def standalone_wrapper(**call_kwargs: Any) -> None:
                merged_kwargs = {**fixture_kwargs, **call_kwargs}
                target = get_target_environment()

                async def _run() -> None:
                    fixture = await _create_fixture(target, **merged_kwargs)
                    start_time = time.perf_counter()
                    try:
                        await test_func(fixture)
                        duration = time.perf_counter() - start_time
                        _format_and_print_banner(
                            test_name=test_name,
                            target=target,
                            passed=True,
                            duration_sec=duration,
                            fixture=fixture,
                        )
                    except Exception as e:
                        duration = time.perf_counter() - start_time
                        _format_and_print_banner(
                            test_name=test_name,
                            target=target,
                            passed=False,
                            duration_sec=duration,
                            fixture=fixture,
                            error=e,
                        )
                        raise
                    finally:
                        await _close_fixture(fixture)

                asyncio.run(_run())

            return standalone_wrapper

    if len(args) == 1 and callable(args[0]):
        return decorator(args[0])
    return decorator
