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
import coralnpu.float.{FloatInstruction, FpFormat}
import org.scalatest.freespec.AnyFreeSpec
import org.scalatest.matchers.should.Matchers

class DecodeInstructionSpec extends AnyFreeSpec with Matchers with ChiselSim {
  val p = new Parameters()

  class DecodeTester(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst       = Input(UInt(32.W))
      val csrFrm     = Input(UInt(3.W))
      val undef      = Output(Bool())
      val floatValid = Output(Bool())
      val floatRs1   = Output(Bool())
      val scalarRs1  = Output(Bool())
      val scalarRd   = Output(Bool())
      val srcFmt     = Output(UInt(3.W))
      val dstFmt     = Output(UInt(3.W))
    })

    val d = DecodeInstruction(p, pipeline = 0, addr = 0.U, op = io.inst, csrFrm = io.csrFrm)
    io.undef      := d.undef
    io.floatValid := d.float.map(_.valid).getOrElse(false.B)
    io.floatRs1   := d.float.map(_.bits.float_rs1).getOrElse(false.B)
    io.scalarRs1  := d.float.map(_.bits.scalar_rs1).getOrElse(false.B)
    io.scalarRd   := d.float.map(_.bits.scalar_rd).getOrElse(false.B)
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
        // rs3 = 20, 24, 28 alias FEQ/FLT/FLE, FCVT.W.S, FMV.X.W/FCLASS funct5 (scalar_rd)
        // rs3 = 26 (5'b11010, aliases FCVT.S.W funct5) and rs3 = 30 (5'b11110, aliases FMV.W.X funct5)
        // rs3 = 8 (5'b01000) with rs2 = 6 (5'b00110) aliases FCVT.S.BF16 funct5/rs2
        for {
          opc <- r4Opcodes
          rs3 <- Seq(8L, 20L, 24L, 26L, 28L, 30L)
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
            dut.io.scalarRd.peek().litValue == 0,
            s"R4 opcode 0x${opc.toHexString} with rs3=$rs3 must set scalar_rd=0"
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

    "should gate Zfbfmin instructions on enableZfbfmin" in {
      val zfbfminWords = Seq(
        "flh"         -> 0x00051087L, // flh f1, 0(x10)
        "fsh"         -> 0x00151027L, // fsh f1, 0(x10)
        "fcvt.s.bf16" -> 0x406500d3L, // fcvt.s.bf16 f1, f10, rne (fmt=0, rs2=6)
        "fcvt.bf16.s" -> 0x448500d3L, // fcvt.bf16.s f1, f10, rne (fmt=2, rs2=8)
        "fmv.x.h"     -> 0xe4050553L, // fmv.x.h x10, f10 (fmt=2, funct5=11100, rm=0)
        "fmv.h.x"     -> 0xf40500d3L  // fmv.h.x f1, x10 (fmt=2, funct5=11110, rm=0)
      )

      val fpNoBf16 = new Parameters()
      fpNoBf16.enableFloat = true
      fpNoBf16.enableZfbfmin = false
      simulate(new DecodeTester(fpNoBf16)) { dut =>
        for ((name, pat) <- FloatInstruction.table(fpNoBf16)) {
          dut.io.inst.poke(pat.value.U(32.W))
          dut.clock.step()
          assert(
            dut.io.floatValid.peek().litValue == 1 && dut.io.undef.peek().litValue == 0,
            s"RV32F instruction $name must remain valid when enableZfbfmin=false"
          )
        }
        for ((name, word) <- zfbfminWords) {
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.floatValid.peek().litValue == 0,
            s"Zfbfmin instruction $name (0x${word.toHexString}) must set floatValid=0 when enableZfbfmin=false"
          )
          assert(
            dut.io.undef.peek().litValue == 1,
            s"Zfbfmin instruction $name (0x${word.toHexString}) must set undef=1 when enableZfbfmin=false"
          )
          assert(
            dut.io.srcFmt.peek().litValue == FpFormat.FP32.litValue,
            s"Zfbfmin instruction $name must not drive FP16ALT src_fmt when enableZfbfmin=false"
          )
        }
      }

      val fpWithBf16 = new Parameters()
      fpWithBf16.enableFloat = true
      fpWithBf16.enableZfbfmin = true
      simulate(new DecodeTester(fpWithBf16)) { dut =>
        for ((name, word) <- zfbfminWords) {
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.floatValid.peek().litValue == 1 && dut.io.undef.peek().litValue == 0,
            s"Zfbfmin instruction $name (0x${word.toHexString}) must be valid when enableZfbfmin=true"
          )
        }
      }
    }

    "should reject non-32b quadrants, unassigned OP-FP encodings, and invalid rounding modes" in {
      val fpParams = new Parameters()
      fpParams.enableFloat = true
      fpParams.enableZfbfmin = true
      simulate(new DecodeTester(fpParams)) { dut =>
        val illegalEncodings = Seq(
          // Non-2'b11 compressed quadrant words matching FP inst[6:2]
          0x00002004L, // LOAD-FP inst[6:2] with inst[1:0]=00
          0x00002025L, // STORE-FP inst[6:2] with inst[1:0]=01
          0x00000042L, // MADD inst[6:2] with inst[1:0]=10
          0x00000050L, // OP-FP inst[6:2] with inst[1:0]=00
          0x00000051L, // OP-FP inst[6:2] with inst[1:0]=01
          0x00000052L, // OP-FP inst[6:2] with inst[1:0]=10
          // Unassigned OP-FP funct5 / rs2 / rm with fmt=0
          (0x06L << 27) | 0x53L,              // Unassigned funct5=00110
          (0x1fL << 27) | 0x53L,              // Unassigned funct5=11111
          (0x08L << 27) | (0L << 20) | 0x53L, // F2F funct5=01000 with rs2=0, fmt=0
          (0x0bL << 27) | (1L << 20) | 0x53L, // fsqrt.s with non-zero rs2=1
          (0x04L << 27) | (3L << 12) | 0x53L, // fsgnj* with unassigned rm=3
          (0x05L << 27) | (2L << 12) | 0x53L, // fmin/max with unassigned rm=2
          (0x14L << 27) | (3L << 12) | 0x53L, // feq/flt/fle with unassigned rm=3
          (0x18L << 27) | (2L << 20) | 0x53L, // fcvt.l.s (rs2=2) on RV32
          (0x1aL << 27) | (2L << 20) | 0x53L, // fcvt.s.l (rs2=2) on RV32
          (0x1cL << 27) | (1L << 20) | 0x53L, // fmv.x.w with non-zero rs2=1
          (0x1cL << 27) | (2L << 12) | 0x53L, // fmv.x.w / fclass.s with rm=2
          (0x1eL << 27) | (1L << 20) | 0x53L, // fmv.w.x with non-zero rs2=1
          (0x1eL << 27) | (1L << 12) | 0x53L, // fmv.w.x funct5 with rm=1
          // Static reserved rounding modes rm=5 and rm=6 on rounding-mode FP ops
          (0x0bL << 27) | (5L << 12) | 0x53L,                          // fsqrt.s with rm=5
          (0x18L << 27) | (6L << 12) | 0x53L,                          // fcvt.w.s with rm=6
          (0x08L << 27) | (6L << 20) | (5L << 12) | 0x53L,             // fcvt.s.bf16 with rm=5
          (0x08L << 27) | (2L << 25) | (8L << 20) | (6L << 12) | 0x53L // fcvt.bf16.s with rm=6
        )

        dut.io.csrFrm.poke(0.U)
        for (word <- illegalEncodings) {
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.floatValid.peek().litValue == 0 && dut.io.undef.peek().litValue == 1,
            s"Illegal FP encoding 0x${word.toHexString} must set floatValid=0 and undef=1"
          )
        }

        // Dynamic rounding (rm=7) with reserved csrFrm >= 5 must fault on all FRM-consuming ops,
        // while non-FRM ops (e.g. fsgnj.s) must remain valid.
        val dynRoundingWords = Seq(
          (0x0bL << 27) | (7L << 12) | 0x53L,                          // fsqrt.s dyn
          (0x18L << 27) | (7L << 12) | 0x53L,                          // fcvt.w.s dyn
          (0x18L << 27) | (1L << 20) | (7L << 12) | 0x53L,             // fcvt.wu.s dyn
          (0x08L << 27) | (6L << 20) | (7L << 12) | 0x53L,             // fcvt.s.bf16 dyn
          (0x08L << 27) | (2L << 25) | (8L << 20) | (7L << 12) | 0x53L // fcvt.bf16.s dyn
        )
        val fsgnjWord = (0x04L << 27) | (0L << 12) | 0x53L // fsgnj.s (rm=000, non-FRM)

        for (badFrm <- Seq(5, 6, 7)) {
          dut.io.csrFrm.poke(badFrm.U)
          for (word <- dynRoundingWords) {
            dut.io.inst.poke(word.U(32.W))
            dut.clock.step()
            assert(
              dut.io.floatValid.peek().litValue == 0 && dut.io.undef.peek().litValue == 1,
              s"Dynamic rounding word 0x${word.toHexString} must fault when csrFrm=$badFrm"
            )
          }
          dut.io.inst.poke(fsgnjWord.U(32.W))
          dut.clock.step()
          assert(
            dut.io.floatValid.peek().litValue == 1 && dut.io.undef.peek().litValue == 0,
            s"fsgnj.s must remain valid when csrFrm=$badFrm"
          )
        }
      }
    }
  }
}
