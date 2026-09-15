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
import chisel3.util.{Cat, Decoupled}

// An integer divide unit, to be fused with fdiv.

object IDiv {
  def apply(n: Int): IDiv = {
    return Module(new IDiv(n))
  }

  val Stages = 4
  val Rcnt   = 32 / Stages
}

case class IDivOp() {
  val DIV     = 0
  val DIVU    = 1
  val REM     = 2
  val REMU    = 3
  val Entries = 4
}

class IDiv(n: Int) extends Module {
  val io = IO(new Bundle {
    val req = Input(UInt(new IDivOp().Entries.W))
    val ina = Flipped(Decoupled(Vec(n, UInt(32.W))))
    val inb = Flipped(Decoupled(Vec(n, UInt(32.W))))
    val out = Decoupled(Vec(n, UInt(32.W)))
  })

  val dvu = new IDivOp()

  val active = RegInit(false.B)
  val result = RegInit(false.B)
  val count  = Reg(UInt(6.W))

  val state = Reg(Vec(n, new IDivState()))

  val ivalid = io.ina.valid && io.ina.ready && io.inb.valid && io.inb.ready
  val ovalid = io.out.valid && io.out.ready

  when(ivalid) {
    active := true.B
  }.elsewhen(active && count === IDiv.Rcnt.U) {
    active := false.B
  }

  when(ovalid) {
    result := false.B
  }.elsewhen(active && count === IDiv.Rcnt.U) {
    result := true.B
  }

  when(ivalid) {
    count := 0.U
  }.elsewhen(active) {
    count := count + 1.U
  }

  for (i <- 0 until n) {
    val ina = io.ina.bits(i)
    val inb = io.inb.bits(i)

    when(ivalid) {
      val divide = io.req(dvu.DIV) || io.req(dvu.DIVU)
      val signed = io.req(dvu.DIV) || io.req(dvu.REM)
      state(i) := IDivComb1(ina, inb, signed, divide)
    }.elsewhen(active) {
      state(i) := IDivComb2(state(i), count)
    }
  }

  io.ina.ready := io.inb.valid && !active && (!result || io.out.ready)
  io.inb.ready := io.ina.valid && !active && (!result || io.out.ready)

  io.out.valid := result

  for (i <- 0 until n) {
    io.out.bits(i) := IDivComb3(state(i))
  }
}

class IDivState extends Bundle {
  val denom  = UInt(32.W) // output is placed first
  val divide = UInt(32.W)
  val remain = UInt(32.W)
  val opdiv  = Bool()
  val opneg  = Bool()
}

object IDivComb1 {
  def apply(ina: UInt, inb: UInt, signed: Bool, divide: Bool): IDivState = {
    val out = Wire(new IDivState())

    val divByZero = inb === 0.U
    val divsign   = signed && (ina(31) =/= inb(31)) && !divByZero
    val remsign   = signed && ina(31)
    val inp       = Mux(signed && ina(31), ~ina + 1.U, ina)

    out.opdiv  := divide
    out.opneg  := Mux(divide, divsign, remsign)
    out.denom  := Mux(signed && inb(31), ~inb + 1.U, inb)
    out.divide := inp
    out.remain := 0.U

    out
  }
}

object IDivComb2 {
  def apply(in: IDivState, count: UInt): IDivState = {
    val out = Wire(new IDivState())
    out := in

    when(count < IDiv.Rcnt.U) {
      val (div1, rem1) = Divide(in.divide, in.remain, in.denom)
      if (IDiv.Stages == 1) {
        out.divide := div1
        out.remain := rem1
      } else if (IDiv.Stages == 2) {
        val (div2, rem2) = Divide(div1, rem1, in.denom)
        out.divide := div2
        out.remain := rem2
      } else if (IDiv.Stages == 4) {
        val (div2, rem2) = Divide(div1, rem1, in.denom)
        val (div3, rem3) = Divide(div2, rem2, in.denom)
        val (div4, rem4) = Divide(div3, rem3, in.denom)
        out.divide := div4
        out.remain := rem4
      } else {
        assert(false)
      }
    }.otherwise {
      val div = Mux(in.opneg, ~in.divide + 1.U, in.divide)
      val rem = Mux(in.opneg, ~in.remain + 1.U, in.remain)
      out.denom := Mux(in.opdiv, div, rem)
    }

    out
  }

  def Divide(prvDivide: UInt, prvRemain: UInt, denom: UInt): (UInt, UInt) = {
    val shfRemain = Cat(prvRemain(30, 0), prvDivide(31))
    val subtract  = shfRemain -& denom
    assert(subtract.getWidth == 33)
    val divDivide = Wire(UInt(32.W))
    val divRemain = Wire(UInt(32.W))

    when(!subtract(32)) {
      divDivide := Cat(prvDivide(30, 0), 1.U(1.W))
      divRemain := subtract(31, 0)
    }.otherwise {
      divDivide := Cat(prvDivide(30, 0), 0.U(1.W))
      divRemain := shfRemain
    }

    (divDivide, divRemain)
  }
}

object IDivComb3 {
  def apply(in: IDivState): UInt = {
    val result = in.denom
    assert(result.getWidth == 32)
    result
  }
}

object EmitIDiv extends App {
  ChiselEmitter.emit(new IDiv(1), args)
}
