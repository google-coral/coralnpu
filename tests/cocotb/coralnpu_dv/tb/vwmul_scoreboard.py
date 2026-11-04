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


class VwmulScoreboard:

    def __init__(self, name: str, a_addr: int, b_addr: int, n: int):
        self.name = name
        self.a_addr = a_addr
        self.b_addr = b_addr
        self.n = n
        self.analysis_export: Queue = Queue()
        self.inputs: dict[str, np.ndarray] = {}
        self.ignored = 0
        self.log = logging.getLogger(f"cocotb.{name}")

    def start(self):
        cocotb.start_soon(self._run())

    async def _run(self):
        while True:
            txn = await self.analysis_export.get()
            if txn.addr == self.a_addr:
                self.inputs["a"] = txn.data.view(np.int8)
            elif txn.addr == self.b_addr:
                self.inputs["b"] = txn.data.view(np.int8)
            else:
                self.ignored += 1

    def expected(self) -> np.ndarray:
        return self.inputs["a"].astype(np.int16
                                       ) * self.inputs["b"].astype(np.int16)

    def check_phase(self, actual: np.ndarray):
        assert "a" in self.inputs and "b" in self.inputs, f"scoreboard never saw inputs: {sorted(self.inputs)}"
        expected = self.expected()
        bad = np.flatnonzero(expected != actual)
        assert len(bad) == 0, (
            f"{len(bad)}/{self.n} mismatches, first at [{bad[0]}]: "
            f"expected: {expected[bad[0]]}, got: {actual[bad[0]]}"
        )
        self.log.info(f"PASS: {self.n} products match, {self.ignored} ignored")
