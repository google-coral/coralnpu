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
"""UVM Test Fixture for CoralNPU.

Provides an API-compatible fixture to run CoralNPU software workloads on the
UVM batch simulation environment with 3-way co-simulation (RTL, MPACT, Spike).
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import struct
import subprocess
import tempfile

import numpy as np

from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.sim_backends.common_utils import (
    infer_read_size_bytes,
    parse_elf_symbols,
    reconstruct_read_data,
    resolve_runfile_path,
    to_uint8_array,
)

logger = logging.getLogger(__name__)


class UvmTestFixture(BaseCoralNPUFixture):
    """Orchestrates UVM batch simulation via a subprocess."""

    def __init__(
        self,
        simulator: str = "verilator",
        enable_spike_cosim: bool = True,
        sim_binary_path: str | None = None,
    ):
        super().__init__()
        self.simulator = simulator
        self.enable_spike_cosim = enable_spike_cosim
        self.sim_binary_path = sim_binary_path

        self.elf_path: str | None = None
        self.entry_point: int = 0
        self.tohost_addr: int = 0
        self.staged_memory: dict[int, bytes] = {}
        self.dumped_memory: list[tuple[int, bytes]] = []
        self.test_passed: bool = False

    @classmethod
    async def Create(
        cls,
        simulator: str = "verilator",
        enable_spike_cosim: bool = True,
        sim_binary_path: str | None = None,
        **_kwargs,
    ) -> UvmTestFixture:
        """Factory method to instantiate the fixture."""
        return cls(simulator, enable_spike_cosim, sim_binary_path)

    async def load_elf_and_lookup_symbols(
        self,
        elf_path: str | os.PathLike,
        symbols: list[str] | None = None,
        optional: bool = False,
        optional_symbols: list[str] | None = None,
    ) -> dict[str, int]:
        """Parses the ELF binary, resets state, and resolves symbol addresses."""
        resolved = resolve_runfile_path(elf_path)
        if not os.path.exists(resolved):
            raise FileNotFoundError(
                f"ELF file not found: {elf_path} (resolved: {resolved})"
            )

        self.elf_path = resolved
        self.tohost_addr = 0
        self.symbols.clear()
        self.symbol_sizes.clear()
        self.staged_memory.clear()
        self.dumped_memory.clear()
        self.cycle_count = None
        self.test_passed = False

        opts = list(optional_symbols or [])
        if "tohost" not in opts:
            opts.append("tohost")

        self.entry_point, self.symbols, self.symbol_sizes = parse_elf_symbols(
            self.elf_path,
            symbols=symbols,
            optional_symbols=opts,
            strict=not optional,
            require_symtab=False,
        )

        if "tohost" in self.symbols:
            self.tohost_addr = self.symbols["tohost"]
        else:
            logger.debug(
                "tohost symbol not found. Required for UVM status tracking."
            )

        return self.symbols

    def _stage_bytes(self, addr: int, byte_data: bytes) -> None:
        """Stages bytes into staged_memory, coalescing strictly overlapping byte ranges."""
        if not byte_data:
            return
        new_start = addr
        new_end = addr + len(byte_data)
        overlapping = [
            (base, data)
            for base, data in self.staged_memory.items()
            if max(base, new_start) < min(base + len(data), new_end)
        ]
        if not overlapping:
            self.staged_memory[addr] = byte_data
            return

        merged_start = min([new_start] + [b for b, _ in overlapping])
        merged_end = max([new_end] + [b + len(d) for b, d in overlapping])
        buf = bytearray(merged_end - merged_start)
        for base, data in overlapping:
            del self.staged_memory[base]
            off = base - merged_start
            buf[off:off + len(data)] = data
        new_off = new_start - merged_start
        buf[new_off:new_off + len(byte_data)] = byte_data
        self.staged_memory[merged_start] = bytes(buf)

    async def write(
        self,
        symbol: str | int,
        data: np.ndarray | bytes | bytearray | int | np.integer,
        offset: int = 0,
    ):
        """Stages data (scalar integer, NumPy array, or bytes) in host memory to be patched into the ELF before simulation."""
        addr = self.resolve_address(symbol, offset=offset)
        self._stage_bytes(addr, to_uint8_array(data).tobytes())

    async def write_word(
        self,
        symbol: str | int,
        data: int | np.integer,
        offset: int = 0,
    ):
        """Stages a single 32-bit scalar word."""
        addr = self.resolve_address(symbol, offset=offset)
        self._stage_bytes(addr, struct.pack("<I", int(data) & 0xFFFFFFFF))

    async def write_ptr(
        self, addr_symbol: str, data_symbol: str, offset: int = 0
    ):
        """Stages the resolved address of data_symbol into addr_symbol."""
        await self.write_word(
            addr_symbol, self.resolve_address(data_symbol, offset)
        )

    def _read_bytes_from_dump(self, addr: int, size: int) -> bytes:
        """Reads a byte sequence from dumped memory blocks (or staged memory pre-halt)."""
        for base, data in self.dumped_memory:
            if base <= addr and addr + size <= base + len(data):
                offset = addr - base
                return bytes(data[offset:offset + size])
        for base, data in self.staged_memory.items():
            if base <= addr and addr + size <= base + len(data):
                offset = addr - base
                return bytes(data[offset:offset + size])
        raise KeyError(
            f"Address 0x{addr:x} (size {size}) not found in dumped memory ranges: "
            f"{[(hex(b), len(d)) for b, d in self.dumped_memory]}"
        )

    async def read(
        self,
        symbol: str | int,
        size: int | None = None,
        offset: int = 0,
        dtype: np.dtype | None = None,
        shape: tuple | None = None,
    ) -> np.ndarray:
        """Reads memory post-simulation from the SRAM memory dump."""
        addr = self.resolve_address(symbol, offset=offset)
        actual_size = infer_read_size_bytes(
            symbol, self.symbol_sizes, size=size, dtype=dtype, shape=shape
        )
        raw_bytes = self._read_bytes_from_dump(addr, actual_size)
        return reconstruct_read_data(raw_bytes, dtype=dtype, shape=shape)

    async def read_word(self, symbol: str | int, offset: int = 0) -> int:
        """Reads a single 32-bit scalar word from dumped memory."""
        addr = self.resolve_address(symbol, offset=offset)
        raw_bytes = self._read_bytes_from_dump(addr, 4)
        return struct.unpack("<I", raw_bytes)[0]

    def _create_patch_file(self) -> str | None:
        """Serializes staged memory into a binary patch file (uint64_t addr, uint32_t len, bytes)."""
        if not self.staged_memory:
            return None

        with tempfile.NamedTemporaryFile(prefix="uvm_mem_patch_",
                                         suffix=".bin", delete=False) as tmp:
            for addr, data in self.staged_memory.items():
                header = struct.pack("<QI", addr, len(data))
                tmp.write(header)
                tmp.write(data)
            return tmp.name

    def _load_dump_file(self, dump_path: str):
        """Loads dumped memory blocks (uint64_t base, uint32_t len, bytes) into memory."""
        self.dumped_memory.clear()
        if not os.path.exists(dump_path) or os.path.getsize(dump_path) == 0:
            return

        with open(dump_path, "rb") as f:
            while True:
                header = f.read(12)  # 8 bytes base + 4 bytes size
                if len(header) < 12:
                    break
                base, size = struct.unpack("<QI", header)
                data = f.read(size)
                if len(data) < size:
                    logger.warning(
                        "Truncated memory dump block at 0x%x (expected %d bytes, got %d)",
                        base,
                        size,
                        len(data),
                    )
                    break
                self.dumped_memory.append((base, data))

    def _get_simulator_binary(self) -> str:
        if self.sim_binary_path:
            return resolve_runfile_path(self.sim_binary_path)
        env_sim = os.environ.get("CORALFLOW_UVM_SIMULATOR", "").strip()
        if env_sim:
            return resolve_runfile_path(f"tests/uvm/uvm_sim_{env_sim}")
        alt_sim = "vcs" if self.simulator == "verilator" else "verilator"
        for candidate in (
                f"tests/uvm/uvm_sim_{self.simulator}_vme",
                f"tests/uvm/uvm_sim_{self.simulator}",
                f"tests/uvm/uvm_sim_{alt_sim}_vme",
                f"tests/uvm/uvm_sim_{alt_sim}",
        ):
            resolved = resolve_runfile_path(candidate)
            if os.path.exists(resolved):
                return resolved
        return resolve_runfile_path(f"tests/uvm/uvm_sim_{self.simulator}_vme")

    async def run_to_halt(
        self,
        timeout_sec: float = 300.0,
        timeout_cycles: int | None = None,
    ) -> bool:
        """Launches simulator, applies patch, dumps memory on halt, and verifies results."""
        if not self.elf_path:
            raise RuntimeError(
                "load_elf_and_lookup_symbols must be called before run_to_halt."
            )

        patch_file: str | None = None
        dump_file: str | None = None
        process = None

        try:
            patch_file = self._create_patch_file()
            with tempfile.NamedTemporaryFile(prefix="uvm_mem_dump_",
                                             suffix=".bin",
                                             delete=False) as dump_tmp:
                dump_file = dump_tmp.name

            cmd = [
                self._get_simulator_binary(),
                f"+TEST_ELF={self.elf_path}",
                f"+ENTRY_POINT=0x{self.entry_point:08x}",
                f"+TOHOST_ADDR=0x{self.tohost_addr:08x}",
                "+UVM_TESTNAME=coralnpu_base_test",
                f"+MEM_DUMP={dump_file}",
            ]
            if timeout_cycles is not None and int(timeout_cycles
                                                  ) * 10 > 20_000_000:
                cmd.append(f"+TEST_TIMEOUT={int(timeout_cycles) * 10}")
                timeout_sec = max(timeout_sec, 300.0)
            if patch_file:
                cmd.append(f"+MEM_PATCH={patch_file}")
            if self.enable_spike_cosim:
                cmd.append("+SPIKE_LOG")

            logger.info("Launching UVM Simulator: %s", " ".join(cmd))

            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            try:
                stdout, _ = await asyncio.wait_for(
                    process.communicate(), timeout=timeout_sec
                )
            except asyncio.TimeoutError as err:
                partial_log = ""
                if process is not None:
                    if process.returncode is None:
                        try:
                            process.kill()
                        except ProcessLookupError:
                            pass
                        await process.wait()
                    if process.stdout is not None:
                        try:
                            raw_partial = await process.stdout.read()
                            if isinstance(raw_partial, (bytes, bytearray)):
                                partial_log = raw_partial.decode(
                                    "utf-8", errors="replace"
                                )
                        except Exception:  # noqa: BLE001
                            pass
                reason = (
                    f"UVM Simulation timed out after {timeout_sec}s "
                    f"(elf={self.elf_path}, sim={cmd[0]})"
                )
                raise RuntimeError(
                    self._dump_sim_log(
                        partial_log
                        or f"Process timed out running: {' '.join(cmd)}\n",
                        reason=reason,
                    )
                ) from err

            stdout_str = stdout.decode("utf-8", errors="replace")
            self._parse_uvm_logs(stdout_str, returncode=process.returncode)

            if self.test_passed:
                self._load_dump_file(dump_file)

            return self.test_passed
        finally:
            if process is not None and process.returncode is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                await process.wait()

            if patch_file and os.path.exists(patch_file):
                try:
                    os.remove(patch_file)
                except OSError:
                    pass

            if dump_file and os.path.exists(dump_file):
                try:
                    os.remove(dump_file)
                except OSError:
                    pass

    @staticmethod
    def _dump_sim_log(log_output: str, reason: str) -> str:
        """Saves full simulation log to file, logs the error, and returns the formatted error message."""
        log_dump_path = None
        try:
            target_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
            if not target_dir or not os.path.isdir(target_dir):
                target_dir = None
            with tempfile.NamedTemporaryFile(
                    mode="w",
                    prefix="uvm_sim_error_",
                    suffix=".log",
                    dir=target_dir,
                    delete=False,
                    encoding="utf-8",
            ) as f:
                f.write(log_output)
                log_dump_path = f.name
        except Exception as err:  # noqa: BLE001
            logger.warning("Failed to dump simulation log to file: %s", err)

        dump_msg = (
            f"\nFull simulation log dumped to: {log_dump_path}"
            if log_dump_path else ""
        )
        error_msg = f"{reason}{dump_msg}"
        logger.error(error_msg)
        return error_msg

    def _parse_uvm_logs(self, log_output: str, returncode: int = 0):
        """Parses UVM simulation output for pass/fail status and cycle count."""
        self.test_passed = False

        # 1. Did UVM fail?
        if "** UVM TEST FAILED **" in log_output or re.search(
                r"UVM_(?:ERROR|FATAL)\s*:\s*[1-9]\d*", log_output):
            first_err = re.search(
                r"^\s*(UVM_(?:FATAL|ERROR).*)$", log_output, re.MULTILINE
            )
            reason = (
                f"UVM test failed: {first_err.group(1).strip()}" if first_err
                else "UVM execution failed due to UVM_ERROR or UVM_FATAL."
            )
            raise RuntimeError(self._dump_sim_log(log_output, reason=reason))

        # 2. Did the simulator process crash?
        if returncode != 0:
            raise RuntimeError(
                self._dump_sim_log(
                    log_output,
                    reason=
                    f"UVM simulation process crashed with exit code {returncode}.",
                )
            )

        # 3. Did UVM pass?
        if "** UVM TEST PASSED **" in log_output:
            self.test_passed = True
        else:
            raise RuntimeError(
                self._dump_sim_log(
                    log_output,
                    reason=
                    "UVM simulation finished without a PASS confirmation.",
                )
            )

        # 4. Extract explicit cycle count banner if emitted
        cycle_match = re.search(
            r"(?:cycle count|cycles)\s*[:=]\s*(\d+)", log_output, re.IGNORECASE
        )
        if cycle_match:
            self.cycle_count = int(cycle_match.group(1))

    def get_cycle_count(self) -> int | None:
        """Returns the simulated cycle count if available."""
        for sym in ("cycle_count", "csr_cycle_count"):
            if sym in self.symbols and self.dumped_memory:
                try:
                    raw = self._read_bytes_from_dump(self.symbols[sym], 4)
                    val = struct.unpack("<I", raw)[0]
                    if val > 0:
                        return val
                except KeyError:
                    pass
        return self.cycle_count

    async def run_batch(
        self,
        elf_paths: list[str | os.PathLike],
        timeout_cycles: int = 100000,
        timeout_sec: float = 600.0,
    ) -> bool:
        """Executes a batch of self-contained ELFs in a single UVM simulator invocation."""
        if not elf_paths:
            raise ValueError("elf_paths must not be empty.")
        if len(elf_paths) == 1:
            return await super().run_batch(
                elf_paths, timeout_cycles=timeout_cycles
            )

        resolved_entries: list[tuple[str, int, int, str]] = []
        for elf_path in elf_paths:
            resolved = resolve_runfile_path(elf_path)
            if not os.path.exists(resolved):
                raise FileNotFoundError(
                    f"ELF file not found: {elf_path} (resolved: {resolved})"
                )
            entry_point, symbols, _ = parse_elf_symbols(
                resolved,
                symbols=["tohost"],
                strict=True,
                require_symtab=False,
            )
            tohost_addr = symbols["tohost"]
            resolved_entries.append((
                os.path.abspath(resolved),
                tohost_addr,
                entry_point,
                os.path.basename(resolved),
            ))

        reg_list_file: str | None = None
        process = None
        timeout_ns = int(timeout_cycles) * 10

        try:
            spike_opt = (
                "SPIKE"
                if getattr(self, "enable_spike_cosim", True) else "NONE"
            )
            with tempfile.NamedTemporaryFile(
                    mode="w",
                    prefix="uvm_regression_list_",
                    suffix=".txt",
                    delete=False,
                    encoding="utf-8",
            ) as reg_tmp:
                for abs_elf, tohost_addr, entry_point, elf_name in resolved_entries:
                    reg_tmp.write(
                        f"{abs_elf} {tohost_addr:08x} {entry_point:08x} "
                        f"{timeout_ns} {spike_opt} {elf_name}\n"
                    )
                reg_list_file = reg_tmp.name

            verbose = os.environ.get("CORALFLOW_VERBOSE", "").strip() in (
                "1",
                "true",
                "True",
            )
            cmd = [
                self._get_simulator_binary(),
                f"+TEST_ELF={resolved_entries[0][0]}",
                "+UVM_TESTNAME=coralnpu_regression_test",
                f"+REGRESSION_LIST={reg_list_file}",
            ]
            if verbose:
                cmd.append("+COSIM_TRACE_LOG")

            logger.info(
                "Launching UVM Batch Simulator (%d ELFs): %s",
                len(resolved_entries),
                " ".join(cmd),
            )

            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            try:
                stdout, _ = await asyncio.wait_for(
                    process.communicate(), timeout=timeout_sec
                )
            except asyncio.TimeoutError as err:
                partial_log = ""
                if process is not None:
                    if process.returncode is None:
                        try:
                            process.kill()
                        except ProcessLookupError:
                            pass
                        await process.wait()
                    if process.stdout is not None:
                        try:
                            raw_partial = await process.stdout.read()
                            if isinstance(raw_partial, (bytes, bytearray)):
                                partial_log = raw_partial.decode(
                                    "utf-8", errors="replace"
                                )
                        except Exception:  # noqa: BLE001
                            pass
                reason = (
                    f"UVM Batch Simulation timed out after {timeout_sec}s "
                    f"({len(resolved_entries)} ELFs, sim={cmd[0]})"
                )
                raise RuntimeError(
                    self._dump_sim_log(
                        partial_log
                        or f"Process timed out running: {' '.join(cmd)}\n",
                        reason=reason,
                    )
                ) from err

            stdout_str = stdout.decode("utf-8", errors="replace")
            if verbose:
                print(stdout_str, flush=True)
            self._parse_uvm_logs(stdout_str, returncode=process.returncode)

            total = len(resolved_entries)
            summary_marker = f"REGRESSION COMPLETE. Passed: {total}/{total}"
            if summary_marker not in stdout_str:
                raise RuntimeError(
                    self._dump_sim_log(
                        stdout_str,
                        reason=(
                            f"UVM batch regression did not report "
                            f"'{summary_marker}'."
                        ),
                    )
                )

            for _, _, _, elf_name in resolved_entries:
                block_match = re.search(
                    rf"--- STARTING TEST: {re.escape(elf_name)} ---"
                    r"(.*?)"
                    rf"--- FINISHED TEST: {re.escape(elf_name)} ---",
                    stdout_str,
                    re.DOTALL,
                )
                if not block_match:
                    raise RuntimeError(
                        self._dump_sim_log(
                            stdout_str,
                            reason=
                            f"Missing execution block for {elf_name} in UVM batch log.",
                        )
                    )
                block = block_match.group(1)
                if "tohost write detected" not in block:
                    raise RuntimeError(
                        self._dump_sim_log(
                            stdout_str,
                            reason=
                            f"{elf_name}: expected tohost == 1, but no tohost write was detected.",
                        )
                    )
                if "** UVM TEST PASSED **" not in block:
                    raise RuntimeError(
                        self._dump_sim_log(
                            stdout_str,
                            reason=
                            f"{elf_name}: did not report UVM TEST PASSED.",
                        )
                    )

            return True
        finally:
            if process is not None and process.returncode is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                await process.wait()

            if reg_list_file and os.path.exists(reg_list_file):
                try:
                    os.remove(reg_list_file)
                except OSError:
                    pass
