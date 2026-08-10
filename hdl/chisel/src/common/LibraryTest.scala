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

class VectorWindowTester(
  dataLen: Int,
  windowSize: Int,
  indexWidth: Int,
  fn: (Vec[UInt], UInt, UInt, Int) => Vec[UInt]
) extends Module {
  val io = IO(new Bundle {
    val data   = Input(Vec(dataLen, UInt(32.W)))
    val filler = Input(UInt(32.W))
    val index  = Input(UInt(indexWidth.W))
    val out    = Output(Vec(windowSize, UInt(32.W)))
  })

  io.out := fn(io.data, io.filler, io.index, windowSize)
}

class CircularVectorWindowTester(
  dataLen: Int,
  windowSize: Int,
  indexWidth: Int,
  fn: (Vec[UInt], UInt, Int) => Vec[UInt]
) extends Module {
  val io = IO(new Bundle {
    val data  = Input(Vec(dataLen, UInt(32.W)))
    val index = Input(UInt(indexWidth.W))
    val out   = Output(Vec(windowSize, UInt(32.W)))
  })

  io.out := fn(io.data, io.index, windowSize)
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

  def testVectorWindow(
    dataLen: Int,
    windowSize: Int,
    indexWidth: Int,
    fn: (Vec[UInt], UInt, UInt, Int) => Vec[UInt]
  ): Unit = {
    simulate(new VectorWindowTester(dataLen, windowSize, indexWidth, fn)) { dut =>
      val data   = Seq.fill(dataLen)(Random.between(1, 1000000))
      val filler = 9999999

      for (i <- 0 until dataLen) {
        dut.io.data(i).poke(data(i))
      }
      dut.io.filler.poke(filler)

      val maxIndex = dataLen.min(1 << indexWidth)
      for (idx <- 0 until maxIndex) {
        dut.io.index.poke(idx)
        for (w <- 0 until windowSize) {
          val expected = if (idx + w < dataLen) data(idx + w) else filler
          dut.io.out(w).expect(expected)
        }
      }
    }
  }

  def testCircularVectorWindow(
    dataLen: Int,
    windowSize: Int,
    indexWidth: Int,
    fn: (Vec[UInt], UInt, Int) => Vec[UInt]
  ): Unit = {
    simulate(new CircularVectorWindowTester(dataLen, windowSize, indexWidth, fn)) { dut =>
      val data = Seq.fill(dataLen)(Random.between(1, 1000000))

      for (i <- 0 until dataLen) {
        dut.io.data(i).poke(data(i))
      }

      val maxIndex = dataLen.min(1 << indexWidth)
      for (idx <- 0 until maxIndex) {
        dut.io.index.poke(idx)
        for (w <- 0 until windowSize) {
          val expected = data((idx + w) % dataLen)
          dut.io.out(w).expect(expected)
        }
      }
    }
  }

  Seq(
    ("VectorWindow.mux2", VectorWindow.mux2[UInt] _),
    ("VectorWindow.mux4", VectorWindow.mux4[UInt] _)
  ).foreach { case (name, fn) =>
    name in {
      // Case 1: 16 elements, window 4, index 4 bits (even index width)
      testVectorWindow(16, 4, 4, fn)
      // Case 2: 8 elements, window 3, index 3 bits (odd index width)
      testVectorWindow(8, 3, 3, fn)
      // Case 3: 4 elements, window 6, index 2 bits (windowSize > dataLen)
      testVectorWindow(4, 6, 2, fn)
      // Case 4: 2 elements, window 2, index 1 bit (1-bit index)
      testVectorWindow(2, 2, 1, fn)
      // Case 5: 10 elements, window 4, index 4 bits (irregular non-power-of-2 dataLen < 2^indexWidth)
      testVectorWindow(10, 4, 4, fn)
      // Case 6: 5 elements, window 3, index 3 bits (irregular odd index width)
      testVectorWindow(5, 3, 3, fn)
    }
  }

  Seq(
    ("VectorWindow.circularMux2", VectorWindow.circularMux2[UInt] _),
    ("VectorWindow.circularMux4", VectorWindow.circularMux4[UInt] _)
  ).foreach { case (name, fn) =>
    name in {
      // Case 1: 16 elements, window 4, index 4 bits (even index width)
      testCircularVectorWindow(16, 4, 4, fn)
      // Case 2: 8 elements, window 3, index 3 bits (odd index width)
      testCircularVectorWindow(8, 3, 3, fn)
      // Case 3: 4 elements, window 6, index 2 bits (windowSize > dataLen)
      testCircularVectorWindow(4, 6, 2, fn)
      // Case 4: 2 elements, window 2, index 1 bit (1-bit index)
      testCircularVectorWindow(2, 2, 1, fn)
      // Case 5: 10 elements, window 4, index 4 bits (irregular non-power-of-2 dataLen < 2^indexWidth)
      testCircularVectorWindow(10, 4, 4, fn)
      // Case 6: 5 elements, window 3, index 3 bits (irregular odd index width)
      testCircularVectorWindow(5, 3, 3, fn)
    }
  }
}
