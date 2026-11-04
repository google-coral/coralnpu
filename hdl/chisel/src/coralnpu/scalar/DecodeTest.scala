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
import coralnpu.float.FpFormat
import org.scalatest.freespec.AnyFreeSpec
import org.scalatest.matchers.should.Matchers

class DecodeInstructionSpec extends AnyFreeSpec with Matchers with ChiselSim {
  val p = new Parameters()

  class DecodeTester(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst       = Input(UInt(32.W))
      val undef      = Output(Bool())
      val floatValid = Output(Bool())
      val floatRs1   = Output(Bool())
      val scalarRs1  = Output(Bool())
      val srcFmt     = Output(UInt(3.W))
      val dstFmt     = Output(UInt(3.W))
    })

    val d = DecodeInstruction(p, pipeline = 0, addr = 0.U, op = io.inst, csrFrm = 0.U(3.W))
    io.undef      := d.undef
    io.floatValid := d.float.map(_.valid).getOrElse(false.B)
    io.floatRs1   := d.float.map(_.bits.float_rs1).getOrElse(false.B)
    io.scalarRs1  := d.float.map(_.bits.scalar_rs1).getOrElse(false.B)
    io.srcFmt     := d.float.map(_.bits.src_fmt.asUInt).getOrElse(0.U)
    io.dstFmt     := d.float.map(_.bits.dst_fmt.asUInt).getOrElse(0.U)
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

    "should not alias R4 rs3 with OP-FP funct5 in FloatInstruction.decode" in {
      val fpParams = new Parameters()
      fpParams.enableFloat = true
      fpParams.enableZfbfmin = true
      simulate(new DecodeTester(fpParams)) { dut =>
        val r4Opcodes = Seq(
          0x43L, // FMADD.S
          0x47L, // FMSUB.S
          0x4bL, // FNMSUB.S
          0x4fL  // FNMADD.S
        )
        // rs3 = 26 (5'b11010, aliases FCVT.S.W funct5) and rs3 = 30 (5'b11110, aliases FMV.W.X funct5)
        // rs3 = 8 (5'b01000) with rs2 = 6 (5'b00110) aliases FCVT.S.BF16 funct5/rs2
        for {
          opc <- r4Opcodes
          rs3 <- Seq(8L, 26L, 30L)
        } {
          val rs2  = 6L
          val rs1  = 6L
          val rm   = 0L
          val rd   = 1L
          val word =
            (rs3 << 27) | (0L << 25) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | opc
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.floatValid.peek().litValue == 1,
            s"R4 opcode 0x${opc.toHexString} with rs3=$rs3 should be valid"
          )
          assert(
            dut.io.floatRs1.peek().litValue == 1,
            s"R4 opcode 0x${opc.toHexString} with rs3=$rs3 must set float_rs1=1"
          )
          assert(
            dut.io.scalarRs1.peek().litValue == 0,
            s"R4 opcode 0x${opc.toHexString} with rs3=$rs3 must set scalar_rs1=0"
          )
          assert(
            dut.io.srcFmt.peek().litValue == FpFormat.FP32.litValue,
            s"R4 opcode 0x${opc.toHexString} with rs3=$rs3 must use FP32 src_fmt"
          )
          assert(
            dut.io.dstFmt.peek().litValue == FpFormat.FP32.litValue,
            s"R4 opcode 0x${opc.toHexString} with rs3=$rs3 must use FP32 dst_fmt"
          )
        }
        // R4 opcodes with fmt=2 (2'b10, BF16) are not valid Zfbfmin instructions even if rs3/rs2 match fcvt.bf16.s or fmv.x.h
        for (opc <- r4Opcodes) {
          val illegalBf16R4 =
            (8L << 27) | (2L << 25) | (8L << 20) | (1L << 15) | (0L << 12) | (1L << 7) | opc
          dut.io.inst.poke(illegalBf16R4.U(32.W))
          dut.clock.step()
          assert(
            dut.io.floatValid.peek().litValue == 0,
            s"R4 opcode 0x${opc.toHexString} with fmt=2 must be invalid"
          )
          assert(
            dut.io.undef.peek().litValue == 1,
            s"R4 opcode 0x${opc.toHexString} with fmt=2 must decode as undef"
          )
        }
      }
    }

    "should decode fence and fence.tso as valid (undef == false)" in {
      simulate(new DecodeTester(p)) { dut =>
        val validFences = Seq(
          0x0ff0000fL, // fence iorw, iorw
          0x0330000fL, // fence rw, rw
          0x8330000fL  // fence.tso
        )
        for (word <- validFences) {
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.undef.peek().litValue == 0,
            s"Fence instruction 0x${word.toHexString} decoded as undef"
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
          0x00000000L | 0x2bL, // Invalid opcode
          0x1330000fL,         // Invalid fence fm=0001
          0x8110000fL          // Invalid fence.tso pred/succ!=0011
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
