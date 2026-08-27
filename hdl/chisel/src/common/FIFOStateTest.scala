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
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class FIFOStateTestWrapper(t: UInt, n: Int, capacity: Int) extends Module {
  val io = IO(new Bundle {
    val enqValid = Input(UInt(log2Ceil(n + 1).W))
    val enqData  = Input(Vec(n, t))
    val deqReady = Input(UInt(log2Ceil(n + 1).W))
    val flush    = Input(Bool())

    val nEnqueued = Output(UInt(log2Ceil(capacity + 1).W))
    val dataOut   = Output(Vec(n, t))
  })

  val state = RegInit(FIFOState.init(capacity, t))

  // Chain: Dequeue then Enqueue to handle simultaneous operations with maximum throughput
  val deqState = state.dequeue(io.deqReady)
  val enqState = deqState.enqueue(io.enqData, io.enqValid)

  state := Mux(io.flush, state.flush(), enqState)
  // Assert that the state is consistent after every cycle
  assert(state.invariant())

  io.nEnqueued := state.count
  io.dataOut   := state.peek(n)
}

class FIFOStateSpec extends AnyFreeSpec with ChiselSim {
  def resetDut(dut: FIFOStateTestWrapper): Unit = {
    dut.reset.poke(true.B)
    dut.clock.step()
    dut.reset.poke(false.B)
    dut.io.flush.poke(false.B)
    dut.io.enqValid.poke(0.U)
    dut.io.deqReady.poke(0.U)
  }

  "FIFOState Operations (capacity=16)" in {
    simulate(new FIFOStateTestWrapper(UInt(32.W), 4, 16)) { dut =>
      // Basic Test
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

      // Simultaneous Read Write
      {
        resetDut(dut)
        dut.io.nEnqueued.expect(0)

        // Fill 16 items
        for (j <- 0 until 4) {
          dut.io.enqValid.poke(4)
          for (i <- 0 until 4) dut.io.enqData(i).poke(j * 100 + i)
          dut.clock.step()
        }
        dut.io.nEnqueued.expect(16)

        // Enqueue 4, Dequeue 4 (Full buffer)
        // Should succeed if logic handles it.
        dut.io.enqValid.poke(4)
        dut.io.deqReady.poke(4)
        for (i <- 0 until 4) dut.io.enqData(i).poke(200 + i)

        dut.clock.step()

        dut.io.nEnqueued.expect(16) // Still full

        // Verify old data removed (0, 1, 2, 3) and new data enqueued (200+i)
        // The peek(4) shows oldest data.
        // We removed 4 (Batch 0).
        // The next oldest data is Batch 1 (100, 101, 102, 103).

        // After removing 4, we expect 100, 101, 102, 103 (from 2nd batch).
        dut.io.dataOut(0).expect(100)
        dut.io.dataOut(1).expect(101)
        dut.io.dataOut(2).expect(102)
        dut.io.dataOut(3).expect(103)
      }
    }
  }

  "FIFOState Non-Power-of-2 Size (capacity=5)" in {
    simulate(new FIFOStateTestWrapper(UInt(32.W), 4, 5)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      // Write 4 items
      dut.io.enqValid.poke(4)
      for (i <- 0 until 4) dut.io.enqData(i).poke(i)
      dut.clock.step()
      dut.io.nEnqueued.expect(4)

      // Dequeue 2 items
      dut.io.enqValid.poke(0)
      dut.io.deqReady.poke(2)
      dut.clock.step()
      dut.io.nEnqueued.expect(2)

      // Write 3 items (should wrap around)
      // Current state: head=4, tail=2. Free=3.
      // Writing 3 items: 20, 21, 22.
      // They should end up at physical indices: 4, 0, 1
      dut.io.enqValid.poke(3)
      dut.io.deqReady.poke(0)
      dut.io.enqData(0).poke(20)
      dut.io.enqData(1).poke(21)
      dut.io.enqData(2).poke(22)
      dut.clock.step()

      dut.io.nEnqueued.expect(5)

      // Verify content (peek shows 4 items starting from tail=2)
      // indices: 2, 3, 4, 0
      // buffer[2]=2 (from first write)
      // buffer[3]=3 (from first write)
      // buffer[4]=20 (from second write)
      // buffer[0]=21 (from second write)
      dut.io.dataOut(0).expect(2)
      dut.io.dataOut(1).expect(3)
      dut.io.dataOut(2).expect(20)
      dut.io.dataOut(3).expect(21)
    }
  }
}
