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
"""High-level test fixture wrapping the MPACT CoralNPUV2Simulator."""

from __future__ import annotations

import os
import struct
import numpy as np

from coralnpu_v2_sim_utils import CoralNPUV2Simulator
from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.sim_backends.common_utils import (
    infer_read_size_bytes,
    parse_elf_symbols,
    reconstruct_read_data,
    resolve_runfile_path,
    to_uint8_array,
)


class MpactNpuSimTestFixture(BaseCoralNPUFixture):
    """High-level test fixture wrapping MPACT CoralNPUV2Simulator."""

    def __init__(
        self,
        highmem: bool = True,
        exit_on_ebreak: bool = True,
        semihost_htif: bool = True,
        sim: CoralNPUV2Simulator | None = None,
    ):
        super().__init__()
        self._highmem = highmem
        self._exit_on_ebreak = exit_on_ebreak
        self._semihost_htif = semihost_htif
        self._injected_sim = sim is not None
        self._program_loaded = False
        self.sim = sim or CoralNPUV2Simulator(
            highmem_ld=highmem,
            exit_on_ebreak=exit_on_ebreak,
            semihost_htif=semihost_htif,
        )

    @classmethod
    async def Create(
        cls,
        highmem: bool = True,
        exit_on_ebreak: bool = True,
        semihost_htif: bool = True,
        **_kwargs,
    ) -> MpactNpuSimTestFixture:
        return cls(
            highmem=highmem,
            exit_on_ebreak=exit_on_ebreak,
            semihost_htif=semihost_htif,
        )

    async def load_elf_and_lookup_symbols(
        self,
        elf_path: str | os.PathLike,
        symbols: list[str] | None = None,
        optional: bool = False,
        optional_symbols: list[str] | None = None,
    ) -> dict[str, int]:
        if self._program_loaded and not self._injected_sim:
            self.sim = CoralNPUV2Simulator(
                highmem_ld=self._highmem,
                exit_on_ebreak=self._exit_on_ebreak,
                semihost_htif=self._semihost_htif,
            )
        resolved = resolve_runfile_path(elf_path)
        self.entry_point, self.symbols, self.symbol_sizes = parse_elf_symbols(
            resolved,
            symbols=symbols,
            optional_symbols=optional_symbols,
            strict=not optional,
        )
        self.sim.load_program(resolved, self.entry_point)
        self._program_loaded = True
        self.cycle_count = None
        return self.symbols

    async def write(
        self,
        symbol: str | int,
        data: np.ndarray | bytes | bytearray | int | np.integer,
        offset: int = 0,
    ):
        addr = self.resolve_address(symbol, offset=offset)
        self.sim.write_memory(addr, to_uint8_array(data))

    async def write_word(
        self,
        symbol: str | int,
        data: int | np.integer,
        offset: int = 0,
    ):
        addr = self.resolve_address(symbol, offset=offset)
        self.sim.write_word(addr, np.uint32(int(data) & 0xFFFFFFFF))

    async def write_ptr(
        self, addr_symbol: str, data_symbol: str, offset: int = 0
    ):
        self.sim.write_ptr(
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
    ) -> np.ndarray:
        addr = self.resolve_address(symbol, offset=offset)
        nbytes = infer_read_size_bytes(
            symbol, self.symbol_sizes, size=size, dtype=dtype, shape=shape
        )
        raw_arr = self.sim.read_memory(addr, nbytes)
        return reconstruct_read_data(raw_arr, dtype=dtype, shape=shape)

    async def read_word(self, symbol: str | int, offset: int = 0) -> int:
        addr = self.resolve_address(symbol, offset=offset)
        raw_arr = self.sim.read_memory(addr, 4)
        return struct.unpack("<I", raw_arr.tobytes())[0]

    async def run_to_halt(
        self,
        timeout_sec: float = 60.0,
        timeout_cycles: int | None = None,
    ) -> int:
        del timeout_sec
        start_cycles = self.sim.get_cycle_count() or 0
        if self.entry_point is not None:
            self.sim.write_register("pc", self.entry_point)
        if timeout_cycles is not None:
            total_cycles = 0
            step_size = min(1_000_000, max(1, timeout_cycles))
            while total_cycles < timeout_cycles:
                batch = min(step_size, timeout_cycles - total_cycles)
                actual_steps = self.sim.step(batch)
                if actual_steps < 0:
                    raise RuntimeError("MPACT simulator step() failed")
                total_cycles += actual_steps
                if actual_steps < batch:
                    delta = (self.sim.get_cycle_count() or 0) - start_cycles
                    self.cycle_count = (delta if delta > 0 else total_cycles)
                    return self.cycle_count
            raise TimeoutError(
                f"MPACT simulation exceeded timeout of {timeout_cycles} cycles"
            )
        self.sim.run()
        self.sim.wait()
        delta = (self.sim.get_cycle_count() or 0) - start_cycles
        self.cycle_count = (delta if delta > 0 else self.sim.get_cycle_count())
        return self.cycle_count

    def get_cycle_count(self) -> int | None:
        if self.cycle_count is not None:
            return self.cycle_count
        return self.sim.get_cycle_count()
