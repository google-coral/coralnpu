// Copyright 2025 Google LLC
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

package coralnpu.rvv

import chisel3._
import chisel3.util._
import coralnpu.Parameters

// =============================================================================
// RvvExecutionUnits — Per-Element SEW-Aware Execution Units
//
// Supports SEW=8,16,32 with element-wise operations and mask (v0) support.
// =============================================================================

// Reservation station entry for ALU
class AluRsEntry(p: Parameters) extends Bundle {
  private val vlen = p.rvvVlen
  val robEntry   = UInt(3.W)
  val funct6     = UInt(6.W)
  val funct3     = UInt(3.W)
  val isCmp      = Bool()
  val vstart     = UInt(log2Ceil(vlen).W)
  val vl         = UInt((log2Ceil(vlen) + 1).W)
  val vm         = Bool()          // mask disabled (vm=1 means no mask)
  val vxrm       = UInt(2.W)
  val v0Data     = UInt(vlen.W)    // mask register (v0)
  val v0DataValid = Bool()
  val vdData     = UInt(vlen.W)    // original vd (for undisturbed)
  val vdDataValid = Bool()
  val vdEew      = UInt(3.W)       // SEW
  val vs1        = UInt(5.W)
  val vs1Data    = UInt(vlen.W)
  val vs1DataValid = Bool()
  val rs1DataValid = Bool()
  val vs2Data    = UInt(vlen.W)
  val vs2DataValid = Bool()
  val vs2Eew     = UInt(3.W)
  val firstUopValid = Bool()
  val lastUopValid  = Bool()
  val uopIndex   = UInt(3.W)
}

class AluResult(p: Parameters) extends Bundle {
  private val vlen = p.rvvVlen
  val robEntry   = UInt(3.W)
  val wValid     = Bool()
  val wData      = UInt(vlen.W)
  val vsaturate  = UInt((vlen / 8).W)
}

// =============================================================================
// Per-element vector ALU operations
// =============================================================================
object VectorAlu {
  // Split VLEN-bit vector into elements of `ew` bits, apply `op` to each pair,
  // reassemble. Mask: if mask(i) is clear and !vm, keep original vd element.
  def elementWiseOp(
    vs2: UInt, vs1: UInt, vd: UInt,
    mask: UInt, vm: Bool,
    sew: UInt, vlen: Int,
    op: (UInt, UInt) => UInt
  ): (UInt, UInt) = {
    val vlenb = vlen / 8
    val result = Wire(UInt(vlen.W))
    val vsaturate = Wire(UInt(vlenb.W))
    result := 0.U
    vsaturate := 0.U

    // For each possible element grouping, use the appropriate width
    // SEW=8 (0): 16 elements of 8 bits each
    // SEW=16 (1): 8 elements of 16 bits each
    // SEW=32 (2): 4 elements of 32 bits each

    val results8  = Wire(Vec(16, UInt(8.W)))
    val results16 = Wire(Vec(8, UInt(16.W)))
    val results32 = Wire(Vec(4, UInt(32.W)))

    for (i <- 0 until 16) {
      val vs2Byte = vs2(8*i+7, 8*i)
      val vs1Byte = vs1(8*i+7, 8*i)
      val vdByte  = vd(8*i+7, 8*i)
      val maskBit = mask(i)
      val eltResult = op(vs2Byte, vs1Byte)
      results8(i) := Mux(vm || maskBit, eltResult, vdByte)
    }
    for (i <- 0 until 8) {
      val vs2Half = vs2(16*i+15, 16*i)
      val vs1Half = vs1(16*i+15, 16*i)
      val vdHalf  = vd(16*i+15, 16*i)
      val maskBit = mask(i)
      val eltResult = op(vs2Half, vs1Half)
      results16(i) := Mux(vm || maskBit, eltResult, vdHalf)
    }
    for (i <- 0 until 4) {
      val vs2Word = vs2(32*i+31, 32*i)
      val vs1Word = vs1(32*i+31, 32*i)
      val vdWord  = vd(32*i+31, 32*i)
      val maskBit = mask(i)
      val eltResult = op(vs2Word, vs1Word)
      results32(i) := Mux(vm || maskBit, eltResult, vdWord)
    }

    // Select based on SEW
    result := MuxLookup(sew, 0.U)(Seq(
      0.U -> Cat(results8.reverse),
      1.U -> Cat(results16.reverse),
      2.U -> Cat(results32.reverse),
    ))

    (result, vsaturate)
  }

  // Saturating element-wise operations (signed and unsigned)
  def saturatingAdd(vs2: UInt, vs1: UInt, vd: UInt, mask: UInt, vm: Bool,
                     sew: UInt, vlen: Int, signed: Boolean): (UInt, UInt) = {
    elementWiseOp(vs2, vs1, vd, mask, vm, sew, vlen, (a, b) => {
      val sum = a +& b  // wide add (with carry)
      if (signed) {
        val maxVal = ((BigInt(1) << (a.getWidth - 1)) - 1).U
        val minVal = (BigInt(1) << (a.getWidth - 1)).U  // negative max in two's complement
        Mux(sum(a.getWidth),  // overflow positive?
          maxVal,
          Mux(sum > maxVal, maxVal, sum(a.getWidth - 1, 0)))
      } else {
        Mux(sum(a.getWidth), Fill(a.getWidth, 1.U(1.W)), sum(a.getWidth - 1, 0))
      }
    })
  }

  def saturatingSub(vs2: UInt, vs1: UInt, vd: UInt, mask: UInt, vm: Bool,
                     sew: UInt, vlen: Int, signed: Boolean): (UInt, UInt) = {
    elementWiseOp(vs2, vs1, vd, mask, vm, sew, vlen, (a, b) => {
      val diff = a -& b  // wide sub (with borrow)
      if (signed) {
        val maxVal = ((BigInt(1) << (a.getWidth - 1)) - 1).U
        val minVal = (BigInt(1) << (a.getWidth - 1)).U
        Mux(diff(a.getWidth),  // underflow?
          minVal,
          Mux(diff > maxVal, maxVal, diff(a.getWidth - 1, 0)))
      } else {
        Mux(diff(a.getWidth), 0.U(a.getWidth.W), diff(a.getWidth - 1, 0))
      }
    })
  }
}

// =============================================================================
// ALU Execution Unit — per-element SEW-aware with mask support
// =============================================================================
class RvvAluUnit(p: Parameters) extends Module {
  private val vlen  = p.rvvVlen
  private val vlenb = vlen / 8

  val io = IO(new Bundle {
    val uopValid    = Input(Bool())
    val uop         = Input(new AluRsEntry(p))
    val popRs       = Output(Bool())
    val resultValid = Output(Bool())
    val result      = Output(new AluResult(p))
    val resultReady = Input(Bool())
    val trapFlush   = Input(Bool())
  })

  io.popRs := io.uopValid && io.resultReady

  val vs2   = io.uop.vs2Data
  val vs1   = io.uop.vs1Data
  val vd    = io.uop.vdData
  val mask  = io.uop.v0Data
  val vm    = io.uop.vm
  val sew   = io.uop.vdEew
  val funct6 = io.uop.funct6
  val funct3 = io.uop.funct3

  // Element-wise op helpers
  def ewOp(op: (UInt, UInt) => UInt): UInt =
    VectorAlu.elementWiseOp(vs2, vs1, vd, mask, vm, sew, vlen, op)._1

  def cmpOp(cond: (UInt, UInt) => Bool): UInt = {
    // Comparisons produce a mask (1 bit per element, packed into LSBs)
    val vlenb = vlen / 8
    val result = Wire(UInt(vlen.W))
    result := 0.U
    val elems8  = Wire(Vec(16, Bool()))
    val elems16 = Wire(Vec(8, Bool()))
    val elems32 = Wire(Vec(4, Bool()))
    for (i <- 0 until 16) {
      elems8(i) := Mux(vm || mask(i),
        cond(vs2(8*i+7, 8*i), vs1(8*i+7, 8*i)),
        vd(i))
    }
    for (i <- 0 until 8) {
      elems16(i) := Mux(vm || mask(i),
        cond(vs2(16*i+15, 16*i), vs1(16*i+15, 16*i)),
        vd(i))
    }
    for (i <- 0 until 4) {
      elems32(i) := Mux(vm || mask(i),
        cond(vs2(32*i+31, 32*i), vs1(32*i+31, 32*i)),
        vd(i))
    }
    val mask8  = Cat(elems8.reverse)
    val mask16 = Cat(elems16.reverse)
    val mask32 = Cat(elems32.reverse)
    MuxLookup(sew, 0.U)(Seq(
      0.U -> mask8.pad(vlen),
      1.U -> mask16.pad(vlen),
      2.U -> mask32.pad(vlen),
    ))
  }

  // Operations
  val addOut     = ewOp(_ + _)
  val subOut     = ewOp(_ - _)
  val andOut     = ewOp(_ & _)
  val orOut      = ewOp(_ | _)
  val xorOut     = ewOp(_ ^ _)
  val minuOut    = ewOp((a, b) => Mux(a < b, a, b))
  val minOut     = ewOp((a, b) => Mux(a.asSInt < b.asSInt, a, b))
  val maxuOut    = ewOp((a, b) => Mux(a > b, a, b))
  val maxOut     = ewOp((a, b) => Mux(a.asSInt > b.asSInt, a, b))
  val sllOut     = ewOp((a, b) => (a << b(log2Ceil(a.getWidth)-1, 0))(a.getWidth-1, 0))
  val srlOut     = ewOp((a, b) => a >> b(log2Ceil(a.getWidth)-1, 0))
  val sraOut     = ewOp((a, b) => (a.asSInt >> b(log2Ceil(a.getWidth)-1, 0)).asUInt)

  val eqOut      = cmpOp(_ === _)
  val neOut      = cmpOp(_ =/= _)
  val ltuOut     = cmpOp(_ < _)
  val ltOut      = cmpOp((a, b) => a.asSInt < b.asSInt)
  val leuOut     = cmpOp(_ <= _)
  val leOut      = cmpOp((a, b) => a.asSInt <= b.asSInt)
  val gtuOut     = cmpOp(_ > _)
  val gtOut      = cmpOp((a, b) => a.asSInt > b.asSInt)

  val (sadduOut, sadduSat) = VectorAlu.saturatingAdd(vs2, vs1, vd, mask, vm, sew, vlen, false)
  val (saddOut, saddSat)   = VectorAlu.saturatingAdd(vs2, vs1, vd, mask, vm, sew, vlen, true)
  val (ssubuOut, ssubuSat) = VectorAlu.saturatingSub(vs2, vs1, vd, mask, vm, sew, vlen, false)
  val (ssubOut, ssubSat)   = VectorAlu.saturatingSub(vs2, vs1, vd, mask, vm, sew, vlen, true)

  // Operation select
  val aluOut = Wire(UInt(vlen.W))
  val aluSat = Wire(UInt(vlenb.W))
  aluOut := 0.U
  aluSat := 0.U

  // funct6-based dispatch
  switch (funct6) {
    is("b000000".U) { aluOut := addOut }     // VADD
    is("b000010".U) { aluOut := subOut }     // VSUB
    is("b000011".U) { aluOut := ewOp((a, b) => b - a) }  // VRSUB
    is("b000100".U) { aluOut := minuOut }    // VMINU
    is("b000101".U) { aluOut := minOut }     // VMIN
    is("b000110".U) { aluOut := maxuOut }    // VMAXU
    is("b000111".U) { aluOut := maxOut }     // VMAX
    is("b001001".U) { aluOut := andOut }     // VAND
    is("b001010".U) { aluOut := orOut }      // VOR
    is("b001011".U) { aluOut := xorOut }     // VXOR
    is("b100000".U) { aluOut := sadduOut; aluSat := sadduSat }  // VSADDU
    is("b100001".U) { aluOut := saddOut;  aluSat := saddSat  }  // VSADD
    is("b100010".U) { aluOut := ssubuOut; aluSat := ssubuSat }  // VSSUBU
    is("b100011".U) { aluOut := ssubOut;  aluSat := ssubSat  }  // VSSUB
    is("b100101".U) { aluOut := sllOut }     // VSLL
    is("b101000".U) { aluOut := srlOut }     // VSRL
    is("b101001".U) { aluOut := sraOut }     // VSRA
  }

  // Comparison ops (funct3 distinguishes them)
  when (io.uop.isCmp) {
    aluOut := MuxLookup(funct3, 0.U)(Seq(
      "b000".U -> eqOut,   // VMSEQ
      "b001".U -> neOut,   // VMSNE
      "b010".U -> ltuOut,  // VMSLTU
      "b011".U -> ltOut,   // VMSLT
      "b100".U -> leuOut,  // VMSLEU
      "b101".U -> leOut,   // VMSLE
      "b110".U -> gtuOut,  // VMSGTU (only .vx/.vi)
      "b111".U -> gtOut,   // VMSGT (only .vx/.vi)
    ))
  }

  // Pipeline register
  val resultValidReg = RegInit(false.B)
  val resultDataReg  = Reg(UInt(vlen.W))
  val resultRobReg   = Reg(UInt(3.W))
  val resultSatReg   = Reg(UInt(vlenb.W))

  when (io.trapFlush) {
    resultValidReg := false.B
  } .elsewhen (io.resultReady || !resultValidReg) {
    resultValidReg := io.uopValid
    resultDataReg  := aluOut
    resultRobReg   := io.uop.robEntry
    resultSatReg   := aluSat
  }

  io.resultValid      := resultValidReg
  io.result.wValid    := true.B
  io.result.wData     := resultDataReg
  io.result.robEntry  := resultRobReg
  io.result.vsaturate := resultSatReg
}

// =============================================================================
// Multiplier Unit — per-element SEW-aware
// =============================================================================
class RvvMulUnit(p: Parameters) extends Module {
  private val vlen = p.rvvVlen

  val io = IO(new Bundle {
    val uopValid    = Input(Bool())
    val uop         = Input(new AluRsEntry(p))
    val popRs       = Output(Bool())
    val resultValid = Output(Bool())
    val result      = Output(new AluResult(p))
    val resultReady = Input(Bool())
    val trapFlush   = Input(Bool())
  })

  io.popRs := io.uopValid && io.resultReady

  val vs2  = io.uop.vs2Data
  val vs1  = io.uop.vs1Data
  val vd   = io.uop.vdData
  val mask = io.uop.v0Data
  val vm   = io.uop.vm
  val sew  = io.uop.vdEew

  // Element-wise multiply (lower half)
  val mulOut = VectorAlu.elementWiseOp(vs2, vs1, vd, mask, vm, sew, vlen,
    (a, b) => (a * b)(a.getWidth - 1, 0))._1

  val resultValidReg = RegInit(false.B)
  val resultDataReg  = Reg(UInt(vlen.W))
  val resultRobReg   = Reg(UInt(3.W))

  when (io.trapFlush) {
    resultValidReg := false.B
  } .elsewhen (io.resultReady || !resultValidReg) {
    resultValidReg := io.uopValid
    resultDataReg  := mulOut
    resultRobReg   := io.uop.robEntry
  }

  io.resultValid      := resultValidReg
  io.result.wValid    := true.B
  io.result.wData     := resultDataReg
  io.result.robEntry  := resultRobReg
  io.result.vsaturate := 0.U
}

// =============================================================================
// Permutation / Reduction Unit
// =============================================================================
class RvvPmtrdtUnit(p: Parameters) extends Module {
  private val vlen  = p.rvvVlen
  private val vlenb = vlen / 8

  val io = IO(new Bundle {
    val uopValid    = Input(Bool())
    val uop         = Input(new AluRsEntry(p))
    val popRs       = Output(Bool())
    val resultValid = Output(Bool())
    val result      = Output(new AluResult(p))
    val resultReady = Input(Bool())
    val trapFlush   = Input(Bool())
    val vrfRdData   = Input(UInt(vlen.W))
  })

  io.popRs := io.uopValid && io.resultReady

  val funct6 = io.uop.funct6
  val vs2    = io.uop.vs2Data
  val vs1    = io.uop.vs1Data
  val vd     = io.uop.vdData
  val mask   = io.uop.v0Data
  val vm     = io.uop.vm
  val sew    = io.uop.vdEew

  // Gather: vs1 holds indices, vs2+io.vrfRdData holds data
  val gatherOut = Wire(UInt(vlen.W))
  gatherOut := vs2  // simplified

  // Slide up/down
  val slideOut = VectorAlu.elementWiseOp(vs2, vs1, vd, mask, vm, sew, vlen,
    (a, b) => b  // vslide: replace with vs1 element
  )._1

  // Reduction sum (simplified — just forward first element)
  val redSum = vs2  // TODO: full reduction tree

  val pmtOut = Wire(UInt(vlen.W))
  pmtOut := MuxLookup(funct6, 0.U)(Seq(
    "b001100".U -> gatherOut,
    "b001110".U -> slideOut,
    "b001111".U -> slideOut,
    "b010111".U -> vs2,  // VCOMPRESS (simplified)
    "b000000".U -> redSum,  // VREDSUM
  ))

  val resultValidReg = RegInit(false.B)
  val resultDataReg  = Reg(UInt(vlen.W))
  val resultRobReg   = Reg(UInt(3.W))

  when (io.trapFlush) {
    resultValidReg := false.B
  } .elsewhen (io.resultReady || !resultValidReg) {
    resultValidReg := io.uopValid
    resultDataReg  := pmtOut
    resultRobReg   := io.uop.robEntry
  }

  io.resultValid      := resultValidReg
  io.result.wValid    := true.B
  io.result.wData     := resultDataReg
  io.result.robEntry  := resultRobReg
  io.result.vsaturate := 0.U
}

// =============================================================================
// LSU Address Remapping
// =============================================================================
class RvvLsuRemap(p: Parameters) extends Module {
  private val vlen = p.rvvVlen

  val io = IO(new Bundle {
    val uopValid   = Input(Bool())
    val uop        = Input(new AluRsEntry(p))
    val addrValid  = Output(Bool())
    val addr       = Output(UInt(32.W))
    val addrReady  = Input(Bool())
    val trapFlush  = Input(Bool())
  })

  val baseAddr = io.uop.vs1Data(31, 0)
  io.addrValid := io.uopValid && io.addrReady
  io.addr := baseAddr
}
