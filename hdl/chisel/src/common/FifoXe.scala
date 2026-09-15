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

// FifoX with entry output and no output registration stage.

object FifoXe {
  def apply[T <: Data](t: T, x: Int, n: Int) = {
    Module(new FifoXe(t, x, n))
  }
}

class FifoXe[T <: Data](t: T, x: Int, n: Int) extends Module {
  val io = IO(new Bundle {
    val in     = Flipped(Decoupled(Vec(x, Valid(t))))
    val out    = Decoupled(t)
    val count  = Output(UInt(log2Ceil(n + 1).W))
    val entry  = Output(Vec(n, Valid(t)))
    val nempty = Output(Bool())
  })

  def Increment(a: UInt, b: UInt): UInt = {
    val c = a +& b
    val d = Mux(c < n.U, c, c - n.U)(a.getWidth - 1, 0)
    d
  }

  val mem = RegInit(VecInit(Seq.fill(n)(0.U(t.getWidth.W).asTypeOf(t))))

  val inxpos = RegInit(VecInit((0 until x).map(x => x.U((log2Ceil(n) + 1).W))))
  val outpos = RegInit(0.U(log2Ceil(n).W))
  val mcount = RegInit(0.U(log2Ceil(n + 1).W))
  val nempty = RegInit(false.B)

  io.count  := mcount
  io.nempty := nempty

  val ivalid = io.in.valid && io.in.ready
  val ovalid = io.out.valid && io.out.ready

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
  val dec = ovalid

  when(ivalid || ovalid) {
    val nxtcount = mcount + inc - dec
    mcount := nxtcount
    nempty := nxtcount =/= 0.U
  }

  // ---------------------------------------------------------------------------
  // Fifo Input.
  val inxvalid = FifoXValid(iactive)

  for (i <- 0 until n) {
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

  // ---------------------------------------------------------------------------
  // Valid Entries.
  val active = RegInit(0.U(n.W))

  val activeSet =
    MuxOR(ivalid, (0 until x).map(i => (icount >= (i + 1).U) << inxpos(i)).reduce(_ | _))

  val activeClr = MuxOR(io.out.valid && io.out.ready, 1.U << outpos)

  when(io.in.valid && io.in.ready || io.out.valid && io.out.ready) {
    active := (active | activeSet) & ~activeClr
  }

  // ---------------------------------------------------------------------------
  // Interface.
  io.in.ready := mcount <= (n.U - icount)

  io.out.valid := mcount =/= 0.U
  io.out.bits  := mem(outpos)

  assert(mcount <= n.U)

  for (i <- 0 until n) {
    io.entry(i).valid := active(i)
    io.entry(i).bits  := mem(i)
  }
}

object EmitFifoXe extends App {
  ChiselEmitter.emit(new FifoXe(UInt(8.W), 4, 10), args)
}
