// Copyright 2024 Google LLC
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

class InstructionBufferSpec extends AnyFreeSpec with ChiselSim {
  "InstructionBuffer" in {
    simulate(new InstructionBuffer(gen = UInt(16.W), n = 4, window = 16)) { dut =>
      def resetDut(): Unit = {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)
        dut.io.feedIn.nValid.poke(0)
        for (i <- 0 until 4) {
          dut.io.out(i).ready.poke(0)
        }
        dut.io.flush.poke(0)
      }

      // Fill
      {
        dut.io.feedIn.nValid.poke(4)
        dut.io.feedIn.bits(0).poke(500)
        dut.io.feedIn.bits(1).poke(501)
        dut.io.feedIn.bits(2).poke(502)
        dut.io.feedIn.bits(3).poke(503)
        dut.clock.step()
        for (i <- 0 until 4) {
          dut.io.out(i).valid.expect(1)
          dut.io.out(i).bits.expect(500 + i)
        }
        dut.io.feedIn.nReady.expect(4)
        dut.io.feedIn.bits(0).poke(504)
        dut.io.feedIn.bits(1).poke(505)
        dut.io.feedIn.bits(2).poke(506)
        dut.io.feedIn.bits(3).poke(507)
        dut.clock.step()
        for (i <- 0 until 4) {
          dut.io.out(i).valid.expect(1)
          dut.io.out(i).bits.expect(500 + i)
        }
        dut.io.feedIn.nReady.expect(4)
        dut.io.feedIn.bits(0).poke(508)
        dut.io.feedIn.bits(1).poke(509)
        dut.io.feedIn.bits(2).poke(510)
        dut.io.feedIn.bits(3).poke(511)
        dut.clock.step()
        for (i <- 0 until dut.io.out.length) {
          dut.io.out(i).valid.expect(1)
          dut.io.out(i).bits.expect(500 + i)
        }
        dut.io.nEnqueued.expect(12)
        dut.io.feedIn.nReady.expect(4)
      }

      resetDut()

      // Remove
      {
        dut.io.feedIn.nValid.poke(4)
        dut.io.feedIn.bits(0).poke(500)
        dut.io.feedIn.bits(1).poke(501)
        dut.io.feedIn.bits(2).poke(502)
        dut.io.feedIn.bits(3).poke(503)
        dut.clock.step()
        dut.io.feedIn.bits(0).poke(504)
        dut.io.feedIn.bits(1).poke(505)
        dut.io.feedIn.bits(2).poke(506)
        dut.io.feedIn.bits(3).poke(507)
        dut.clock.step()
        dut.io.feedIn.bits(0).poke(508)
        dut.io.feedIn.bits(1).poke(509)
        dut.io.feedIn.bits(2).poke(510)
        dut.io.feedIn.bits(3).poke(511)
        dut.clock.step()

        for (i <- 0 until 4) {
          dut.io.out(i).valid.expect(1)
        }
        dut.io.nEnqueued.expect(12)
      }

      resetDut()

      // Add and Remove
      {
        dut.io.feedIn.nValid.poke(4)
        dut.io.feedIn.bits(0).poke(300)
        dut.io.feedIn.bits(1).poke(301)
        dut.io.feedIn.bits(2).poke(302)
        dut.io.feedIn.bits(3).poke(303)
        dut.clock.step()

        // Remove two (must be in order due to CircularBufferMulti being in order FIFO)
        dut.io.out(0).ready.poke(1)
        dut.io.out(1).ready.poke(1)

        // Add 3 elements
        dut.io.feedIn.nValid.poke(3)
        dut.io.feedIn.bits(0).poke(400)
        dut.io.feedIn.bits(1).poke(401)
        dut.io.feedIn.bits(2).poke(402)

        dut.clock.step()

        for (i <- 0 until 4) {
          dut.io.out(i).valid.expect(1)
        }
        dut.io.nEnqueued.expect(5)

        dut.io.out(0).bits.expect(302)
        dut.io.out(1).bits.expect(303)
        dut.io.out(2).bits.expect(400)
        dut.io.out(3).bits.expect(401)
      }

      resetDut()

      // Add and Remove Max Capacity
      {
        dut.io.feedIn.nValid.poke(4)
        dut.io.feedIn.bits(0).poke(300)
        dut.io.feedIn.bits(1).poke(301)
        dut.io.feedIn.bits(2).poke(302)
        dut.io.feedIn.bits(3).poke(303)
        dut.clock.step()
        dut.io.feedIn.bits(0).poke(304)
        dut.io.feedIn.bits(1).poke(305)
        dut.io.feedIn.bits(2).poke(306)
        dut.io.feedIn.bits(3).poke(307)
        dut.clock.step()
        dut.io.feedIn.bits(0).poke(308)
        dut.io.feedIn.bits(1).poke(309)
        dut.io.feedIn.bits(2).poke(310)
        dut.io.feedIn.bits(3).poke(311)
        dut.clock.step()
        dut.io.feedIn.bits(0).poke(312)
        dut.io.feedIn.bits(1).poke(313)
        dut.io.feedIn.bits(2).poke(314)
        dut.io.feedIn.bits(3).poke(315)
        dut.clock.step()
        dut.io.feedIn.nValid.poke(0)

        dut.io.nEnqueued.expect(16)
        dut.io.nSpace.expect(0)

        // NOTE: FIFO ONLY with current version of CircularBufferMulti. May change.
        dut.io.out(0).ready.poke(1)
        dut.io.out(1).ready.poke(1)
        dut.io.out(2).ready.poke(1)
        dut.clock.step()

        dut.io.out(0).bits.expect(303)
        dut.io.out(1).bits.expect(304)
        dut.io.out(2).bits.expect(305)
        dut.io.out(3).bits.expect(306)
      }

      resetDut()

      // Flush
      {
        dut.io.feedIn.nValid.poke(4)
        dut.io.feedIn.bits(0).poke(500)
        dut.io.feedIn.bits(1).poke(501)
        dut.io.feedIn.bits(2).poke(502)
        dut.io.feedIn.bits(3).poke(503)
        dut.clock.step()
        dut.io.feedIn.nValid.poke(3)
        dut.io.feedIn.bits(0).poke(900)
        dut.io.feedIn.bits(1).poke(301)
        dut.io.feedIn.bits(2).poke(102)
        dut.clock.step()

        dut.io.flush.poke(1)
        dut.clock.step()

        dut.io.nEnqueued.expect(0)
        dut.io.nSpace.expect(16)
      }
    }
  }
}
