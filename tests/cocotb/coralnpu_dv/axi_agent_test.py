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
"""Directed tests for the AXI slave-port agent and the sequences."""

import cocotb
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from cocotb.queue import Queue

from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture
from tb.axi_slave_agent import AxiSlaveAgent
from tb.sequences import ReadBufferSequence, WriteBufferSequence
from tb.transaction import AxiTransaction, TxnKind

VWMUL_ELF = "coralnpu_hw/tests/cocotb/coralnpu_dv/vwmul.elf"
BUFFER_BYTES = 32


@cocotb.test()
async def axi_write_read_back(dut):
    """Two concurrent writes: read back, and seen exactly by the monitor."""
    fixture = await VerilatorTestFixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        runfiles.Create().Rlocation(VWMUL_ELF), ["input_a", "input_b"]
    )
    agent = AxiSlaveAgent("axi", dut, fixture.core_mini_axi)
    observed = Queue()
    agent.monitor.write_ap.connect(observed)
    agent.start()

    rng = np.random.default_rng(7)
    data = {
        fixture.symbols[name]:
        rng.integers(0, 256, BUFFER_BYTES, dtype=np.uint8)
        for name in ("input_a", "input_b")
    }

    # Both write sequences run at once; the sequencer grants one at a time.
    tasks = [
        cocotb.start_soon(
            WriteBufferSequence(f"write_{addr:#x}", addr,
                                payload).start(agent.sequencer)
        ) for addr, payload in data.items()
    ]
    for task in tasks:
        await task

    for addr, expected in data.items():
        read = ReadBufferSequence(f"read_{addr:#x}", addr, BUFFER_BYTES)
        await read.start(agent.sequencer)
        assert np.array_equal(read.result, expected), \
            f"readback at {addr:#x}: {read.result} != {expected}"

    seen = [observed.get_nowait() for _ in range(observed.qsize())]
    assert len(seen) == len(data), \
        f"monitor saw {len(seen)} writes, expected {len(data)}"
    for txn in seen:
        assert txn.addr in data, f"unexpected write {txn}"
        sent = AxiTransaction(TxnKind.WRITE, txn.addr, data[txn.addr])
        assert txn.compare(sent), f"monitor saw {txn}, sequence sent {sent}"
        # Beats times bytes per beat must cover the bytes written.
        capacity = (txn.burst_len + 1) * (1 << txn.size)
        assert capacity >= len(txn.data), \
            f"burst too small for {txn}: len={txn.burst_len} size={txn.size}"
    # First cocotb test to print an AxiTransaction: check its log format once.
    text = str(seen[0])
    assert text.startswith(f"WRITE addr={seen[0].addr:#x} len=32 data="), text
    dut._log.info(
        f"PASS: {len(seen)} writes seen by the monitor, all read back"
    )