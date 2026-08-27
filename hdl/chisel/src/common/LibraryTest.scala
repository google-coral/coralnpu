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
import chisel3.util._
import org.scalatest.freespec.AnyFreeSpec
import scala.util.Random

class ForceZeroTester extends Module {
  val io = IO(new Bundle {
    val in  = Input(Valid(SInt(32.W)))
    val out = Output(Valid(SInt(32.W)))
  })

  io.out := ForceZero(io.in)
}

class Zip32Tester extends Module {
  val io = IO(new Bundle {
    val sz  = Input(UInt(3.W))
    val a   = Input(UInt(32.W))
    val b   = Input(UInt(32.W))
    val out = Output(UInt(64.W))
  })

  io.out := Zip32(io.sz, io.a, io.b)
}

class RotateVectorLeftTester extends Module {
  val io = IO(new Bundle {
    val in    = Input(Vec(16, Valid(UInt(32.W))))
    val shift = Input(UInt(4.W))
    val out   = Output(Vec(16, Valid(UInt(32.W))))
  })

  io.out := RotateVectorLeft(io.in, io.shift)
}

class RotateVectorRightTester extends Module {
  val io = IO(new Bundle {
    val in    = Input(Vec(16, Valid(UInt(32.W))))
    val shift = Input(UInt(4.W))
    val out   = Output(Vec(16, Valid(UInt(32.W))))
  })

  io.out := RotateVectorRight(io.in, io.shift)
}

class ShiftVectorLeftTester extends Module {
  val io = IO(new Bundle {
    val in    = Input(Vec(16, Valid(UInt(32.W))))
    val shift = Input(UInt(4.W))
    val out   = Output(Vec(16, Valid(UInt(32.W))))
  })

  io.out := ShiftVectorLeft(io.in, io.shift)
}

class ShiftVectorRightTester extends Module {
  val io = IO(new Bundle {
    val in    = Input(Vec(16, Valid(UInt(32.W))))
    val shift = Input(UInt(4.W))
    val out   = Output(Vec(16, Valid(UInt(32.W))))
  })

  io.out := ShiftVectorRight(io.in, io.shift)
}

class LibrarySpec extends AnyFreeSpec with ChiselSim {
  "ForceZero" in {
    simulate(new ForceZeroTester) { dut =>
      // ForceZero when invalid
      {
        dut.io.in.bits.poke(9001)
        dut.io.in.valid.poke(0)
        dut.clock.step()
        dut.io.out.bits.expect(0)
      }

      // ForceZero propogates when valid
      {
        dut.io.in.bits.poke(9001)
        dut.io.in.valid.poke(1)
        dut.clock.step()
        dut.io.out.bits.expect(9001)
      }
    }
  }

  "Zip32" in {
    simulate(new Zip32Tester) { dut =>
      // Zip32 Words
      {
        dut.io.sz.poke(4)
        dut.io.a.poke(5)
        dut.io.b.poke(3163)
        dut.io.out.expect((3163L << 32L) | 5)
      }

      // Zip32 Halves
      {
        dut.io.sz.poke(2)
        dut.io.a.poke((7L << 16L) | 3)
        dut.io.b.poke((11L << 16L) | 5)
        dut.io.out.expect((11L << 48L) | (7L << 32L) | (5L << 16L) | 3L)
      }

      // Zip32 Bytes
      {
        dut.io.sz.poke(1)
        dut.io.a.poke((37L << 16L) | (7L << 8L) | 3)
        dut.io.b.poke((43L << 16L) | (11L << 8L) | 5)
        dut.io.out.expect(
          (43L << 40L) | (37L << 32L) | (11L << 24L) | (7L << 16L) | (5L << 8L) | 3L
        )
      }
    }
  }

  "RotateVectorLeft" in {
    simulate(new RotateVectorLeftTester) { dut =>
      val valids = Seq.fill(16)(Random.between(0, 2))
      val data   = Seq.fill(16)(Random.between(0, 2147483647))
      for (i <- 0 until 16) {
        dut.io.in(i).valid.poke(valids(i))
        dut.io.in(i).bits.poke(data(i))
      }

      // Check that for all possible shifts `t`, input[o] = output[o + t]
      for (t <- 0 until 16) {
        dut.io.shift.poke(t)
        for (o <- 0 until 16) {
          var targetIndex = o + t
          if (targetIndex >= 16) {
            targetIndex = targetIndex - 16
          }
          dut.io.out(targetIndex).valid.expect(valids(o))
          dut.io.out(targetIndex).bits.expect(data(o))
        }
      }
    }
  }

  "RotateVectorRight" in {
    simulate(new RotateVectorRightTester) { dut =>
      val valids = Seq.fill(16)(Random.between(0, 2))
      val data   = Seq.fill(16)(Random.between(0, 2147483647))
      for (i <- 0 until 16) {
        dut.io.in(i).valid.poke(valids(i))
        dut.io.in(i).bits.poke(data(i))
      }

      // Check that for all possible shifts `t`, input[o] = output[o - t]
      for (t <- 0 until 16) {
        dut.io.shift.poke(t)
        for (o <- 0 until 16) {
          var targetIndex = o - t
          if (targetIndex < 0) {
            targetIndex = targetIndex + 16
          }
          dut.io.out(targetIndex).valid.expect(valids(o))
          dut.io.out(targetIndex).bits.expect(data(o))
        }
      }
    }
  }

  "ShiftVectorLeft" in {
    simulate(new ShiftVectorLeftTester) { dut =>
      val valids = Seq.fill(16)(Random.between(0, 2))
      val data   = Seq.fill(16)(Random.between(0, 2147483647))
      for (i <- 0 until 16) {
        dut.io.in(i).valid.poke(valids(i))
        dut.io.in(i).bits.poke(data(i))
      }

      for (t <- 0 until 16) {
        dut.io.shift.poke(t)
        for (o <- 0 until 16) {
          var targetIndex = o + t
          if (targetIndex >= 16) {
            targetIndex = targetIndex - 16
          }
          if (targetIndex < o) {
            dut.io.out(targetIndex).valid.expect(0.U.asTypeOf(dut.io.out(0).valid))
            dut.io.out(targetIndex).bits.expect(0.U.asTypeOf(dut.io.out(0).bits))
          } else {
            dut.io.out(targetIndex).valid.expect(valids(o))
            dut.io.out(targetIndex).bits.expect(data(o))
          }
        }
      }
    }
  }

  "ShiftVectorRight" in {
    simulate(new ShiftVectorRightTester) { dut =>
      val valids = Seq.fill(16)(Random.between(0, 2))
      val data   = Seq.fill(16)(Random.between(0, 2147483647))
      for (i <- 0 until 16) {
        dut.io.in(i).valid.poke(valids(i))
        dut.io.in(i).bits.poke(data(i))
      }

      for (t <- 0 until 16) {
        dut.io.shift.poke(t)
        for (o <- 0 until 16) {
          var targetIndex = o - t
          if (targetIndex < 0) {
            targetIndex = targetIndex + 16
          }
          if (targetIndex > o) {
            dut.io.out(targetIndex).valid.expect(0.U.asTypeOf(dut.io.out(0).valid))
            dut.io.out(targetIndex).bits.expect(0.U.asTypeOf(dut.io.out(0).bits))
          } else {
            dut.io.out(targetIndex).valid.expect(valids(o))
            dut.io.out(targetIndex).bits.expect(data(o))
          }
        }
      }
    }
  }
}
