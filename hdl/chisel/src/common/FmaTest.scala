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

class FmaTester extends Module {
  val io = IO(new Bundle {
    val ina    = Input(UInt(32.W))
    val inb    = Input(UInt(32.W))
    val inc    = Input(UInt(32.W))
    val state1 = Output(new FmaState1)
    val state2 = Output(new FmaState2)
    val out    = Output(new Fp32)
  })

  val fp_a = Fp32.fromWord(io.ina)
  val fp_b = Fp32.fromWord(io.inb)
  val fp_c = Fp32.fromWord(io.inc)

  val cmd = Wire(new FmaCmd)
  cmd.ina := fp_a
  cmd.inb := fp_b
  cmd.inc := fp_c

  val stage1 = Fma.FmaStage1(cmd)
  val stage2 = Fma.FmaStage2(stage1)
  io.state1 := stage1
  io.state2 := stage2
  io.out    := Fma.FmaStage3(stage2)
}

class FmaSpec extends AnyFreeSpec with ChiselSim {
  def Float2BigInt(x: Float): BigInt = {
    val abs = x.abs
    var int = BigInt(java.lang.Float.floatToIntBits(abs))
    if (x < 0) {
      int += (BigInt(1) << 31)
    }
    int
  }

  def GetFloat(exponent: Int, mantissa: Int): Float = {
    val int_val = (exponent << 23) + mantissa
    java.lang.Float.intBitsToFloat(int_val)
  }

  "FMA Operations" in {
    simulate(new FmaTester()) { dut =>
      // Mul Zero
      {
        dut.io.ina.poke(Float2BigInt(0))
        dut.io.inb.poke(Float2BigInt(42))
        dut.io.inc.poke(Float2BigInt(0))
        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(0)
        dut.io.out.mantissa.expect(0)
      }

      // Mul Identity
      {
        dut.io.ina.poke(Float2BigInt(1))
        dut.io.inb.poke(Float2BigInt(42))
        dut.io.inc.poke(Float2BigInt(0))
        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(132)
        dut.io.out.mantissa.expect(2621440)
      }

      // Mul Negative
      {
        dut.io.ina.poke(Float2BigInt(-1.0f))
        dut.io.inb.poke(Float2BigInt(42))
        dut.io.inc.poke(Float2BigInt(0))
        dut.io.out.sign.expect(1)
        dut.io.out.exponent.expect(132)
        dut.io.out.mantissa.expect(2621440)
      }

      // Mul Half
      {
        dut.io.ina.poke(Float2BigInt(0.5f))
        dut.io.inb.poke(Float2BigInt(42))
        dut.io.inc.poke(Float2BigInt(0))
        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(131)
        dut.io.out.mantissa.expect(2621440)
      }

      // Mul Overflow
      {
        dut.io.ina.poke(Float2BigInt(2e30f))
        dut.io.inb.poke(Float2BigInt(2e30f))
        dut.io.inc.poke(Float2BigInt(0))
        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(255)
        dut.io.out.mantissa.expect(0)
      }

      // Mul Rounds to Zero
      {
        dut.io.ina.poke(Float2BigInt(1e-30f))
        dut.io.inb.poke(Float2BigInt(1e-30f))
        dut.io.inc.poke(Float2BigInt(0))
        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(0)
        dut.io.out.mantissa.expect(0)
      }

      // Mul NaN
      {
        dut.io.ina.poke(Float2BigInt(Float.NaN))
        dut.io.inb.poke(Float2BigInt(4.0f))
        dut.io.inc.poke(Float2BigInt(0))
        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(255)
        assert(dut.io.out.mantissa.peek().litValue != 0)
      }

      // Fma
      {
        dut.io.ina.poke(Float2BigInt(2.0f))
        dut.io.inb.poke(Float2BigInt(1.5f))
        dut.io.inc.poke(Float2BigInt(6.0f))

        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(130)
        dut.io.out.mantissa.expect(1048576)
      }

      // Fms
      {
        dut.io.ina.poke(Float2BigInt(2.0f))
        dut.io.inb.poke(Float2BigInt(1.5f))
        dut.io.inc.poke(Float2BigInt(-6.0f))

        dut.io.out.sign.expect(1)
        dut.io.out.exponent.expect(128)
        dut.io.out.mantissa.expect(4194304)
      }

      // Fnma
      {
        dut.io.ina.poke(Float2BigInt(-2.0f))
        dut.io.inb.poke(Float2BigInt(1.5f))
        dut.io.inc.poke(Float2BigInt(13.5f))

        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(130)
        dut.io.out.mantissa.expect(2621440)
      }

      // Fnms
      {
        dut.io.ina.poke(Float2BigInt(-2.0f))
        dut.io.inb.poke(Float2BigInt(1.5f))
        dut.io.inc.poke(Float2BigInt(-13.5f))

        dut.io.out.sign.expect(1)
        dut.io.out.exponent.expect(131)
        dut.io.out.mantissa.expect(262144)
      }

      // Add
      {
        dut.io.ina.poke(Float2BigInt(9000.0f))
        dut.io.inb.poke(Float2BigInt(1.0f))
        dut.io.inc.poke(Float2BigInt(1.0f))

        dut.io.out.sign.expect(0)
        dut.io.out.exponent.expect(140)
        dut.io.out.mantissa.expect(828416)
      }

      // Sub
      {
        dut.io.ina.poke(Float2BigInt(15.0f))
        dut.io.inb.poke(Float2BigInt(1.0f))
        dut.io.inc.poke(Float2BigInt(-100.0f))

        dut.io.out.sign.expect(1)
        dut.io.out.exponent.expect(133)
        dut.io.out.mantissa.expect(2752512)
      }
    }
  }
}
