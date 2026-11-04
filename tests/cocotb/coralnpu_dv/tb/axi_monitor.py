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

import collections
import logging

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge

from tb.analysis import AnalysisPort
from tb.transaction import AxiTransaction, TxnKind


class AxiMonitor:
    BUS_BYTES = 16

    def __init__(self, name: str, dut, prefix: str):
        self.name = name
        self.dut = dut
        self.prefix = prefix
        self.write_ap = AnalysisPort(f"{name}.write_ap")
        self.read_ap = AnalysisPort(f"{name}.read_ap")
        self.log = logging.getLogger(f"cocotb.{name}")

    def _sig(self, signal: str):
        return getattr(self.dut, f"{self.prefix}_{signal}")

    def start(self):
        cocotb.start_soon(self._write_path())

    async def _write_path(self):
        aw_valid = self._sig("write_addr_valid")
        aw_ready = self._sig("write_addr_ready")
        aw_addr = self._sig("write_addr_bits_addr")
        aw_id = self._sig("write_addr_bits_id")
        aw_len = self._sig("write_addr_bits_len")
        aw_size = self._sig("write_addr_bits_size")
        w_valid = self._sig("write_data_valid")
        w_ready = self._sig("write_data_ready")
        w_data = self._sig("write_data_bits_data")
        w_strb = self._sig("write_data_bits_strb")
        w_last = self._sig("write_data_bits_last")

        addrs = collections.deque()
        bursts = collections.deque()
        beats = []
        while True:
            await RisingEdge(self.dut.io_aclk)
            if aw_valid.value == 1 and aw_ready.value == 1:
                addrs.append((
                    aw_addr.value.to_unsigned(),
                    aw_id.value.to_unsigned(),
                    aw_len.value.to_unsigned(),
                    aw_size.value.to_unsigned(),
                ))
            if w_valid.value == 1 and w_ready.value == 1:
                lanes = w_data.value.to_unsigned().to_bytes(
                    self.BUS_BYTES, "little"
                )
                strb = w_strb.value.to_unsigned()
                beats.extend(
                    lanes[i] for i in range(self.BUS_BYTES) if (strb >> i) & 1
                )
                if w_last.value == 1:
                    bursts.append(np.array(beats, dtype=np.uint8))
                    beats = []
            while addrs and bursts:
                addr, axi_id, burst_len, size = addrs.popleft()
                txn = AxiTransaction(
                    TxnKind.WRITE,
                    addr,
                    bursts.popleft(),
                    axi_id=axi_id,
                    burst_len=burst_len,
                    size=size,
                )
                self.log.info(f"saw {txn}")
                self.write_ap.write(txn)
