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
"""Shared helper utilities across CoralNPU simulation and FPGA backend fixtures."""

from __future__ import annotations

import os
import struct
from typing import Any
from bazel_tools.tools.python.runfiles import runfiles
from elftools.elf.elffile import ELFFile
import numpy as np

AUTO_PROBE_SYMBOLS: tuple[str, ...] = (
    "tohost",
    "fromhost",
    "cycle_count",
    "csr_cycle_count",
    "cycle_count_lo",
    "cycle_count_hi",
    "minstret_val",
)

_RUNFILES_INSTANCE = None


def get_runfiles():
    """Returns a cached Bazel runfiles instance if available."""
    global _RUNFILES_INSTANCE
    if _RUNFILES_INSTANCE is None:
        try:
            _RUNFILES_INSTANCE = runfiles.Create()
        except Exception:  # noqa: BLE001
            _RUNFILES_INSTANCE = None
    return _RUNFILES_INSTANCE


def resolve_runfile_path(path: str | os.PathLike) -> str:
    """Resolves a filesystem or Bazel runfile path, supporting TEST_XLEN=64 and coralnpu_hw/ prefixes."""
    if not path:
        return ""
    path_str = os.fspath(path)
    xlen = os.environ.get("TEST_XLEN", "32")
    r = get_runfiles()

    def _try_resolve(p: str) -> str | None:
        if os.path.exists(p):
            return p
        if r:
            for candidate in (
                    p if p.startswith("coralnpu_hw/") else f"coralnpu_hw/{p}",
                    p,
            ):
                loc = r.Rlocation(candidate)
                if loc and os.path.exists(loc):
                    return loc
        return None

    if xlen == "64":
        for ext in (".elf", ".bin", ".vmem"):
            if path_str.endswith(ext) and not path_str.endswith(f"_64{ext}"):
                resolved_64 = _try_resolve(path_str[:-len(ext)] + f"_64{ext}")
                if resolved_64:
                    return resolved_64

    resolved = _try_resolve(path_str)
    if resolved:
        return resolved

    if r:
        loc = r.Rlocation(path_str)
        if loc:
            return loc
    return path_str


def parse_elf_symbols(
    elf_path: str | os.PathLike,
    symbols: list[str] | None = None,
    optional_symbols: list[str] | None = None,
    strict: bool = True,
    require_symtab: bool = False,
) -> tuple[int, dict[str, int], dict[str, int]]:
    """Extracts (entry_point, symbols_dict, symbol_sizes_dict) from an ELF file."""
    resolved = resolve_runfile_path(elf_path)
    if not os.path.exists(resolved):
        raise FileNotFoundError(
            f"ELF file not found: {elf_path} (resolved: {resolved})"
        )

    all_syms: dict[str, tuple[int, int]] = {}
    with open(resolved, "rb") as f:
        elf = ELFFile(f)
        entry_point = int(elf.header["e_entry"])
        symtab = next(elf.iter_sections(type="SHT_SYMTAB"), None)
        if symtab is None:
            symtab = elf.get_section_by_name(".symtab")
        if symtab is None and require_symtab:
            raise ValueError(f"No symbol table (.symtab) found in {elf_path}")

        if symtab is not None:
            for s in symtab.iter_symbols():
                # Preserve first-match precedence matching get_symbol_by_name()[0]
                if s.name and s.name not in all_syms:
                    all_syms[s.name] = (int(s["st_value"]), int(s["st_size"]))

    resolved_addrs: dict[str, int] = {}
    resolved_sizes: dict[str, int] = {}

    # Tier 1: Requested workload symbols
    for sym in symbols or []:
        if sym in all_syms:
            resolved_addrs[sym], resolved_sizes[sym] = all_syms[sym]
        elif strict:
            raise ValueError(
                f"Required symbol '{sym}' not found in {elf_path}. "
                f"Pass optional=True or optional_symbols=['{sym}'] if simulator-specific."
            )

    # Tier 2 & Tier 3: Optional caller symbols + Auto-probed simulator metadata symbols
    for sym in list(optional_symbols or []) + list(AUTO_PROBE_SYMBOLS):
        if sym in all_syms and sym not in resolved_addrs:
            resolved_addrs[sym], resolved_sizes[sym] = all_syms[sym]

    return entry_point, resolved_addrs, resolved_sizes


def resolve_symbol_address(
    addr_or_symbol: int | str,
    symbols: dict[str, int],
    offset: int = 0
) -> int:
    """Resolves a symbol name or integer address plus byte offset."""
    if isinstance(addr_or_symbol, int):
        return addr_or_symbol + offset
    if addr_or_symbol in symbols and symbols[addr_or_symbol] is not None:
        return symbols[addr_or_symbol] + offset
    raise ValueError(
        f"Symbol '{addr_or_symbol}' not found in resolved symbol table: {sorted(symbols.keys())}"
    )


def to_uint8_array(
    data: np.ndarray | bytes | bytearray | int | np.integer
) -> np.ndarray:
    """Normalizes scalar int, bytes, or ndarray into a contiguous 1D np.uint8 array."""
    if isinstance(data, np.integer):
        return np.ascontiguousarray(data).view(np.uint8).ravel()
    if isinstance(data, int) and not isinstance(data, bool):
        return np.frombuffer(
            struct.pack("<I",
                        int(data) & 0xFFFFFFFF), dtype=np.uint8
        )
    if isinstance(data, (bytes, bytearray)):
        return np.frombuffer(bytes(data), dtype=np.uint8)
    if isinstance(data, np.ndarray):
        return np.ascontiguousarray(data).view(np.uint8).ravel()
    raise TypeError(f"Unsupported data type for memory write: {type(data)}")


def infer_read_size_bytes(
    symbol: int | str,
    symbol_sizes: dict[str, int],
    size: int | None = None,
    size_bytes: int | None = None,
    dtype: Any = None,
    shape: tuple[int, ...] | None = None,
) -> int:
    """Infers byte length to read from explicit size, (dtype, shape), or ELF st_size."""
    actual = size if size is not None else size_bytes
    if actual is not None:
        return int(actual)
    if dtype is not None and shape is not None:
        return int(np.prod(shape)) * np.dtype(dtype).itemsize
    if (isinstance(symbol, str) and symbol in symbol_sizes
            and symbol_sizes[symbol] > 0):
        return symbol_sizes[symbol]
    if dtype is not None:
        return np.dtype(dtype).itemsize
    raise ValueError(
        f"Cannot infer read size for '{symbol}'. Specify size, size_bytes, or (dtype and shape)."
    )


def reconstruct_read_data(
    raw_bytes: bytes | np.ndarray,
    dtype: Any = None,
    shape: tuple[int, ...] | None = None,
) -> np.ndarray:
    """Views and reshapes a uint8 array/bytes buffer into the target dtype and shape."""
    arr = (
        np.frombuffer(raw_bytes, dtype=np.uint8)
        if isinstance(raw_bytes, (bytes, bytearray)) else
        np.ascontiguousarray(raw_bytes, dtype=np.uint8)
    )
    if dtype is not None:
        arr = arr.view(dtype=np.dtype(dtype))
    if shape is not None:
        arr = arr.reshape(shape)
    return arr


class WordResult(int):
    """32-bit unsigned int return type for read_word() that also supports legacy .view() and .tobytes()."""

    def tobytes(self) -> bytes:
        return struct.pack("<I", int(self) & 0xFFFFFFFF)

    def view(self, dtype: Any = np.uint32) -> np.ndarray:
        return np.frombuffer(self.tobytes(), dtype=dtype)

    def __bytes__(self) -> bytes:
        return self.tobytes()


class BytesResult(bytes):
    """Bytes return type for read(dtype=None) that also supports .view() and .tobytes()."""

    def tobytes(self) -> bytes:
        return bytes(self)

    def view(self, dtype: Any = np.uint8) -> np.ndarray:
        return np.frombuffer(self, dtype=dtype)
