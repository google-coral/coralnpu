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

class FetcherSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters

  "Fetcher" in {
    simulate(new Fetcher(p)) { dut =>
      // Initialization
      {
        dut.io.fetch.valid.expect(0)
      }

      // Reset
      dut.reset.poke(true.B)
      dut.clock.step()
      dut.reset.poke(false.B)

      // Fetch
      {
        dut.io.ctrl.bits.poke(32.U)
        dut.io.ctrl.valid.poke(true.B)
        dut.io.ibus.ready.poke(true.B)
        dut.io.ctrl.ready.expect(true.B)
        dut.io.ibus.valid.expect(true.B)
        dut.clock.step()
        dut.io.ibus.ready.poke(false.B)
        dut.io.ctrl.ready.expect(false.B)
        dut.io.ibus.rdata.poke("x0012d678000000000012d687".U(256.W))
        dut.io.fetch.valid.expect(0)
        dut.clock.step()
        dut.io.fetch.valid.expect(true.B)
        dut.io.fetch.bits.addr.expect(32)
        dut.io.fetch.bits.inst(0).expect(1234567)
        dut.io.fetch.bits.inst(1).expect(0)
        dut.io.fetch.bits.inst(2).expect(1234552)
      }
    }
  }
}
