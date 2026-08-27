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

class Fp32Tester extends Module {
  val io = IO(new Bundle {
    val in      = Input(UInt(32.W))
    val is_zero = Output(Bool())
    val is_inf  = Output(Bool())
    val is_nan  = Output(Bool())
  })

  val fp = Fp32.fromWord(io.in)
  io.is_zero := fp.isZero()
  io.is_inf  := fp.isInf()
  io.is_nan  := fp.isNan()
}

class Fp32CvtuTester extends Module {
  val io = IO(new Bundle {
    val int         = Input(UInt(32.W))
    val fp_sign     = Output(Bool())
    val fp_mantissa = Output(UInt(23.W))
    val fp_exponent = Output(UInt(8.W))
  })

  val fp = Wire(new Fp32)
  fp             := Fp32.fromInteger(io.int, false.B)
  io.fp_sign     := fp.sign
  io.fp_mantissa := fp.mantissa
  io.fp_exponent := fp.exponent
}

class Fp32CvtTester extends Module {
  val io = IO(new Bundle {
    val int         = Input(SInt(32.W))
    val fp_sign     = Output(Bool())
    val fp_mantissa = Output(UInt(23.W))
    val fp_exponent = Output(UInt(8.W))
  })

  val fp = Wire(new Fp32)
  fp             := Fp32.fromInteger(io.int.asUInt, true.B)
  io.fp_sign     := fp.sign
  io.fp_mantissa := fp.mantissa
  io.fp_exponent := fp.exponent
}

class FpSpec extends AnyFreeSpec with ChiselSim {
  "Classification (Zero, Inf, Nan)" in {
    simulate(new Fp32Tester()) { dut =>
      // Zero
      {
        dut.io.in.poke(0.U)
        dut.io.is_zero.expect(1)
        dut.io.is_inf.expect(0)
        dut.io.is_nan.expect(0)
      }

      // Inf
      {
        dut.io.in.poke(BigInt("0" + "11111111" + "00000000000000000000000", 2))
        dut.io.is_zero.expect(0)
        dut.io.is_inf.expect(1)
        dut.io.is_nan.expect(0)

        dut.io.in.poke(BigInt("1" + "11111111" + "00000000000000000000000", 2))
        dut.io.is_zero.expect(0)
        dut.io.is_inf.expect(1)
        dut.io.is_nan.expect(0)
      }

      // Nan
      {
        dut.io.in.poke(BigInt("0" + "11111111" + "00011000011000111000100", 2))
        dut.io.is_zero.expect(0)
        dut.io.is_inf.expect(0)
        dut.io.is_nan.expect(1)

        dut.io.in.poke(BigInt("1" + "11111111" + "00011000011000111000100", 2))
        dut.io.is_zero.expect(0)
        dut.io.is_inf.expect(0)
        dut.io.is_nan.expect(1)
      }
    }
  }

  "Convert UInt to Float" in {
    simulate(new Fp32CvtuTester) { dut =>
      for (i <- 0 until 20000000 by 3000) {
        dut.io.int.poke(i)
        dut.clock.step()
        assertResult(i.toFloat) {
          PeekFloat(
            dut.io.fp_sign.peek().litValue.toInt,
            dut.io.fp_exponent.peek().litValue.toInt,
            dut.io.fp_mantissa.peek().litValue.toInt
          )
        }
      }
    }
  }

  "Convert SInt to Float" in {
    simulate(new Fp32CvtTester) { dut =>
      for (i <- -20000001 until 20000000 by 3000) {
        dut.io.int.poke(i)
        dut.clock.step()
        assertResult(i.toFloat) {
          PeekFloat(
            dut.io.fp_sign.peek().litValue.toInt,
            dut.io.fp_exponent.peek().litValue.toInt,
            dut.io.fp_mantissa.peek().litValue.toInt
          )
        }
      }
    }
  }
}
