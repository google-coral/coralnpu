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
"""Utility functions for parsing ELF files."""

from elftools.elf.elffile import ELFFile


class SymbolInfo:
    """Holds information about a symbol in an ELF file."""

    def __init__(self, addr, size):
        self.addr = addr
        self.size = size


def parse_elf(elf_path, symbol_names=None):
    """Parses an ELF file to find the entry point and requested symbols.

    Args:
        elf_path: Path to the ELF file.
        symbol_names: A list of symbol names to look up.

    Returns:
        A tuple: (entry_point, symbol_map)
        where symbol_map is a dict of {symbol_name: SymbolInfo}.
        If a symbol is not found, it will not be in the map.
    """
    symbol_names = symbol_names or []
    symbol_map = {}
    with open(elf_path, "rb") as f:
        elf = ELFFile(f)
        entry_point = elf.header["e_entry"]

        if symbol_names:
            symtab = elf.get_section_by_name(".symtab")
            if symtab:
                for name in symbol_names:
                    syms = symtab.get_symbol_by_name(name)
                    if syms:
                        sym = syms[0]
                        symbol_map[name] = SymbolInfo(
                            sym.entry["st_value"], sym.entry["st_size"]
                        )
    return entry_point, symbol_map
