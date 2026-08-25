# Copyright 2026 Google LLC
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

import coralnpu_v2_sim_pybind
from elftools.elf.elffile import ELFFile
import numpy as np


class CoralNPUV2Simulator:
    """Wrapper for CoralNPUV2SimulatorPy providing helper methods."""

    def __init__(
        self, highmem_ld=True, exit_on_ebreak=True, semihost_htif=True
    ):
        self.options = coralnpu_v2_sim_pybind.CoralNPUSimulatorOptions()
        self.options.semihost_htif = semihost_htif
        if highmem_ld:
            MP = coralnpu_v2_sim_pybind.MemoryPermission
            self.itcm_region = self._create_memory_region(
                0x0, 0x00100000, MP.kReadWriteExecute
            )
            self.dtcm_region = self._create_memory_region(
                0x100000, 0x100000, MP.kReadWrite
            )
            self.extmem_region = self._create_memory_region(
                0x20000000, 0x400000, MP.kReadWrite
            )
            self.ddr_region = self._create_memory_region(
                0x80000000, 0x8000000, MP.kReadWriteExecute
            )
            self.options.initial_misa_value = 0x40a01120
            self.options.memory_regions = [
                self.itcm_region, self.dtcm_region, self.extmem_region,
                self.ddr_region
            ]
        if exit_on_ebreak:
            self.options.exit_on_ebreak = True
        self.sim = coralnpu_v2_sim_pybind.CoralNPUSimulatorPy(self.options)

    def _create_memory_region(self, start_address, length, permissions):
        """Creates a CoralNPUV2MemoryRegion object."""
        region = coralnpu_v2_sim_pybind.CoralNPUV2MemoryRegion()
        region.start_address = start_address
        region.length = length
        region.permissions = permissions
        return region

    def load_program(self, elf_path, entry_point=None):
        """Loads an ELF program.

    If entry_point is None, it's inferred from ELF if not provided.
    """
        # Note: The underlying C++ API might expect an optional or raw value.
        # Based on previous code: LoadProgrampy(path, entry_point)
        self.sim.LoadProgram(elf_path, entry_point)

    def run(self):
        """Runs the simulator."""
        self.sim.Run()

    def wait(self):
        """Waits for the simulator to finish."""
        self.sim.Wait()

    def step(self, num_steps):
        """Steps the simulator."""
        return self.sim.Step(num_steps)

    def set_sw_breakpoint(self, address):
        """Sets a software breakpoint at the given address."""
        self.sim.SetSwBreakpoint(address)

    def clear_sw_breakpoint(self, address):
        """Clears a software breakpoint at the given address."""
        self.sim.ClearSwBreakpoint(address)

    def halt(self):
        """Halts the simulator."""
        self.sim.Halt()

    def get_cycle_count(self):
        """Returns the cycle count."""
        return self.sim.GetCycleCount()

    def read_memory(self, address, length):
        """Reads memory and returns a numpy array of uint8."""
        return self.sim.ReadMemory(address, length)

    def read_register(self, name):
        """Reads a register and returns the hex value of it."""
        return hex(self.sim.ReadRegister(name))

    def write_register(self, name, value):
        """Writes uint64 values to given register value."""
        if not isinstance(name, str):
            raise TypeError(
                f"Register name must be a string, got {type(name).__name__}"
            )
        if not isinstance(value, int):
            raise TypeError(
                f"Register value must be an integer, got {type(value).__name__}"
            )
        return self.sim.WriteRegister(name, value)

    def write_memory(self, address, data):
        """Writes data to memory. Data must be a numpy array."""
        if not isinstance(data, np.ndarray):
            raise TypeError('data must be a numpy array')
        if data.dtype != np.uint8:
            data = data.view(np.uint8)
        self.sim.WriteMemory(address, data, len(data))

    def write_word(self, address, data):
        if data.dtype != np.uint32:
            raise TypeError('data must be a numpy uint32')
        self.sim.WriteWord(address, data)

    def write_ptr(self, address, ptr_address):
        self.sim.WriteWord(address, ptr_address & 0xFFFFFFFF)

    def get_elf_entry_and_symbol(self, filename, symbol_names=None):
        """Returns the entry point and a dictionary of symbol addresses from an ELF file."""
        symbol_map = {}
        with open(filename, 'rb') as f:
            elf_file = ELFFile(f)
            entry_point = elf_file.header['e_entry']
            if symbol_names:
                symtab_section = next(
                    elf_file.iter_sections(type='SHT_SYMTAB')
                )
                for symbol_name in symbol_names:
                    symbol = symtab_section.get_symbol_by_name(symbol_name)
                    if symbol:
                        symbol_map[symbol_name] = symbol[0].entry['st_value']
                    else:
                        symbol_map[symbol_name] = 0
            return entry_point, symbol_map
