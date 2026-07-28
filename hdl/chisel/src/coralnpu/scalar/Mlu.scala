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
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

object Mlu {
  def apply(p: Parameters): Mlu = {
    return Module(new Mlu(p))
  }
}

object MluOp extends ChiselEnum {
  val MUL     = Value
  val MULH    = Value
  val MULHSU  = Value
  val MULHU   = Value
  val MULW    = Value
  val Entries = Value
}

class MluCmd(p: Parameters) extends Bundle {
  val addr = UInt(log2Ceil(p.scalarRegCount).W)
  val op   = MluOp()
}

class MluStage1(p: Parameters) extends Bundle {
  val rd  = UInt(log2Ceil(p.scalarRegCount).W)
  val op  = MluOp()
  val sel = UInt(p.instructionLanes.W)
}

class MluStage2(p: Parameters) extends Bundle {
  val rd   = UInt(log2Ceil(p.scalarRegCount).W)
  val op   = MluOp()
  val prod = SInt((2 * p.xlen + 2).W)
}

class Mlu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Decode cycle.
    val req = Vec(p.instructionLanes, Flipped(Decoupled(new MluCmd(p))))

    // Execute cycle.
    val rs1 = Vec(p.instructionLanes, Flipped(new RegfileReadDataIO(p)))
    val rs2 = Vec(p.instructionLanes, Flipped(new RegfileReadDataIO(p)))
    val rd  = Decoupled(Flipped(new RegfileWriteDataIO(p)))
  })

  // Stage 1 select and decode instruction
  val arb = Module(new Arbiter(new MluCmd(p), p.instructionLanes))
  arb.io.in <> io.req

  val stage1 = Wire(Decoupled(new MluStage1(p)))
  stage1.valid     := arb.io.out.valid
  stage1.bits.rd   := arb.io.out.bits.addr
  stage1.bits.op   := arb.io.out.bits.op
  stage1.bits.sel  := UIntToOH(arb.io.chosen)
  arb.io.out.ready := stage1.ready
  val stage2Input = Queue(stage1, 1, true)

  // Stage 2 do multiplication
  val valid2in = stage2Input.valid
  val op2in    = stage2Input.bits.op
  val addr2in  = stage2Input.bits.rd
  val sel2in   = stage2Input.bits.sel

  val rs1 =
    (0 until p.instructionLanes).map(x => MuxOR(valid2in & sel2in(x), io.rs1(x).data)).reduce(_ | _)
  val rs2 =
    (0 until p.instructionLanes).map(x => MuxOR(valid2in & sel2in(x), io.rs2(x).data)).reduce(_ | _)

  val rs2signed = op2in.isOneOf(MluOp.MULH)
  val rs1signed = op2in.isOneOf(MluOp.MULHSU) || rs2signed
  val rs1s      = Cat(rs1signed && rs1(p.xlen - 1), rs1).asSInt
  val rs2s      = Cat(rs2signed && rs2(p.xlen - 1), rs2).asSInt
  val prod      = rs1s * rs2s
  assert(prod.getWidth == (2 * p.xlen + 2))

  val stage2 = Wire(Decoupled(new MluStage2(p)))
  stage2.valid      := valid2in
  stage2.bits.rd    := addr2in
  stage2.bits.op    := op2in
  stage2.bits.prod  := prod
  stage2Input.ready := stage2.ready

  val stage3Input = Queue(stage2, 1, true)
  val op3in       = stage3Input.bits.op
  val prod3in     = stage3Input.bits.prod

  // To be guarded by stage3Input.valid
  val mul = Mux(
    op3in === MluOp.MULW,
    SignExtend(prod3in(31, 0), p.xlen),
    Mux(
      op3in === MluOp.MUL,
      prod3in(p.xlen - 1, 0),         // MUL
      prod3in(2 * p.xlen - 1, p.xlen) // MULH, MULHSU, MULHU
    )
  )

  // Stage 3 output result
  // Multiplier has a registered output.
  stage3Input.ready := io.rd.ready

  io.rd.valid     := stage3Input.valid
  io.rd.bits.addr := stage3Input.bits.rd
  io.rd.bits.data := mul

  // Assertions.
  for (i <- 0 until p.instructionLanes) {
    assert(!(valid2in && sel2in(i) && !io.rs1(i).valid))
    assert(!(valid2in && sel2in(i) && !io.rs2(i).valid))
  }
}

@nowarn
object EmitMlu extends App {
  val p = new Parameters
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new Mlu(p))) ++ Seq(
      FirtoolOption("-enable-layers=Verification")
    )
  )
}
