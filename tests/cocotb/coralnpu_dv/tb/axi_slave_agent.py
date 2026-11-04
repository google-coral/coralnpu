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

from tb.axi_monitor import AxiMonitor
from tb.sequences import Sequencer
from tb.transaction import AxiTransaction, TxnKind


class AxiDriver:

    def __init__(self, name: str, bfm):
        self.name = name
        self.bfm = bfm
        self.seq_item_port: Queue[AxiTransaction] = Queue()
        self.log = logging.getLogger(f"cocotb.{name}")

    def start(self):
        cocotb.start_soon(self.run_phase())

    async def run_phase(self):
        while True:
            txn = await self.seq_item_port.get()
            if txn.kind is TxnKind.WRITE:
                await self.bfm.write(txn.addr, txn.data)
            else:
                data = await self.bfm.read(txn.addr, txn.n_bytes)
                txn.data = np.asarray(data, dtype=np.uint8)
            self.log.info(f"drove: {txn}")
            txn.done.set()


class AxiSlaveAgent:
    PREFIX = "io_axi_slave"

    def __init__(self, name: str, dut, bfm):
        self.name = name
        self.driver = AxiDriver(f"{name}.driver", bfm)
        self.sequencer = Sequencer(f"{name}.sequencer", self.driver)
        self.monitor = AxiMonitor(f"{name}.monitor", dut, self.PREFIX)

    def start(self):
        self.monitor.start()
        self.driver.start()
