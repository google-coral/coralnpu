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

package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class MluSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters

  "Mlu" in {
    simulate(new Mlu(p)) { dut =>
      // Initialization
      {
        dut.io.rd.valid.expect(0)
      }

      // Multiply
      {
        dut.io.req(0).bits.addr.poke(13)
        dut.io.req(0).bits.op.poke(MluOp.MUL)
        dut.io.req(0).valid.poke(true.B)
        dut.io.req(1).valid.poke(false.B)
        dut.io.req(2).valid.poke(false.B)
        dut.io.req(3).valid.poke(false.B)
        for (i <- 0 until 4) {
          dut.io.rs1(i).valid.poke(true.B)
          dut.io.rs1(i).data.poke(i + 2)
          dut.io.rs2(i).valid.poke(true.B)
          dut.io.rs2(i).data.poke(i + 2)
        }

        dut.clock.step()
        dut.io.req(0).valid.poke(false.B)
        dut.io.rd.ready.poke(true.B)

        dut.clock.step()
        dut.io.rd.valid.expect(1)
        dut.io.rd.bits.addr.expect(13)
        dut.io.rd.bits.data.expect(4)

        dut.clock.step()
        dut.io.rd.valid.expect(0)
        dut.io.rd.ready.poke(false.B)
      }
    }
  }
}

class Mlu64Spec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters(xlen = 64)

  "Multiply Word (MULW)" in {
    simulate(new Mlu(p)) { dut =>
      dut.io.req(0).bits.addr.poke(15)
      dut.io.req(0).bits.op.poke(MluOp.MULW)
      dut.io.req(0).valid.poke(true.B)
      dut.io.req(1).valid.poke(false.B)
      dut.io.req(2).valid.poke(false.B)
      dut.io.req(3).valid.poke(false.B)

      dut.io.rs1(0).valid.poke(true.B)
      dut.io.rs1(0).data.poke(0x000000007fffffffL)
      dut.io.rs2(0).valid.poke(true.B)
      dut.io.rs2(0).data.poke(2L)

      dut.clock.step()
      dut.io.req(0).valid.poke(false.B)
      dut.io.rd.ready.poke(true.B)

      dut.clock.step()
      dut.io.rd.valid.expect(1)
      dut.io.rd.bits.addr.expect(15)
      dut.io.rd.bits.data
        .expect(
          BigInt("fffffffffffffffe", 16)
        ) // (0x7fffffff * 2) = 0xfffffffe, sign extended to 64 bits

      dut.clock.step()
      dut.io.rd.valid.expect(0)
      dut.io.rd.ready.poke(false.B)
    }
  }
}
