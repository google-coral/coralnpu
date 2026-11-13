// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class DispatchBranchAlignSpec extends AnyFreeSpec with ChiselSim {
  "Conditional branch with misaligned target dispatches to Bru without a decode fault" in {
    val p = new Parameters()
    simulate(new DispatchV2(p)) { dut =>
      DispatchTestUtils.initialize(dut, p)
      dut.io.branchTaken.poke(false.B)

      // Lane 0: beq x0, x0, .+2 (0x00000163). With the ROB empty it dispatches to Bru, which
      // decides whether the branch is taken and therefore whether it traps.
      dut.io.retirement_buffer_empty.poke(true.B)
      dut.io.inst(0).valid.poke(true.B)
      dut.io.inst(0).bits.inst.poke(0x00000163L.U)
      dut.io.inst(0).ready.expect(true.B)
      dut.io.bxxFault(0).expect(false.B)
      dut.io.bru(0).valid.expect(true.B)

      // The branch waits while the ROB still holds older instructions.
      dut.io.retirement_buffer_empty.poke(false.B)
      dut.io.inst(0).ready.expect(false.B)
      dut.io.bru(0).valid.expect(false.B)

      // The branch dispatches from lane 0 only: behind a nop in lane 0 it waits in lane 1.
      dut.io.retirement_buffer_empty.poke(true.B)
      dut.io.inst(0).bits.inst.poke(0x13.U) // addi x0, x0, 0
      dut.io.inst(1).valid.poke(true.B)
      dut.io.inst(1).bits.inst.poke(0x00000163L.U)
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(false.B)
      dut.io.bxxFault(1).expect(false.B)
    }
  }
}
