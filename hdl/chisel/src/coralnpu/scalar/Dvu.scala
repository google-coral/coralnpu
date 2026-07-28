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

package coralnpu

import chisel3._
import chisel3.util._
import common._
import _root_.circt.stage.ChiselStage

object Dvu {
  def apply(p: Parameters): Dvu = {
    return Module(new Dvu(p))
  }
}

object DvuOp extends ChiselEnum {
  val DIV   = Value
  val DIVU  = Value
  val REM   = Value
  val REMU  = Value
  val DIVW  = Value
  val DIVUW = Value
  val REMW  = Value
  val REMUW = Value
}

class DvuCmd(p: Parameters) extends Bundle {
  val addr = UInt(log2Ceil(p.scalarRegCount).W)
  val op   = DvuOp()
}

class Dvu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Decode cycle.
    val req = Flipped(Decoupled(new DvuCmd(p)))

    // Execute cycle.
    val rs1 = Flipped(new RegfileReadDataIO(p))
    val rs2 = Flipped(new RegfileReadDataIO(p))
    val rd  = Decoupled(new RegfileWriteDataIO(p))
  })

  // This implemention differs to common::idiv by supporting early termination,
  // and only performs one bit per cycle.

  def Divide(prvDivide: UInt, prvRemain: UInt, denom: UInt): (UInt, UInt) = {
    val shfRemain = Cat(prvRemain(p.xlen - 2, 0), prvDivide(p.xlen - 1))
    val subtract  = shfRemain -& denom
    assert(subtract.getWidth == (p.xlen + 1))
    val divDivide = Wire(UInt(p.xlen.W))
    val divRemain = Wire(UInt(p.xlen.W))

    when(!subtract(p.xlen)) {
      divDivide := Cat(prvDivide(p.xlen - 2, 0), 1.U(1.W))
      divRemain := subtract(p.xlen - 1, 0)
    }.otherwise {
      divDivide := Cat(prvDivide(p.xlen - 2, 0), 0.U(1.W))
      divRemain := shfRemain
    }

    (divDivide, divRemain)
  }

  val active  = RegInit(false.B)
  val compute = RegInit(false.B)

  val addr1   = RegInit(0.U(log2Ceil(p.scalarRegCount).W))
  val signed1 = RegInit(false.B)
  val divide1 = RegInit(false.B)
  val isWord1 = RegInit(false.B)

  val addr2    = RegInit(0.U(log2Ceil(p.scalarRegCount).W))
  val signed2d = RegInit(false.B)
  val signed2r = RegInit(false.B)
  val divide2  = RegInit(false.B)
  val isWord2  = RegInit(false.B)

  val count = RegInit(0.U(log2Ceil(p.xlen + 1).W))

  val divide = RegInit(0.U(p.xlen.W))
  val remain = RegInit(0.U(p.xlen.W))
  val denom  = RegInit(0.U(p.xlen.W))

  // For RV64 word operations (DIVW, REMW, DIVUW, REMUW), 32-bit operands must be correctly extended
  // to 64 bits before division: signed word operations (DIVW, REMW -> signed1 == true) sign-extend
  // the lower 32 bits, while unsigned word operations (DIVUW, REMUW -> signed1 == false) zero-extend
  // them so that unsigned 64-bit division computes the exact 32-bit unsigned quotient/remainder.
  val op1 = if (p.xlen == 64) {
    Mux(
      isWord1,
      Mux(
        signed1,
        SignExtend(io.rs1.data(31, 0), p.xlen),
        io.rs1.data(31, 0)
      ),
      io.rs1.data
    )
  } else {
    io.rs1.data
  }

  val op2 = if (p.xlen == 64) {
    Mux(
      isWord1,
      Mux(
        signed1,
        SignExtend(io.rs2.data(31, 0), p.xlen),
        io.rs2.data(31, 0)
      ),
      io.rs2.data
    )
  } else {
    io.rs2.data
  }

  val divByZero = op2 === 0.U

  io.req.ready := !active && !compute && !count(log2Ceil(p.xlen))

  // This is not a Clz, one value too small.
  def Clz1(bits: UInt): UInt = {
    val msb = bits.getWidth - 1
    Mux(bits(msb), 0.U, PriorityEncoder(Reverse(bits(msb - 1, 0))))
  }

  // Disable active second to last cycle.
  when(io.req.valid && io.req.ready) {
    active := true.B
  }.elsewhen(count === (p.xlen - 2).U) {
    active := false.B
  }

  // Compute is delayed by one cycle.
  compute := active

  addr1   := Mux(io.req.fire, io.req.bits.addr, addr1)
  signed1 := Mux(
    io.req.fire,
    io.req.bits.op.isOneOf(DvuOp.DIV, DvuOp.REM, DvuOp.DIVW, DvuOp.REMW),
    signed1
  )
  divide1 := Mux(
    io.req.fire,
    io.req.bits.op.isOneOf(DvuOp.DIV, DvuOp.DIVU, DvuOp.DIVW, DvuOp.DIVUW),
    divide1
  )
  isWord1 := Mux(
    io.req.fire,
    io.req.bits.op.isOneOf(DvuOp.DIVW, DvuOp.DIVUW, DvuOp.REMW, DvuOp.REMUW),
    isWord1
  )

  when(active && !compute) {
    addr2    := addr1
    signed2d := signed1 && (op1(p.xlen - 1) =/= op2(p.xlen - 1)) && !divByZero
    signed2r := signed1 && op1(p.xlen - 1)
    divide2  := divide1
    isWord2  := isWord1

    val inp = Mux(signed1 && op1(p.xlen - 1), ~op1 + 1.U, op1)

    // The divBy0 uses full latency to simplify logic.
    // Count the leading zeroes, which is one less than the priority encoding.
    val clz = Mux(divByZero, 0.U, Clz1(inp))

    denom  := Mux(signed1 && op2(p.xlen - 1), ~op2 + 1.U, op2)
    divide := inp << clz
    remain := 0.U
    count  := clz
  }.elsewhen(compute && count < p.xlen.U) {
    val (div, rem) = Divide(divide, remain, denom)
    divide := div
    remain := rem
    count  := count + 1.U
  }.elsewhen(io.rd.valid && io.rd.ready) {
    count := 0.U
  }

  val div = Mux(signed2d, ~divide + 1.U, divide)
  val rem = Mux(signed2r, ~remain + 1.U, remain)

  val res       = Mux(divide2, div, rem)
  val final_res = if (p.xlen == 64) {
    Mux(isWord2, SignExtend(res(31, 0), p.xlen), res)
  } else {
    res
  }

  io.rd.valid     := count(log2Ceil(p.xlen))
  io.rd.bits.addr := addr2
  io.rd.bits.data := final_res
}

object EmitDvu extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new Dvu(p), args)
}
