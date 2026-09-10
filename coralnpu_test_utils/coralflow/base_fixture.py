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
"""Base fixture interface and types for CoralFlow unified test orchestration."""

from __future__ import annotations

import os
from typing import Protocol
import numpy as np


class BaseCoralNPUFixture(Protocol):
    """Common asynchronous test fixture protocol for CoralNPU backends."""

    async def load_elf_and_lookup_symbols(
        self,
        elf_path: str | os.PathLike,
        symbols: list[str] | None = None,
        optional: bool = False,
        optional_symbols: list[str] | None = None,
    ) -> dict[str, int]:
        """Loads an ELF binary and resolves addresses for required and optional symbols."""
        ...

    async def write(
        self,
        symbol: str | int,
        data: int | bytes | np.ndarray,
        offset: int = 0,
    ) -> None:
        """Writes data (scalar int, raw bytes, or NumPy array) to the symbol's memory address."""
        ...

    async def write_word(
        self, symbol: str | int, data: int, offset: int = 0
    ) -> None:
        """Writes a 32-bit unsigned word to the symbol's address + offset."""
        ...

    async def write_ptr(
        self,
        addr_symbol: str,
        data_symbol: str,
        offset: int = 0,
    ) -> None:
        """Writes the pointer address of data_symbol (plus offset) into addr_symbol."""
        ...

    async def read(
        self,
        symbol: str | int,
        size: int | None = None,
        dtype: np.dtype | type | None = None,
        shape: tuple[int, ...] | None = None,
        offset: int = 0,
    ) -> bytes | np.ndarray:
        """Reads data from the symbol's address, optionally decoding into a shaped NumPy array."""
        ...

    async def read_word(self, symbol: str | int, offset: int = 0) -> int:
        """Reads a 32-bit unsigned word from symbol's address + offset."""
        ...

    async def run_to_halt(
        self,
        timeout_sec: float = 60.0,
        timeout_cycles: int | None = None,
    ) -> int | bool:
        """Executes the loaded program until completion or timeout."""
        ...

    def get_cycle_count(self) -> int | None:
        """Returns the total elapsed cycle count, or None if unavailable."""
        ...
