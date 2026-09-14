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
import io
import logging
import os
import re
import struct
import subprocess
import tempfile
from bazel_tools.tools.python.runfiles import runfiles

import numpy as np
from elftools.elf.elffile import ELFFile

logger = logging.getLogger(__name__)


class UvmTestFixture:
    """Orchestrates UVM batch simulation via a subprocess."""

    _runfiles = None

    @classmethod
    def get_runfiles(cls):
        if cls._runfiles is None:
            try:
                cls._runfiles = runfiles.Create()
            except Exception:  # noqa: BLE001
                cls._runfiles = None
        return cls._runfiles

    @classmethod
    def resolve_path(cls, relative_path: str | os.PathLike) -> str:
        """Resolves a filesystem or Bazel runfile path."""
        if not relative_path:
            return ""
        path_str = os.fspath(relative_path)
        if os.path.isabs(path_str) and os.path.exists(path_str):
            return path_str

        r = cls.get_runfiles()
        if r:
            for candidate in (
                    path_str if path_str.startswith("coralnpu_hw/") else
                    f"coralnpu_hw/{path_str}",
                    path_str,
            ):
                resolved = r.Rlocation(candidate)
                if resolved and os.path.exists(resolved):
                    return resolved

        return path_str

    def __init__(
        self,
        simulator: str = "verilator",
        enable_spike_cosim: bool = True,
        sim_binary_path: str | None = None,
    ):
        self.simulator = simulator
        self.enable_spike_cosim = enable_spike_cosim
        self.sim_binary_path = sim_binary_path

        self.elf_path: str | None = None
        self.symbols: dict[str, int] = {}
        self.entry_point: int = 0
        self.tohost_addr: int = 0
        self.staged_memory: dict[int, bytes] = {}
        self.dumped_memory: list[tuple[int, bytes]] = []

        self.cycle_count: int | None = None
        self.test_passed: bool = False

    @classmethod
    async def Create(
        cls,
        simulator: str = "verilator",
        enable_spike_cosim: bool = True,
        sim_binary_path: str | None = None,
        **kwargs,
    ) -> UvmTestFixture:
        """Factory method to instantiate the fixture."""
        return cls(simulator, enable_spike_cosim, sim_binary_path)

    async def load_elf_and_lookup_symbols(
        self,
        elf_path: str | os.PathLike,
        symbols: list[str] | None = None,
        optional_symbols: list[str] | None = None,
    ) -> dict[str, int]:
        """Parses the ELF binary, resets state, and resolves symbol addresses."""
        resolved = self.resolve_path(elf_path)
        if not os.path.exists(resolved):
            raise FileNotFoundError(
                f"ELF file not found: {elf_path} (resolved: {resolved})"
            )

        self.elf_path = resolved
        self.tohost_addr = 0
        self.symbols.clear()
        self.staged_memory.clear()
        self.dumped_memory.clear()
        self.cycle_count = None
        self.test_passed = False

        with open(self.elf_path, "rb") as f:
            elf = ELFFile(f)
            self.entry_point = elf.header["e_entry"]
            symtab = elf.get_section_by_name(".symtab")
            all_symbols = ({
                s.name: s["st_value"]
                for s in symtab.iter_symbols()
            } if symtab else {})

        if "tohost" in all_symbols:
            self.tohost_addr = all_symbols["tohost"]
            self.symbols["tohost"] = self.tohost_addr
        else:
            logger.warning(
                "tohost symbol not found. Required for UVM status tracking."
            )

        for name in symbols or []:
            if name not in all_symbols:
                raise ValueError(f"Required symbol '{name}' not found in ELF.")
            self.symbols[name] = all_symbols[name]

        for name in optional_symbols or []:
            if name in all_symbols:
                self.symbols[name] = all_symbols[name]

        return self.symbols

    def _resolve_address(self, symbol: str | int, offset: int = 0) -> int:
        if isinstance(symbol, str):
            if symbol not in self.symbols:
                raise ValueError(
                    f"Symbol '{symbol}' not resolved. Pass it to load_elf_and_lookup_symbols."
                )
            return self.symbols[symbol] + offset
        return symbol + offset

    async def write(
        self,
        symbol: str | int,
        data: np.ndarray | bytes | bytearray | int | np.integer,
        offset: int = 0,
    ):
        """Stages data (scalar integer, NumPy array, or bytes) in host memory to be patched into the ELF before simulation."""
        addr = self._resolve_address(symbol, offset=offset)

        if isinstance(data, (int, np.integer)) and not isinstance(data, bool):
            byte_data = struct.pack("<I", int(data) & 0xFFFFFFFF)
        elif isinstance(data, np.ndarray):
            byte_data = data.tobytes()
        elif isinstance(data, (bytes, bytearray)):
            byte_data = bytes(data)
        else:
            raise TypeError(f"Unsupported data type for write: {type(data)}")

        self.staged_memory[addr] = byte_data

    async def write_word(
        self, symbol: str | int, data: int | np.integer, offset: int = 0
    ):
        """Stages a single 32-bit scalar word."""
        addr = self._resolve_address(symbol, offset=offset)
        self.staged_memory[addr] = struct.pack("<I", int(data) & 0xFFFFFFFF)

    async def write_ptr(
        self, addr_symbol: str, data_symbol: str, offset: int = 0
    ):
        """Stages the resolved address of data_symbol into addr_symbol."""
        await self.write_word(
            addr_symbol, self._resolve_address(data_symbol, offset)
        )

    def _read_bytes_from_dump(self, addr: int, size: int) -> bytes:
        """Reads a byte sequence from dumped memory blocks."""
        for base, data in self.dumped_memory:
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
        size_bytes: int | None = None,
    ) -> bytes | np.ndarray:
        """Reads memory post-simulation from the SRAM memory dump."""
        actual_size = size if size is not None else size_bytes
        addr = self._resolve_address(symbol, offset=offset)

        if shape is not None and dtype is not None:
            dtype = np.dtype(dtype)
            total_bytes = int(np.prod(shape)) * dtype.itemsize
            raw_bytes = self._read_bytes_from_dump(addr, total_bytes)
            return np.frombuffer(raw_bytes, dtype=dtype).reshape(shape)

        if actual_size is not None:
            return self._read_bytes_from_dump(addr, actual_size)

        raise ValueError(
            "Either size or both shape and dtype must be specified for read."
        )

    async def read_word(self, symbol: str | int, offset: int = 0) -> int:
        """Reads a single 32-bit scalar word from dumped memory."""
        addr = self._resolve_address(symbol, offset=offset)
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
                        base, size, len(data)
                    )
                    break
                self.dumped_memory.append((base, data))

    def _get_simulator_binary(self) -> str:
        if self.sim_binary_path:
            return self.resolve_path(self.sim_binary_path)
        return self.resolve_path(f"tests/uvm/uvm_sim_{self.simulator}")

    async def run_to_halt(self, timeout_sec: float = 60.0) -> bool:
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
                raise RuntimeError(
                    f"UVM Simulation timed out after {timeout_sec}s"
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

        # 4. Extract simulated cycle count
        cycle_match = re.search(
            r"(?:cycle count|cycles)\s*[:=]\s*(\d+)", log_output, re.IGNORECASE
        )
        if cycle_match:
            self.cycle_count = int(cycle_match.group(1))

    def get_cycle_count(self) -> int | None:
        """Returns the simulated cycle count if available."""
        return self.cycle_count
