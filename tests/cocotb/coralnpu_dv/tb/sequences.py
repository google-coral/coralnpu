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

import numpy as np
from cocotb.triggers import Lock

from tb.transaction import AxiTransaction, TxnKind


class Sequencer:

    def __init__(self, name: str, driver):
        self.name = name
        self._port = driver.seq_item_port
        self._lock = Lock()
        self._owner = None
        self.log = logging.getLogger(f"cocotb.{name}")

    async def lock(self, seq: "Sequence"):
        await self._lock.acquire()
        self._owner = seq
        self.log.info(f"locked by {seq.name}")

    def unlock(self, seq: "Sequence"):
        assert self._owner is seq, f"{seq.name} unlocking a lock it doesn't own"
        self._owner = None
        self._lock.release()
        self.log.info(f"unlocked by {seq.name}")

    async def execute_item(self, txn: AxiTransaction, seq: "Sequence"):
        if self._owner is seq:
            await self._port.put(txn)
            await txn.done.wait()
            return
        await self._lock.acquire()
        try:
            await self._port.put(txn)
            await txn.done.wait()
        finally:
            self._lock.release()


class Sequence:
    atomic = False

    def __init__(self, name: str):
        self.name = name
        self.sequencer: Sequencer | None = None

    async def start(self, sequencer: Sequencer):
        self.sequencer = sequencer
        if self.atomic:
            await sequencer.lock(self)
        try:
            await self.body()
        finally:
            if self.atomic:
                sequencer.unlock(self)

    async def send(self, txn: AxiTransaction):
        await self.sequencer.execute_item(txn, self)

    async def body(self):
        raise NotImplementedError


class WriteBufferSequence(Sequence):

    def __init__(self, name: str, addr: int, data: np.ndarray):
        super().__init__(name)
        self.addr = addr
        self.data = np.ascontiguousarray(data).view(np.uint8)

    async def body(self):
        await self.send(AxiTransaction(TxnKind.WRITE, self.addr, self.data))


class ReadBufferSequence(Sequence):

    def __init__(self, name: str, addr: int, n_bytes: int):
        super().__init__(name)
        self.addr = addr
        self.n_bytes = n_bytes
        self.result: np.ndarray | None = None

    async def body(self):
        txn = AxiTransaction(TxnKind.READ, self.addr, n_bytes=self.n_bytes)
        await self.send(txn)
        self.result = txn.data


class KickoffSequence(Sequence):
    atomic = True

    def __init__(self, name: str, csr_base: int, entry_pc: int):
        super().__init__(name)
        self.csr_base = csr_base
        self.entry_pc = entry_pc

    async def body(self):
        await self.send(
            AxiTransaction(
                TxnKind.WRITE, self.csr_base + 4, word_bytes(self.entry_pc)
            )
        )

        await self.send(
            AxiTransaction(TxnKind.WRITE, self.csr_base, word_bytes(1))
        )

        await self.send(
            AxiTransaction(TxnKind.WRITE, self.csr_base, word_bytes(0))
        )


def word_bytes(value: int) -> np.ndarray:
    return np.array([value], dtype=np.uint32).view(np.uint8)
