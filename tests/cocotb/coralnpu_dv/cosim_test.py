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
"""Cosim tests on the verification core: the RVVI trace, then lockstep."""

import logging

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from cocotb.queue import Queue

from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture
from coralnpu_v2_sim_utils import CoralNPUV2Simulator
from tb.base_test import BaseTest
from tb.env import CoralNpuEnv, EnvConfig
from tb.rvvi_monitor import RvviMonitor
from tb.sequences import (
    KickoffSequence,
    ReadBufferSequence,
    WriteBufferSequence,
)
from tb.vwmul_scoreboard import VwmulScoreboard

VWMUL_ELF = "coralnpu_hw/tests/cocotb/coralnpu_dv/vwmul.elf"
SYMBOLS = ["input_a", "input_b", "output_products"]
ELEMENT_COUNT = 32


@cocotb.test()
async def rvvi_trace(dut):
    """The RVVI monitor sees every retirement once, in program order."""
    fixture = await VerilatorTestFixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        runfiles.Create().Rlocation(VWMUL_ELF), SYMBOLS
    )
    monitor = RvviMonitor("rvvi", dut)
    trace = Queue()
    monitor.retire_ap.connect(trace)
    monitor.start()
    await fixture.run_to_halt(timeout_cycles=10000)

    retired = [trace.get_nowait() for _ in range(trace.qsize())]
    dut._log.info(f"{monitor.retire_lanes} lanes, {len(retired)} retirements")
    for txn in retired[:6]:
        dut._log.info(str(txn))
    assert retired, "no instructions retired"
    assert [t.order for t in retired] == list(range(len(retired))), \
        "retirements missing or out of order"


class VwmulCosimTest(BaseTest):

    def __init__(self, name: str, dut, seed: int = 8):
        super().__init__(name, dut)
        self.seed = seed
        self.fixture = None
        self.iss = None
        self.env = None
        self.golden = None
        self.result = None

    async def reset_phase(self):
        elf = runfiles.Create().Rlocation(VWMUL_ELF)
        self.fixture = await VerilatorTestFixture.Create(self.dut)
        await self.fixture.load_elf_and_lookup_symbols(elf, SYMBOLS)
        self.iss = CoralNPUV2Simulator(highmem_ld=False)
        self.iss.load_program(elf, self.fixture.entry_point)

    def build_phase(self):
        sym = self.fixture.symbols
        self.golden = VwmulScoreboard(
            "golden", sym["input_a"], sym["input_b"], ELEMENT_COUNT
        )
        self.env = CoralNpuEnv(
            "env",
            self.dut,
            self.fixture.core_mini_axi,
            EnvConfig(cosim=True),
            iss=self.iss,
            scoreboards=[self.golden],
        )
        self.env.build_phase()

    def connect_phase(self):
        self.env.connect_phase()

    def start_run_phase(self):
        self.env.start_run_phase()

    async def main_phase(self):
        sym = self.fixture.symbols
        sqr = self.env.sequencer
        rng = np.random.default_rng(self.seed)
        a = rng.integers(-128, 128, ELEMENT_COUNT, dtype=np.int8)
        b = rng.integers(-128, 128, ELEMENT_COUNT, dtype=np.int8)
        await WriteBufferSequence("load_a", sym["input_a"], a).start(sqr)
        await WriteBufferSequence("load_b", sym["input_b"], b).start(sqr)
        await KickoffSequence(
            "kickoff", self.env.bfm.csr_base_addr, self.fixture.entry_point
        ).start(sqr)
        await self.env.bfm.wait_for_halted(timeout_cycles=10000)
        read_out = ReadBufferSequence(
            "read_out", sym["output_products"], 2 * ELEMENT_COUNT
        )
        await read_out.start(sqr)
        self.result = read_out.result

    def check_phase(self):
        self.golden.check_phase(self.result.view(np.int16))
        assert self.golden.ignored == 3, \
            f"expected only the 3 kickoff writes besides the inputs, " \
            f"got {self.golden.ignored}"
        self.env.check_phase()
        self.env.cosim.check_memory(
            self.fixture.symbols["output_products"], self.result
        )


@cocotb.test()
async def vwmul_cosim(dut):
    """vwmul.elf: golden model, lockstep against MPACT, and memory compare."""
    await VwmulCosimTest("cosim_test", dut).run()
