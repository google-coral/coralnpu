// Copyright 2023 Google LLC
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

object FifoX {
  def apply[T <: Data](t: T, x: Int, n: Int) = {
    Module(new FifoX(t, x, n))
  }
}

// Xway decode, used for FifoX style input controls.
object FifoXValid {
  def apply(in: UInt): Seq[UInt] = {
    val inx = new Array[UInt](in.getWidth)

    for (i <- 0 until in.getWidth) {
      inx(i) = Cat(
        (0 until in.getWidth).reverse.map(x =>
          if (x < i) { false.B }
          else {
            (PopCount(in(x, 0)) === (i + 1).U) && in(x)
          }
        )
      )
    }
    inx.toIndexedSeq
  }
}

class FifoX[T <: Data](t: T, x: Int, n: Int) extends Module {
  val io = IO(new Bundle {
    val in    = Flipped(Decoupled(Vec(x, Valid(t))))
    val out   = Decoupled(t)
    val count = Output(UInt(log2Ceil(n + 1).W))
  })

  val m = n - 1 // n = Mem(n-1) + Slice

  def Increment(a: UInt, b: UInt): UInt = {
    val c = a +& b
    val d = Mux(c < m.U, c, c - m.U)(a.getWidth - 1, 0)
    d
  }

  val mem    = RegInit(VecInit(Seq.fill(n)(0.U(t.getWidth.W).asTypeOf(t))))
  val mslice = Slice(t, false, true)

  val inxpos = RegInit(VecInit((0 until x).map(x => x.U(log2Ceil(m).W))))
  // val outpos = RegInit(0.U(log2Ceil(m).W))
  val outpos = RegInit(0.U(log2Ceil(n).W))
  val mcount = RegInit(0.U(log2Ceil(n + 1).W))

  io.count := mcount + io.out.valid

  val ivalid = io.in.valid && io.in.ready
  val ovalid = mslice.io.in.valid && mslice.io.in.ready

  val iactive = Cat((0 until x).reverse.map(x => io.in.bits(x).valid))

  val icount = PopCount(iactive)

  // ---------------------------------------------------------------------------
  // Fifo Control.
  when(ivalid) {
    for (i <- 0 until x) {
      inxpos(i) := Increment(inxpos(i), icount)
    }
  }

  when(ovalid) {
    outpos := Increment(outpos, 1.U)
  }

  val inc = MuxOR(ivalid, icount)
  val dec = mslice.io.in.valid && mslice.io.in.ready

  when(ivalid || ovalid) {
    mcount := mcount + inc - dec
  }

  // ---------------------------------------------------------------------------
  // Fifo Input.
  val inxvalid = FifoXValid(iactive)

  for (i <- 0 until m) {
    val valid = Cat(
      (0 until x).reverse.map(q =>
        if (q == 0) { inxpos(0) === i.U && inxvalid(0)(0) }
        else {
          (0 to q).map(y => inxpos(y) === i.U && inxvalid(y)(q)).reduce(_ || _)
        }
      )
    )

    when(ivalid) {
      when(PopCount(valid) >= 1.U) {
        val idx = PriorityEncoder(valid)
        mem(i) := io.in.bits(idx).bits
      }
    }
  }

  mslice.io.in.valid := false.B
  mslice.io.in.bits  := io.in.bits(0).bits // defaults

  when(mcount > 0.U) {
    when(io.out.ready) {
      mslice.io.in.valid := true.B
    }
  }.otherwise {
    when(ivalid && iactive =/= 0.U) {
      mslice.io.in.valid := true.B
    }
  }

  when(mcount > 0.U) {
    mslice.io.in.bits := mem(outpos)
  }.elsewhen(ivalid) {
    when(iactive =/= 0.U) {
      val idx = PriorityEncoder(iactive)
      mslice.io.in.bits := io.in.bits(idx).bits
    }
  }

  // ---------------------------------------------------------------------------
  // Valid Entries.
  val active = RegInit(0.U(m.W))

  val activeSet =
    MuxOR(ivalid, (0 until x).map(i => (icount >= (i + 1).U) << inxpos(i)).reduce(_ | _))

  val activeClr = MuxOR(mslice.io.in.valid && mslice.io.in.ready, 1.U << outpos)

  active := (active | activeSet) & ~activeClr

  // ---------------------------------------------------------------------------
  // Interface.
  io.in.ready := mcount <= (m.U - icount)
  io.out <> mslice.io.out

  assert(mcount <= m.U)
}

object EmitFifoX extends App {
  ChiselEmitter.emit(new FifoX(UInt(8.W), 4, 11), args)
}
