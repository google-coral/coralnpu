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
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class RouterWrapper[T <: Data](gen: T, route: T => Seq[Bool]) extends Module {
  // We don't know 'n' statically in the wrapper constructor without calling route,
  // but we can call it on a wire to find out the size for the outer IO.
  // Actually, during elaboration we can do:
  val dummy = Wire(gen)
  dummy := DontCare
  val n = route(dummy).length

  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(gen))
    val out = Vec(n, Decoupled(gen))
  })

  io.out <> Router(io.in, route)
}

class RouterSpec extends AnyFreeSpec with ChiselSim {
  "Router should route based on function" in {
    val routeFn = (x: UInt) => Seq(x === 0.U, x === 1.U, x === 2.U)
    simulate(new RouterWrapper(UInt(8.W), routeFn)) { dut =>
      // Initial state
      dut.io.in.valid.poke(false)
      dut.io.in.bits.poke(0.U)
      for (i <- 0 until 3) {
        dut.io.out(i).ready.poke(false)
      }

      // Test routing to port 0 (value 0)
      dut.io.in.bits.poke(0.U)
      dut.io.in.valid.poke(true)
      dut.io.out(0).valid.expect(true.B)
      dut.io.out(1).valid.expect(false.B)
      dut.io.out(2).valid.expect(false.B)
      dut.io.out(0).bits.expect(0)

      // Ready propagation for port 0
      dut.io.in.ready.expect(false.B)
      dut.io.out(0).ready.poke(true)
      dut.io.in.ready.expect(true.B)
      dut.clock.step()

      // Test routing to port 1 (value 1)
      dut.io.out(0).ready.poke(false)
      dut.io.in.bits.poke(1.U)
      dut.io.in.valid.poke(true)
      dut.io.out(0).valid.expect(false.B)
      dut.io.out(1).valid.expect(true.B)
      dut.io.out(2).valid.expect(false.B)
      dut.io.out(1).bits.expect(1)

      // Ready propagation for port 1
      dut.io.in.ready.expect(false.B)
      dut.io.out(1).ready.poke(true)
      dut.io.in.ready.expect(true.B)
      dut.clock.step()

      // Test routing to port 2 (value 2)
      dut.io.out(1).ready.poke(false)
      dut.io.in.bits.poke(2.U)
      dut.io.in.valid.poke(true)
      dut.io.out(0).valid.expect(false.B)
      dut.io.out(1).valid.expect(false.B)
      dut.io.out(2).valid.expect(true.B)
      dut.io.out(2).bits.expect(2)

      // Ready propagation for port 2
      dut.io.in.ready.expect(false.B)
      dut.io.out(2).ready.poke(true)
      dut.io.in.ready.expect(true.B)
      dut.clock.step()
    }
  }
}
