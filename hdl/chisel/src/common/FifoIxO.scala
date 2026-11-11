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

object FifoIxO {
  def apply[T <: Data](t: T, i: Int, o: Int, n: Int) = {
    Module(new FifoIxO(t, i, o, n))
  }
}

// Input accepted with a common handshake and per lane select.
// Outputs are transacted independently, and ordered {[0], [0,1], [0,1,2], [0,1,2,3]}.
// Outputs are not registered, assumes passes directly into shallow combinatorial.
class FifoIxO[T <: Data](t: T, i: Int, o: Int, n: Int /* depth */ ) extends Module {
  val io = IO(new Bundle {
    val in     = Flipped(Decoupled(Vec(i, Valid(t))))
    val out    = Vec(o, Decoupled(t))
    val count  = Output(UInt(BitWidthForInt(n)))
    val nempty = Output(Bool())
  })

  val m = n

  val mb  = log2Ceil(m)
  val n1b = log2Ceil(n + 1)

  def Increment(a: UInt, b: UInt): UInt = {
    val c = a +& b
    val d = Mux(c < m.U, c, c - m.U)(a.getWidth - 1, 0)
    d
  }

  val mem = RegInit(VecInit(Seq.fill(n)(0.U(t.getWidth.W).asTypeOf(t))))

  val inpos  = Reg(Vec(i, UInt(mb.W))) // reset below
  val outpos = Reg(Vec(o, UInt(mb.W))) // reset below

  val mcount   = RegInit(0.U(n1b.W))
  val nempty   = RegInit(false.B)
  val inready  = RegInit(false.B)
  val outvalid = RegInit(0.U(o.W))

  val ivalid = io.in.valid && io.in.ready

  val iactive = Cat((0 until i).reverse.map(x => io.in.bits(x).valid)).asUInt

  val icount = (io.in.bits.map(x => x.valid.asUInt).reduce(_ +& _))(log2Ceil(i), 0)

  val oactiveBits = Cat((0 until o).reverse.map(x => io.out(x).valid && io.out(x).ready))

  val ovalid = oactiveBits =/= 0.U

  val ocount = (0 until o).map(x => oactiveBits(x).asUInt).reduce(_ +& _)(log2Ceil(o), 0)

  for (n <- 1 until o) {
    assert(!(oactiveBits(n) === 1.U && oactiveBits(n - 1, 0) =/= ((1 << n) - 1).U))
  }

  val ovalidBits = Cat((0 until o).reverse.map(x => io.out(x).valid))

  for (n <- 1 until o) {
    assert(!(ovalidBits(n) === 1.U && ovalidBits(n - 1, 0) =/= ((1 << n) - 1).U))
  }

  val oreadyBits = Cat((0 until o).reverse.map(x => io.out(x).ready))

  for (n <- 1 until o) {
    assert(!(oreadyBits(n) === 1.U && oreadyBits(n - 1, 0) =/= ((1 << n) - 1).U))
  }

  // ---------------------------------------------------------------------------
  // Fifo Control.
  when(reset.asBool) {
    for (i <- 0 until i) {
      inpos(i) := i.U
    }
  }.elsewhen(ivalid) {
    for (i <- 0 until i) {
      inpos(i) := Increment(inpos(i), icount)
    }
  }

  when(reset.asBool) {
    for (i <- 0 until o) {
      outpos(i) := i.U
    }
  }.elsewhen(ovalid) {
    for (i <- 0 until o) {
      outpos(i) := Increment(outpos(i), ocount)
    }
  }

  val inc = MuxOR(ivalid, icount)
  val dec = MuxOR(ovalid, ocount)

  when(ivalid || ovalid) {
    val nxtmcount = mcount + inc - dec
    inready  := nxtmcount <= (m.U - i.U)
    mcount   := nxtmcount
    nempty   := nxtmcount =/= 0.U
    outvalid := Cat((0 until o).reverse.map(x => nxtmcount >= (x + 1).U))
  }.otherwise {
    inready  := mcount <= (m.U - i.U)
    outvalid := Cat((0 until o).reverse.map(x => mcount >= (x + 1).U))
  }

  // ---------------------------------------------------------------------------
  // Fifo Input.
  val inxvalid = FifoXValid(iactive)

  for (q <- 0 until m) {
    val valid = Cat(
      (0 until i).reverse.map(x =>
        if (x == 0) { inpos(0) === q.U && inxvalid(0)(0) }
        else {
          (0 to x).map(y => inpos(y) === q.U && inxvalid(y)(x)).reduce(_ || _)
        }
      )
    )

    if (true) {
      val data = (0 until i).map(x => MuxOR(valid(x), io.in.bits(x).bits.asUInt)).reduce(_ | _)

      when(ivalid && valid =/= 0.U) {
        mem(q) := data.asTypeOf(t)
      }
    } else {
      when(ivalid) {
        when(PopCount(valid) >= 1.U) {
          val idx = PriorityEncoder(valid)
          mem(q) := io.in.bits(idx).bits
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Interface.
  io.in.ready := inready

  for (i <- 0 until o) {
    io.out(i).valid := outvalid(i)
    io.out(i).bits  := mem(outpos(i)) // TODO: VecAt()
  }

  io.count := mcount

  io.nempty := nempty

  assert(io.count <= m.U)
}

object EmitFifoIxO extends App {
  ChiselEmitter.emit(new FifoIxO(UInt(32.W), 4, 4, 24), args)
}
