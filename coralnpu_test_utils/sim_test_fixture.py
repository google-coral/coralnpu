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

import os

import cocotb
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface


class Fixture:

    _runfiles = None

    def __init__(self, dut, **kwargs):
        self.core_mini_axi = CoreMiniAxiInterface(dut, **kwargs)
        self.entry_point = None
        self.symbols = {}

    @classmethod
    def get_runfiles(cls):
        if cls._runfiles is None:
            try:
                cls._runfiles = runfiles.Create()
            except Exception:  # noqa: BLE001
                cls._runfiles = None
        return cls._runfiles

    @classmethod
    def resolve_path(cls, path: str | os.PathLike) -> str:
        """Resolves a file or runfile path, supporting 64-bit alternative binaries when TEST_XLEN=64."""
        if not path:
            return path
        path_str = os.fspath(path)
        xlen = os.environ.get("TEST_XLEN", "32")

        r = cls.get_runfiles()

        def _try_resolve(p: str) -> str | None:
            if os.path.exists(p):
                return p
            if r:
                loc = r.Rlocation(p)
                if loc and os.path.exists(loc):
                    return loc
            return None

        if xlen == "64":
            for ext in (".elf", ".bin", ".vmem"):
                if path_str.endswith(ext
                                     ) and not path_str.endswith(f"_64{ext}"):
                    path_64 = path_str[:-len(ext)] + f"_64{ext}"
                    resolved_64 = _try_resolve(path_64)
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

    @classmethod
    async def Create(cls, dut, **kwargs):
        if kwargs.get("highmem"):
            kwargs["csr_base_addr"] = 0x200000
            del kwargs["highmem"]
        inst = cls(dut, **kwargs)
        await inst.core_mini_axi.init()
        await inst.core_mini_axi.reset()
        cocotb.start_soon(inst.core_mini_axi.clock.start())
        return inst

    async def load_elf_and_lookup_symbols(
        self,
        path: str | os.PathLike,
        symbols: list[str],
        optional: bool = False,
        optional_symbols: list[str] | None = None,
    ):
        self.symbols = {}
        await self.core_mini_axi.reset()
        resolved_path = self.resolve_path(path)
        with open(resolved_path, "rb") as f:  # noqa: ASYNC230
            self.entry_point = await self.core_mini_axi.load_elf(f)
            for symbol in symbols:
                try:
                    self.symbols[symbol] = self.core_mini_axi.lookup_symbol(
                        f, symbol
                    )
                except Exception as e:
                    if not optional:
                        raise e
            if optional_symbols:
                for symbol in optional_symbols:
                    try:
                        self.symbols[symbol
                                     ] = self.core_mini_axi.lookup_symbol(
                                         f, symbol
                                     )
                    except Exception:
                        pass

    async def write(self, symbol: str, data):
        await self.core_mini_axi.write(self.symbols[symbol], data)

    async def write_word(self, symbol: str, data):
        await self.core_mini_axi.write_word(self.symbols[symbol], data)

    async def write_ptr(
        self, addr_symbol: str, data_symbol: str, offset: int = 0
    ):
        await self.core_mini_axi.write_word(
            self.symbols[addr_symbol], self.symbols[data_symbol] + offset
        )

    async def read(self, symbol: str, size: int):
        return await self.core_mini_axi.read(self.symbols[symbol], size)

    async def read_word(self, symbol: str):
        return await self.core_mini_axi.read_word(self.symbols[symbol])

    async def run_to_halt(self, timeout_cycles=10000):
        await self.core_mini_axi.execute_from(self.entry_point)
        return await self.core_mini_axi.wait_for_halted(
            timeout_cycles=timeout_cycles
        )

    async def run_to_fault(self, timeout_cycles=10000):
        await self.core_mini_axi.execute_from(self.entry_point)
        return await self.core_mini_axi.wait_for_fault(
            timeout_cycles=timeout_cycles
        )

    def fault(self):
        return self.core_mini_axi.dut.io_fault.value == 1
