#!/usr/bin/env python3
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
"""Unified FPGA Test Orchestrator for CoralNPU hardware."""

from __future__ import annotations

import os
from typing import Optional, Tuple, Union

import numpy as np

from coralnpu_test_utils.ftdi_spi_master import FtdiSpiMaster
from coralnpu_test_utils.sim_backends.common_utils import (
    BytesResult,
    WordResult,
    get_runfiles,
    infer_read_size_bytes,
    parse_elf_symbols,
    reconstruct_read_data,
    resolve_runfile_path,
    resolve_symbol_address,
)


class FpgaTestFixture:
    """Unified Test Fixture for CoralNPU FPGA Hardware (mirrors verilator_test_fixture.VerilatorTestFixture)."""

    get_runfiles = staticmethod(get_runfiles)
    resolve_path = staticmethod(resolve_runfile_path)

    def __init__(
        self,
        usb_serial: str,
        highmem: bool = False,
        ftdi_port: int = 1,
        csr_base_addr: int | None = None,
        auto_recovery: bool = True,
    ):
        self.usb_serial = usb_serial
        self.highmem = highmem
        self.ftdi_port = ftdi_port
        self.auto_recovery = auto_recovery
        self.csr_base_addr = (
            csr_base_addr if csr_base_addr is not None else
            (0x200000 if highmem else 0x30000)
        )
        self.spi_master = FtdiSpiMaster(
            usb_serial=usb_serial,
            ftdi_port=ftdi_port,
            csr_base_addr=self.csr_base_addr,
        )
        self.entry_point: int | None = None
        self.symbols: dict[str, int] = {}
        self.symbol_sizes: dict[str, int] = {}

    @classmethod
    def create(
        cls,
        usb_serial: str,
        highmem: bool = False,
        **kwargs
    ) -> "FpgaTestFixture":
        """Factory method to instantiate the fixture."""
        return cls(usb_serial=usb_serial, highmem=highmem, **kwargs)

    Create = create

    def close(self) -> None:
        if hasattr(self.spi_master, "close"):
            self.spi_master.close()

    def __enter__(self) -> "FpgaTestFixture":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    async def __aenter__(self) -> "FpgaTestFixture":
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def has_symbol(self, symbol: str) -> bool:
        return symbol in self.symbols

    def resolve_address(
        self, addr_or_symbol: Union[int, str], offset: int = 0
    ) -> int:
        """Resolves an integer address or symbol name to an address."""
        return resolve_symbol_address(
            addr_or_symbol, self.symbols, offset=offset
        )

    def check_memory_accessible(
        self,
        addr_or_symbol: Union[int, str],
        pattern: int = 0x5A5A5A5A,
        restore: bool = True,
    ) -> bool:
        """Tests whether a memory address or symbol is read/write accessible via pattern probe."""
        addr = self.resolve_address(addr_or_symbol)
        orig = self.read_word(addr) if restore else None
        try:
            self.write_word(addr, pattern)
            return self.read_word(addr) == pattern
        except Exception:
            return False
        finally:
            if restore and orig is not None:
                try:
                    self.write_word(addr, orig)
                except Exception:
                    pass

    def load_elf_and_lookup_symbols(
        self,
        elf_file: str | os.PathLike,
        symbols: list[str] | None = None,
        optional: bool = False,
        optional_symbols: list[str] | None = None,
        verify: bool = False,
        verify_memory: bool = False,
    ) -> dict[str, int]:
        """Loads ELF binary onto FPGA hardware and resolves requested symbol table entries."""
        resolved_elf = self.resolve_path(elf_file)
        if not os.path.exists(resolved_elf):
            raise FileNotFoundError(f"Could not find ELF file: {elf_file}")

        self.entry_point, self.symbols, self.symbol_sizes = parse_elf_symbols(
            resolved_elf,
            symbols=symbols,
            optional_symbols=optional_symbols,
            strict=not optional,
            require_symtab=True,
        )

        self.spi_master.load_elf(resolved_elf, start_core=False, verify=verify)

        if verify_memory:
            for s, addr in self.symbols.items():
                if not self.check_memory_accessible(addr):
                    raise RuntimeError(
                        f"Memory accessibility check failed for symbol '{s}' at 0x{addr:08x}"
                    )

        return self.symbols

    # SPI throughput constants based on measured FTDI SPI master transfers
    SPI_WRITE_BYTES_PER_SEC: float = 2_000_000.0  # ~2 MB/s write throughput
    SPI_READ_BYTES_PER_SEC: float = 500_000.0  # ~500 kB/s read throughput
    BASE_TRANSFER_TIMEOUT_SEC: float = 10.0  # Base setup/overhead latency
    TRANSFER_SAFETY_MARGIN: float = 2.0  # 2.0x safety factor for bus contention

    @classmethod
    def calculate_transfer_timeout(
        cls,
        size_bytes: int,
        is_read: bool = False,
        base_sec: float = BASE_TRANSFER_TIMEOUT_SEC,
        safety_factor: float = TRANSFER_SAFETY_MARGIN,
    ) -> float:
        """Calculates transfer timeout based on size, direction, and measured SPI throughput."""
        rate = (
            cls.SPI_READ_BYTES_PER_SEC
            if is_read else cls.SPI_WRITE_BYTES_PER_SEC
        )
        return base_sec + (size_bytes / rate) * safety_factor

    @classmethod
    def calculate_write_timeout(cls, size_bytes: int) -> float:
        """Calculates write transfer timeout based on SPI write rate (~2 MB/s)."""
        return cls.calculate_transfer_timeout(size_bytes, is_read=False)

    @classmethod
    def calculate_read_timeout(cls, size_bytes: int) -> float:
        """Calculates read transfer timeout based on SPI read rate (~500 kB/s)."""
        return cls.calculate_transfer_timeout(size_bytes, is_read=True)

    def write(
        self,
        addr_or_symbol: Union[int, str],
        data: Union[bytes, bytearray, np.ndarray, int, np.integer],
        offset: int = 0,
        timeout: Optional[float] = None,
    ):
        """Writes data (scalar integer, NumPy array, or bytes) to memory or a resolved symbol."""
        addr = self.resolve_address(addr_or_symbol, offset=offset)

        if isinstance(data, (int, np.integer)) and not isinstance(data, bool):
            self.spi_master.write_word(addr, int(data) & 0xFFFFFFFF)
        elif isinstance(data, np.ndarray):
            data_bytes = data.tobytes()
            to = (
                timeout if timeout is not None else
                self.calculate_write_timeout(len(data_bytes))
            )
            self.spi_master.load_data(data_bytes, addr, timeout=to)
        elif isinstance(data, (bytes, bytearray)):
            to = (
                timeout if timeout is not None else
                self.calculate_write_timeout(len(data))
            )
            self.spi_master.load_data(bytes(data), addr, timeout=to)
        else:
            raise TypeError(f"Unsupported data type for write: {type(data)}")

    def write_word(
        self,
        addr_or_symbol: Union[int, str],
        value: Union[int, np.integer],
        offset: int = 0,
        signed: bool = False,
    ):
        """Writes a single 32-bit word to memory."""
        del signed
        self.spi_master.write_word(
            self.resolve_address(addr_or_symbol, offset=offset),
            int(value) & 0xFFFFFFFF,
        )

    def write_ptr(self, addr_symbol: str, data_symbol: str, offset: int = 0):
        """Writes the pointer address of data_symbol into addr_symbol."""
        self.write_word(
            addr_symbol, self.resolve_address(data_symbol, offset=offset)
        )

    def read(
        self,
        addr_or_symbol: Union[int, str],
        size_bytes: Optional[int] = None,
        offset: int = 0,
        dtype: Optional[np.dtype] = None,
        shape: Optional[Tuple[int, ...]] = None,
        timeout: Optional[float] = None,
        size: Optional[int] = None,
    ) -> Union[bytes, np.ndarray]:
        """Reads data from memory or a resolved symbol with automatic dtype/shape reconstruction."""
        addr = self.resolve_address(addr_or_symbol, offset=offset)
        try:
            nbytes = infer_read_size_bytes(
                addr_or_symbol,
                self.symbol_sizes,
                size=size,
                size_bytes=size_bytes,
                dtype=dtype,
                shape=shape,
            )
        except ValueError:
            nbytes = 4

        to = (
            timeout
            if timeout is not None else self.calculate_read_timeout(nbytes)
        )
        raw_bytes = self.spi_master.read_data(addr, nbytes, timeout=to)
        if dtype is not None:
            return reconstruct_read_data(raw_bytes, dtype=dtype, shape=shape)
        return BytesResult(raw_bytes)

    def read_word(
        self, addr_or_symbol: Union[int, str], offset: int = 0
    ) -> WordResult:
        """Reads a single 32-bit word from memory."""
        val = self.spi_master.read_word(
            self.resolve_address(addr_or_symbol, offset=offset)
        )
        return WordResult(val)

    def run_to_halt(
        self,
        timeout_sec: float = 60.0,
        timeout_cycles: Optional[int] = None
    ) -> bool:
        """Starts core execution from entry point and polls for halt status."""
        if self.entry_point is None:
            raise ValueError(
                "Entry point is not set. Load an ELF binary first."
            )
        self.spi_master.set_entry_point(self.entry_point)
        self.spi_master.start_core()
        return self.spi_master.poll_for_halt(timeout=timeout_sec)

    def soft_reset(self):
        """Performs a non-destructive soft reset of the CoralNPU core."""
        self.spi_master.soft_reset()

    def reset_hardware(self):
        """Performs a non-destructive soft reset of the CoralNPU core."""
        self.soft_reset()

    def get_cycle_count(self) -> Optional[int]:
        """Reads hardware execution cycle count from resolved cycle counter symbols."""
        for sym in ["cycle_count", "csr_cycle_count"]:
            if sym in self.symbols:
                return int(self.read_word(sym))
        if "cycle_count_hi" in self.symbols and "cycle_count_lo" in self.symbols:
            return (int(self.read_word("cycle_count_hi")) << 32) | int(
                self.read_word("cycle_count_lo")
            )
        return None

    def get_core_frequency_mhz(self) -> int:
        """Retrieves core clock frequency in MHz from FPGA hardware Clock Table register (0x40001000)."""
        try:
            if self.read_word(0x40001000) == 0x434C4B54:  # "CLKT"
                freq = int(self.read_word(0x40001004))
                if 1 <= freq <= 500:
                    return freq
        except Exception:
            pass
        return 50  # Default 50 MHz for Nexus FPGA bitstream

    def get_core_frequency_hz(self) -> int:
        """Retrieves core clock frequency in Hz."""
        return self.get_core_frequency_mhz() * 1_000_000
