# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""CoralNPU Dispatch Monitor (`dispatch_verifier.monitor`).

Monitors internal dispatch lanes (`dut.core.score.dispatch`) cycle-by-cycle in
Cocotb simulations, disassembles retired/dispatched RISC-V scalar, float, and
RVV vector instructions, and provides both an interactive terminal UI (`tqdm` +
live rolling instruction box) and structured trace logging (`dispatch.log`).

Features:
  - Superscalar Multi-Lane Tracing: Tracks up to 4 concurrent dispatch lanes
    (`io_inst_0` to `io_inst_3`), capturing cycle count, lane index, PC
    (`addr`), disassembled mnemonic, target functional unit (`ALU`, `BRU`,
    `MLU`, `DVU`, `LSU`, `CSR`, `FLOAT`, `RVV`), register indices (`rd`, `rs1`,
    `rs2`), and raw hex encoding.
  - Dynamic In-Place Terminal UI (`TerminalUI`): Renders a live 10-line rolling
    window of the active testcase's instructions directly above a `tqdm`
    progress bar using ANSI cursor control (throttled to ~30 FPS to prevent
    terminal flicker).
  - Complete Trace File Logging: Automatically writes every dispatched
    instruction across all testcases to `dispatch.log` in the workspace root,
    separated by testcase headers.
  - Programmatic History & Callbacks: Access all traced instructions via
    `monitor.history` (a list of `DispatchedInst` objects) or register a
    real-time `on_dispatch(inst)` callback.

Quick Start:
  1. Add `//coralnpu_test_utils:dispatch_verifier` to `deps` in your `cocotb_test`
     or `cocotb_test_suite` target in `tests/cocotb/BUILD`.
  2. Integrate into a Cocotb testbench:

      import cocotb
      from tqdm import tqdm
      from coralnpu_test_utils.dispatch_verifier.monitor import DispatchMonitor

      @cocotb.test()
      async def my_rvv_test(dut):
          monitor = DispatchMonitor(dut, clk=dut.io_aclk)
          monitor.start()

          test_cases = ["case_1", "case_2", "case_3"]
          with tqdm(test_cases, desc="Running RVV cases", unit="case") as pbar:
              monitor.set_pbar(pbar)
              for case_name in pbar:
                  monitor.start_case(case_name)
                  await run_single_test_case(dut, case_name)

          monitor.close()
          dut._log.info(
              f"Test finished in {monitor.cycle_count} cycles. "
              f"Total instructions traced: {len(monitor.history)}"
          )

  3. Run the test directly with `bazel run`:
     `bazel run //tests/cocotb:rvv_assembly_cocotb_test_vgather_test`

Environment Variables:
  DISPATCH_UI: Defaults to `1` (enabled). Set `DISPATCH_UI=0` to disable the
    ANSI in-place terminal UI in non-interactive CI pipelines.

Verilator VPI & Build Notes:
  To inspect internal Chisel/Verilog dispatch signals
  (`dut.core.score.dispatch.io_inst_*`), Verilator requires VPI visibility on
  the `DispatchV2` module:
  - `coralnpu_test_utils/dispatch.vlt.tpl` adds
    `public -module "DispatchV2" -var "io_*"` to selectively expose only
    `DispatchV2`'s I/O ports to VPI without disabling Verilator optimizations
    across the rest of the chip.
  - `rvv_core_mini_axi_model` in `tests/cocotb/BUILD` sets
    `vlt_tpl = "//coralnpu_test_utils:dispatch.vlt.tpl"`, allowing all tests
    using `rvv_core_mini_axi_model` to access `DispatchMonitor` at full
    simulation speed.
"""

from dataclasses import dataclass
from enum import Enum, auto
import os
from typing import Any, Callable, Optional

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge
from coralnpu_test_utils.dispatch_verifier.disasm import disassemble
from coralnpu_test_utils.dispatch_verifier.terminal_ui import TerminalUI


class FunctionalUnit(Enum):
    """Execution functional units targeted by a dispatched instruction."""
    NONE = auto()
    ALU = auto()
    BRU = auto()
    MLU = auto()
    DVU = auto()
    LSU = auto()
    CSR = auto()
    FLOAT = auto()
    RVV = auto()
    FENCE = auto()


@dataclass
class DispatchedInst:
    """Represents a single instruction dispatched on one superscalar lane."""
    cycle: int
    lane: int
    pc: int
    raw_inst: int
    disasm: str
    fu: FunctionalUnit
    rd: int
    rs1: int
    rs2: int

    def __repr__(self) -> str:
        return (
            f"[Cycle: {self.cycle:5d}] Lane {self.lane}: "
            f"addr: 0x{self.pc:08x} | {self.disasm:<32} | "
            f"Target: {self.fu.name:<5} | raw_inst: (0x{self.raw_inst:08x})"
        )


class DispatchMonitor:
    """Monitors internal superscalar dispatch lanes (`DispatchV2`) in Cocotb."""

    def __init__(
        self,
        dut,
        clk=None,
        num_lanes: int = 4,
        log_to_console: bool = False,
        dynamic_ui: bool = True,
        max_ui_lines: int = 10,
        log_file: Optional[str] = "dispatch.log",
        pbar: Any = None,
        on_dispatch: Optional[Callable[[DispatchedInst], None]] = None,
    ):
        self.dut = dut

        if hasattr(dut, "core") and hasattr(dut.core, "score") and hasattr(
                dut.core.score, "dispatch"):
            self.dispatch = dut.core.score.dispatch
        elif hasattr(dut, "score") and hasattr(dut.score, "dispatch"):
            self.dispatch = dut.score.dispatch
        elif hasattr(dut, "dispatch"):
            self.dispatch = dut.dispatch
        else:
            raise AttributeError(
                f"Could not locate dispatch module in DUT hierarchy. DUT handles: {[h._name for h in dut]}"
            )

        self.clk = clk if clk is not None else (
            dut.io_aclk if hasattr(dut, "io_aclk") else
            (dut.aclk if hasattr(dut, "aclk") else dut.clk)
        )
        self.num_lanes = num_lanes
        self.log_to_console = log_to_console
        self.dynamic_ui = dynamic_ui
        self.log_file = log_file
        self.on_dispatch = on_dispatch

        self.history: list[DispatchedInst] = []
        self.cycle_count = 0
        self._task = None

        # Resolve log_file path: write directly to workspace root if under bazel run
        self.log_path = None
        self._log_handle = None
        if self.log_file:
            if "BUILD_WORKING_DIRECTORY" in os.environ and not os.path.isabs(
                    self.log_file):
                self.log_path = os.path.join(
                    os.environ["BUILD_WORKING_DIRECTORY"], self.log_file
                )
            else:
                self.log_path = os.path.abspath(self.log_file)
            try:
                self._log_handle = open(self.log_path, "w", encoding="utf-8")
            except Exception as e:
                dut._log.warning(
                    f"Could not open dispatch log file {self.log_path}: {e}"
                )

        self.ui = TerminalUI(
            max_lines=max_ui_lines, pbar=pbar
        ) if dynamic_ui else None

    def start_case(self, case_name: str) -> None:
        """Starts tracking instructions for a new testcase, displaying only instructions of this case."""
        if self._log_handle:
            self._log_handle.write(
                f"\n{'=' * 30} Case: {case_name} {'=' * 30}\n"
            )
            self._log_handle.flush()
        if self.ui:
            self.ui.start_case(case_name)

    def set_pbar(self, pbar: Any) -> None:
        """Attaches a tqdm progress bar to render alongside instructions."""
        if self.ui:
            self.ui.set_pbar(pbar)

    def close(self) -> None:
        """Closes the log file and finalizes terminal UI output."""
        if self.ui:
            self.ui.finish()
        if self._log_handle:
            self._log_handle.flush()
            self._log_handle.close()
            self._log_handle = None

    def start(self) -> None:
        if self._task is None:
            self._task = cocotb.start_soon(self._run())

    def _sig(self, name: str) -> int:
        sig = getattr(self.dispatch, name, None)
        if sig is not None:
            try:
                return int(sig.value)
            except Exception:
                return 0
        return 0

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.clk)
            await ReadOnly()

            if hasattr(self.dut, "aresetn") and int(self.dut.aresetn.value
                                                    ) == 0:
                continue
            if hasattr(self.dut, "io_aresetn") and int(
                    self.dut.io_aresetn.value) == 0:
                continue
            if hasattr(self.dut, "rstn") and int(self.dut.rstn.value) == 0:
                continue

            self.cycle_count += 1

            for lane in range(self.num_lanes):
                valid = self._sig(f"io_inst_{lane}_valid")
                ready = self._sig(f"io_inst_{lane}_ready")

                # Only sample if the instruction fired
                if valid == 1 and ready == 1:
                    pc = self._sig(f"io_inst_{lane}_bits_addr")
                    raw_inst = self._sig(f"io_inst_{lane}_bits_inst")

                    rd = (raw_inst >> 7) & 0x1F
                    rs1 = (raw_inst >> 15) & 0x1F
                    rs2 = (raw_inst >> 20) & 0x1F

                    fu = self._get_functional_unit(lane)
                    disasm_str = disassemble(raw_inst, pc=pc)

                    inst = DispatchedInst(
                        cycle=self.cycle_count,
                        lane=lane,
                        pc=pc,
                        raw_inst=raw_inst,
                        disasm=disasm_str,
                        fu=fu,
                        rd=rd,
                        rs1=rs1,
                        rs2=rs2,
                    )

                    self.history.append(inst)

                    if self._log_handle:
                        self._log_handle.write(str(inst) + "\n")

                    if self.log_to_console:
                        self.dut._log.info(str(inst))

                    if self.ui:
                        self.ui.add_instruction(inst)
                        self.ui.render()

                    if self.on_dispatch:
                        self.on_dispatch(inst)

    def _get_functional_unit(self, lane: int) -> FunctionalUnit:
        if self._sig(f"io_alu_{lane}_valid") == 1:
            return FunctionalUnit.ALU
        if self._sig(f"io_bru_{lane}_valid") == 1:
            return FunctionalUnit.BRU
        if self._sig(f"io_mlu_{lane}_valid") == 1:
            return FunctionalUnit.MLU
        if self._sig(f"io_dvu_{lane}_valid") == 1:
            return FunctionalUnit.DVU
        if self._sig(f"io_lsu_{lane}_valid") == 1:
            return FunctionalUnit.LSU
        if lane == 0 and self._sig("io_csr_valid") == 1:
            return FunctionalUnit.CSR
        if self._sig(f"io_rvv_{lane}_valid") == 1:
            return FunctionalUnit.RVV
        if lane == 0 and self._sig("io_float_valid") == 1:
            return FunctionalUnit.FLOAT
        return FunctionalUnit.NONE
