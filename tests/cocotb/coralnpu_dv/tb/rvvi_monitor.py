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
from cocotb.triggers import ReadOnly, RisingEdge

from tb.analysis import AnalysisPort
from tb.retired_insn import RetiredInsn


class RvviMonitor:

    def __init__(self, name: str, dut):
        self.name = name
        self.dut = dut
        self.trace = dut.core.score.rvvi.rvviTraceBlackBox
        self.retire_lanes = 0
        while hasattr(self.trace, f"valid_i_{self.retire_lanes}"):
            self.retire_lanes += 1
        self.retire_ap = AnalysisPort(f"{name}.retire_ap")
        self.log = logging.getLogger(f"cocotb.{name}")

    def start(self):
        cocotb.start_soon(self._run())

    def _lane(self, signal: str, lane: int):
        return getattr(self.trace, f"{signal}_{lane}").value

    def _sample(self, lane: int):
        return RetiredInsn(
            order=self._lane("order_i", lane).to_unsigned(),
            pc=self._lane("pc_rdata_i", lane).to_unsigned(),
            insn=self._lane("insn_i", lane).to_unsigned(),
            trap=self._lane("trap_i", lane) == 1,
            x_wb=self._lane("x_wb_i", lane).to_unsigned(),
            x_wdata=self._lane("x_wdata_i", lane).to_unsigned(),
            f_wb=self._lane("f_wb_i", lane).to_unsigned(),
            f_wdata=self._lane("f_wdata_i", lane).to_unsigned(),
            v_wb=self._lane("v_wb_i", lane).to_unsigned(),
        )

    async def _run(self):
        while True:
            await RisingEdge(self.dut.io_aclk)
            await ReadOnly()
            retired = [
                self._sample(lane)
                for lane in range(self.retire_lanes)
                if self._lane("valid_i", lane) == 1
            ]
            for txn in sorted(retired, key=lambda t: t.order):
                self.retire_ap.write(txn)
