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

package bus

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec
import coralnpu.Parameters

class GPIOSpec extends AnyFreeSpec with ChiselSim with TLULTestUtils {
  val p      = new Parameters
  val tlul_p = p.toTLUL()
  val gp     = GPIOParameters(width = 8)

  "GPIO" in {
    simulate(new GPIO(tlul_p, gp)) { dut =>
      def resetDut(): Unit = {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)
        dut.io.gpio_i.poke(0.U)
      }

      // GPIO Output Control
      {
        resetDut()

        // Set output data
        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0xa5.U) // DATA_OUT
        assert(dut.io.gpio_o.peek().litValue == 0xa5)

        // Enable output
        tlWrite(dut.io.tl, dut.clock, 0x08.U, 0xff.U) // OUT_EN
        assert(dut.io.gpio_en_o.peek().litValue == 0xff)

        // Read back
        assert(tlReadData(dut.io.tl, dut.clock, 0x04.U) == 0xa5)
        assert(tlReadData(dut.io.tl, dut.clock, 0x08.U) == 0xff)
      }

      // GPIO Input Read
      {
        resetDut()

        // Drive input
        dut.io.gpio_i.poke(0x5a.U)
        dut.clock.step()

        // Read input register
        assert(tlReadData(dut.io.tl, dut.clock, 0x00.U) == 0x5a)
      }
    }
  }
}
