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

package common

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec
import scala.util.Random

trait IndexAllocatorSpec extends ChiselSim { this: AnyFreeSpec =>
  def makeDut(): IndexAllocator

  def spec(capacity: Int) = {
    "Operations" in {
      simulate(makeDut()) { dut =>
        def resetDut(): Unit = {
          dut.reset.poke(true.B)
          dut.clock.step()
          dut.reset.poke(false.B)
          dut.io.alloc.ready.poke(false.B)
          dut.io.free.valid.poke(false.B)
        }

        // Initialize
        {
          dut.io.alloc.valid.expect(true.B)
          dut.io.alloc.bits.expect(0.U)
          dut.io.free.ready.expect(false.B)
        }

        resetDut()

        // Allocate all
        {
          dut.io.alloc.ready.poke(true.B)
          for (i <- (0 until capacity)) {
            dut.io.alloc.valid.expect(true.B)
            dut.io.alloc.bits.expect(i.U)
            dut.clock.step()
          }
          dut.io.alloc.valid.expect(false.B)
        }

        resetDut()

        // No pipe
        {
          dut.io.alloc.ready.poke(true.B)
          dut.io.free.ready.expect(false.B)
        }

        resetDut()

        // Flow
        {
          dut.io.alloc.ready.poke(true.B)
          for (i <- (0 until capacity)) {
            dut.clock.step()
          }
          dut.io.free.valid.poke(true.B)
          dut.io.free.bits.poke(1.U)
          dut.io.alloc.valid.expect(true.B)
          dut.io.alloc.bits.expect(1.U)
        }

        resetDut()

        // Out of order free
        {
          dut.io.alloc.ready.poke(true.B)
          for (i <- (0 until capacity)) {
            dut.clock.step()
          }
          dut.io.alloc.ready.poke(false.B)
          dut.io.free.valid.poke(true.B)
          val s = Random.shuffle((0 until capacity).toVector)
          for (i <- s) {
            dut.io.free.bits.poke(i.U)
            dut.clock.step()
          }
          // Dump all Index for inspection
          dut.io.alloc.ready.poke(true.B)
          dut.io.free.valid.poke(false.B)
          for (i <- s) {
            dut.io.alloc.valid.expect(true.B)
            dut.io.alloc.bits.expect(i.U)
            dut.clock.step()
          }
        }

        resetDut()

        // Alloc and free on same cycle
        {
          dut.io.alloc.ready.poke(true.B)
          dut.clock.step()
          // We allocated 0
          // Now we allocate 1 and free 0
          dut.io.free.valid.poke(true.B)
          dut.io.free.bits.poke(0.U)
          dut.clock.step()
          // Dump all Index for inspection
          dut.io.free.valid.poke(false.B)
          val s = 0 +: (2 until capacity).toVector
          for (i <- s) {
            dut.io.alloc.valid.expect(true.B)
            dut.io.alloc.bits.expect(i.U)
            dut.clock.step()
          }
        }
      }
    }
  }
}

class IndexAllocatorShiftingSpec extends AnyFreeSpec with IndexAllocatorSpec {
  def makeDut() = new IndexAllocatorShifting(4)
  behave like spec(4)
}
