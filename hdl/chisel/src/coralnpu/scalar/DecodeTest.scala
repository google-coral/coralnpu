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
import org.scalatest.matchers.should.Matchers

class DecodeInstructionSpec extends AnyFreeSpec with Matchers with ChiselSim {
  val p = new Parameters()

  class DecodeTester(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst  = Input(UInt(32.W))
      val undef = Output(Bool())
    })

    val d = DecodeInstruction(p, pipeline = 0, addr = 0.U, op = io.inst, csrFrm = 0.U)
    io.undef := d.undef
  }

  "DecodeInstruction" - {
    "should decode all table instructions as valid (undef == false)" in {
      simulate(new DecodeTester(p)) { dut =>
        val tbl = DecodeInstruction.table(p)
        for ((name, pat) <- tbl) {
          dut.io.inst.poke(pat.value.U(32.W))
          dut.clock.step()
          assert(
            dut.io.undef.peek().litValue == 0,
            s"Instruction $name (0x${pat.value.toString(16)}) decoded as undef"
          )
        }
      }
    }

    "should decode invalid opcodes as undefined (undef == true)" in {
      simulate(new DecodeTester(p)) { dut =>
        val invalidWords = Seq(
          0x00000000L,         // All zeros
          0xffffffffL,         // All ones
          0x00000000L | 0x7bL, // Invalid custom opcode
          0x00000000L | 0x0bL, // Invalid opcode
          0x00000000L | 0x2bL  // Invalid opcode
        )
        for (word <- invalidWords) {
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.undef.peek().litValue == 1,
            s"Word 0x${word.toHexString} should decode as undef"
          )
        }
      }
    }
  }
}
