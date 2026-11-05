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
import atexit
import logging
import os
import re
import select
import shutil
import struct
import subprocess
import tempfile
import time

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


def _env_flag(name: str, default: bool = False) -> bool:
    val = os.environ.get(name, "").strip()
    if not val:
        return default
    return val.lower() in ("1", "true", "yes", "on")


class _PersistentUvmWorker:
    """Manages a persistent UVM simulator subprocess fed via a POSIX FIFO."""

    def __init__(
        self,
        sim_binary: str,
        verbose: bool = False,
        lsu_mem_check: bool = True,
    ):
        self.sim_binary = sim_binary
        self.verbose = verbose
        self.lsu_mem_check = lsu_mem_check
        self.temp_dir: str | None = None
        self.fifo_path: str | None = None
        self.fifo_r_fd: int | None = None
        self.fifo_w_fd: int | None = None
        self.process: subprocess.Popen[bytes] | None = None
        self.run_counter: int = 0

    def _start(self, initial_elf: str) -> None:
        self.close()
        self.temp_dir = tempfile.mkdtemp(prefix="uvm_worker_")
        self.fifo_path = os.path.join(self.temp_dir, "cmd.fifo")
        os.mkfifo(self.fifo_path)
        self.fifo_r_fd = os.open(self.fifo_path, os.O_RDONLY | os.O_NONBLOCK)
        self.fifo_w_fd = os.open(self.fifo_path, os.O_WRONLY)

        cmd = [
            self.sim_binary,
            f"+TEST_ELF={os.path.abspath(initial_elf)}",
            "+UVM_TESTNAME=coralnpu_regression_test",
            f"+REGRESSION_LIST={self.fifo_path}",
            f"+COSIM_LSU_MEM_CHECK={1 if self.lsu_mem_check else 0}",
        ]
        if self.verbose:
            cmd.append("+COSIM_TRACE_LOG")

        logger.info(
            "Starting persistent UVM Simulator worker: %s", " ".join(cmd)
        )
        self.process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        assert self.process.stdout is not None
        os.set_blocking(self.process.stdout.fileno(), False)

    def run_test(
        self,
        elf_path: str,
        entry_point: int,
        tohost_addr: int,
        timeout_sec: float,
        timeout_cycles: int | None,
        halt_on_wfi: bool,
        patch_file: str | None,
        dump_file: str | None,
    ) -> tuple[str, int]:
        if self.process is None or self.process.poll() is not None:
            self._start(elf_path)

        assert self.process is not None
        assert self.process.stdout is not None
        assert self.fifo_w_fd is not None

        self.run_counter += 1
        target_id = f"run_{self.run_counter}_{os.path.basename(elf_path)}"
        timeout_ns = (
            int(timeout_cycles) *
            10 if timeout_cycles is not None else 20_000_000
        )
        halt_flag = 1 if halt_on_wfi else 0
        patch_arg = os.path.abspath(patch_file) if patch_file else "NONE"
        dump_arg = os.path.abspath(dump_file) if dump_file else "NONE"

        cmd_line = (
            f"{os.path.abspath(elf_path)} {tohost_addr:08x} {entry_point:08x} "
            f"{timeout_ns} SPIKE {target_id} {halt_flag} {patch_arg} {dump_arg}\n"
        )
        os.write(self.fifo_w_fd, cmd_line.encode("utf-8"))

        start_marker = f"--- STARTING TEST: {target_id} ---"
        finish_marker = f"--- FINISHED TEST: {target_id} ---"
        stdout_fd = self.process.stdout.fileno()
        poller = select.poll()
        poller.register(
            stdout_fd, select.POLLIN | select.POLLHUP | select.POLLERR
        )

        deadline = time.monotonic() + timeout_sec
        chunks: list[bytes] = []
        decoded_so_far = ""

        while True:
            remaining_ms = int((deadline - time.monotonic()) * 1000)
            if remaining_ms <= 0:
                self.close()
                raise TimeoutError(decoded_so_far)

            events = poller.poll(min(remaining_ms, 1000))
            if not events:
                if self.process.poll() is not None:
                    returncode = self.process.returncode or 1
                    self.close()
                    return decoded_so_far, returncode
                continue

            try:
                data = os.read(stdout_fd, 65536)
            except BlockingIOError:
                continue

            if not data:
                returncode = self.process.wait()
                self.close()
                return decoded_so_far, returncode

            chunks.append(data)
            decoded_so_far = b"".join(chunks).decode("utf-8", errors="replace")

            if self.fifo_r_fd is not None and start_marker in decoded_so_far:
                try:
                    os.close(self.fifo_r_fd)
                except OSError:
                    pass
                self.fifo_r_fd = None

            if finish_marker in decoded_so_far:
                start_idx = decoded_so_far.find(start_marker)
                if start_idx != -1 and self.run_counter > 1:
                    return decoded_so_far[start_idx:], 0
                return decoded_so_far, 0

    def close(self) -> None:
        if self.fifo_w_fd is not None:
            try:
                os.write(self.fifo_w_fd, b"QUIT\n")
            except OSError:
                pass
            try:
                os.close(self.fifo_w_fd)
            except OSError:
                pass
            self.fifo_w_fd = None

        if self.fifo_r_fd is not None:
            try:
                os.close(self.fifo_r_fd)
            except OSError:
                pass
            self.fifo_r_fd = None

        if self.process is not None:
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    try:
                        self.process.kill()
                    except OSError:
                        pass
                    self.process.wait()
            if self.process.stdout is not None:
                try:
                    self.process.stdout.close()
                except OSError:
                    pass
            self.process = None

        if self.temp_dir and os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir, ignore_errors=True)
            self.temp_dir = None
            self.fifo_path = None


_ACTIVE_WORKERS: dict[tuple[str, bool, bool], _PersistentUvmWorker] = {}


def _shutdown_all_workers() -> None:
    for worker in list(_ACTIVE_WORKERS.values()):
        worker.close()
    _ACTIVE_WORKERS.clear()


atexit.register(_shutdown_all_workers)


class UvmTestFixture(BaseCoralNPUFixture):
    """Orchestrates UVM batch simulation via a subprocess."""

    def __init__(
        self,
        simulator: str = "verilator",
        sim_binary_path: str | None = None,
        lsu_mem_check: bool | None = None,
    ):
        super().__init__()
        self.simulator = simulator
        self.sim_binary_path = sim_binary_path
        self.lsu_mem_check = lsu_mem_check

        self.elf_path: str | None = None
        self.entry_point: int = 0
        self.tohost_addr: int = 0
        self.staged_memory: dict[int, bytes] = {}
        self.dumped_memory: list[tuple[int, bytes]] = []
        self.test_passed: bool = False
        self.faulted: bool = False

    @classmethod
    async def Create(
        cls,
        simulator: str = "verilator",
        sim_binary_path: str | None = None,
        lsu_mem_check: bool | None = None,
        **_kwargs,
    ) -> UvmTestFixture:
        """Factory method to instantiate the fixture."""
        return cls(simulator, sim_binary_path, lsu_mem_check=lsu_mem_check)

    def _is_lsu_mem_check_enabled(self) -> bool:
        if self.lsu_mem_check is not None:
            return bool(self.lsu_mem_check)
        return _env_flag("CORALFLOW_LSU_MEM_CHECK", default=True)

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
        self.faulted = False

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

        raw_blocks: list[tuple[int, bytes]] = []
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
                raw_blocks.append((base, data))

        for base, data in sorted(raw_blocks, key=lambda x: x[0]):
            if (self.dumped_memory and self.dumped_memory[-1][0] +
                    len(self.dumped_memory[-1][1]) == base):
                prev_base, prev_data = self.dumped_memory[-1]
                self.dumped_memory[-1] = (prev_base, prev_data + data)
            else:
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
        halt_on_wfi: bool = False,
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

            verbose = _env_flag("CORALFLOW_VERBOSE", default=False)
            lsu_mem_check = self._is_lsu_mem_check_enabled()
            sim_binary = self._get_simulator_binary()
            if timeout_cycles is not None:
                timeout_sec = max(timeout_sec, 300.0)

            use_oneshot = (
                hasattr(asyncio.create_subprocess_exec, "_mock_name")
                or os.environ.get("CORALFLOW_UVM_ONESHOT", "").strip() == "1"
            )
            if not use_oneshot:
                key = (sim_binary, verbose, lsu_mem_check)
                worker = _ACTIVE_WORKERS.get(key)
                if worker is None:
                    worker = _PersistentUvmWorker(
                        sim_binary,
                        verbose=verbose,
                        lsu_mem_check=lsu_mem_check,
                    )
                    _ACTIVE_WORKERS[key] = worker
                try:
                    stdout_str, returncode = worker.run_test(
                        elf_path=self.elf_path,
                        entry_point=self.entry_point,
                        tohost_addr=self.tohost_addr,
                        timeout_sec=timeout_sec,
                        timeout_cycles=timeout_cycles,
                        halt_on_wfi=halt_on_wfi,
                        patch_file=patch_file,
                        dump_file=dump_file,
                    )
                except TimeoutError as err:
                    partial_log = str(err)
                    reason = (
                        f"UVM Simulation timed out after {timeout_sec}s "
                        f"(elf={self.elf_path}, sim={sim_binary})"
                    )
                    raise RuntimeError(
                        self._dump_sim_log(
                            partial_log
                            or f"Process timed out running: {self.elf_path}\n",
                            reason=reason,
                        )
                    ) from err

                if verbose:
                    print(stdout_str, flush=True)
                try:
                    self._parse_uvm_logs(stdout_str, returncode=returncode)
                except Exception:
                    worker.close()
                    raise

                if self.test_passed:
                    self._load_dump_file(dump_file)
                return self.test_passed

            cmd = [
                sim_binary,
                f"+TEST_ELF={self.elf_path}",
                f"+ENTRY_POINT=0x{self.entry_point:08x}",
                f"+TOHOST_ADDR=0x{self.tohost_addr:08x}",
                "+UVM_TESTNAME=coralnpu_base_test",
                f"+MEM_DUMP={dump_file}",
            ]
            if halt_on_wfi:
                cmd.append("+HALT_ON_WFI=1")
            if timeout_cycles is not None:
                cmd.append(f"+TEST_TIMEOUT={int(timeout_cycles) * 10}")
            if patch_file:
                cmd.append(f"+MEM_PATCH={patch_file}")
                if verbose:
                    patch_summary = ", ".join(
                        f"0x{addr:08x} ({len(data)}B)"
                        for addr, data in self.staged_memory.items()
                    )
                    logger.info(
                        "Staged +MEM_PATCH regions: [%s] -> %s",
                        patch_summary,
                        patch_file,
                    )
            cmd.append(f"+COSIM_LSU_MEM_CHECK={1 if lsu_mem_check else 0}")
            if verbose:
                cmd.append("+COSIM_TRACE_LOG")

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
            if verbose:
                print(stdout_str, flush=True)
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
        self.faulted = "Test ended on DUT fault" in log_output

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

    async def run_to_wfi(
        self,
        timeout_cycles: int = 10000,
    ) -> int | bool:
        """Executes the loaded program until the DUT reaches WFI."""
        return await self.run_to_halt(
            timeout_cycles=timeout_cycles, halt_on_wfi=True
        )

    async def run_to_fault(
        self,
        timeout_cycles: int = 10000,
    ) -> int | bool:
        """Executes the loaded program and asserts that the DUT terminated on a fault."""
        await self.run_to_halt(timeout_cycles=timeout_cycles)
        if not self.faulted:
            raise RuntimeError(
                f"Expected DUT fault, but simulation ended without faulting (elf={self.elf_path})."
            )
        return self.get_cycle_count() or True

    def fault(self) -> bool:
        """Returns True if the DUT faulted during the last UVM simulation run."""
        return self.faulted

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

        resolved_entries: list[tuple[str, int, int, str, bool]] = []
        for elf_path in elf_paths:
            resolved = resolve_runfile_path(elf_path)
            if not os.path.exists(resolved):
                raise FileNotFoundError(
                    f"ELF file not found: {elf_path} (resolved: {resolved})"
                )
            entry_point, symbols, _ = parse_elf_symbols(
                resolved,
                optional_symbols=["tohost", "fromhost"],
                strict=True,
                require_symtab=False,
            )
            tohost_addr = symbols.get("tohost", 0)
            requires_tohost_write = (
                tohost_addr != 0 and "fromhost" not in symbols
            )
            resolved_entries.append((
                os.path.abspath(resolved),
                tohost_addr,
                entry_point,
                os.path.basename(resolved),
                requires_tohost_write,
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
                for (
                        abs_elf,
                        tohost_addr,
                        entry_point,
                        elf_name,
                        _,
                ) in resolved_entries:
                    reg_tmp.write(
                        f"{abs_elf} {tohost_addr:08x} {entry_point:08x} "
                        f"{timeout_ns} {spike_opt} {elf_name}\n"
                    )
                reg_list_file = reg_tmp.name

            verbose = _env_flag("CORALFLOW_VERBOSE", default=False)
            lsu_mem_check = self._is_lsu_mem_check_enabled()
            cmd = [
                self._get_simulator_binary(),
                f"+TEST_ELF={resolved_entries[0][0]}",
                "+UVM_TESTNAME=coralnpu_regression_test",
                f"+REGRESSION_LIST={reg_list_file}",
            ]
            cmd.append(f"+COSIM_LSU_MEM_CHECK={1 if lsu_mem_check else 0}")
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

            for (
                    _,
                    tohost_addr,
                    _,
                    elf_name,
                    requires_tohost_write,
            ) in resolved_entries:
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
                if requires_tohost_write and "tohost write detected" not in block:
                    raise RuntimeError(
                        self._dump_sim_log(
                            stdout_str,
                            reason=
                            f"{elf_name}: expected tohost == 1, but no tohost write was detected.",
                        )
                    )
                if (tohost_addr != 0 and not requires_tohost_write
                        and "tohost write detected" not in block
                        and "mpause instruction received." not in block):
                    raise RuntimeError(
                        self._dump_sim_log(
                            stdout_str,
                            reason=
                            f"{elf_name}: did not write tohost or halt cleanly via mpause.",
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
