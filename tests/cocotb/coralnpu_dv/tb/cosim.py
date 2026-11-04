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

import cocotb
import numpy as np
from cocotb.queue import Queue

from tb.lockstep import ExpectedDifferences, LockstepChecker


class CosimScoreboard:

    def __init__(
        self,
        name: str,
        iss,
        expected: ExpectedDifferences = ExpectedDifferences(),
        mmio_base: int = 0x30000
    ):
        self.name = name
        self.checker = LockstepChecker(name, iss, expected, mmio_base)
        self.axi_export: Queue = Queue()
        self.rvvi_export: Queue = Queue()
        self.log = logging.getLogger(f"cocotb.{name}")

    def start(self):
        cocotb.start_soon(self._mirror_writes())
        cocotb.start_soon(self._check_retirements())

    async def _mirror_writes(self):
        while True:
            txn = await self.axi_export.get()
            self.checker.mirror_write(txn.addr, txn.data)

    async def _check_retirements(self):
        while True:
            self.checker.check(await self.rvvi_export.get())

    def check_memory(self, addr: int, rtl_bytes: np.ndarray):
        bad = self.checker.compare_memory(addr, rtl_bytes)
        assert not bad, f"memory @ {addr:#x}: {len(bad)} bytes differ, first at +{bad[0]}"

    def check_phase(self, retired: int):
        checker = self.checker
        assert not checker.mismatches, f"{len(checker.mismatches)} mismatch(es): {checker.mismatches[0]}"
        assert checker.checked == retired, f"checked {checker.checked} of {retired} retirements"
        assert checker.reg_compares > 0, "no register writes compared"
        self.log.info(f"PASS: {checker.summary()}")
