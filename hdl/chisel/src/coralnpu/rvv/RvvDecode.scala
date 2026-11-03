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

package coralnpu.rvv

import chisel3._
import chisel3.util._
import common.{ForceZero, MakeInvalid, MakeValid, MakeWireBundle, MuxUpTo1H}
import coralnpu.Parameters

object RvvCompressedOpcode extends ChiselEnum {
  val RVVLOAD  = Value(0.U)
  val RVVSTORE = Value(1.U)
  val RVVALU   = Value(2.U)
}

object RvvAddressingMode extends ChiselEnum {
  val UNIT_STRIDE       = Value(0.U(2.W))
  val INDEXED_UNORDERED = Value(1.U(2.W))
  val STRIDED           = Value(2.U(2.W))
  val INDEXED_ORDERED   = Value(3.U(2.W))
}

class RvvCompressedInstruction(p: Parameters) extends Bundle {
  val pc      = UInt(p.programCounterBits.W)
  val opcode  = RvvCompressedOpcode()
  val bits    = UInt(25.W)
  val rob_tag = UInt(log2Ceil(p.retirementBufferSize).W)

  def originalEncoding(): UInt = {
    val lower7bits = MuxLookup(opcode, 0.U)(
      Seq(
        RvvCompressedOpcode.RVVLOAD  -> "b0000111".U,
        RvvCompressedOpcode.RVVSTORE -> "b0100111".U,
        RvvCompressedOpcode.RVVALU   -> Mux(isVtxmm(), "b1110111".U, "b1010111".U)
      )
    )
    Cat(bits, lower7bits)
  }

  def funct6(): UInt = {
    bits(24, 19)
  }

  def vm(): Bool = {
    bits(18)
  }

  def vs2(): UInt = {
    bits(17, 13)
  }

  def vs1(): UInt = {
    bits(12, 8)
  }

  def funct3(): UInt = {
    bits(7, 5)
  }

  def vd(): UInt = {
    bits(4, 0)
  }

  /** Checks if a vector floating-point instruction is illegal and should trap.
    *
    * The decision is evaluated in the following order:
    *   1. Check if the instruction is a floating-point vector operation (funct3 === OPFVV or
    *      OPFVF). If it is not a float instruction, it is allowed (returns false).
    *   2. If it is a float instruction:
    *      a. If scalar float support (p.enableFloat) is ENABLED:
    *         - Standard single-precision vector float instructions (e.g., vfadd.vv) are allowed.
    *         - Unimplemented widening/narrowing float instructions (e.g., vfwadd, vfwsub, vfwmul,
    *           vfwmacc, vfwmsac, vfwnmacc, vfwnmsac) are inhibited.
    *         - Supported vector BF16 instructions (VFWMACCBF16, VFNCVTBF16, VFWCVTBF16) are allowed
    *           if vector BF16 support (p.enableVectorBf16) is enabled; otherwise they are
    *           inhibited.
    *      b. If scalar float support (p.enableFloat) is DISABLED:
    *         - All vector float instructions are inhibited.
    *         - The only exceptions are the supported vector BF16 instructions (VFWMACCBF16,
    *           VFNCVTBF16, VFWCVTBF16) which are allowed if vector BF16 support
    *           (p.enableVectorBf16) is enabled.
    */
  def isIllegalFloat(p: Parameters): Bool = {
    val isFloat   = funct3() === "b001".U || funct3() === "b101".U
    val funct6Val = funct6()
    val vs1Val    = vs1()

    val isBf16 = if (p.enableVectorBf16) {
      (funct6Val === "b111011".U) || // VFWMACCBF16
      (funct6Val === "b010010".U && (vs1Val === "b11101".U || vs1Val === "b01101".U)) // VFNCVTBF16, VFWCVTBF16
    } else {
      false.B
    }

    val isWidenFloat = (
      (funct6Val(5, 3) === "b110".U) || // vfwadd, vfwsub (110xxx)
        (funct6Val === "b111000".U) ||  // vfwmul
        (funct6Val === "b111100".U) ||  // vfwmacc
        (funct6Val === "b111101".U) ||  // vfwnmacc
        (funct6Val === "b111110".U) ||  // vfwmsac
        (funct6Val === "b111111".U)     // vfwnmsac
    )

    val isBf16OnlyWiden = (funct6Val === "b111011".U) ||
      (funct6Val === "b010010".U && (vs1Val === "b11101".U || vs1Val === "b01101".U))

    val isIllegalWiden =
      if (p.enableVectorBf16) isWidenFloat
      else (isWidenFloat || isBf16OnlyWiden)

    Mux(
      isFloat,
      if (p.enableFloat) {
        isIllegalWiden
      } else {
        !isBf16
      },
      false.B
    )
  }

  // These instructions need to trap when vstart is not zero. This includes
  // all reduction instructions.
  def requireZeroVstart(): Bool = {
    (opcode === RvvCompressedOpcode.RVVALU) && (
      ((funct3() === "b010".U) &&
        MuxLookup(funct6(), false.B)(
          Seq(
            "b000000".U    -> true.B, // vredsum
            "b000001".U    -> true.B, // vredand
            "b000010".U    -> true.B, // vredor
            "b000011".U    -> true.B, // vredxor
            "b000100".U    -> true.B, // vredminu
            "b000101".U    -> true.B, // vredmin
            "b000110".U    -> true.B, // vredmaxu
            "b000111".U    -> true.B, // vredmax
            "b010000".U    -> MuxLookup(vs1(), false.B)(
              Seq( // VWXUNARY0
                "b10000".U -> true.B, // vcpop
                "b10001".U -> true.B  // vfirst
              )
            ),
            "b010100".U -> MuxLookup(vs1(), false.B)(
              Seq( // VMUNARY0
                "b00001".U -> true.B, // vmsbf
                "b00010".U -> true.B, // vmsof
                "b00011".U -> true.B, // vmsif
                "b10000".U -> true.B  // viota
              )
            ),
            "b010111".U -> true.B, // vcompress
            "b110000".U -> true.B, // vwredsumu
            "b110001".U -> true.B  // vwredsum
          )
        )) ||
        ((funct3() === "b001".U) &&
          MuxLookup(funct6(), false.B)(
            Seq(
              "b000001".U -> true.B, // vfredusum
              "b000011".U -> true.B, // vfredosum
              "b000101".U -> true.B, // vfredmin
              "b000111".U -> true.B  // vfredmax
            )
          )) ||
        ((funct3() === "b000".U) && ((funct6() === "b110000".U) || (funct6() === "b110001".U))) ||
        isVtxmm()
    )
  }

  // "Addressing Mode" for loads/store (see Section 7.2 of RVV Spec)
  def mop: RvvAddressingMode.Type = {
    RvvAddressingMode(bits(20, 19))
  }

  // Is vset*/mset* configuration opcode (1010111, funct3=111)
  def isVset(): Bool = {
    (opcode === RvvCompressedOpcode.RVVALU && funct3() === "b111".U)
  }

  // VME (Zvt) mset* family. All share opcode 1010111 and funct3 111 with
  // vset*vl*, distinguished by bit31=1 and the funct7 / sub-funct fields.
  // In the 25-bit `bits` view (which is instr[31:7]):
  //   bits(24,18)  = instr[31:25] = funct7
  //   bits(17,13)  = instr[24:20] = rs2 / sub-funct
  //   bits(12,8)   = instr[19:15] = rs1
  //   bits(7,5)    = instr[14:12] = funct3
  //   bits(4,0)    = instr[11:7]  = rd
  // v0.4: msetmtype funct7=1000010 (inst[27:25]=010), rd=00000
  def isMsetmtype(): Bool =
    isVset() && bits(24, 18) === "b1000010".U && bits(4, 0) === 0.U
  // v0.4: msettn/m/k funct7=1000100 (inst[27:25]=100)
  def isMsettn(): Bool =
    isVset() && bits(24, 18) === "b1000100".U && bits(17, 13) === "b00000".U
  def isMsettm(): Bool =
    isVset() && bits(24, 18) === "b1000100".U && bits(17, 13) === "b00001".U
  def isMsettk(): Bool =
    isVset() && bits(24, 18) === "b1000100".U && bits(17, 13) === "b00010".U
  // v0.4: msetmtypei has bits[24:22]=100, bits[20:18]=100, bits[15:13]=100, bits[12:10]=000, rd=00000
  def isMsetmtypei(): Bool =
    isVset() && (bits(24, 22) === "b100".U) && (bits(20, 18) === "b100".U) &&
      (bits(15, 13) === "b100".U) && (bits(12, 10) === "b000".U) && (bits(4, 0) === 0.U)
  def isMsetAny(): Bool =
    isMsetmtype() || isMsettn() || isMsettm() || isMsettk() || isMsetmtypei()
  def isMsetWritesMtype(): Bool =
    isMsetmtype() || isMsettm() || isMsettk() || isMsetmtypei()
  def isMsetWritesVtype(): Bool =
    isMsetmtype() || isMsetmtypei()

  def isLoadStore(): Bool = {
    opcode.isOneOf(RvvCompressedOpcode.RVVLOAD, RvvCompressedOpcode.RVVSTORE)
  }

  def isWholeRegisterLoadStore(): Bool = {
    isLoadStore() && !bits(21) && (bits(20, 19) === 0.U) && (bits(17, 13) === "b01000".U)
  }

  def isMaskLoadStore(): Bool = {
    isLoadStore() && !bits(21) && (bits(20, 19) === 0.U) && (bits(17, 13) === "b01011".U)
  }

  def isFaultOnlyFirstLoad(): Bool = {
    (opcode === RvvCompressedOpcode.RVVLOAD) && !bits(21) && (bits(20, 19) === 0.U) &&
    (bits(17, 13) === "b10000".U)
  }

  def isVmeLdSt(): Bool = {
    isLoadStore() && (bits(21, 18) === "b1001".U) && (funct3() === "b111".U) && (bits(4, 0) === 0.U)
  }

  def isIllegalLsuConfig(sew: UInt, lmul_orig: UInt): Bool = {
    val lmulLog2   = Cat(Fill(2, lmul_orig(2)), lmul_orig).asSInt
    val sewLog2    = Cat(0.U(3.W), sew(1, 0)).asSInt
    val vtypeValid = (sew <= 2.U) && (lmul_orig =/= "b100".U) &&
      (lmul_orig =/= "b101".U) && ((lmulLog2 - sewLog2) >= -2.S(5.W))
    isLoadStore() && !isLegalLsuDynamic(sew, lmul_orig, !vtypeValid, 1.U)
  }

  def readsRs1(): Bool = {
    isLoadStore() ||
    (funct3() === "b100".U) ||                                                    // OPIVX
    (funct3() === "b110".U) ||                                                    // OPMVX
    ((funct3() === "b111".U) && (bits(24, 23) =/= "b11".U) && !isMsetmtypei()) || // vsetvl(i)
    // VME mset*: msetmtype/msettn/msettm/msettk all read rs1.
    isMsetmtype() || isMsettn() || isMsettm() || isMsettk()
  }

  def readsRs2(): Bool = {
    (isLoadStore() && (mop === RvvAddressingMode.STRIDED)) ||
    ((funct3() === "b111".U) && (bits(24, 18) === "b1000000".U)) ||
    isMsetmtype() ||
    isVmeLdSt()
  }

  def readsFloatRs1(): Bool = {
    // OP FV F
    opcode === RvvCompressedOpcode.RVVALU && funct3() === "b101".U
  }

  def writesRd(): Bool = {
    (isVset() && !isMsetmtype() && !isMsetmtypei()) ||
    // OP MVV, VWXUNARY0 (all): vmv.x.s, vcpop, vfirst.
    (opcode === RvvCompressedOpcode.RVVALU && funct3() === "b010".U && funct6() === "b010000".U)
  }

  def writesFrd(): Bool = {
    // OP FVV, VWRFUNARY0: vfmv.f.s.
    opcode === RvvCompressedOpcode.RVVALU && funct3() === "b001".U && funct6() === "b010000".U
  }

  def isVtle(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      isVmeLdSt() && opcode === RvvCompressedOpcode.RVVLOAD
    }
  }

  def isVtse(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      isVmeLdSt() && opcode === RvvCompressedOpcode.RVVSTORE
    }
  }

  def isVtxmm(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      (opcode === RvvCompressedOpcode.RVVALU) && (funct6() === "b111100".U) &&
      bits(18) && (funct3() === "b000".U || funct3() === "b001".U)
    }
  }

  def isVtfmm(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      isVtxmm() && (funct3() === "b001".U)
    }
  }

  def isVtzero(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      (opcode === RvvCompressedOpcode.RVVALU) && (funct3() === "b110".U) &&
      (funct6() === "b010000".U) && (bits(18) === 1.U) &&
      (bits(17, 13) === "b11110".U) && (bits(12, 8) === 0.U)
    }
  }

  def isVtmvVT(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      (opcode === RvvCompressedOpcode.RVVALU) && (funct3() === "b110".U) &&
      (funct6() === "b010000".U) && (bits(18) === 1.U) &&
      (bits(17, 13) === "b11111".U)
    }
  }

  def isVtmvTV(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      (opcode === RvvCompressedOpcode.RVVALU) && (funct3() === "b110".U) &&
      (funct6() === "b010111".U) && (bits(18) === 1.U) && (bits(4, 0) === 0.U)
    }
  }

  def isVtdiscard(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      (opcode === RvvCompressedOpcode.RVVALU) &&
      (funct6() === "b010000".U) && (bits(18) === 1.U) && (funct3() === "b110".U) &&
      (bits(17, 13) === "b11100".U) && (bits(12, 8) === 0.U) && (bits(4, 0) === 0.U)
    }
  }

  def readsTile(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      isVtse() || isVtmvVT() || isVtxmm()
    }
  }

  def writesTile(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      isVtle() || isVtxmm() || isVtzero() || isVtmvTV()
    }
  }

  def accessesTile(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      readsTile() || writesTile() || isVtdiscard()
    }
  }

  def isWholeRegisterMove(): Bool = {
    (opcode === RvvCompressedOpcode.RVVALU) &&
    (funct3() === "b011".U) &&
    (funct6() === "b100111".U) &&
    (bits(18) === 1.U) &&
    (bits(12, 11) === "b00".U)
  }

  def changesVtypeOrMtwiden(): Bool = {
    isVset() && !isMsettn() && !isMsettm() && !isMsettk()
  }

  def requiresVillClear(): Bool = {
    Mux(
      opcode === RvvCompressedOpcode.RVVALU,
      (!isVset() && !isWholeRegisterMove()) || isMsettm() || isMsettk(),
      !isWholeRegisterLoadStore()
    )
  }

  def requiresValidMtwiden(): Bool = {
    if (!p.enableVme) { false.B }
    else {
      readsTile() || writesTile() || isMsettm() || isMsettk()
    }
  }

  def writesVectorRegister(): Bool = {
    // A vector instruction writes to a vector register if it's an ALU operation
    // or a load operation, unless it is a config instruction (vset*/mset*),
    // writes to a scalar register (rd/frd) or tile memory, or is a tile
    // discard instruction (vtdiscard).
    // Store operations do not write to a vector register.
    (opcode.isOneOf(RvvCompressedOpcode.RVVLOAD, RvvCompressedOpcode.RVVALU)) &&
    !isVset() && !writesRd() && !writesFrd() && !writesTile() && !isVtdiscard()
  }

  /** Checks dynamic RVV / Zvt load/store legality against architectural configuration state (`sew`,
    * `lmulOrig`, `vill`, `mtwiden`). Assumes static legality has already been verified by
    * `RvvCompressedInstruction.from_uncompressed`.
    */
  def isLegalLsuDynamic(sew: UInt, lmulOrig: UInt, vill: Bool, mtwiden: UInt): Bool = {
    import RvvCompressedInstruction._
    val (vs2Idx, f3, vdIdx) = (vs2(), funct3(), vd())
    val (nf, mopBits)       = (bits(24, 22), bits(20, 19))
    val lmulLog2            = Cat(Fill(2, lmulOrig(2)), lmulOrig).asSInt
    val sewLog2             = Cat(0.U(3.W), sew(1, 0)).asSInt

    MuxCase(
      {
        val widthEewLog2 = MuxLookup(f3, 0.S(5.W))(
          Seq("b000".U -> 0.S(5.W), "b101".U -> 1.S(5.W), "b110".U -> 2.S(5.W))
        )
        val isIndexed    = mopBits(0)
        val eewDataLog2  = Mux(isIndexed, sewLog2, widthEewLog2)
        val emulDataLog2 = lmulLog2 + eewDataLog2 - sewLog2
        val shiftData    = emulShift(emulDataLog2)
        val totalRegs    = (nf +& 1.U(4.W)) * (1.U(4.W) << shiftData)(3, 0)
        val baseOk       = !vill && emulValid(emulDataLog2) && (totalRegs <= 8.U) &&
          ((vdIdx +& totalRegs) <= 32.U) && isAligned(vdIdx, shiftData)

        val emulIdxLog2         = lmulLog2 + widthEewLog2 - sewLog2
        val shiftIdx            = emulShift(emulIdxLog2)
        val idxRegs             = (1.U(4.W) << shiftIdx)(3, 0)
        val (vdStart, vs2Start) = (Cat(0.U(1.W), vdIdx), Cat(0.U(1.W), vs2Idx))
        val segNoOverlap        = ((vs2Start + Cat(0.U(2.W), idxRegs)) <= vdStart) ||
          (vs2Start >= (vdStart + totalRegs(5, 0)))

        val idxOverlapOk = Mux(
          opcode =/= RvvCompressedOpcode.RVVLOAD,
          (widthEewLog2 === sewLog2) || segNoOverlap,
          Mux(
            nf =/= 0.U,
            segNoOverlap,
            MuxCase(
              true.B,
              Seq(
                (widthEewLog2 > sewLog2)                -> narrowOverlapOk(vdIdx, vs2Idx, shiftIdx),
                ((widthEewLog2 + 1.S(5.W)) === sewLog2) ->
                  widen2to1OverlapOk(vdIdx, shiftData, vs2Idx, emulIdxLog2),
                ((widthEewLog2 + 2.S(5.W)) === sewLog2) ->
                  widen4to1OverlapOk(vdIdx, shiftData, vs2Idx)
              )
            )
          )
        )
        baseOk && (!isIndexed || (emulValid(emulIdxLog2) && isAligned(
          vs2Idx,
          shiftIdx
        ) && idxOverlapOk))
      },
      Seq(
        isWholeRegisterLoadStore() -> true.B,
        isVmeLdSt()                -> (!vill && (mtwiden =/= 0.U)),
        isMaskLoadStore()          -> !vill
      )
    )
  }

  /** Checks dynamic OP-VE matrix-multiply (`vtmmu`, `vtmms`, `vtfmm`) mode and operand-base
    * legality against architectural configuration state (`sew`, `lmulOrig`, `mtwiden`, `altfmt`,
    * `frm`). Assumes static OP-VE legality has already been verified by `isOpVeValid`.
    */
  def isLegalVtxmmDynamic(
    sew: UInt,
    lmulOrig: UInt,
    mtwiden: UInt,
    altfmt: Bool,
    frm: UInt = 0.U(3.W)
  ): Bool = {
    if (!p.enableVme) { true.B }
    else {
      val (vs1Idx, vs2Idx, vdIdx) = (vs1(), vs2(), vd())
      val mtdAlign4               = vdIdx(2, 1) === 0.U
      val int8Ok                  = (sew === 0.U) && (lmulOrig === 0.U) && (mtwiden === 3.U) &&
        (vs1Idx(2, 1) === 0.U) && (vs2Idx(2, 1) === 0.U)
      val int16Ok = (sew === 1.U) && (lmulOrig === 1.U) && (mtwiden === 2.U) &&
        !vs1Idx(2) && !vs1Idx(0) && !vs2Idx(2) && !vs2Idx(0)
      val fp32Ok = (sew === 2.U) && (lmulOrig === 2.U) && (mtwiden === 1.U) && !altfmt &&
        (vs1Idx(1, 0) === 0.U) && (vs2Idx(1, 0) === 0.U)
      val bf16Ok = (sew === 1.U) && (lmulOrig === 1.U) && (mtwiden === 2.U) && altfmt &&
        !vs1Idx(2) && !vs1Idx(0) && !vs2Idx(2) && !vs2Idx(0)
      val fpAllowed = if (p.enableFloat) (frm < 5.U) && (fp32Ok || bf16Ok) else false.B
      !isVtxmm() || (mtdAlign4 && Mux(funct3() === "b000".U, int8Ok || int16Ok, fpAllowed))
    }
  }

  override def toPrintable: Printable = {
    cf"[opcode=$opcode, bits=$bits%b]"
  }
}

object RvvCompressedInstruction {
  def matches(x: UInt, pats: String*): Bool =
    pats.map(p => x === BitPat("b" + p)).reduce(_ || _)

  def emulValid(emulLog2: SInt): Bool = (emulLog2 >= -2.S(5.W)) && (emulLog2 <= 3.S(5.W))
  def emulShift(e: SInt): UInt        = Mux(e <= 0.S, 0.U(2.W), Mux(e >= 3.S, 3.U(2.W), e(1, 0)))
  def alignMask(shift: UInt): UInt    = ((1.U(4.W) << shift) - 1.U)(2, 0)
  def isAligned(reg: UInt, shift: UInt): Bool        = (reg(2, 0) & alignMask(shift)) === 0.U
  def sameGroup(a: UInt, b: UInt, shift: UInt): Bool =
    ((a ^ b) & ~Cat(0.U(2.W), alignMask(shift))) === 0.U
  def noGroupOverlap(a: UInt, sA: UInt, b: UInt, sB: UInt): Bool =
    !sameGroup(a, b, Mux(sA > sB, sA, sB))
  def narrowOverlapOk(vd: UInt, src: UInt, sSrc: UInt): Bool =
    !sameGroup(vd, src, sSrc) || isAligned(vd, sSrc)
  def widen2to1OverlapOk(vd: UInt, sVd: UInt, src: UInt, emulSrcLog2: SInt): Bool =
    !sameGroup(vd, src, sVd) || ((emulSrcLog2 >= 0.S) &&
      ((src(2, 0) & alignMask(sVd)) === (1.U(3.W) << (sVd - 1.U))(2, 0)))
  def widen4to1OverlapOk(vd: UInt, sVd: UInt, src: UInt): Bool =
    !sameGroup(vd, src, sVd) || ((sVd === 2.U) && (src(1, 0) === 3.U)) ||
      ((sVd === 3.U) && (src(2, 0) === 6.U))

  def isStaticAluLegal(inst: UInt, p: Parameters): Bool = {
    val (vd, funct3, vs1, vs2) = (inst(11, 7), inst(14, 12), inst(19, 15), inst(24, 20))
    val (vm, funct6, funct7)   = (inst(25), inst(31, 26), inst(31, 25))

    val (vdNotV0, vs2NotV0, vs1NotV0) =
      (vm || (vd =/= 0.U), vm || (vs2 =/= 0.U), vm || (vs1 =/= 0.U))
    val (vvvMaskOk, vvxMaskOk)     = (vdNotV0 && vs2NotV0 && vs1NotV0, vdNotV0 && vs2NotV0)
    val (vvSrcMaskOk, vxSrcMaskOk) = (vs2NotV0 && vs1NotV0, vs2NotV0)
    val (widenNoEqVv, widenNoEqVx) =
      ((vd =/= vs2) && (vd =/= vs1) && vvvMaskOk, (vd =/= vs2) && vvxMaskOk)
    val vmergeVxOk = (!vm && (vd =/= 0.U) && vxSrcMaskOk) || (vm && (vs2 === 0.U))

    // Shared OPI* (OPIVV=000, OPIVI=011, OPIVX=100) checks.
    val (isOpiVv, isOpiVx)      = (funct3 === "b000".U, funct3 === "b100".U)
    val (opiMaskOk, opiSrcMask) =
      (Mux(isOpiVv, vvvMaskOk, vvxMaskOk), Mux(isOpiVv, vvSrcMaskOk, vxSrcMaskOk))
    val opiValid =
      // vadd, vand/or/xor, vsaddu/vsadd, vsll, vsrl/vsra/vssrl/vssra
      (matches(funct6, "000000", "001001", "00101?", "10000?", "100101", "1010??") && opiMaskOk) ||
        // vsub, vminu/vmin/vmaxu/vmax, vssubu/vssub, vsmul (OPIVV & OPIVX)
        (!funct3(0) && matches(funct6, "000010", "0001??", "10001?", "100111") && opiMaskOk) ||
        // vrsub, vslidedown, vnsrl/vnsra/vnclipu/vnclip (OPIVX & OPIVI)
        (!isOpiVv && matches(funct6, "000011", "001111", "1011??") && vvxMaskOk) ||
        // vnsrl.wv, vnsra.wv, vnclipu.wv, vnclip.wv (OPIVV: vs2 != vs1)
        (isOpiVv && matches(funct6, "1011??") && (vs1 =/= vs2) && vvvMaskOk) ||
        // vrgather.vv / vrgatherei16.vv (OPIVV) and vrgather.vx/.vi, vslideup.vx/.vi (OPIVX/OPIVI)
        (matches(funct6, "001100", "001110") && Mux(isOpiVv, widenNoEqVv, widenNoEqVx)) ||
        // vadc, vsbc (require vm=0, vd!=v0; vsbc is OPIVV/OPIVX only)
        (((funct6 === "b010000".U) || (!funct3(0) && (funct6 === "b010010".U))) &&
          !vm && (vd =/= 0.U) && opiSrcMask) ||
        // vmadc, vmseq, vmsne, vmsleu, vmsle (all OPI*)
        (matches(funct6, "010001", "01100?", "01110?") && opiSrcMask) ||
        // vmsbc, vmsltu, vmslt (OPIVV & OPIVX); vmsgtu, vmsgt (OPIVX & OPIVI)
        (((!funct3(0) && matches(funct6, "010011", "01101?")) ||
          (!isOpiVv && matches(funct6, "01111?"))) && opiSrcMask) ||
        // vmerge / vmv.v.*
        ((funct6 === "b010111".U) && ((!vm && (vd =/= 0.U) && opiSrcMask) || (vm && (vs2 === 0.U)))) ||
        // vwredsumu.vs, vwredsum.vs (OPIVV)
        (isOpiVv && matches(funct6, "11000?") && (vs1 =/= vs2) && vvSrcMaskOk) ||
        // vmv<nr>r.v (OPIVI)
        (funct3(0) && (funct6 === "b100111".U) && vm &&
          matches(vs1, "00000", "00001", "00011", "00111") && (((vd | vs2) & vs1) === 0.U))

    val opmvvValid =
      (matches(funct6, "000???") && vvSrcMaskOk) || // vred*
        (matches(
          funct6,
          "0010??",
          "100???",
          "101??1"
        ) && vvvMaskOk) || // vmul*, vdiv*, vaver*, vmacc*
        ((funct6 === "b010000".U) && ((vm && (vs1 === 0.U)) || matches(
          vs1,
          "1000?"
        ))) || // vmv.x.s, vcpop, vfirst
        ((funct6 === "b010010".U) && (vs1(
          4,
          2
        ) === "b001".U) && widenNoEqVx) ||        // vzext/vsext.vf2/vf4
        ((funct6 === "b010100".U) && vdNotV0 && ( // vmsbf/vmsof/vmsif/viota, vid.v
          (matches(vs1, "00001", "0001?", "10000") && (vd =/= vs2)) ||
            ((vs1 === "b10001".U) && (vs2 === 0.U))
        )) ||
        ((funct6 === "b010111".U) && vm && (vd =/= vs2) && (vd =/= vs1) && (vs1 =/= vs2)) || // vcompress.vm
        (matches(funct6, "011???") && vm) || // vmand*, vmor*, vmxor*, vmnand*, vmnor*, vmxnor*
        (matches(
          funct6,
          "1100??",
          "111000",
          "11101?",
          "11110?",
          "111111"
        ) && widenNoEqVv) || // vwadd/sub.vv, vwmul*, vwmacc*
        (matches(
          funct6,
          "1101??"
        ) && (vd =/= vs1) && (vs2 =/= vs1) && vvvMaskOk) // vwadd.wv, vwsub.wv

    val opmvxValid =
      (matches(
        funct6,
        "0010??",
        "001111",
        "100???",
        "101??1",
        "1101??"
      ) && vvxMaskOk) || // vslide1down, vdiv*, vmul*, vmacc*, vwadd/sub.wx
        ((funct6 === "b001110".U) && widenNoEqVx) || // vslide1up.vx
        ((funct6 === "b010000".U) && vm && (         // vmv.s.x, vtdiscard, vtzero.t, vtmv.v.t
          (vs2 === 0.U) || (p.enableVme.B && (
            ((vs2 === "b11100".U) && (vs1 === 0.U) && (vd === 0.U)) ||
              ((vs2 === "b11110".U) && (vs1 === 0.U) && !vd(0)) || (vs2 === "b11111".U)
          ))
        )) ||
        ((funct6 === "b010111".U) && p.enableVme.B && vm && (vd === 0.U)) || // vtmv.t.v
        (matches(
          funct6,
          "1100??",
          "111000",
          "11101?",
          "1111??"
        ) && widenNoEqVx) // vwadd/sub.vx, vwmul*, vwmacc*

    val opfvvValid =
      (p.enableFloat.B && (
        // vfadd, vfsub, vfmin, vfmax, vfsgnj*, vfdiv, vfmul, vfmadd/vfmsub/vfmacc/vfmsac
        (matches(
          funct6,
          "000??0",
          "00100?",
          "001010",
          "100000",
          "100100",
          "101???"
        ) && vvvMaskOk) ||
          // vfred*, vmfeq, vmfne, vmflt, vmfle
          (matches(funct6, "000??1", "01100?", "011011", "011100") && vvSrcMaskOk) ||
          ((funct6 === "b010000".U) && vm && (vs1 === 0.U)) || // vfmv.f.s
          ((funct6 === "b010011".U) && matches(
            vs1,
            "00000",
            "0010?",
            "10000"
          ) && vvxMaskOk) // vfsqrt, vfrsqrt7, vfrec7, vfclass
      )) ||
        ((funct6 === "b010010".U) && ( // vfcvt*, vfwcvt*, vfncvt*, vfwcvtbf16, vfncvtbf16
          (((p.enableFloat.B && matches(vs1, "000??", "0011?", "1000?", "1011?")) ||
            (p.enableVectorBf16.B && (vs1 === "b11101".U))) && vvxMaskOk) ||
            (((p.enableFloat.B && matches(vs1, "0101?")) ||
              (p.enableVectorBf16.B && (vs1 === "b01101".U))) && widenNoEqVx)
        )) ||
        (p.enableVectorBf16.B && (funct6 === "b111011".U) && widenNoEqVv) // vfwmaccbf16.vv

    val opfvfValid =
      (p.enableFloat.B && (
        // vfadd, vfsub, vfmin, vfmax, vfsgnj*, vslide1down, vfdiv, vfrdiv, vfmul, vfrsub, vfmadd/vfmacc
        (matches(
          funct6,
          "000??0",
          "00100?",
          "001010",
          "001111",
          "10000?",
          "100100",
          "100111",
          "101???"
        ) && vvxMaskOk) ||
          ((funct6 === "b001110".U) && widenNoEqVx) ||         // vfslide1up.vf
          ((funct6 === "b010000".U) && vm && (vs2 === 0.U)) || // vfmv.s.f
          ((funct6 === "b010111".U) && vmergeVxOk) ||          // vfmerge.vfm / vfmv.v.f
          (matches(funct6, "01100?", "011011", "01110?", "011111") && vxSrcMaskOk) // vmfeq..vmfgt
      )) ||
        (p.enableVectorBf16.B && (funct6 === "b111011".U) && widenNoEqVx) // vfwmaccbf16.vf

    val opcfgValid = (!inst(31)) || (inst(31, 30) === "b11".U) || (funct7 === "b1000000".U) || (
      p.enableVme.B && (
        ((funct7 === "b1000010".U) && (vd === 0.U)) ||
          ((funct7 === "b1000100".U) && matches(vs2, "0000?", "00010")) ||
          ((inst(31, 29) === "b100".U) && (inst(27, 25) === "b100".U) &&
            (inst(22, 20) === "b100".U) && (inst(19, 17) === "b000".U) && (vd === 0.U))
      )
    )

    MuxLookup(funct3, false.B)(
      Seq(
        "b000".U -> opiValid,
        "b001".U -> opfvvValid,
        "b010".U -> opmvvValid,
        "b011".U -> opiValid,
        "b100".U -> opiValid,
        "b101".U -> opfvfValid,
        "b110".U -> opmvxValid,
        "b111".U -> opcfgValid
      )
    )
  }

  def from_uncompressed(p: Parameters, inst: UInt, pc: UInt): Valid[RvvCompressedInstruction] = {
    val (old_opcode, bits)   = (inst(6, 0), inst(31, 7))
    val (vd, width, vs2, vm) = (inst(11, 7), inst(14, 12), inst(24, 20), inst(25))
    val (mop, mew, nf)       = (inst(27, 26), inst(28), inst(31, 29))
    val (isLoad, isStore)    = (old_opcode === "b0000111".U, old_opcode === "b0100111".U)
    val (vdNotV0, vs2NotV0)  = (vm || (vd =/= 0.U), vm || (vs2 =/= 0.U))
    val validStdWidth        = !mew && matches(width, "000", "101", "110")

    val unitStrideLegal = MuxLookup(vs2, false.B)(
      Seq(
        "b00000".U -> vdNotV0,
        "b01000".U -> (vm && (isLoad || (isStore && (width === "b000".U))) && (
          (nf === "b000".U) ||
            ((nf === "b001".U) && !vd(0)) ||
            ((nf === "b011".U) && (vd(1, 0) === 0.U)) ||
            ((nf === "b111".U) && (vd(2, 0) === 0.U))
        )),
        "b01011".U -> (vm && (width === "b000".U) && (nf === "b000".U)),
        "b10000".U -> (isLoad && vdNotV0)
      )
    )
    val indexedLegal = vdNotV0 && vs2NotV0 && (!(isLoad && (nf =/= 0.U)) || (vd =/= vs2))
    val isRvvLdSt    =
      validStdWidth && Mux(mop(0), indexedLegal, Mux(mop(1), vdNotV0, unitStrideLegal))
    val isVmeLdSt = p.enableVme.B && mew && (width === "b111".U) && (vd === 0.U) &&
      vm && (mop === 0.U) && matches(nf, "00?", "010")
    val validLdSt = isRvvLdSt || isVmeLdSt

    val temp_inst = Wire(new RvvCompressedInstruction(p))
    temp_inst.bits    := bits
    temp_inst.opcode  := RvvCompressedOpcode.RVVALU
    temp_inst.pc      := pc
    temp_inst.rob_tag := 0.U
    val staticAluOk = !temp_inst.isIllegalFloat(p) && isStaticAluLegal(inst, p)

    val new_opcode = MuxLookup(old_opcode, MakeInvalid(RvvCompressedOpcode()))(
      Seq(
        "b0000111".U -> MakeValid(validLdSt, RvvCompressedOpcode.RVVLOAD),
        "b0100111".U -> MakeValid(validLdSt, RvvCompressedOpcode.RVVSTORE),
        "b1010111".U -> MakeValid(staticAluOk, RvvCompressedOpcode.RVVALU),
        "b1110111".U -> MakeValid(isOpVeValid(inst, p), RvvCompressedOpcode.RVVALU)
      )
    )

    // Fancy way to MakeValid.
    MakeWireBundle[ValidIO[RvvCompressedInstruction]](
      Valid(new RvvCompressedInstruction(p)),
      _.valid        -> new_opcode.valid,
      _.bits.opcode  -> new_opcode.bits,
      _.bits.pc      -> pc,
      _.bits.bits    -> bits,
      _.bits.rob_tag -> 0.U
    )
  }

  def isOpVeValid(inst: UInt, p: Parameters): Bool = {
    if (p.enableVme) {
      val opcode    = inst(6, 0)
      val funct6    = inst(31, 26)
      val funct3    = inst(14, 12)
      val vm        = inst(25)
      val isFp      = (funct3 === "b001".U) && !inst(15) && !inst(20)
      val isInt     = (funct3 === "b000".U) && !inst(17) && !inst(22)
      val fpValid   = p.enableFloat.B
      val mtdAlign4 = inst(9, 8) === 0.U
      (opcode === "b1110111".U) && (funct6 === "b111100".U) && vm && mtdAlign4 &&
      (isInt || (isFp && fpValid))
    } else {
      false.B
    }
  }

  def isVsetvl(inst: UInt): Bool = {
    val opcode     = inst(6, 0)
    val funct3     = inst(14, 12)
    val funct7     = inst(31, 25)
    val isCfg      = opcode === "b1010111".U && funct3 === "b111".U
    val isVsetvli  = !inst(31)
    val isVsetivli = inst(31, 30) === "b11".U
    val isVsetvl   = funct7 === "b1000000".U
    isCfg && (isVsetvli || isVsetivli || isVsetvl)
  }

  def isMsetWritesMtype(inst: UInt): Bool = {
    val opcode       = inst(6, 0)
    val funct3       = inst(14, 12)
    val funct7       = inst(31, 25)
    val rs2          = inst(24, 20)
    val rd           = inst(11, 7)
    val isVset       = opcode === "b1010111".U && funct3 === "b111".U
    val isMsetmtype  = funct7 === "b1000010".U && rd === 0.U
    val isMsettm     = funct7 === "b1000100".U && rs2 === "b00001".U
    val isMsettk     = funct7 === "b1000100".U && rs2 === "b00010".U
    val isMsetmtypei = (inst(31, 29) === "b100".U) && (inst(27, 25) === "b100".U) &&
      (inst(22, 20) === "b100".U) && (inst(19, 17) === "b000".U) && (rd === 0.U)
    isVset && (isMsetmtype || isMsettm || isMsettk || isMsetmtypei)
  }

  def isMsetWritesVtype(inst: UInt): Bool = {
    val opcode       = inst(6, 0)
    val funct3       = inst(14, 12)
    val funct7       = inst(31, 25)
    val rd           = inst(11, 7)
    val isVset       = opcode === "b1010111".U && funct3 === "b111".U
    val isMsetmtype  = funct7 === "b1000010".U && rd === 0.U
    val isMsetmtypei = (inst(31, 29) === "b100".U) && (inst(27, 25) === "b100".U) &&
      (inst(22, 20) === "b100".U) && (inst(19, 17) === "b000".U) && (rd === 0.U)
    isVset && (isMsetmtype || isMsetmtypei)
  }

  def writesMtype(inst: UInt): Bool =
    isVsetvl(inst) || isMsetWritesMtype(inst)
}

class RvvS1DecodeInstructionBase {
  def invalid() = MakeInvalid(new RvvS1DecodedInstruction)

  private def s1decode_opivv(
    f6vm: UInt,
    vs2: UInt,
    vs1: UInt,
    vd: UInt
  ): Valid[RvvS1DecodedInstruction] = {
    val no_overlap = (vd =/= vs1 && vd =/= vs2)
    val op         = MuxUpTo1H(
      MakeInvalid(RvvAluOp()),
      Seq(
        // We're assuming all instructions are mask-optional unless the spec says otherwise.
        (f6vm === BitPat("b000000_?")) -> MakeValid(RvvAluOp.VADD),
        (f6vm === BitPat("b000010_?")) -> MakeValid(RvvAluOp.VSUB),
        // No VRSUB.
        (f6vm === BitPat("b000100_?")) -> MakeValid(RvvAluOp.VMINU),
        (f6vm === BitPat("b000101_?")) -> MakeValid(RvvAluOp.VMIN),
        (f6vm === BitPat("b000110_?")) -> MakeValid(RvvAluOp.VMAXU),
        (f6vm === BitPat("b000111_?")) -> MakeValid(RvvAluOp.VMAX),
        (f6vm === BitPat("b001001_?")) -> MakeValid(RvvAluOp.VAND),
        (f6vm === BitPat("b001010_?")) -> MakeValid(RvvAluOp.VOR),
        (f6vm === BitPat("b001011_?")) -> MakeValid(RvvAluOp.VXOR),
        (f6vm === BitPat("b001100_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHER),
        (f6vm === BitPat("b001110_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHEREI16),
        // No VSLIDEUP.
        // No VSLIDEDOWN.
        (f6vm === "b010000_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VADC), // Mask required.
        (f6vm === BitPat("b010001_?")) -> MakeValid(RvvAluOp.VMADC),
        (f6vm === "b010010_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VSBC), // Mask required.
        (f6vm === BitPat("b010011_?")) -> MakeValid(RvvAluOp.VMSBC),
        (f6vm === "b010111_0".U)       -> MakeValid(RvvAluOp.VMERGE), // Mask required.
        (f6vm === "b010111_1".U)       -> MakeValid(RvvAluOp.VMV),    // Mask not available
        (f6vm === "b011000_0".U)       -> MakeValid(RvvAluOp.VMSEQ),  // Mask required.
        (f6vm === "b011001_0".U)       -> MakeValid(RvvAluOp.VMSNE),  // Mask required.
        (f6vm === "b011010_0".U)       -> MakeValid(RvvAluOp.VMSLTU), // Mask required.
        (f6vm === "b011011_0".U)       -> MakeValid(RvvAluOp.VMSLT),  // Mask required.
        (f6vm === "b011100_0".U)       -> MakeValid(RvvAluOp.VMSLEU), // Mask required.
        (f6vm === "b011101_0".U)       -> MakeValid(RvvAluOp.VMSLE),  // Mask required.
        // No VMSGTU.
        // No VMSGT.
        (f6vm === BitPat("b100000_?")) -> MakeValid(RvvAluOp.VSADDU),
        (f6vm === BitPat("b100001_?")) -> MakeValid(RvvAluOp.VSADD),
        (f6vm === BitPat("b100010_?")) -> MakeValid(RvvAluOp.VSSUBU),
        (f6vm === BitPat("b100011_?")) -> MakeValid(RvvAluOp.VSSUB),
        (f6vm === BitPat("b100101_?")) -> MakeValid(RvvAluOp.VSLL),
        (f6vm === BitPat("b100111_?")) -> MakeValid(RvvAluOp.VSMUL),
        // No VMV1R.
        // No VMV2R.
        // No VMV4R.
        // No VMV8R.
        (f6vm === BitPat("b101000_?")) -> MakeValid(RvvAluOp.VSRL),
        (f6vm === BitPat("b101001_?")) -> MakeValid(RvvAluOp.VSRA),
        (f6vm === BitPat("b101010_?")) -> MakeValid(RvvAluOp.VSSRL),
        (f6vm === BitPat("b101011_?")) -> MakeValid(RvvAluOp.VSSRA),
        (f6vm === BitPat("b101100_?")) -> MakeValid(RvvAluOp.VNSRL),
        (f6vm === BitPat("b101101_?")) -> MakeValid(RvvAluOp.VNSRA),
        (f6vm === BitPat("b101110_?")) -> MakeValid(RvvAluOp.VNCLIPU),
        (f6vm === BitPat("b101111_?")) -> MakeValid(RvvAluOp.VNCLIP)
      )
    )

    ForceZero(
      MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
        Valid(new RvvS1DecodedInstruction),
        _.valid            -> op.valid,
        _.bits.op          -> op.bits,
        _.bits.is_float    -> false.B,
        _.bits.is_widening -> false.B
      )
    )
  }

  private def s1decode_opivx(
    f6vm: UInt,
    vs2: UInt,
    rs1: UInt,
    vd: UInt
  ): Valid[RvvS1DecodedInstruction] = {
    val no_overlap = (vd =/= vs2)
    val op         = MuxUpTo1H(
      MakeInvalid(RvvAluOp()),
      Seq(
        (f6vm === BitPat("b000000_?")) -> MakeValid(RvvAluOp.VADD),
        (f6vm === BitPat("b000010_?")) -> MakeValid(RvvAluOp.VSUB),
        (f6vm === BitPat("b000011_?")) -> MakeValid(RvvAluOp.VRSUB),
        (f6vm === BitPat("b000100_?")) -> MakeValid(RvvAluOp.VMINU),
        (f6vm === BitPat("b000101_?")) -> MakeValid(RvvAluOp.VMIN),
        (f6vm === BitPat("b000110_?")) -> MakeValid(RvvAluOp.VMAXU),
        (f6vm === BitPat("b000111_?")) -> MakeValid(RvvAluOp.VMAX),
        (f6vm === BitPat("b001001_?")) -> MakeValid(RvvAluOp.VAND),
        (f6vm === BitPat("b001010_?")) -> MakeValid(RvvAluOp.VOR),
        (f6vm === BitPat("b001011_?")) -> MakeValid(RvvAluOp.VXOR),
        (f6vm === BitPat("b001100_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHER),
        // No VRGATHEREI16.
        (f6vm === BitPat("b001110_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEUP),
        (f6vm === BitPat("b001111_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEDOWN),
        (f6vm === "b010000_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VADC), // Mask required.
        (f6vm === BitPat("b010001_?")) -> MakeValid(RvvAluOp.VMADC),
        (f6vm === "b010010_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VSBC), // Mask required.
        (f6vm === BitPat("b010011_?")) -> MakeValid(RvvAluOp.VMSBC),
        (f6vm === "b010111_0".U)       -> MakeValid(RvvAluOp.VMERGE), // Mask required.
        (f6vm === "b010111_1".U)       -> MakeValid(
          vs2 === "b00000".U,
          RvvAluOp.VMV
        ), // Mask not available
        (f6vm === "b011000_0".U)       -> MakeValid(RvvAluOp.VMSEQ),  // Mask required.
        (f6vm === "b011001_0".U)       -> MakeValid(RvvAluOp.VMSNE),  // Mask required.
        (f6vm === "b011010_0".U)       -> MakeValid(RvvAluOp.VMSLTU), // Mask required.
        (f6vm === "b011011_0".U)       -> MakeValid(RvvAluOp.VMSLT),  // Mask required.
        (f6vm === "b011100_0".U)       -> MakeValid(RvvAluOp.VMSLEU), // Mask required.
        (f6vm === "b011101_0".U)       -> MakeValid(RvvAluOp.VMSLE),  // Mask required.
        (f6vm === "b011110_0".U)       -> MakeValid(RvvAluOp.VMSGTU), // Mask required.
        (f6vm === "b011111_0".U)       -> MakeValid(RvvAluOp.VMSGT),  // Mask required.
        (f6vm === BitPat("b100000_?")) -> MakeValid(RvvAluOp.VSADDU),
        (f6vm === BitPat("b100001_?")) -> MakeValid(RvvAluOp.VSADD),
        (f6vm === BitPat("b100010_?")) -> MakeValid(RvvAluOp.VSSUBU),
        (f6vm === BitPat("b100011_?")) -> MakeValid(RvvAluOp.VSSUB),
        (f6vm === BitPat("b100101_?")) -> MakeValid(RvvAluOp.VSLL),
        (f6vm === BitPat("b100111_?")) -> MakeValid(RvvAluOp.VSMUL),
        // No VMV1R.
        // No VMV2R.
        // No VMV4R.
        // No VMV8R.
        (f6vm === BitPat("b101000_?")) -> MakeValid(RvvAluOp.VSRL),
        (f6vm === BitPat("b101001_?")) -> MakeValid(RvvAluOp.VSRA),
        (f6vm === BitPat("b101010_?")) -> MakeValid(RvvAluOp.VSSRL),
        (f6vm === BitPat("b101011_?")) -> MakeValid(RvvAluOp.VSSRA),
        (f6vm === BitPat("b101100_?")) -> MakeValid(RvvAluOp.VNSRL),
        (f6vm === BitPat("b101101_?")) -> MakeValid(RvvAluOp.VNSRA),
        (f6vm === BitPat("b101110_?")) -> MakeValid(RvvAluOp.VNCLIPU),
        (f6vm === BitPat("b101111_?")) -> MakeValid(RvvAluOp.VNCLIP)
      )
    )

    ForceZero(
      MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
        Valid(new RvvS1DecodedInstruction),
        _.valid            -> op.valid,
        _.bits.op          -> op.bits,
        _.bits.is_float    -> false.B,
        _.bits.is_widening -> false.B
      )
    )
  }

  private def s1decode_opivi(
    f6vm: UInt,
    vs2: UInt,
    imm5: UInt,
    vd: UInt
  ): Valid[RvvS1DecodedInstruction] = {
    val no_overlap   = (vd =/= vs2)
    val unary_align2 = (vd === BitPat("b????0")) && (vs2 === BitPat("b????0"))
    val unary_align4 = (vd === BitPat("b???00")) && (vs2 === BitPat("b???00"))
    val unary_align8 = (vd === BitPat("b??000")) && (vs2 === BitPat("b??000"))
    val op           = MuxUpTo1H(
      MakeInvalid(RvvAluOp()),
      Seq(
        (f6vm === BitPat("b000000_?")) -> MakeValid(RvvAluOp.VADD),
        // No VSUB.
        (f6vm === BitPat("b000011_?")) -> MakeValid(RvvAluOp.VRSUB),
        // No VMINU.
        // No VMIN.
        // No VMAXU.
        // No VMAX.
        (f6vm === BitPat("b001001_?")) -> MakeValid(RvvAluOp.VAND),
        (f6vm === BitPat("b001010_?")) -> MakeValid(RvvAluOp.VOR),
        (f6vm === BitPat("b001011_?")) -> MakeValid(RvvAluOp.VXOR),
        (f6vm === BitPat("b001100_?")) -> MakeValid(no_overlap, RvvAluOp.VRGATHER),
        // No VRGATHEREI16.
        (f6vm === BitPat("b001110_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEUP),
        (f6vm === BitPat("b001111_?")) -> MakeValid(no_overlap, RvvAluOp.VSLIDEDOWN),
        (f6vm === "b010000_0".U) -> MakeValid(vd =/= "b00000".U, RvvAluOp.VADC), // Mask required.
        (f6vm === BitPat("b010001_?")) -> MakeValid(RvvAluOp.VMADC),
        // No VSBC.
        // No VMSBC.
        (f6vm === "b010111_0".U) -> MakeValid(RvvAluOp.VMERGE), // Mask required.
        (f6vm === "b010111_1".U) -> MakeValid(
          vs2 === "b00000".U,
          RvvAluOp.VMV
        ), // Mask not available.
        (f6vm === "b011000_0".U) -> MakeValid(RvvAluOp.VMSEQ), // Mask required.
        (f6vm === "b011001_0".U) -> MakeValid(RvvAluOp.VMSNE), // Mask required.
        // No VMSLTU.
        // No VMSLT.
        (f6vm === "b011100_0".U)       -> MakeValid(RvvAluOp.VMSLEU), // Mask required.
        (f6vm === "b011101_0".U)       -> MakeValid(RvvAluOp.VMSLE),  // Mask required.
        (f6vm === "b011110_0".U)       -> MakeValid(RvvAluOp.VMSGTU), // Mask required.
        (f6vm === "b011111_0".U)       -> MakeValid(RvvAluOp.VMSGT),  // Mask required.
        (f6vm === BitPat("b100000_?")) -> MakeValid(RvvAluOp.VSADDU),
        (f6vm === BitPat("b100001_?")) -> MakeValid(RvvAluOp.VSADD),
        // No VSSUBU.
        // No VSSUB.
        (f6vm === BitPat("b100101_?")) -> MakeValid(RvvAluOp.VSLL),
        // No VSMUL.
        // TODO(davidgao): the 4 entries below looks ugly. Consider merging them into one function call.
        (f6vm === "b100111_1".U && imm5 === "b00000".U) -> MakeValid(
          RvvAluOp.VMV1R
        ), // Mask not available.
        (f6vm === "b100111_1".U && imm5 === "b00001".U) -> MakeValid(
          unary_align2,
          RvvAluOp.VMV2R
        ), // Mask not available.
        (f6vm === "b100111_1".U && imm5 === "b00011".U) -> MakeValid(
          unary_align4,
          RvvAluOp.VMV4R
        ), // Mask not available.
        (f6vm === "b100111_1".U && imm5 === "b00111".U) -> MakeValid(
          unary_align8,
          RvvAluOp.VMV8R
        ), // Mask not available.
        (f6vm === BitPat("b101000_?")) -> MakeValid(RvvAluOp.VSRL),
        (f6vm === BitPat("b101001_?")) -> MakeValid(RvvAluOp.VSRA),
        (f6vm === BitPat("b101010_?")) -> MakeValid(RvvAluOp.VSSRL),
        (f6vm === BitPat("b101011_?")) -> MakeValid(RvvAluOp.VSSRA),
        (f6vm === BitPat("b101100_?")) -> MakeValid(RvvAluOp.VNSRL),
        (f6vm === BitPat("b101101_?")) -> MakeValid(RvvAluOp.VNSRA),
        (f6vm === BitPat("b101110_?")) -> MakeValid(RvvAluOp.VNCLIPU),
        (f6vm === BitPat("b101111_?")) -> MakeValid(RvvAluOp.VNCLIP)
      )
    )

    ForceZero(
      MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
        Valid(new RvvS1DecodedInstruction),
        _.valid            -> op.valid,
        _.bits.op          -> op.bits,
        _.bits.is_float    -> false.B,
        _.bits.is_widening -> false.B
      )
    )
  }

  private def s1decode_opfvv(
    f6vm: UInt,
    vs2: UInt,
    vs1: UInt,
    vd: UInt
  ): Valid[RvvS1DecodedInstruction] = {
    val op = MuxUpTo1H(
      MakeInvalid(RvvAluOp()),
      Seq(
        (f6vm === "b000001".U)                       -> MakeValid(RvvAluOp.VFREDUSUM),
        (f6vm === "b000011".U)                       -> MakeValid(RvvAluOp.VFREDOSUM),
        (f6vm === "b000101".U)                       -> MakeValid(RvvAluOp.VFREDMIN),
        (f6vm === "b000111".U)                       -> MakeValid(RvvAluOp.VFREDMAX),
        (f6vm === "b010010".U && vs1 === "b01101".U) -> MakeValid(RvvAluOp.VFWCVTBF16),
        (f6vm === "b010010".U && vs1 === "b11101".U) -> MakeValid(RvvAluOp.VFNCVTBF16),
        (f6vm === "b111011".U)                       -> MakeValid(RvvAluOp.VFWMACCBF16)
      )
    )

    val is_widening = (f6vm === "b010010".U || f6vm === "b111011".U) && (vs1 =/= "b11101".U)

    ForceZero(
      MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
        Valid(new RvvS1DecodedInstruction),
        _.valid            -> op.valid,
        _.bits.op          -> op.bits,
        _.bits.is_float    -> true.B,
        _.bits.is_widening -> is_widening
      )
    )
  }

  private def s1decode_opfvf(
    f6vm: UInt,
    vs2: UInt,
    rs1: UInt,
    vd: UInt
  ): Valid[RvvS1DecodedInstruction] = {
    val op = MuxUpTo1H(
      MakeInvalid(RvvAluOp()),
      Seq(
        (f6vm === "b010010".U && rs1 === "b01101".U) -> MakeValid(RvvAluOp.VFWCVTBF16),
        (f6vm === "b111011".U)                       -> MakeValid(RvvAluOp.VFWMACCBF16)
      )
    )

    ForceZero(
      MakeWireBundle[ValidIO[RvvS1DecodedInstruction]](
        Valid(new RvvS1DecodedInstruction),
        _.valid            -> op.valid,
        _.bits.op          -> op.bits,
        _.bits.is_float    -> true.B,
        _.bits.is_widening -> true.B
      )
    )
  }

  protected def s1decode_opv(bits: UInt): Valid[RvvS1DecodedInstruction] = {
    // 7 LSB have already been consumed, 25 bits left.
    val vd     = bits(4, 0)   // Or rd where applicable.
    val mode   = bits(7, 5)
    val vs1    = bits(12, 8)  // Or rs1, or imm5, where applicable.
    val vs2    = bits(17, 13) // Does not apply to 2 of the 3 config ops.
    val f6vm   = bits(24, 18) // Does not apply to config ops.
    val funct6 = bits(24, 19)

    MuxLookup(mode, invalid())(
      Seq(
        "b000".U -> s1decode_opivv(f6vm, vs2, vs1, vd),
        "b001".U -> s1decode_opfvv(funct6, vs2, vs1, vd),
        "b011".U -> s1decode_opivi(f6vm, vs2, vs1, vd),
        "b100".U -> s1decode_opivx(f6vm, vs2, vs1, vd),
        "b101".U -> s1decode_opfvf(funct6, vs2, vs1, vd)
      )
    )
  }
}

object RvvS1DecodeInstruction extends RvvS1DecodeInstructionBase {
  // RVV is an extension and does not directly handle undefined (illegal)
  // instructions.
  def apply(inst: UInt): Valid[RvvS1DecodedInstruction] = {
    // All instructions are 32 bits and all have 7-bit opcodes.
    val opcode = inst(6, 0)
    val bits   = inst(31, 7)
    MuxLookup(opcode, invalid())(
      Seq(
        "b1010111".U -> s1decode_opv(bits),
        "b1110111".U -> s1decode_opv(bits),
        "b0000111".U -> invalid(), // TODO LOAD-FP
        "b0100111".U -> invalid()  // TODO STORE-FP
      )
    )
  }
}

object RvvS1DecodeCompressedInstruction extends RvvS1DecodeInstructionBase {
  // RVV is an extension and does not directly handle undefined (illegal)
  // instructions. This compressed format is only used within some of our
  // cores, and never exposed to sw.
  def apply(inst: RvvCompressedInstruction): Valid[RvvS1DecodedInstruction] = {
    // All instructions are 2-bit opcode plus 25 bits for further decoding.
    MuxLookup(inst.opcode, invalid())(
      Seq(
        RvvCompressedOpcode.RVVLOAD  -> invalid(), // TODO: implement this
        RvvCompressedOpcode.RVVSTORE -> invalid(), // TODO: implement this
        RvvCompressedOpcode.RVVALU   -> s1decode_opv(inst.bits)
      )
    )
  }

  def apply(inst: Valid[RvvCompressedInstruction]): Valid[RvvS1DecodedInstruction] = {
    // Wrapper to emit invalid output for invalid input.
    Mux(inst.valid, apply(inst.bits), MakeInvalid(new RvvS1DecodedInstruction))
  }
}
