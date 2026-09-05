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

import ctypes
import numpy as np
import logging

# --- ctypes setup for SRAM backdoor loading ---
# We use CDLL(None) to access symbols already loaded in the process (the simulator).
try:
    lib = ctypes.CDLL(None)
    sram_backdoor_load = lib.sram_backdoor_load_c
    # Explicitly set argument types for correctness
    sram_backdoor_load.argtypes = [
        ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t
    ]
    sram_backdoor_load.restype = ctypes.c_bool
except (AttributeError, Exception):
    # This might happen if the test is run on a simulator that doesn't have the DPI linked,
    # or if the simulator wasn't built with -rdynamic.
    sram_backdoor_load = None


def backdoor_load(addr, data):
    """Loads data into the simulator's SRAM via the C++ backdoor.

    Args:
        addr: Global byte address.
        data: bytes or bytearray of data to load.

    Raises:
        RuntimeError: if the backdoor load function is not found or fails.
    """
    if sram_backdoor_load is None:
        raise RuntimeError(
            "sram_backdoor_load_c symbol not found in the simulator process. "
            "Ensure the DPI library is linked and Verilator is run with -rdynamic."
        )

    data_bytes = bytes(data)
    # Using cast to void_p to ensure it's handled as a pointer
    if not sram_backdoor_load(
            ctypes.c_uint64(addr),
            ctypes.cast(ctypes.c_char_p(data_bytes), ctypes.c_void_p),
            ctypes.c_size_t(len(data_bytes)),
    ):
        raise RuntimeError(f"Backdoor load failed for address 0x{addr:x}")


# --- DDR (axi_sim_mem) backdoor -------------------------------------------
# Present only in models built with //hdl/verilog:ddr_sim_mem (the *SimMem
# wrapper tops). CoreMiniAxiInterface uses it when the DUT has no
# io_axi_master_* ports.
try:
    _ddr_lib = ctypes.CDLL(None)
    ddr_backdoor_configure = _ddr_lib.ddr_backdoor_configure_c
    ddr_backdoor_configure.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    ddr_backdoor_configure.restype = None
    _ddr_write = _ddr_lib.ddr_backdoor_write_c
    _ddr_write.argtypes = [ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t]
    _ddr_write.restype = ctypes.c_bool
    _ddr_read = _ddr_lib.ddr_backdoor_read_c
    _ddr_read.argtypes = [ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t]
    _ddr_read.restype = ctypes.c_bool
except (OSError, AttributeError):
    ddr_backdoor_configure = None
    _ddr_write = None
    _ddr_read = None


def has_ddr_backdoor() -> bool:
    return ddr_backdoor_configure is not None


class DdrBackdoorMemory:
    """numpy-like view of the RTL-side external memory.

    Supports the accesses CoreMiniAxiInterface makes on its `memory` array:
    len(), integer and slice get/set with uint8 data.
    """

    def __init__(self, base: int, size: int):
        if not has_ddr_backdoor():
            raise RuntimeError(
                "ddr_backdoor_*_c symbols not found: this simulator was not "
                "built with //hdl/verilog:ddr_sim_mem")
        self.base = base
        self.size = size
        ddr_backdoor_configure(base, size)

    def __len__(self):
        return self.size

    def _span(self, key):
        if isinstance(key, slice):
            start, stop, step = key.indices(self.size)
            assert step == 1, "DdrBackdoorMemory: only contiguous slices"
            return start, max(stop - start, 0)
        return int(key), 1

    def __getitem__(self, key):
        start, n = self._span(key)
        buf = np.zeros(n, dtype=np.uint8)
        if n and not _ddr_read(self.base + start, buf.ctypes.data, n):
            raise IndexError(f"DDR backdoor read out of range: 0x{self.base + start:x} +{n}")
        return buf if isinstance(key, slice) else buf[0]

    def __setitem__(self, key, value):
        start, n = self._span(key)
        buf = np.ascontiguousarray(np.asarray(value, dtype=np.uint8)).reshape(-1)
        if buf.size == 1 and n > 1:
            buf = np.full(n, buf[0], dtype=np.uint8)
        assert buf.size == n, f"DdrBackdoorMemory: shape mismatch {buf.size} != {n}"
        if n and not _ddr_write(self.base + start, buf.ctypes.data, n):
            raise IndexError(f"DDR backdoor write out of range: 0x{self.base + start:x} +{n}")
