# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Interactive Cocotb RTL/Netlist fixture for Verilator and VCS simulations."""

from __future__ import annotations

import os
import struct

import cocotb
import numpy as np

from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface
from coralnpu_test_utils.sim_backends.common_utils import (
    WordResult,
    get_runfiles,
    infer_read_size_bytes,
    parse_elf_symbols,
    reconstruct_read_data,
    resolve_runfile_path,
    resolve_symbol_address,
    to_uint8_array,
)


class VerilatorTestFixture:
    """Interactive Cocotb RTL/Netlist fixture for Verilator and VCS simulations."""

    get_runfiles = staticmethod(get_runfiles)
    resolve_path = staticmethod(resolve_runfile_path)

    def __init__(self, dut, **kwargs):
        self.core_mini_axi = CoreMiniAxiInterface(dut, **kwargs)
        self.entry_point: int | None = None
        self.symbols: dict[str, int] = {}
        self.symbol_sizes: dict[str, int] = {}
        self.cycle_count: int | None = None

    @classmethod
    async def Create(cls, dut, **kwargs) -> VerilatorTestFixture:
        if kwargs.get("highmem"):
            kwargs["csr_base_addr"] = 0x200000
            del kwargs["highmem"]
        inst = cls(dut, **kwargs)
        await inst.core_mini_axi.init()
        await inst.core_mini_axi.reset()
        cocotb.start_soon(inst.core_mini_axi.clock.start())
        return inst

    def has_symbol(self, symbol: str) -> bool:
        return symbol in self.symbols

    def resolve_address(
        self, addr_or_symbol: int | str, offset: int = 0
    ) -> int:
        return resolve_symbol_address(
            addr_or_symbol, self.symbols, offset=offset
        )

    async def load_elf_and_lookup_symbols(
        self,
        path: str | os.PathLike,
        symbols: list[str] | None = None,
        optional: bool = True,
        optional_symbols: list[str] | None = None,
    ) -> dict[str, int]:
        await self.core_mini_axi.reset()
        resolved_path = resolve_runfile_path(path)
        self.entry_point, self.symbols, self.symbol_sizes = parse_elf_symbols(
            resolved_path,
            symbols=symbols,
            optional_symbols=optional_symbols,
            strict=not optional,
        )
        self.cycle_count = None
        with open(resolved_path, "rb") as f:  # noqa: ASYNC230
            self.entry_point = await self.core_mini_axi.load_elf(f)
        return self.symbols

    async def write(
        self,
        symbol: str | int,
        data: np.ndarray | bytes | bytearray | int | np.integer,
        offset: int = 0,
    ):
        addr = self.resolve_address(symbol, offset=offset)
        await self.core_mini_axi.write(addr, to_uint8_array(data))

    async def write_word(
        self,
        symbol: str | int,
        data: int | np.integer,
        offset: int = 0,
        signed: bool = False,
    ):
        del signed
        await self.core_mini_axi.write_word(
            self.resolve_address(symbol, offset=offset),
            int(data) & 0xFFFFFFFF
        )

    async def write_ptr(
        self, addr_symbol: str, data_symbol: str, offset: int = 0
    ):
        await self.core_mini_axi.write_word(
            self.resolve_address(addr_symbol),
            self.resolve_address(data_symbol, offset=offset),
        )

    async def read(
        self,
        symbol: str | int,
        size: int | None = None,
        offset: int = 0,
        dtype: np.dtype | None = None,
        shape: tuple[int, ...] | None = None,
        size_bytes: int | None = None,
    ) -> np.ndarray:
        addr = self.resolve_address(symbol, offset=offset)
        nbytes = infer_read_size_bytes(
            symbol, self.symbol_sizes, size, size_bytes, dtype, shape
        )
        raw_arr = await self.core_mini_axi.read(addr, nbytes)
        return reconstruct_read_data(raw_arr, dtype=dtype, shape=shape)

    async def read_word(
        self, symbol: str | int, offset: int = 0
    ) -> WordResult:
        raw_bytes = await self.core_mini_axi.read_word(
            self.resolve_address(symbol, offset=offset)
        )
        val = struct.unpack(
            "<I",
            np.asarray(raw_bytes, dtype=np.uint8).tobytes()
        )[0]
        return WordResult(val)

    async def run_to_halt(
        self,
        timeout_cycles: int = 10000,
        timeout_sec: float | None = None
    ) -> int:
        await self.core_mini_axi.execute_from(self.entry_point)
        self.cycle_count = await self.core_mini_axi.wait_for_halted(
            timeout_cycles=timeout_cycles
        )
        return self.cycle_count

    async def run_to_fault(self, timeout_cycles: int = 10000) -> int:
        await self.core_mini_axi.execute_from(self.entry_point)
        return await self.core_mini_axi.wait_for_fault(
            timeout_cycles=timeout_cycles
        )

    def fault(self) -> bool:
        return self.core_mini_axi.dut.io_fault.value == 1

    def get_cycle_count(self) -> int | None:
        return self.cycle_count


Fixture = VerilatorTestFixture
