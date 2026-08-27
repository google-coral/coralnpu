// Copyright 2025 Google LLC
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

package common

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class CircularBufferMultiSpec extends AnyFreeSpec with ChiselSim {
  def resetDut(dut: CircularBufferMulti[UInt]): Unit = {
    dut.reset.poke(true.B)
    dut.clock.step()
    dut.reset.poke(false.B)
    dut.io.flush.poke(false.B)
    dut.io.enqValid.poke(0.U)
    dut.io.deqReady.poke(0.U)
  }

  "CircularBufferMulti Operations" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      // Basic
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        dut.io.enqValid.poke(2)
        dut.io.enqData(0).poke(3)
        dut.io.enqData(1).poke(5)
        dut.clock.step()

        dut.io.nEnqueued.expect(2)
        dut.io.dataOut(0).expect(3)
        dut.io.dataOut(1).expect(5)

        dut.io.enqValid.poke(1)
        dut.io.enqData(0).poke(9001)
        dut.io.enqData(1).poke(0)
        dut.clock.step()

        dut.io.nEnqueued.expect(3)
        dut.io.dataOut(0).expect(3)
        dut.io.dataOut(1).expect(5)
        dut.io.dataOut(2).expect(9001)

        dut.io.enqValid.poke(0)
        dut.io.deqReady.poke(1)
        dut.clock.step()

        dut.io.nEnqueued.expect(2)
        dut.io.dataOut(0).expect(5)
        dut.io.dataOut(1).expect(9001)
      }

      // Write n
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        for (n <- 0 until 4) {
          dut.io.enqData(n).poke(n)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()

        dut.io.nEnqueued.expect(4)

        for (n <- 0 until 4) {
          dut.io.dataOut(n).expect(n)
        }
      }

      // Fill Buffer
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        // Fill buffer completely
        for (writeCount <- 0 until 4) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
          // Confirm nEnqueued increments the amount corresponding to #enqValid each cycle
          dut.io.nEnqueued.expect((writeCount + 1) * 4)
        }
      }

      // Fill and Empty Buffer
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        // Fill buffer completely
        for (writeCount <- 0 until 4) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
        }
        dut.io.enqValid.poke(0)
        dut.io.nEnqueued.expect(16)

        // Empty buffer completely
        for (writeCount <- 0 until 4) {
          for (nIndex <- 0 until 4) {
            val outdata = writeCount * 4 + nIndex
            dut.io.dataOut(nIndex).expect(outdata)
          }
          dut.io.deqReady.poke(4)
          dut.clock.step()
        }
        dut.io.deqReady.poke(0)
        dut.io.nEnqueued.expect(0)
      }

      // Fill, Remove 4 items, and fill back to the top
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        // Fill buffer completely
        // Use 4x transactions of n=4 items to fill up to size 16, incrementing each transaction
        for (writeCount <- 0 until 4) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
        }
        dut.io.enqValid.poke(0)
        dut.io.nEnqueued.expect(16)

        // Remove 4x items
        for (writeCount <- 0 until 1) {
          for (nIndex <- 0 until 4) {
            val outdata = writeCount * 4 + nIndex
            dut.io.dataOut(nIndex).expect(outdata)
          }
          dut.io.deqReady.poke(4)
          dut.clock.step()
        }
        dut.io.deqReady.poke(0)
        dut.io.nEnqueued.expect(12)

        // Add back n=4 items
        for (writeCount <- 4 until 5) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
        }
        dut.io.enqValid.poke(0)
        dut.io.nEnqueued.expect(16)
        // Remove 4x items
        for (writeCount <- 1 until 2) {
          for (nIndex <- 0 until 4) {
            val outdata = writeCount * 4 + nIndex
            dut.io.dataOut(nIndex).expect(outdata)
          }
          dut.io.deqReady.poke(4)
          dut.clock.step()
        }
        dut.io.nEnqueued.expect(12)
      }

      // Flush Test
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        // Fill buffer completely and flush
        for (writeCount <- 0 until 4) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
        }
        dut.io.enqValid.poke(0)

        dut.io.nEnqueued.expect(16)

        dut.io.flush.poke(true)
        dut.clock.step()
        dut.clock.step()
        dut.io.nEnqueued.expect(0)
        dut.io.flush.poke(false)

        // Add 4x items and flush
        for (writeCount <- 0 until 1) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
        }
        dut.io.enqValid.poke(0)

        dut.io.nEnqueued.expect(4)

        dut.io.flush.poke(true)
        dut.clock.step()
        dut.clock.step()
        dut.io.nEnqueued.expect(0)
        dut.io.flush.poke(false)
      }

      // Read and Write Buffer on Same Cycle
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        // Use 2x transactions of n=4 items to fill up to size 8, incrementing each transaction
        for (writeCount <- 0 until 2) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
        }
        dut.io.enqValid.poke(0)
        dut.io.nEnqueued.expect(8)

        // Enque and Deque on same cycle
        dut.io.enqValid.poke(3)
        dut.io.enqData(0).poke(3)
        dut.io.enqData(1).poke(5)
        dut.io.enqData(2).poke(7)

        dut.io.deqReady.poke(4)

        dut.clock.step()
        dut.io.deqReady.poke(0)
        dut.io.enqValid.poke(0)
        dut.io.nEnqueued.expect(7)

        // Flush
        dut.io.flush.poke(true)
        dut.clock.step()
        dut.clock.step()
        dut.io.nEnqueued.expect(0)
        dut.io.flush.poke(false)
        dut.clock.step()

        // Fill buffer up to 12 items
        for (writeCount <- 0 until 3) {
          for (nIndex <- 0 until 4) {
            val indata = writeCount * 4 + nIndex
            dut.io.enqData(nIndex).poke(indata)
          }
          dut.io.enqValid.poke(4)
          dut.clock.step()
        }
        dut.io.nEnqueued.expect(12)

        // Fill buffer completely and dequeue on same cycle
        for (nIndex <- 0 until 4) {
          val indata = nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.io.deqReady.poke(4)
        dut.clock.step()
        dut.io.enqValid.poke(0)
        dut.io.deqReady.poke(0)

        dut.io.nEnqueued.expect(12)
      }
    }
  }
}
