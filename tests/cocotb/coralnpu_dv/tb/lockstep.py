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

import logging
from dataclasses import dataclass

import numpy as np

from tb.isa import COUNTER_CSRS, is_counter_access
from tb.retired_insn import RetiredInsn

_WORD = 0xFFFFFFFF


@dataclass(frozen=True)
class ExpectedDifferences:

    csrs: frozenset[int] = COUNTER_CSRS
    memory: tuple[tuple[int, int], ...] = ()


class LockstepChecker:

    def __init__(
        self,
        name: str,
        iss,
        expected: ExpectedDifferences = ExpectedDifferences(),
        mmio_base: int = 0x30000,
    ):
        self.name = name
        self.iss = iss
        self.expected = expected
        self.mmio_base = mmio_base
        self.checked = 0
        self.reg_compares = 0
        self.skipped = 0
        self.vector_writes = 0
        self.mirrored = 0
        self.mismatches: list[str] = []
        self.log = logging.getLogger(f"cocotb.{name}")

    def mirror_write(self, addr: int, data: np.ndarray):
        if addr >= self.mmio_base:
            return
        self.iss.write_memory(addr, np.asarray(data, dtype=np.uint8))
        self.mirrored += 1

    def check(self, txn: RetiredInsn):
        if self.mismatches:
            return
        iss_pc = int(self.iss.read_register("pc"), 16)
        if iss_pc != txn.pc:
            self._mismatch(txn, f"pc: ISS is at {iss_pc:#x}")
            return
        self.iss.step(1)
        for reg, rtl_val in txn.x_writes().items():
            if is_counter_access(txn.insn, self.expected.csrs):
                self.iss.write_register(f"x{reg}", rtl_val)
                self.skipped += 1
                continue
            iss_val = int(self.iss.read_register(f"x{reg}"), 16) & _WORD
            self.reg_compares += 1
            if iss_val != rtl_val:
                self._mismatch(
                    txn, f"x{reg}: RTL {rtl_val:#x} ISS {iss_val:#x}"
                )
        self.vector_writes += bin(txn.v_wb).count("1")
        self.checked += 1

    def compare_memory(self, addr: int, rtl_bytes: np.ndarray) -> list[int]:
        rtl = np.asarray(rtl_bytes, dtype=np.uint8)
        iss = np.asarray(self.iss.read_memory(addr, len(rtl)), dtype=np.uint8)
        return [
            int(offset)
            for offset in np.flatnonzero(iss != rtl)
            if not self._ignored(addr + int(offset))
        ]

    def summary(self) -> str:
        return (
            f"{self.checked} instructions in lockstep, "
            f"{self.reg_compares} register writes match, "
            f"{self.skipped} counter reads skipped, "
            f"{self.vector_writes} vector writes (checked via memory), "
            f"{self.mirrored} AXI writes mirrored"
        )

    def _ignored(self, byte_addr: int) -> bool:
        return any(
            start <= byte_addr < end for start, end in self.expected.memory
        )

    def _mismatch(self, txn: RetiredInsn, what: str):
        message = f"{what} at {txn}"
        self.log.error(f"MISMATCH {message}")
        self.mismatches.append(message)
