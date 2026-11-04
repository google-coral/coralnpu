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

from tb.axi_slave_agent import AxiSlaveAgent
from tb.cosim import CosimScoreboard
from tb.lockstep import ExpectedDifferences
from tb.rvvi_monitor import RvviMonitor


@dataclass(frozen=True)
class EnvConfig:
    cosim: bool = True
    expected: ExpectedDifferences = ExpectedDifferences()


class CoralNpuEnv:

    def __init__(
        self,
        name: str,
        dut,
        bfm,
        config: EnvConfig = EnvConfig(),
        iss=None,
        scoreboards=()
    ):
        self.name = name
        self.dut = dut
        self.bfm = bfm
        self.config = config
        self.iss = iss
        self.scoreboards = list(scoreboards)
        self.axi_slave: AxiSlaveAgent | None = None
        self.rvvi: RvviMonitor | None = None
        self.cosim: CosimScoreboard | None = None
        self.log = logging.getLogger(f"cocotb.{name}")

    @property
    def sequencer(self):
        return self.axi_slave.sequencer

    def build_phase(self):
        self.axi_slave = AxiSlaveAgent(
            f"{self.name}.axi_slave", self.dut, self.bfm
        )
        if self.config.cosim:
            assert self.iss is not None, "EnvConfig(cosim=True) needs an ISS"
            self.rvvi = RvviMonitor(f"{self.name}.rvvi", self.dut)
            self.cosim = CosimScoreboard(
                f"{self.name}",
                self.iss,
                self.config.expected,
                mmio_base=self.bfm.csr_base_addr
            )

    def connect_phase(self):
        writes = self.axi_slave.monitor.write_ap
        for scoreboard in self.scoreboards:
            writes.connect(scoreboard.analysis_export)
        if self.cosim:
            writes.connect(self.cosim.axi_export)
            self.rvvi.retire_ap.connect(self.cosim.rvvi_export)

    def start_run_phase(self):
        self.axi_slave.start()
        if self.cosim:
            self.rvvi.start()
            self.cosim.start()
        for scoreboard in self.scoreboards:
            scoreboard.start()

    def check_phase(self):
        if self.cosim:
            self.cosim.check_phase(self.rvvi.retire_ap.count)
