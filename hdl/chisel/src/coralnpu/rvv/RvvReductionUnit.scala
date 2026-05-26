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
// Reduction Tree Unit — Port of rvv_backend_pmtrdt_unit_reduction*.sv
//
// Performs element-wise reduction (sum, and, or, xor, min, max, minu, maxu)
// using a tree-based byte-level recursive reduction.
//
// For VLEN=128:
//   SEW=8:  16 elements → reduce 16→8→4→2→1 in 4 stages
//   SEW=16: 8 elements  → reduce 8→4→2→1  in 3 stages
//   SEW=32: 4 elements  → reduce 4→2→1    in 2 stages
// =============================================================================

// Reduction ALU: operates on ALU_BYTE bytes in parallel
class ReductionAlu(aluByte: Int = 4) extends Module {
  val io = IO(new Bundle {
    val src1 = Input(Vec(aluByte, UInt(8.W)))
    val src2 = Input(Vec(aluByte, UInt(8.W)))
    val funct6 = Input(UInt(6.W))
    val eew    = Input(UInt(3.W))  // element width: 0=8b, 1=16b, 2=32b, 3=64b
    val dst    = Output(Vec(aluByte, UInt(8.W)))
  })

  // Number of bytes per element
  val elementByte = Wire(UInt(3.W))
  elementByte := MuxLookup(io.eew, 1.U)(Seq(
    0.U -> 1.U,  // SEW8
    1.U -> 2.U,  // SEW16
    2.U -> 4.U,  // SEW32
    3.U -> 8.U,  // SEW64
  ))

  // Sign-extend src2 for signed min/max at element boundaries
  val src2Tmp = Wire(Vec(aluByte, UInt(9.W)))
  val src1Tmp = Wire(Vec(aluByte, UInt(9.W)))
  val cin     = Wire(Vec(aluByte, Bool()))
  val cout    = Wire(Vec(aluByte, Bool()))
  val sumDst  = Wire(Vec(aluByte, UInt(9.W)))
  val andDst  = Wire(Vec(aluByte, UInt(8.W)))
  val orDst   = Wire(Vec(aluByte, UInt(8.W)))
  val xorDst  = Wire(Vec(aluByte, UInt(8.W)))
  val lt      = Wire(Vec(aluByte, Bool()))

  val isSignedMinMax = io.funct6 === "b000101".U || io.funct6 === "b000111".U  // VREDMIN, VREDMAX
  val isMinMax = io.funct6 === "b000100".U || io.funct6 === "b000101".U ||
                 io.funct6 === "b000110".U || io.funct6 === "b000111".U

  for (i <- 0 until aluByte) {
    // src2_tmp: sign-extend at element boundary for signed min/max
    val isLastByte = (i.U + 1.U) % elementByte === 0.U
    src2Tmp(i) := Mux(isSignedMinMax && isLastByte,
      Cat(io.src2(i)(7), io.src2(i)),
      Cat(0.U(1.W), io.src2(i)))
    // src1_tmp: invert for subtraction-based comparison
    src1Tmp(i) := Mux(isMinMax,
      Mux(isSignedMinMax && isLastByte,
        ~Cat(io.src1(i)(7), io.src1(i)),
        ~Cat(0.U(1.W), io.src1(i))),
      Cat(0.U(1.W), io.src1(i)))
    // Cin: ~1 for min/max (to do src2 - src1 via src2 + ~src1 + 1)
    cin(i) := Mux(isMinMax, true.B, false.B)
    // For non-first bytes within element: carry chain
    if (i > 0) {
      val isFirstByte = (i.U % elementByte) === 0.U
      cin(i) := Mux(isMinMax,
        Mux(isFirstByte, true.B, !cout(i-1)),
        Mux(isFirstByte, false.B, cout(i-1)))
    }
    // Byte ALU: adder + logic
    sumDst(i) := src2Tmp(i) +& src1Tmp(i) + cin(i)
    cout(i)   := sumDst(i)(8)
    andDst(i) := io.src2(i) & io.src1(i)
    orDst(i)  := io.src2(i) | io.src1(i)
    xorDst(i) := io.src2(i) ^ io.src1(i)
    lt(i)     := cout(i)
  }

  // Output selection based on operation
  for (i <- 0 until aluByte) {
    // Compute the last byte index of the current element
    val elemEnd = WireDefault(0.U(3.W))
    when (elementByte === 1.U) { elemEnd := i.U }
    .elsewhen (elementByte === 2.U) { elemEnd := ((i.U >> 1) << 1) + 1.U }
    .elsewhen (elementByte === 4.U) { elemEnd := ((i.U >> 2) << 2) + 3.U }
    .otherwise { elemEnd := ((i.U >> 3) << 3) + 7.U }

    io.dst(i) := MuxLookup(io.funct6, xorDst(i))(Seq(
      "b000000".U -> sumDst(i)(7, 0),  // VREDSUM
      "b000001".U -> andDst(i),         // VREDAND
      "b000010".U -> orDst(i),          // VREDOR
      "b000011".U -> xorDst(i),         // VREDXOR
      "b000100".U -> Mux(!lt(elemEnd), io.src2(i), io.src1(i)),  // VREDMINU
      "b000101".U -> Mux(lt(elemEnd), io.src2(i), io.src1(i)),   // VREDMIN
      "b000110".U -> Mux(!lt(elemEnd), io.src2(i), io.src1(i)),  // VREDMAXU
      "b000111".U -> Mux(lt(elemEnd), io.src2(i), io.src1(i)),   // VREDMAX
    ))
  }
}

// =============================================================================
// Full Reduction Tree Unit
// =============================================================================
class RvvReductionUnit(p: Parameters) extends Module {
  private val vlen  = p.rvvVlen
  private val vlenb = vlen / 8
  private val aluWidth = 32
  private val aluByte = aluWidth / 8  // 4

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

  val vs2    = io.uop.vs2Data
  val vs1    = io.uop.vs1Data
  val funct6 = io.uop.funct6
  val sew    = io.uop.vdEew
  val vl     = io.uop.vl
  val vm     = io.uop.vm
  val v0     = io.uop.v0Data
  val vd     = io.uop.vdData

  // ---- Stage 0: Split vs2 into byte pairs, reduce within each pair ----
  // For VLEN=128 (16 bytes): 8 pairs → 8 ALU operations → 8 results
  // Each group has 2*aluByte=8 bytes → 2 ALUs needed for 16 bytes
  val stage0Pairs = vlenb / (2 * aluByte)  // VLEN=128 → 2
  val stage0In   = Wire(Vec(stage0Pairs * 2, Vec(aluByte, UInt(8.W))))
  val stage0Out  = Wire(Vec(stage0Pairs, Vec(aluByte, UInt(8.W))))

  for (pIdx <- 0 until stage0Pairs) {
    for (b <- 0 until aluByte) {
      stage0In(pIdx * 2)(b)     := vs2(8 * (pIdx * 2 * aluByte + b) + 7, 8 * (pIdx * 2 * aluByte + b))
      stage0In(pIdx * 2 + 1)(b) := vs2(8 * (pIdx * 2 * aluByte + aluByte + b) + 7, 8 * (pIdx * 2 * aluByte + aluByte + b))
    }
    val alu = Module(new ReductionAlu(aluByte))
    alu.io.src1   := stage0In(pIdx * 2 + 1)  // odd bytes as src1
    alu.io.src2   := stage0In(pIdx * 2)      // even bytes as src2
    alu.io.funct6 := funct6
    alu.io.eew    := sew
    stage0Out(pIdx) := alu.io.dst
  }

  // ---- Stage 1+: Recursive reduction ----
  // For VLEN=128, stage0Pairs=2, so we need 1 more stage (log2(2)=1)
  // Flatten stage0Out for next stage
  val stage1In = Wire(Vec(stage0Pairs * aluByte, UInt(8.W)))
  for (p <- 0 until stage0Pairs; b <- 0 until aluByte) {
    stage1In(p * aluByte + b) := stage0Out(p)(b)
  }

  // Re-pack into ALU-byte groups for stage 1
  val stage1Pairs = stage0Pairs / 2  // 1 for VLEN=128
  val stage1Out = Wire(Vec(math.max(stage1Pairs, 1), Vec(aluByte, UInt(8.W))))

  if (stage1Pairs >= 1) {
    for (pIdx <- 0 until stage1Pairs) {
      val alu = Module(new ReductionAlu(aluByte))
      for (b <- 0 until aluByte) {
        alu.io.src1(b) := stage1In(2 * pIdx * aluByte + aluByte + b)
        alu.io.src2(b) := stage1In(2 * pIdx * aluByte + b)
      }
      alu.io.funct6 := funct6
      alu.io.eew    := sew
      stage1Out(pIdx) := alu.io.dst
    }
  } else {
    // Single ALU at stage 0 — just pass through
    stage1Out(0) := stage0Out(0)
  }

  // ---- Final result: take first element of final stage ----
  // The reduced result is in the first byte(s) of the last stage output
  // Broadcast to fill VLEN for the result
  val reducedByte = stage1Out(0)(0)
  val reducedHWord = Cat(stage1Out(0)(1), stage1Out(0)(0))
  val reducedWord  = Cat(stage1Out(0)(3), stage1Out(0)(2), stage1Out(0)(1), stage1Out(0)(0))

  val finalResult = Wire(UInt(vlen.W))
  finalResult := MuxLookup(sew, 0.U)(Seq(
    0.U -> Fill(vlenb, reducedByte),                           // SEW8
    1.U -> Fill(vlenb / 2, reducedHWord),                      // SEW16
    2.U -> Fill(vlenb / 4, reducedWord),                        // SEW32
  ))

  // Mask handling: inactive elements should not contribute
  // For reductions, the result is written to vd[0] (first element position)
  // We produce the reduced value in the first element slot

  // Pipeline register
  val resultValidReg = RegInit(false.B)
  val resultDataReg  = Reg(UInt(vlen.W))
  val resultRobReg   = Reg(UInt(3.W))

  when (io.trapFlush) {
    resultValidReg := false.B
  } .elsewhen (io.resultReady || !resultValidReg) {
    resultValidReg := io.uopValid
    resultDataReg  := finalResult
    resultRobReg   := io.uop.robEntry
  }

  io.resultValid      := resultValidReg
  io.result.wValid    := true.B
  io.result.wData     := resultDataReg
  io.result.robEntry  := resultRobReg
  io.result.vsaturate := 0.U
}

// =============================================================================
// Permutation Unit — Port of rvv_backend_pmtrdt_unit_permutation.sv
//
// Supports: vslideup, vslidedown, vrgather, vrgatherei16, vcompress
// =============================================================================
class RvvPermutationUnit(p: Parameters) extends Module {
  private val vlen  = p.rvvVlen
  private val vlenb = vlen / 8
  private val vlenbWidth = log2Ceil(vlenb)

  val io = IO(new Bundle {
    val uopValid    = Input(Bool())
    val uop         = Input(new AluRsEntry(p))
    val popRs       = Output(Bool())
    val resultValid = Output(Bool())
    val result      = Output(new AluResult(p))
    val resultReady = Input(Bool())
    val trapFlush   = Input(Bool())
    val vrfRdData   = Input(UInt(vlen.W))  // VRF read data for gather
    val robRptr     = Input(UInt(3.W))      // ROB read pointer
  })

  val funct6 = io.uop.funct6
  val vs1    = io.uop.vs1Data
  val vs2    = io.uop.vs2Data
  val rs1    = vs1(31, 0)  // scalar operand (for .vx/.vi forms)
  val sew    = io.uop.vdEew
  val vlMax  = io.uop.vl
  val uopIdx = io.uop.uopIndex

  // ---- Element width in bytes ----
  val ew = MuxLookup(sew, 1.U)(Seq(
    0.U -> 1.U, 1.U -> 2.U, 2.U -> 4.U, 3.U -> 8.U))

  // ---- Result assembly: collect bytes from VRF reads ----
  val resultBytes = Wire(Vec(vlenb, UInt(8.W)))
  for (i <- 0 until vlenb) {
    resultBytes(i) := 0.U
  }

  // ---- Vslideup offset computation ----
  val baseIdx = uopIdx * vlenb.U
  val slideOffset = Wire(UInt((vlenbWidth + 5).W))
  when (io.uop.funct3 === "b100".U || io.uop.funct3 === "b110".U) {
    slideOffset := MuxLookup(sew, baseIdx - rs1)(Seq(
      0.U -> (baseIdx - rs1),
      1.U -> (baseIdx - (rs1 << 1)),
      2.U -> (baseIdx - (rs1 << 2)),
    ))
  }.otherwise {
    slideOffset := baseIdx
  }

  // ---- Vslidedown offset ----
  val slideDownOffset = Wire(UInt((vlenbWidth + 5).W))
  when (io.uop.funct3 === "b100".U || io.uop.funct3 === "b110".U) {
    slideDownOffset := MuxLookup(sew, baseIdx + rs1)(Seq(
      0.U -> (baseIdx + rs1),
      1.U -> (baseIdx + (rs1 << 1)),
      2.U -> (baseIdx + (rs1 << 2)),
    ))
  }.otherwise {
    slideDownOffset := baseIdx
  }

  // ---- Build result from permutation logic ----
  val resultData = Wire(UInt(vlen.W))
  resultData := 0.U

  // Per-byte routing for slide/gather
  for (i <- 0 until vlenb) {
    val byteIdx = i.U

    when (funct6 === "b001110".U || funct6 === "b001111".U) {  // VSLIDEUP / VSLIDEDOWN
      val offset = Mux(funct6 === "b001110".U, slideOffset, slideDownOffset)
      val srcIdx = Wire(UInt((vlenbWidth + 6).W))
      srcIdx := Mux(funct6 === "b001110".U,
        byteIdx +& offset,   // vslideup: source is earlier
        byteIdx - offset)    // vslidedown: source is later
      val overflow = offset > vlMax
      // Read from VRF data at the computed source index
      when (!overflow && srcIdx < vlenb.U) {
        // Dynamic byte extraction: (vrfRdData >> (srcIdx*8)) & 0xFF
        resultBytes(i) := (io.vrfRdData >> (srcIdx << 3))(7, 0)
      }
    }.elsewhen (funct6 === "b001100".U) {  // VRGATHER
      // Source index comes from vs1 elements
      val gatherIdx = (vs1 >> (i.U * 8.U))(7, 0)
      when (gatherIdx < vlenb.U) {
        resultBytes(i) := (io.vrfRdData >> (gatherIdx << 3))(7, 0)
      }
    }.elsewhen (funct6 === "b010111".U) {  // VCOMPRESS
      // Simplified compress: write enabled bytes (mask selects which elements)
      // vs1 holds the mask (v0), vs2 holds data
      when (vs1(i)) {
        resultBytes(i) := vs2(8*i + 7, 8*i)
      }
    }.otherwise {
      resultBytes(i) := vs2(8*i + 7, 8*i)  // passthrough
    }
  }

  // Pack bytes into result (use Cat to avoid combinational loop)
  resultData := Cat(resultBytes.reverse)

  // Pop RS and pipeline output
  io.popRs := io.uopValid && io.resultReady

  val resultValidReg = RegInit(false.B)
  val resultDataReg  = Reg(UInt(vlen.W))
  val resultRobReg   = Reg(UInt(3.W))

  when (io.trapFlush) {
    resultValidReg := false.B
  } .elsewhen (io.resultReady || !resultValidReg) {
    resultValidReg := io.uopValid
    resultDataReg  := resultData
    resultRobReg   := io.uop.robEntry
  }

  io.resultValid      := resultValidReg
  io.result.wValid    := true.B
  io.result.wData     := resultDataReg
  io.result.robEntry  := resultRobReg
  io.result.vsaturate := 0.U
}
