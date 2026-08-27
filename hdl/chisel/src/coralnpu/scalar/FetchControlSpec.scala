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

class FetchControlSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters

  def resetDut(dut: FetchControl): Unit = {
    dut.reset.poke(true.B)
    dut.clock.step()
    dut.reset.poke(false.B)
    dut.io.bufferRequest.nReady.poke(0.U)
    dut.io.csr.value(0).poke(0.U)
    dut.io.branch.valid.poke(false.B)
    dut.io.fetchData.valid.poke(false.B)
    dut.io.fetchAddr.ready.poke(false.B)
  }

  "FetchControl Operations" in {
    simulate(new FetchControl(p)) { dut =>
      // Initialization
      {
        resetDut(dut)
        dut.io.fetchAddr.valid.expect(0)
      }

      // ResetPC
      {
        resetDut(dut)
        dut.io.bufferRequest.nReady.poke(8.U)
        dut.io.csr.value(0).poke(0x20000000.U)
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.io.fetchAddr.valid.expect(0)
        dut.reset.poke(false.B)
        dut.clock.step()
        dut.io.bufferRequest.nValid.expect(0.U)
        dut.io.fetchAddr.valid.expect(1)
        dut.io.fetchAddr.bits.expect(0x20000000)
      }

      // Branch
      {
        resetDut(dut)
        dut.clock.step() // Clear reset.
        dut.io.bufferRequest.nReady.poke(8.U)
        dut.io.branch.valid.poke(true.B)
        dut.io.branch.bits.poke(0x30000000.U)
        dut.io.fetchData.valid.poke(true.B)
        dut.io.fetchData.bits.addr.poke(0x20000000)
        for (i <- 0 until dut.io.fetchData.bits.inst.length) {
          dut.io.fetchData.bits.inst(i).poke(i.U)
        }
        dut.io.bufferRequest.nValid.expect(0.U)
        dut.io.fetchAddr.valid.expect(0)
        dut.clock.step()
        dut.io.fetchData.valid.poke(false.B)

        // Resolve the branch, triggering new fetch
        dut.io.branch.valid.poke(false.B)
        dut.io.bufferRequest.nValid.expect(0.U)
        dut.io.fetchAddr.bits.expect(0x30000000)
        dut.io.fetchAddr.valid.expect(true.B)
        dut.io.fetchAddr.ready.poke(true.B)
        dut.clock.step()
        dut.io.fetchAddr.ready.poke(false.B)
        // Continues to speculate and fetch
        dut.io.fetchAddr.bits.expect(0x30000020)
        dut.io.fetchAddr.valid.expect(true.B)
      }

      // AlignedSpeculativeFetch
      {
        resetDut(dut)
        dut.io.csr.value(0).poke(0x20000000.U)
        dut.clock.step()

        dut.io.bufferRequest.nReady.poke(8.U)
        dut.clock.step()
        dut.io.fetchAddr.valid.expect(true.B)
        dut.io.fetchAddr.bits.expect(0x20000000)
        dut.io.fetchAddr.ready.poke(true.B)
        dut.clock.step()
        dut.io.fetchAddr.valid.expect(true.B)
        dut.io.fetchAddr.bits.expect(0x20000020)
        dut.clock.step()
        dut.io.fetchAddr.valid.expect(true.B)
        dut.io.fetchAddr.bits.expect(0x20000040)
      }

      // FetchWithBranch
      {
        resetDut(dut)
        dut.clock.step() // Clear reset.
        dut.io.bufferRequest.nReady.poke(8.U)
        dut.io.fetchData.valid.poke(true.B)
        dut.io.fetchData.bits.addr.poke(0x20000000)
        for (i <- 0 until dut.io.fetchData.bits.inst.length) {
          dut.io.fetchData.bits.inst(i).poke(i.U)
        }
        dut.io.fetchData.bits.inst(3).poke("x0000006f".U)
        dut.io.bufferRequest.nValid.expect(4.U)
        dut.clock.step() // Temporary

        dut.io.fetchData.valid.poke(false.B)
        dut.io.fetchAddr.valid.expect(1)
        dut.io.fetchAddr.bits.expect(0x2000000c)
      }

      // FetchJump
      {
        resetDut(dut)
        dut.clock.step() // Clear reset.
        dut.io.bufferRequest.nReady.poke(8.U)
        dut.io.fetchData.valid.poke(true.B)
        dut.io.fetchData.bits.addr.poke(0x20000000)
        for (i <- 0 until dut.io.fetchData.bits.inst.length) {
          dut.io.fetchData.bits.inst(i).poke(i.U)
        }
        dut.io.fetchData.bits.inst(3).poke("x0200006f".U) // JAL opcode (offset +32)
        dut.io.bufferRequest.nValid.expect(4.U)           // JAL is predicted, 4 valid
        dut.io.flushTx.expect(true.B)
        dut.clock.step()

        dut.io.fetchData.valid.poke(false.B)
        dut.io.fetchAddr.valid.expect(true.B)
        dut.io.fetchAddr.bits.expect(0x2000002c) // Fetch redirects to target
      }

      // CommitBackpressure
      {
        resetDut(dut)
        dut.io.csr.value(0).poke(0x20000000.U)
        dut.clock.step()

        // Instruction buffer is full, cannot accept 8 instructions
        dut.io.bufferRequest.nReady.poke(4.U)

        // Fetch initiation is NOT blocked
        dut.io.fetchAddr.valid.expect(1)

        dut.io.fetchData.valid.poke(true.B)
        dut.io.fetchData.bits.addr.poke(0x20000000)
        for (i <- 0 until dut.io.fetchData.bits.inst.length) {
          dut.io.fetchData.bits.inst(i).poke(i.U)
        }

        // Committing fetch results IS blocked
        dut.io.fetchData.ready.expect(false.B)
        dut.io.bufferRequest.nValid.expect(0.U)

        // Free up buffer space
        dut.io.bufferRequest.nReady.poke(8.U)

        // Committing fetch results is now unblocked
        dut.io.fetchData.ready.expect(true.B)
        dut.io.bufferRequest.nValid.expect(8.U)
      }
    }
  }
}
