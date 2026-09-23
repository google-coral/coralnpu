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
import coralnpu.rvv._

class Lsu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Decode cycle.
    val req         = Vec(p.instructionLanes, Flipped(Decoupled(new LsuCmd(p))))
    val busPort     = Flipped(new RegfileBusPortIO(p))
    val busPort_flt = Option.when(p.enableFloat)(Flipped(new RegfileBusPortIO(p)))

    // Execute cycle(s).
    val rd     = Valid(Flipped(new RegfileWriteDataIO(p)))
    val rd_flt = Valid(Flipped(new FloatRegfileWriteDataIO(p)))

    // Cached interface.
    val ibus  = new IBusIO(p)
    val dbus  = new DBusIO(p)
    val flush = new IFlushIO(p)
    val fault = Valid(new LsuFaultInfo(p))

    // DBus that will eventually reach an external bus.
    // Intended for sending a transaction to an external
    // peripheral, likely on TileLink or AXI.
    val ebus = new EBusIO(p)

    val rvv2lsu = Option.when(p.enableRvv)(Vec(2, Flipped(Decoupled(new Rvv2Lsu(p)))))
    val lsu2rvv = Option.when(p.enableRvv)(Vec(2, Decoupled(new Lsu2Rvv(p))))

    val vme2lsu = Option.when(p.enableVme)(Flipped(Decoupled(new Vme2Lsu(p))))
    val lsu2vme = Option.when(p.enableVme)(Decoupled(new Lsu2Vme(p)))

    // RVV config state
    val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))

    val queueCapacity = Output(UInt(3.W))
    val active        = Output(Bool())
    val storeComplete = Output(Valid(UInt(p.programCounterBits.W)))
    val pipelineFlush = Input(Bool())
  })
}

object Lsu {
  def apply(p: Parameters): Lsu = {
    Module(new LsuV3(p))
  }
}

object LsuOp extends ChiselEnum {
  val LB      = Value
  val LH      = Value
  val LW      = Value
  val LBU     = Value
  val LHU     = Value
  val SB      = Value
  val SH      = Value
  val SW      = Value
  val LD      = Value
  val SD      = Value
  val LWU     = Value
  val FENCEI  = Value
  val FLOAT   = Value
  val FLOAT_H = Value

  // Vector instructions.
  val VLOAD_UNIT      = Value
  val VLOAD_STRIDED   = Value
  val VLOAD_OINDEXED  = Value
  val VLOAD_UINDEXED  = Value
  val VSTORE_UNIT     = Value
  val VSTORE_STRIDED  = Value
  val VSTORE_OINDEXED = Value
  val VSTORE_UINDEXED = Value

  // VME instructions.
  val VTLOAD  = Value
  val VTSTORE = Value

  def isVector(op: LsuOp.Type): Bool = {
    op.isOneOf(
      LsuOp.VLOAD_UNIT,
      LsuOp.VLOAD_STRIDED,
      LsuOp.VLOAD_OINDEXED,
      LsuOp.VLOAD_UINDEXED,
      LsuOp.VSTORE_UNIT,
      LsuOp.VSTORE_STRIDED,
      LsuOp.VSTORE_OINDEXED,
      LsuOp.VSTORE_UINDEXED
    )
  }

  def isTile(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VTLOAD, LsuOp.VTSTORE)
  }

  def isIndexedVector(op: LsuOp.Type): Bool = {
    op.isOneOf(
      LsuOp.VLOAD_OINDEXED,
      LsuOp.VLOAD_UINDEXED,
      LsuOp.VSTORE_OINDEXED,
      LsuOp.VSTORE_UINDEXED
    )
  }

  def isNonindexedVector(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED)
  }

}

class LsuCmd(p: Parameters) extends Bundle {
  val store     = Bool()
  val addr      = UInt(log2Ceil(p.scalarRegCount).W)
  val op        = LsuOp()
  val pc        = UInt(p.programCounterBits.W)
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  val nfields   = Option.when(p.enableRvv) { UInt(3.W) }
  val bit24To20 = Option.when(p.enableRvv) { UInt(5.W) }
  // Whether or not a vector L/S instruction is masked. Unused in other ops.
  val vm = Option.when(p.enableRvv) { Bool() }

  def umop = bit24To20 // when unit-stride
  def rs2  = bit24To20 // when const-stride

  def isMaskOperation(): Bool = {
    if (p.enableRvv) {
      (umop.get === "b01011".U) &&
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT)
    } else {
      false.B
    }
  }

  def isWholeRegister(): Bool = {
    if (p.enableRvv) {
      (umop.get === "b01000".U) &&
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT)
    } else {
      false.B
    }
  }

  override def toPrintable: Printable = {
    cf"LsuCmd(store -> ${store}, addr -> 0x${addr}%x, op -> ${op}, " +
      cf"pc -> 0x${pc}%x, elemWidth -> ${elemWidth}, nfields -> ${nfields})"
  }
}

class LsuUOp(p: Parameters) extends Bundle {
  val nCells   = if (p.enableRvv) 8 * p.rvvVlenb else 4
  val ctrWidth = log2Ceil(nCells + 1)

  val store = Bool()
  val rd    = UInt(log2Ceil(p.scalarRegCount).W)
  val op    = LsuOp()
  val pc    = UInt(p.programCounterBits.W)
  val addr  = UInt(p.lsuAddrBits.W)
  val data  = UInt(p.xlen.W) // Doubles as rs2
  // This aligns with "width" in the spec. It controls index width in
  // indexed loads/stores and data width otherwise.
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  // This is the sew from vtype. It controls data width in indexed
  // loads/stores and is unused in other ops.
  val sew = Option.when(p.enableRvv) { UInt(3.W) }
  // How many data registers (per segment if applicable) to operate on.
  val emul_data      = Option.when(p.enableRvv) { UInt(3.W) }
  val emul_data_orig = Option.when(p.enableRvv) { UInt(3.W) }
  val nfields        = Option.when(p.enableRvv) { UInt(3.W) }
  val strict         = Option.when(p.enableRvv) { Bool() }
  val vl             = Option.when(p.enableRvv) { UInt(log2Ceil(p.rvvVlen + 1).W) }
  val vstart         = Option.when(p.enableRvv) { UInt(log2Ceil(p.rvvVlen).W) }
  // Whether or not a vector L/S instruction is masked. Unused in other ops.
  val masked = Option.when(p.enableRvv) { Bool() }

  // Inclusive lower bound: cells at indices < startCell are pre-start (inactive).
  val startCell = Option.when(p.enableRvv) { UInt(ctrWidth.W) }
  // Exclusive upper bound of active data: cells at indices in [startCell, endCell)
  // are active; cells in [endCell, unreachableCell) are tail elements (inactive).
  val endCell = Option.when(p.enableRvv) { UInt(ctrWidth.W) }
  // Exclusive upper bound of allocated cells across active registers (LMUL * nfields).
  // Cells at indices >= unreachableCell are unreachable/disabled (DONE).
  val unreachableCell = UInt(ctrWidth.W)

  val initAsConstStride = Bool()
  val bytesPerSegment   = Option.when(p.enableRvv) { UInt(6.W) }

  override def toPrintable: Printable = {
    cf"LsuUOp(store -> ${store}, rd -> ${rd}, op -> ${op}, " +
      cf"pc -> 0x${pc}%x, addr -> 0x${addr}%x, data -> ${data})"
  }
}

object LsuUOp {
  def apply(
    p: Parameters,
    i: Int,
    cmd: LsuCmd,
    sbus: RegfileBusPortIO,
    fbus: Option[RegfileBusPortIO],
    rvvState: Option[Valid[RvvConfigState]]
  ): LsuUOp = {
    val result = Wire(new LsuUOp(p))
    result.store := cmd.store
    result.rd    := cmd.addr
    result.op    := cmd.op
    result.pc    := cmd.pc
    if (fbus.isDefined) {
      result.addr := sbus.addr(i)
      result.data := Mux(cmd.op.isOneOf(LsuOp.FLOAT, LsuOp.FLOAT_H), fbus.get.data(i), sbus.data(i))
    } else {
      result.addr := sbus.addr(i)
      result.data := sbus.data(i)
    }
    val isScalar1B  = cmd.op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB)
    val isScalar2B  = cmd.op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH, LsuOp.FLOAT_H)
    val scalarBytes = Cat(
      0.U((result.ctrWidth - 3).W),
      !isScalar1B && !isScalar2B,
      isScalar2B,
      isScalar1B
    )

    if (p.enableRvv) {
      val isTile     = if (p.enableVme) LsuOp.isTile(cmd.op) else false.B
      val isVector   = LsuOp.isVector(cmd.op) || isTile
      val isIndexed  = LsuOp.isIndexedVector(cmd.op)
      val isStrided  = cmd.op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED)
      val isMask     = cmd.isMaskOperation()
      val isWholeReg = cmd.isWholeRegister()
      val isRvvStore = cmd.store && !isTile

      val sew       = rvvState.get.bits.sew // From vtype
      val lmul_eff  = rvvState.get.bits.lmul
      val lmul_orig = rvvState.get.bits.lmul_orig
      val vstart    = rvvState.get.bits.vstart
      val vl_raw    = rvvState.get.bits.vl

      val tileEew = Option
        .when(p.enableVme) {
          MuxLookup(cmd.nfields.get, "b000".U)(
            Seq(
              "b000".U -> "b000".U, // 8-bit
              "b001".U -> "b101".U, // 16-bit
              "b010".U -> "b110".U  // 32-bit
            )
          )
        }
        .getOrElse("b000".U)
      val eew = Mux(isTile, tileEew, cmd.elemWidth.get)

      def elemShift(w: UInt): UInt = MuxLookup(w, 0.U(2.W))(
        Seq("b000".U -> 0.U, "b001".U -> 1.U, "b010".U -> 2.U, "b101".U -> 1.U, "b110".U -> 2.U)
      )
      val shift_eew          = elemShift(cmd.elemWidth.get)
      val shift_sew          = elemShift(sew)
      val shift_tile         = elemShift(tileEew)
      val dataElemBytesShift = Mux(isIndexed, shift_sew, Mux(isTile, shift_tile, shift_eew))

      // TODO(davidgao): Add checks for illegal LMUL values in the frontend.
      def lmulToDataEmul(lmul: UInt): UInt = {
        // Unit-stride, const-stride. Default value applies when eew == sew.
        val emul_data = MuxUpTo1H(
          lmul,
          Seq(
            // eew == 1/4 sew
            (eew === "b000".U && sew === "b010".U) -> (lmul - 2.U),
            // eew == 1/2 sew
            ((eew === "b000".U && sew === "b001".U) ||
              (eew === "b101".U && sew === "b010".U)) -> (lmul - 1.U),
            // eew == 2 sew
            ((eew === "b101".U && sew === "b000".U) ||
              (eew === "b110".U && sew === "b001".U)) -> (lmul + 1.U),
            // eew == 4 sew
            (eew === "b110".U && sew === "b000".U) -> (lmul + 2.U)
          )
        )
        MuxCase(
          lmul,
          Seq(
            // If mask operation, always make LMUL=1.
            isMask -> 0.U,
            // Section 7.9 of RVV Spec: "The nf field encodes how many vector
            // registers to load and store".
            isWholeReg -> MuxUpTo1H(
              0.U,
              Seq(
                (cmd.nfields.get === 0.U) -> 0.U, // NF1 -> LMUL1
                (cmd.nfields.get === 1.U) -> 1.U, // NF2 -> LMUL2
                (cmd.nfields.get === 3.U) -> 2.U, // NF4 -> LMUL4
                (cmd.nfields.get === 7.U) -> 3.U  // NF8 -> LMUL8
              )
            ),
            (LsuOp.isNonindexedVector(cmd.op) || isTile) -> emul_data
            // default: indexed vector and scalar
          )
        )
      }

      val vl_mask    = (vl_raw >> 3) + vl_raw.take(3).orR
      val vl_tile    = Mux(vl_raw < p.vmeTe.U, vl_raw, p.vmeTe.U)
      val wholeBytes = MuxUpTo1H(
        WireInit(UInt(result.vl.get.getWidth.W), DontCare),
        Seq(
          (cmd.nfields.get === 0.U) -> p.rvvVlenb.U,       // NF1 -> LMUL1
          (cmd.nfields.get === 1.U) -> (p.rvvVlenb * 2).U, // NF2 -> LMUL2
          (cmd.nfields.get === 3.U) -> (p.rvvVlenb * 4).U, // NF4 -> LMUL4
          (cmd.nfields.get === 7.U) -> (p.rvvVlenb * 8).U  // NF8 -> LMUL8
        )
      )

      result.elemWidth.get      := eew
      result.emul_data.get      := lmulToDataEmul(lmul_eff)
      result.emul_data_orig.get := lmulToDataEmul(lmul_orig)
      result.vl.get             := MuxUpTo1H(
        vl_raw,
        Seq(
          isMask     -> vl_mask,
          isWholeReg -> (wholeBytes >> shift_eew),
          isTile     -> vl_tile
        )
      )
      result.vstart.get := vstart

      // If mask operation or tile operation, force fields to zero
      result.nfields.get := Mux(isMask || isWholeReg || isTile, 0.U, cmd.nfields.get)
      result.sew.get     := sew

      // We only care about const stride here.
      // Ordered indexed is apparent on the op.
      result.strict.get := (
        isStrided &&
          cmd.rs2.get =/= 0.U &&
          sbus.data(i) === 0.U
      )
      result.masked.get        := isVector && !cmd.vm.get && !isTile
      result.initAsConstStride := isStrided || isIndexed

      val rawSegMult    = cmd.nfields.get +& 1.U
      val segMultiplier = Mux(isMask || isWholeReg || isTile, 1.U, rawSegMult)
      result.bytesPerSegment.foreach(_ := segMultiplier << dataElemBytesShift)

      // 1. Unreachable cell count:
      // Combine (segMultiplier << vectorsPerSegmentShift) * rvvVlenb into a single left shift.
      val emulEff            = result.emul_data.get
      val unreachShift       = Mux(emulEff(2), 0.U(2.W), emulEff(1, 0)) +& log2Ceil(p.rvvVlenb).U
      val vecUnreachableCell = (segMultiplier << unreachShift)(result.ctrWidth - 1, 0)

      // 2. Indexed active cell count:
      // For indexed ops, emul is always lmul_eff (2's complement signed log2(LMUL))
      // and segMultiplier is always rawSegMult. Computed directly from registered
      // rvvState.lmul and raw inst wires with a single shift, completely independent of cmd.op.
      val idxActiveShift  = (log2Ceil(p.rvvVlenb).S(5.W) + lmul_eff.asSInt).asUInt
      val activeCellCount = (rawSegMult << idxActiveShift)(result.ctrWidth - 1, 0)

      // 3. Start and End cell counts:
      // Multiplication by rawSegMult is ONLY needed for normal unit-stride/strided ops, where
      // vl is always vl_raw (from register) and shift is shift_eew (wire from inst).
      // By placing the multiplier directly on (vl_raw * rawSegMult) << shift_eew BEFORE muxing
      // special cases (mask/whole-reg/tile where segMultiplier == 1), the multiplier runs in
      // parallel with DispatchV2 decoding cmd.op.
      val normalStartCell =
        ((vstart * rawSegMult) << shift_eew).pad(result.ctrWidth)(result.ctrWidth - 1, 0)
      val normalEndCell =
        ((vl_raw * rawSegMult) << shift_eew).pad(result.ctrWidth)(result.ctrWidth - 1, 0)

      val vecStartCell = MuxCase(
        normalStartCell,
        Seq(
          (isMask || isWholeReg) -> (vstart << shift_eew)
            .pad(result.ctrWidth)(result.ctrWidth - 1, 0),
          isTile -> (vstart << shift_tile).pad(result.ctrWidth)(result.ctrWidth - 1, 0)
        )
      )
      val vecEndCell = MuxCase(
        normalEndCell,
        Seq(
          isMask     -> vl_mask.pad(result.ctrWidth),
          isWholeReg -> wholeBytes.pad(result.ctrWidth),
          isTile     -> (vl_tile << shift_tile).pad(result.ctrWidth)(result.ctrWidth - 1, 0)
        )
      )

      // Cell boundary indices:
      // - Unindexed vector loads (and tile ops) are bounded by vl/vstart.
      // - Indexed operations initialize all cells up to activeCellCount to W_DATA.
      // - RVV stores initialize all cells up to vecUnreachableCell to W_DATA.
      // - Scalar/float operations use scalarBytes.
      result.startCell.foreach(_ := Mux(isVector && !isIndexed && !isRvvStore, vecStartCell, 0.U))

      result.endCell.foreach(
        _ := MuxUpTo1H(
          scalarBytes,
          Seq(
            isIndexed                               -> activeCellCount,
            (isVector && !isIndexed && isRvvStore)  -> vecUnreachableCell,
            (isVector && !isIndexed && !isRvvStore) -> vecEndCell
          )
        )
      )

      result.unreachableCell := MuxUpTo1H(
        scalarBytes,
        Seq(
          isIndexed                -> activeCellCount,
          (isVector && !isIndexed) -> vecUnreachableCell
        )
      )
    } else {
      result.initAsConstStride := false.B
      result.unreachableCell   := scalarBytes
    }

    result
  }
}

class FlushCmd extends Bundle {
  val pcNext = UInt(32.W)
}

object FlushCmd {
  def apply(cmd: LsuCmd): FlushCmd = {
    val result = Wire(new FlushCmd)
    result.pcNext := cmd.pc + 4.U
    result
  }
}

object LsuCellState extends ChiselEnum {
  // TODO(davidgao): manually arrange the enum values?
  val DONE    = Value
  val W_DATA  = Value
  val W_START = Value
  val W_RESP  = Value
  val W_WB    = Value
}

object LsuScalarWritebackMode extends ChiselEnum {
  val NONE = Value
  val U1   = Value
  val S1   = Value
  val U2   = Value
  val S2   = Value
  val U4   = Value
  val F2   = Value
  // When we extend xlen to 64:
  // val S4   = Value
  // val U8   = Value
}

object LsuVectorElementWidth extends ChiselEnum {
  val E8  = Value
  val E16 = Value
  val E32 = Value
}

class LsuCell(p: Parameters) extends Bundle {
  val state   = LsuCellState()
  val data    = UInt(8.W)
  val rowAddr = UInt(p.dbusRowAddrBits.W)
  val mask    = UInt(p.lsuDataBytes.W)

  def addr: UInt = Cat(rowAddr, OHToUInt(mask))

  def canAcceptResp(respRowAddr: UInt): Bool = {
    rowAddr === respRowAddr && state.isOneOf(LsuCellState.W_START, LsuCellState.W_RESP)
  }

  def next(
    write: Bool,
    initData: ValidIO[UInt],
    vectorIndex: Option[ValidIO[UInt]],
    vectorData: Option[ValidIO[UInt]],
    vectorMask: Option[ValidIO[Bool]],
    start: Bool,
    respData: ValidIO[Vec[UInt]],
    wb: Bool
  ): LsuCell = {
    // Fundamentally we have these 5 mutually exclusive actions to do
    val doInvalidate = vectorMask
      .map { x =>
        x.valid && !x.bits
      }
      .getOrElse(false.B)
    val doData = vectorMask
      .map { x =>
        x.valid && x.bits
      }
      .getOrElse(false.B)
    // If we snoop a valid response when we start a transaction, we take the
    // response and ignore the start.
    val doStart = start && !respData.valid
    val doResp  = respData.valid && !wb
    val doWb    = wb

    val noConflict = VecInit(Seq(doInvalidate, doData, doStart, doResp, wb)).count(x => x) <= 1.U

    // Check for illegal transitions
    val noBadInvalidate = !doInvalidate || (state === LsuCellState.W_DATA)
    val noBadData       = !doData || (state === LsuCellState.W_DATA)
    val noBadStart      = !doStart || (state === LsuCellState.W_START)
    val noBadResp       = !doResp || state.isOneOf(LsuCellState.W_START, LsuCellState.W_RESP)
    val noBadWb = !doWb || state.isOneOf(LsuCellState.W_WB, LsuCellState.DONE) || (write && state
      .isOneOf(LsuCellState.W_START, LsuCellState.W_RESP))
    // Wb must not be skipped when reading
    val noBadSkipWb      = write || !respData.valid || !wb
    val noBadInit        = !initData.valid || (state === LsuCellState.DONE) || doWb
    val noBadTransitions =
      noBadInvalidate && noBadData && noBadStart && noBadResp && noBadWb && noBadSkipWb && noBadInit

    // Check for unused inputs
    val noUnusedIndex = vectorIndex.map(!_.valid || doData || doInvalidate).getOrElse(true.B)
    val noUnusedData  =
      vectorData.map(!_.valid || (write && (doData || doInvalidate))).getOrElse(true.B)
    val noUnusedMask  = vectorMask.map(!_.valid || doData || doInvalidate).getOrElse(true.B)
    val noUnusedInput = noUnusedIndex && noUnusedData && noUnusedMask

    // Check for missing data to write
    val noMissingData = vectorData.map(!write || !doData || _.valid).getOrElse(true.B)

    val precondition = noConflict && noBadTransitions && noUnusedInput && noMissingData
    assert(precondition)

    val withAddr = applyVectorIndex(vectorIndex)

    // Pre-combine early signals (uop scalar store init / vector store data / hold data)
    // and pre-gate the byte-lane mask with takeResp so late-arriving respData sees a
    // single flat one-hot reduction tree across all cells 0..nCells-1.
    val takeResp      = !write && doResp
    val holdOrVecData = Mux(
      initData.valid,
      initData.bits,
      Mux(write && doData, vectorData.map(_.bits).getOrElse(this.data), this.data)
    )
    val effMask = Mux(takeResp, mask, 0.U(p.lsuDataBytes.W))

    val ret = MakeWireBundle[LsuCell](
      new LsuCell(p),
      _       -> withAddr,
      _.state -> MuxUpTo1H(
        state,
        Seq(
          doInvalidate -> LsuCellState.W_WB,
          doData       -> LsuCellState.W_START,
          doStart      -> LsuCellState.W_RESP,
          doResp       -> LsuCellState.W_WB,
          doWb         -> LsuCellState.DONE
        )
      ),
      // Cell data can only come from:
      // 1. scalar store init
      // 2. load response
      // 3. vector/matrix data, unreachable if neither is set.
      _.data -> Mux1H(
        effMask.asBools :+ !takeResp,
        respData.bits :+ holdOrVecData
      )
    )

    Mux(precondition, ret, LsuCell.unreachable(p))
  }

  def setAddr(addr: UInt): LsuCell = {
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _         -> this,
      _.rowAddr -> addr(p.lsuAddrBits - 1, p.dbusOffsetBits),
      _.mask    -> UIntToOH(addr(p.dbusOffsetBits - 1, 0), p.lsuDataBytes)
    )
  }

  def applyVectorIndex(vectorIndex: Option[ValidIO[UInt]]): LsuCell = {
    vectorIndex
      .map { x =>
        Mux(x.valid, setAddr(addr + x.bits), this)
      }
      .getOrElse(this)
  }
}

object LsuCell {
  def apply(p: Parameters): LsuCell = {
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _.state   -> LsuCellState.DONE,
      _.data    -> 0.U,
      _.rowAddr -> 0.U,
      _.mask    -> 0.U
    )
  }

  def unreachable(p: Parameters): LsuCell = {
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _.state   -> DontCare,
      _.data    -> DontCare,
      _.rowAddr -> DontCare,
      _.mask    -> DontCare
    )
  }
}

class LsuSuperSlot(p: Parameters) extends Module {
  // Max amount of bytes that a single instruction can operate on.
  // Elements are ordered logically (addr strictly ascending when unit-stride).
  // With RVV this is 8 vecs (seg8 or m8 and similar combinations)
  val nCells                 = if (p.enableRvv) 8 * p.rvvVlenb else 4
  val indexWidth             = log2Ceil(nCells)
  val ctrWidth               = log2Ceil(nCells + 1)
  val maxConsecutiveRows     = (nCells + p.lsuDataBytes - 1) / p.lsuDataBytes + 1
  val windowSizeNormal       = math.min(nCells, p.lsuDataBytes)
  val windowSizeStrict       = math.min(windowSizeNormal, p.lsuStrictWindowBytes)
  val windowIndexWidthNormal = log2Ceil(windowSizeNormal)
  val windowIndexWidthStrict = log2Ceil(windowSizeStrict)

  // Simplified bus request interface before bookkeeping.
  class BusReq extends Bundle {
    val rowAddr   = UInt(p.dbusRowAddrBits.W)
    val offset    = UInt(p.dbusOffsetBits.W)
    val size      = UInt(p.dbusSize.W)
    val write     = Bool()
    val wdata     = UInt(p.lsuDataBits.W)
    val wmask     = UInt(p.lsuDataBytes.W)
    val cellIndex = Option.when(p.enableRvv)(UInt(ctrWidth.W))
  }

  class WritebackReq extends Bundle {
    val integer = Valid(UInt(32.W))
    val float   = Option.when(p.enableFloat) { Valid(UInt(32.W)) }
    val vector  = Option.when(p.enableRvv) { Valid(new Lsu2Rvv(p)) }
  }

  class State extends Bundle {
    val pc      = UInt(p.programCounterBits.W)
    val write   = Bool()
    val faulted = Bool()
    // TODO: move into vector
    val strictMode = Bool()

    // Used in all writebacks
    val rd = UInt(5.W)

    val skipWriteback       = Bool()
    val scalarWritebackMode = LsuScalarWritebackMode()

    // Bus transaction sizes precomputed at instruction initialization:
    // - For scalar ops: a cross-row access requires up to two bus transactions.
    //   `tx1Size` is the naturally-aligned power-of-2 size for the first transaction
    //   in row 1 (or the whole access if within a single row).
    //   `tx2Size` is the size for the second transaction in row 2 (starting at offset 0).
    // - For vector ops: all bus transactions are full row transfers of size `p.lsuDataBytes`.
    //   Both `tx1Size` and `tx2Size` are set to `p.lsuDataBytes.U`.
    // In `maybeStart()`, `cells(0).state === W_START` selects `tx1Size` for the first tx,
    // and `tx2Size` for any subsequent tx (scalar tx2 or vector rows).
    val tx1Size = UInt(p.dbusSize.W)
    val tx2Size = UInt(p.dbusSize.W)

    val float = Option.when(p.enableFloat)(new Bundle {
      val writeback = Bool()
    })

    val vector = Option.when(p.enableRvv)(new Bundle {
      val isVme                     = Option.when(p.enableVme)(Bool())
      val dataEew                   = LsuVectorElementWidth()
      val indexEew                  = LsuVectorElementWidth()
      val segmentStep               = UInt(3.W)
      val emulStep                  = UInt(indexWidth.W)
      val vectorsPerSegMinusOneOrig = UInt(3.W)
      val endCell                   = UInt(ctrWidth.W)
      val faultingCell              = UInt(ctrWidth.W)
      // Data phase
      val dataSubvector = new LoopingCounter(2.W)
      // Max offset of index vector per data vector.
      val dataSubvectorTheoretical = UInt(2.W)
      val dataSegment              = new LoopingCounter(3.W)
      val dataEmul                 = new LoopingCounter(3.W)
      val dataActiveCells          = Vec(p.rvvVlenb, UInt(indexWidth.W))
      // Writeback phase
      val writebackSegment     = new LoopingCounter(3.W)
      val writebackEmul        = new LoopingCounter(3.W)
      val writebackActiveCells = Valid(Vec(p.rvvVlenb, UInt(indexWidth.W)))
    })

    val cells     = Vec(nCells, new LsuCell(p))
    val leadIndex = UInt(indexWidth.W)
    val rowAddr   = UInt(p.dbusRowAddrBits.W)
    val isDone    = Bool()

    def leadWindow: Vec[LsuCell] = VectorWindow.mux4(
      cells,
      filler = LsuCell(p),
      index = leadIndex,
      windowSize = windowSizeNormal + 1
    )

    // returns: (tx, started, moveLeadOH)
    def maybeStart(): (ValidIO[BusReq], UInt, UInt) = {
      def canBundleFn(w: Vec[LsuCell]): UInt = {
        VecInit(w.map { x =>
          x.state === LsuCellState.W_START &&
          x.rowAddr === rowAddr
        }).asUInt
      }
      def cellCanStart: UInt = canBundleFn(cells) // TODO: if timing violation, retime this
      def cellCanStartWindowFn(size: Int): UInt = {
        VecInit
          .tabulate(size) { i =>
            val index = leadIndex + i.U
            Mux(index < nCells.U(ctrWidth.W), cellCanStart(index), false.B)
          }
          .asUInt
      }
      def reqValidFn(w: Vec[LsuCell]): Bool = {
        w(0).state === LsuCellState.W_START && (
          if (p.enableRvv) {
            // Wait for more (vector) data to arrive to achieve optimal
            // bundling. This does not reduce our latency, only improves
            // power by reducing bus transactions.
            w.drop(1).map(_.state =/= LsuCellState.W_DATA).reduce(_ && _)
          } else { true.B }
        )
      }

      // Returns: (reqValid, wData, wMask, started, moveLeadOH)
      def maybeStartNormal(window: Vec[LsuCell]): (Bool, UInt, UInt, UInt, UInt) = {
        val reqValid           = reqValidFn(window)
        val cellCanStartWindow = cellCanStartWindowFn(window.length)

        // bundle(i)(j) is whether window(i) is affected by byte(j)
        val bundle = VecInit.tabulate(window.length) { i =>
          Mux(cellCanStartWindow(i), window(i).mask, 0.U)
        }
        val wData = VecInit
          .tabulate(p.lsuDataBytes) { j =>
            val sel   = VecInit((0 until window.length).map { i => bundle(i)(j) }).asUInt
            val selOH = PriorityEncoderOH(sel)
            Mux1H(selOH, window.map(_.data))
          }
          .asUInt
        val wMask   = bundle.reduce(_ | _)
        val started = VecInit
          .tabulate(nCells) { i =>
            cellCanStart(i) &&
            // if we're reading, we can always snoop. This implies always reading
            // a full row.
            // if we're writing, we can only snoop on active bytes.
            (!write || (cells(i).mask & wMask) =/= 0.U)
          }
          .asUInt
        val stopConds = VecInit((0 until window.length).map { i =>
          window(i).state === LsuCellState.W_DATA || (
            window(i).state === LsuCellState.W_START &&
              (window(i).rowAddr =/= rowAddr || !reqValid)
          )
        })
        val stopOH = PriorityEncoderOH(Cat(1.B, stopConds.asUInt))

        (reqValid, wData, wMask, started, stopOH)
      }

      // Returns: (reqValid, wData, wMask, started, moveLeadOH)
      def maybeStartStrict(window: Vec[LsuCell]): (Bool, UInt, UInt, UInt, UInt) = {
        val reqValid           = reqValidFn(window)
        val cellCanStartWindow = cellCanStartWindowFn(window.length)

        val cellActive = Wire(Vec(window.length, Bool()))
        cellActive(0) := true.B
        // Priority mux, slow
        for (i <- 1 until window.length) {
          val prevMask = window.take(i).map(_.mask).reduce(_ | _)
          cellActive(i) :=
            cellActive(i - 1) &&
              cellCanStartWindow(i) &&
              !(prevMask & window(i).mask)
        }
        // bundle(i)(j) is whether window(i) is affected by byte(j)
        // We're protected by the valid signal so no need to check state
        val bundle = VecInit.tabulate(window.length) { i =>
          Mux(cellActive(i), window(i).mask, 0.U)
        }
        val wData = VecInit
          .tabulate(p.lsuDataBytes) { j =>
            // We've already checked for conflicts, so each row of j elements is upTo1H now.
            MuxUpTo1H(
              WireInit(UInt(8.W), DontCare),
              (0 until window.length).map { i =>
                bundle(i)(j) -> window(i).data
              }
            )
          }
          .asUInt
        val wMask   = bundle.reduce(_ | _)
        val started = VecInit
          .tabulate(nCells) { i =>
            i.U >= leadIndex &&
            i.U - leadIndex < windowSizeStrict.U &&
            cellActive((i.U - leadIndex)(windowIndexWidthStrict - 1, 0))
          }
          .asUInt
        val stopConds = VecInit((0 until windowSizeStrict).map { i =>
          window(i).state === LsuCellState.W_DATA || (
            window(i).state === LsuCellState.W_START &&
              (!cellActive(i) || !reqValid)
          )
        })
        val stopOH = PriorityEncoderOH(Cat(1.B, stopConds.asUInt))

        (reqValid, wData, wMask, started, stopOH)
      }

      val windowNormal = VecInit(leadWindow.take(windowSizeNormal))
      val windowStrict = VecInit(leadWindow.take(windowSizeStrict))

      val (
        reqValidNormal,
        wDataNormal,
        wMaskNormal,
        startedNormal,
        moveLeadOHNormal
      ) = maybeStartNormal(windowNormal)
      val (
        reqValidStrict,
        wDataStrict,
        wMaskStrict,
        startedStrict,
        moveLeadOHStrict
      ) = maybeStartStrict(windowStrict)

      val isFirstTx = cells(0).state === LsuCellState.W_START

      val txSize   = Mux(isFirstTx, tx1Size, tx2Size)
      val txOffset =
        Mux(isFirstTx, OHToUInt(cells(0).mask) & ~(tx1Size - 1.U), 0.U(p.dbusOffsetBits.W))

      val tx = MakeWireBundle[ValidIO[BusReq]](
        Valid(new BusReq),
        _.valid        -> Mux(strictMode, reqValidStrict, reqValidNormal),
        _.bits.rowAddr -> rowAddr,
        _.bits.offset  -> txOffset,
        _.bits.size    -> txSize,
        _.bits.write   -> write,
        // Write signals are junk when we're reading
        _.bits.wdata -> Mux(strictMode, wDataStrict, wDataNormal),
        _.bits.wmask -> Mux(strictMode, wMaskStrict, wMaskNormal)
      )
      tx.bits.cellIndex.foreach(_ := leadIndex)
      val started    = Mux(strictMode, startedStrict, startedNormal)
      val moveLeadOH = Mux(strictMode, moveLeadOHStrict.pad(windowSizeNormal + 1), moveLeadOHNormal)

      (tx, Mux(tx.valid, started, 0.U), moveLeadOH)
    }

    def maybeWriteback(): (WritebackReq, UInt) = {
      val scalar8       = cells(0).data
      val scalar16      = VecInit(cells.take(2).map(_.data)).asUInt
      val scalar32      = VecInit(cells.take(4).map(_.data)).asUInt
      val scalar8U      = WireInit(UInt(32.W), scalar8)
      val scalar8S      = WireInit(SInt(32.W), scalar8.asSInt).asUInt
      val scalar16U     = WireInit(UInt(32.W), scalar16)
      val scalar16S     = WireInit(SInt(32.W), scalar16.asSInt).asUInt
      val scalar8Valid  = cells(0).state === LsuCellState.W_WB
      val scalar16Valid = VecInit(cells.take(2)).forall(_.state === LsuCellState.W_WB)
      val scalar32Valid = VecInit(cells.take(4)).forall(_.state === LsuCellState.W_WB)

      val scalarReq = MuxLookup(scalarWritebackMode, MakeInvalid(UInt(32.W)))(
        Seq(
          LsuScalarWritebackMode.U1 -> MakeValid(scalar8Valid, scalar8U),
          LsuScalarWritebackMode.S1 -> MakeValid(scalar8Valid, scalar8S),
          LsuScalarWritebackMode.U2 -> MakeValid(scalar16Valid, scalar16U),
          LsuScalarWritebackMode.S2 -> MakeValid(scalar16Valid, scalar16S),
          LsuScalarWritebackMode.U4 -> MakeValid(scalar32Valid, scalar32),
          LsuScalarWritebackMode.F2 -> MakeValid(
            scalar16Valid,
            Cat("hFFFF".U(16.W), scalar16U(15, 0))
          )
        )
      )
      val scalarWritebacks = VecInit
        .tabulate(nCells) { i =>
          if (i < 4) {
            (scalarWritebackMode =/= LsuScalarWritebackMode.NONE) && (cells(
              i
            ).state === LsuCellState.W_WB)
          } else {
            false.B
          }
        }
        .asUInt

      val req = MakeWireBundle[WritebackReq](
        new WritebackReq,
        _.integer -> Mux(
          float.map(_.writeback).getOrElse(false.B),
          MakeInvalid(UInt(32.W)),
          scalarReq
        )
      )
      req.float.foreach { x =>
        x := Mux(float.get.writeback, scalarReq, MakeInvalid(UInt(32.W)))
      }
      val vectorWritebackValid = Option
        .when(p.enableRvv) {
          vector.get.writebackActiveCells.valid &&
          vector.get.writebackActiveCells.bits
            .map { x =>
              // TODO: subvector mask
              cells(x).state === LsuCellState.DONE ||
              cells(x).state === LsuCellState.W_WB
            }
            .reduce(_ && _)
        }
        .getOrElse(false.B)
      val vectorWritebacks = Option.when(p.enableRvv) {
        val mask = VecInit(vector.get.writebackActiveCells.bits.map(UIntToOH(_)))
        VecInit
          .tabulate(nCells) { i =>
            // TODO: subvector mask
            VecInit(mask.map(_(i))).reduce(_ || _)
          }
          .asUInt
      }
      req.vector.foreach { x =>
        val vectorWbData = VecInit
          .tabulate(p.rvvVlenb) { i =>
            cells(vector.get.writebackActiveCells.bits(i)).data
          }
          .asUInt
        val validLimit  = Mux(faulted, vector.get.faultingCell, vector.get.endCell)
        val ffTailIndex = PopCount(VecInit.tabulate(p.rvvVlenb) { i =>
          vector.get.writebackActiveCells.bits(i) < validLimit
        })
        x := MakeWireBundle[ValidIO[Lsu2Rvv]](
          Valid(new Lsu2Rvv(p)),
          _.valid -> vectorWritebackValid,
          // TODO: materialize this counter if needed for timing
          _.bits.addr -> (rd + vector.get.writebackSegment.curr * (vector.get.vectorsPerSegMinusOneOrig +& 1.U) + vector.get.writebackEmul.curr),
          _.bits.data -> vectorWbData,
          // This means last writeback of this vreg.
          // TODO: subvector
          _.bits.last          -> write,
          _.bits.ff_tail_index -> ffTailIndex
        )
      }
      // TODO: mutual exclusion assert
      val writebacks = MuxUpTo1H(
        0.U,
        Seq(
          (scalarWritebackMode =/= LsuScalarWritebackMode.NONE)       -> scalarWritebacks,
          vector.map(_.writebackActiveCells.valid).getOrElse(false.B) -> vectorWritebacks.getOrElse(
            0.U
          )
        )
      )

      (req, writebacks)
    }

    def act(
      initCellsData: Vec[ValidIO[UInt]],
      starts: UInt,
      moveLeadOH: UInt,
      resp: Bool,
      fault: Bool,
      respRowAddr: UInt,
      respData: Vec[UInt],
      respMask: UInt,
      writebacks: UInt,
      vectorData: Option[ValidIO[Rvv2Lsu]],
      vmeData: Option[ValidIO[Vme2Lsu]]
    ): State = {
      val isVmeInst       = vector.map(_.isVme.getOrElse(false.B)).getOrElse(false.B)
      val vectorDataBytes = Option.when(p.enableRvv) {
        val rvvBytes = VecInit.tabulate(p.rvvVlenb) { i =>
          vectorData.get.bits.vregfile.bits.data(i * 8 + 7, i * 8)
        }
        val vmeBytes = vmeData
          .map { v =>
            VecInit.tabulate(p.rvvVlenb) { i =>
              v.bits.data(i * 8 + 7, i * 8)
            }
          }
          .getOrElse(rvvBytes)
        Mux(isVmeInst, vmeBytes, rvvBytes)
      }
      val vectorDataValid = Option.when(p.enableRvv) {
        val vmeValid = vmeData.map(_.valid).getOrElse(false.B)
        Mux(isVmeInst, vmeValid, vectorData.get.valid)
      }
      val vectorDataPayloadValid = Option.when(p.enableRvv) {
        val vmeValid = vmeData.map(_.valid).getOrElse(false.B)
        Mux(isVmeInst, vmeValid, vectorData.get.valid && vectorData.get.bits.vregfile.valid)
      }
      val vectorMaskValid = Option.when(p.enableRvv) {
        val vmeValid = vmeData.map(_.valid).getOrElse(false.B)
        Mux(isVmeInst, vmeValid, vectorData.get.valid && vectorData.get.bits.mask.valid)
      }
      val enableLane = Option.when(p.enableRvv) {
        MuxLookup(
          Cat(vector.get.dataSubvector.curr, vector.get.dataSubvectorTheoretical),
          ~0.U(p.rvvVlenb.W) // All enabled by default
        )(
          Seq(
            "b00_01".U -> Cat(0.U((p.rvvVlenb / 2).W), ~0.U((p.rvvVlenb / 2).W)),     // 1 of 2
            "b01_01".U -> Cat(~0.U((p.rvvVlenb / 2).W), 0.U((p.rvvVlenb / 2).W)),     // 2 of 2
            "b00_11".U -> Cat(0.U((p.rvvVlenb * 3 / 4).W), ~0.U((p.rvvVlenb / 4).W)), // 1 of 4
            "b01_11".U -> Cat(
              0.U((p.rvvVlenb / 2).W),
              ~0.U((p.rvvVlenb / 4).W),
              0.U((p.rvvVlenb / 4).W)
            ), // 2 of 4
            "b10_11".U -> Cat(
              0.U((p.rvvVlenb / 4).W),
              ~0.U((p.rvvVlenb / 4).W),
              0.U((p.rvvVlenb / 2).W)
            ), // 3 of 4
            "b11_11".U -> Cat(~0.U((p.rvvVlenb / 4).W), 0.U((p.rvvVlenb * 3 / 4).W)) // 4 of 4
          )
        )
      }
      val vectorDataActive = Option.when(p.enableRvv) {
        VecInit.tabulate(p.rvvVlenb) { i =>
          Mux(enableLane.get(i), UIntToOH(vector.get.dataActiveCells(i)), 0.U)
        }
      }
      val vectorIndices = Option.when(p.enableRvv) {
        val allIndices                                   = vectorData.get.bits.idx.bits.data
        def getIndexSlice(indexEew: Int, idx: Int): UInt = indexEew match {
          case 8  => Cat(0.U(24.W), allIndices(idx * 8 + 7, idx * 8))
          case 16 => Cat(0.U(16.W), allIndices(idx * 16 + 15, idx * 16))
          case 32 => allIndices(idx * 32 + 31, idx * 32)
        }

        val idxEew = vector.get.indexEew
        val datEew = vector.get.dataEew
        val emul   = vector.get.dataEmul.curr(1, 0)

        val is_e8  = datEew === LsuVectorElementWidth.E8
        val is_e16 = datEew === LsuVectorElementWidth.E16
        val is_e32 = datEew === LsuVectorElementWidth.E32

        val is_ei8  = idxEew === LsuVectorElementWidth.E8
        val is_ei16 = idxEew === LsuVectorElementWidth.E16
        val is_ei32 = idxEew === LsuVectorElementWidth.E32

        val sel_e8_ei8  = is_e8 && is_ei8
        val sel_e8_ei16 = is_e8 && is_ei16
        val sel_e8_ei32 = is_e8 && is_ei32

        val sel_e16_ei8_0 = is_e16 && is_ei8 && !emul(0)
        val sel_e16_ei8_1 = is_e16 && is_ei8 && emul(0)
        val sel_e16_ei16  = is_e16 && is_ei16
        val sel_e16_ei32  = is_e16 && is_ei32

        val sel_e32_ei8_0  = is_e32 && is_ei8 && emul === 0.U
        val sel_e32_ei8_1  = is_e32 && is_ei8 && emul === 1.U
        val sel_e32_ei8_2  = is_e32 && is_ei8 && emul === 2.U
        val sel_e32_ei8_3  = is_e32 && is_ei8 && emul === 3.U
        val sel_e32_ei16_0 = is_e32 && is_ei16 && !emul(0)
        val sel_e32_ei16_1 = is_e32 && is_ei16 && emul(0)
        val sel_e32_ei32   = is_e32 && is_ei32

        VecInit.tabulate(p.rvvVlenb) { i =>
          val rawMappings: Seq[(Bool, (Int, Int))] = Seq(
            // Data EEW 8 (e8)
            sel_e8_ei8  -> (8, i),
            sel_e8_ei16 -> (16, i % (p.rvvVlenb / 2)),
            sel_e8_ei32 -> (32, i % (p.rvvVlenb / 4)),
            // Data EEW 16 (e16)
            sel_e16_ei8_0 -> (8, i / 2),
            sel_e16_ei8_1 -> (8, (p.rvvVlenb / 2) + i / 2),
            sel_e16_ei16  -> (16, i / 2),
            sel_e16_ei32  -> (32, (i / 2) % (p.rvvVlenb / 4)),
            // Data EEW 32 (e32)
            sel_e32_ei8_0  -> (8, i / 4),
            sel_e32_ei8_1  -> (8, (p.rvvVlenb / 4) + i / 4),
            sel_e32_ei8_2  -> (8, (p.rvvVlenb / 2) + i / 4),
            sel_e32_ei8_3  -> (8, (p.rvvVlenb * 3 / 4) + i / 4),
            sel_e32_ei16_0 -> (16, i / 4),
            sel_e32_ei16_1 -> (16, (p.rvvVlenb / 4) + i / 4),
            sel_e32_ei32   -> (32, i / 4)
          )
          val merged = rawMappings
            .groupBy(_._2)
            .toSeq
            .sortBy(_._1)
            .map { case ((eiWidth, idx), group) =>
              group.map(_._1).reduce(_ || _) -> getIndexSlice(eiWidth, idx)
            }
          MuxUpTo1H(WireInit(UInt(32.W), DontCare), merged)
        }
      }

      // If we're in strict mode, or we're writing, there's no snooping.
      // In strict mode respMask only includes what's bundled in the tx,
      // but in non-strict writing, respMask also includes skippable cells.
      val cellAcceptResp = VecInit
        .tabulate(nCells) { i =>
          resp && Mux(
            strictMode || write,
            respMask(i),
            cells(i).canAcceptResp(respRowAddr)
          )
        }
        .asUInt
      val cellWriteback     = Mux(skipWriteback, cellAcceptResp, writebacks)
      val cellVectorIndices = Option.when(p.enableRvv) {
        VecInit.tabulate(nCells) { i =>
          MuxUpTo1H(
            MakeInvalid(UInt(32.W)),
            (0 until p.rvvVlenb).map { j =>
              (
                vectorData.get.valid &&
                  vectorData.get.bits.idx.valid &&
                  vectorDataActive.get(j)(i) &&
                  cells(i).state === LsuCellState.W_DATA
              ) -> MakeValid(vectorIndices.get(j))
            }
          )
        }
      }

      val cellsNext = VecInit.tabulate(nCells) { i =>
        val acceptVectorData = Option.when(p.enableRvv) {
          vectorDataValid.get &&
          vectorDataActive.get.map(_(i)).reduce(_ || _) &&
          cells(i).state === LsuCellState.W_DATA
        }

        val cellVectorIndex = cellVectorIndices.map(_(i))
        if (p.enableRvv) {
          assert(
            !acceptVectorData.get ||
              !write ||
              isVmeInst ||
              vectorData.get.bits.vregfile.valid
          )
        }
        val cellVectorData = Option.when(p.enableRvv) {
          MuxUpTo1H(
            MakeInvalid(UInt(8.W)),
            (0 until p.rvvVlenb).map { j =>
              (
                vectorDataPayloadValid.get &&
                  vectorDataActive.get(j)(i) &&
                  cells(i).state === LsuCellState.W_DATA
              ) -> MakeValid(vectorDataBytes.get(j))
            }
          )
        }
        if (p.enableRvv) {
          assert(
            !acceptVectorData.get ||
              isVmeInst ||
              vectorData.get.bits.mask.valid
          )
        }
        val cellVectorMask = Option.when(p.enableRvv) {
          MuxUpTo1H(
            MakeInvalid(Bool()),
            (0 until p.rvvVlenb).map { j =>
              (
                vectorMaskValid.get &&
                  vectorDataActive.get(j)(i) &&
                  cells(i).state === LsuCellState.W_DATA
              ) -> MakeValid(
                Mux(
                  isVmeInst,
                  true.B,
                  vectorData.get.bits.mask.bits(j)
                )
              )
            }
          )
        }
        cells(i).next(
          initData = initCellsData(i),
          write = write,
          vectorIndex = cellVectorIndex,
          vectorData = cellVectorData,
          vectorMask = cellVectorMask,
          start = starts(i),
          respData = MakeValid(cellAcceptResp(i), respData),
          wb = cellWriteback(i)
        )
      }
      val allCellsDone = VecInit
        .tabulate(nCells) { i =>
          cells(i).state === LsuCellState.DONE ||
          cellWriteback(i)
          // We don't need to worry about invalidate because it doesn't skip WB.
        }
        .reduce(_ && _)

      val nextRowAddrCandidates = VecInit.tabulate(windowSizeNormal + 1) { i =>
        val idx         = leadIndex +& i.U
        val vectorIndex = Option.when(p.enableRvv) {
          MuxUpTo1H(
            MakeInvalid(UInt(32.W)),
            (0 until p.rvvVlenb).map { j =>
              (
                vectorData.get.valid &&
                  vectorData.get.bits.idx.valid &&
                  (idx < nCells.U(ctrWidth.W)) &&
                  enableLane.get(j) &&
                  (vector.get.dataActiveCells(j) === idx(indexWidth - 1, 0)) &&
                  (leadWindow(i).state === LsuCellState.W_DATA)
              ) -> MakeValid(vectorIndices.get(j))
            }
          )
        }
        val candidate = leadWindow(i).applyVectorIndex(vectorIndex).rowAddr
        when(idx < nCells.U(ctrWidth.W)) {
          assert(candidate === cellsNext(idx(indexWidth - 1, 0)).rowAddr)
        }
        candidate
      }

      val moveLead = OHToUInt(moveLeadOH).pad(ctrWidth)
      val ret      = MakeWireBundle[State](
        new State(),
        _           -> this,
        _.faulted   -> (faulted || fault),
        _.cells     -> cellsNext,
        _.leadIndex -> (leadIndex + moveLead),
        _.rowAddr   -> Mux1H(moveLeadOH, nextRowAddrCandidates),
        _.isDone    -> allCellsDone
      )
      ret.vector.foreach { x =>
        val curr = vector.get
        x.endCell       := curr.endCell
        x.faultingCell  := Mux(fault && !faulted, busRespCellIndex.get, curr.faultingCell)
        x.dataSubvector := Mux(
          vectorDataValid.get,
          curr.dataSubvector.next(),
          curr.dataSubvector
        )
        val nextDataSegment = vectorDataValid.get && curr.dataSubvector.isFull()
        val nextDataEmul    = nextDataSegment && curr.dataSegment.isFull()
        x.dataSegment := Mux(
          nextDataSegment,
          curr.dataSegment.next(),
          curr.dataSegment
        )
        // This is the number, not lmul/emul encoding
        x.dataEmul := Mux(
          nextDataEmul,
          curr.dataEmul.next(),
          curr.dataEmul
        )
        x.dataActiveCells := VecInit(curr.dataActiveCells.map { y =>
          MuxCase(
            y,
            Seq(
              nextDataEmul    -> (y + curr.emulStep),
              nextDataSegment -> (y + curr.segmentStep)
            )
          )
        })
        val nextWriteback     = curr.writebackActiveCells.valid && writebacks.orR
        val nextWritebackEmul = nextWriteback && curr.writebackSegment.isFull()
        val writebackDone     = nextWritebackEmul && curr.writebackEmul.isFull()
        x.writebackSegment := Mux(
          nextWriteback,
          curr.writebackSegment.next(),
          curr.writebackSegment
        )
        x.writebackEmul := Mux(
          nextWritebackEmul,
          curr.writebackEmul.next(),
          curr.writebackEmul
        )
        x.writebackActiveCells.valid := curr.writebackActiveCells.valid && !writebackDone
        x.writebackActiveCells.bits  := VecInit(curr.writebackActiveCells.bits.map { x =>
          MuxCase(
            x,
            Seq(
              nextWritebackEmul -> (x + curr.emulStep),
              nextWriteback     -> (x + curr.segmentStep)
            )
          )
        })
      }

      ret
    }

    def computeScalarTxPlan(offset: UInt, bytes: Int): (UInt, UInt) = {
      if (bytes == 1) {
        (1.U, 1.U)
      } else {
        val isCrossRow  = offset > (p.lsuDataBytes - bytes).U
        val bytesInRow1 = p.lsuDataBytes.U - offset
        val bytesInRow2 = bytes.U - bytesInRow1

        // Cross-row accesses boundary-align: Tx1 ends at row-end, Tx2 starts at row-start.
        val tx1SizeCross = Mux(bytesInRow1 === 3.U, 4.U, bytesInRow1)
        val tx2SizeCross = Mux(bytesInRow2 === 3.U, 4.U, bytesInRow2)

        val tx1SizeSameRow = if (bytes == 2) {
          2.U << PriorityEncoder(~offset)
        } else { // bytes == 4
          Mux(
            offset(1, 0) === 0.U,
            4.U,
            8.U << PriorityEncoder(~offset(p.dbusOffsetBits - 1, 2))
          )
        }

        val tx1Size = Mux(isCrossRow, tx1SizeCross, tx1SizeSameRow)
        val tx2Size = tx2SizeCross

        (tx1Size, tx2Size)
      }
    }

    def fromUop(uop: LsuUOp): State = {
      val isTile    = if (p.enableVme) LsuOp.isTile(uop.op) else false.B
      val isVector  = if (p.enableRvv) LsuOp.isVector(uop.op) || isTile else false.B
      val isIndexed = if (p.enableRvv) LsuOp.isIndexedVector(uop.op) else false.B
      val isFloat   = if (p.enableFloat) uop.op.isOneOf(LsuOp.FLOAT, LsuOp.FLOAT_H) else false.B
      val isScalar  = !isVector && !isFloat
      val isOrderedIndexed =
        if (p.enableRvv) uop.op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VSTORE_OINDEXED) else false.B

      // 1. Cell State Array (cellsInitState)
      val inactiveState = MuxCase(
        LsuCellState.W_WB,
        Option
          .when(p.enableVme)(
            // RVV stores never have inactive cells because all cells in active registers
            // must perform handshakes with the vector core (endCell = vecUnreachableCell).
            // Therefore, an inactive store cell can only ever occur for tile stores (VTSTORE),
            // which have no register writeback and complete immediately as DONE.
            (isTile && uop.store) -> LsuCellState.DONE
          )
          .toSeq ++ Seq(
          // Masked vector loads must see mask to determine if elements are active.
          (isVector && uop.masked.getOrElse(false.B)) -> LsuCellState.W_DATA
        )
      )

      val activeState = Mux(
        uop.store,
        Mux(isVector, LsuCellState.W_DATA, LsuCellState.W_START),
        Mux(
          isVector && (isIndexed || uop.masked.getOrElse(false.B)),
          LsuCellState.W_DATA,
          LsuCellState.W_START
        )
      )

      val (cellsInitState, cellIsActive) = {
        val pairs = (0 until nCells).map { i =>
          val isUnreachable = i.U >= uop.unreachableCell
          val isPreStart    = uop.startCell.map(i.U < _).getOrElse(false.B)
          val isTail        = !isUnreachable && uop.endCell.map(i.U >= _).getOrElse(false.B)

          val state = MuxUpTo1H(
            activeState,
            Seq(
              isUnreachable -> LsuCellState.DONE,
              isPreStart    -> inactiveState,
              isTail        -> inactiveState
            )
          )
          val isActive = !isUnreachable && !isPreStart && !isTail
          (state, isActive)
        }
        (VecInit(pairs.map(_._1)), VecInit(pairs.map(_._2)))
      }

      // 2. Cell Address Path
      // Mode A: Continuous (Scalar and Unit-Stride base incrementer)
      val baseRowAddr = uop.addr(p.lsuAddrBits - 1, p.dbusOffsetBits)
      val baseOffset  = uop.addr(p.dbusOffsetBits - 1, 0)
      val rowTable    = VecInit.tabulate(maxConsecutiveRows) { k =>
        (baseRowAddr + k.U)(p.dbusRowAddrBits - 1, 0)
      }

      val byteSum  = VecInit.tabulate(nCells) { i => baseOffset +& i.U }
      val rowDelta = VecInit.tabulate(nCells) { i =>
        (byteSum(i) >> p.dbusOffsetBits).asUInt.pad(log2Ceil(maxConsecutiveRows))
      }
      val byteInRow         = VecInit.tabulate(nCells) { i => byteSum(i)(p.dbusOffsetBits - 1, 0) }
      val continuousRowAddr = VecInit.tabulate(nCells) { i => rowTable(rowDelta(i)) }
      val continuousMask = VecInit.tabulate(nCells) { i => UIntToOH(byteInRow(i), p.lsuDataBytes) }

      // Mode B: Strided / Indexed (Unified 16-entry lookup, RVV only)
      val (cellRowAddr, cellMask) = if (p.enableRvv) {
        val effStride         = Mux(isIndexed, 0.U(32.W), uop.data)
        val uniqueStructSizes = Seq(1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32)
        val stridedOffsets    = MuxLookup(
          uop.bytesPerSegment.get,
          VecInit.fill(nCells)(0.U(32.W))
        )(
          uniqueStructSizes.map { size =>
            size.U -> State.makeStridedOffsets(size, effStride)
          }
        )
        val stridedAddr    = VecInit.tabulate(nCells) { i => uop.addr + stridedOffsets(i) }
        val stridedRowAddr = VecInit.tabulate(nCells) { i =>
          stridedAddr(i)(p.lsuAddrBits - 1, p.dbusOffsetBits)
        }
        val stridedMask = VecInit.tabulate(nCells) { i =>
          UIntToOH(stridedAddr(i)(p.dbusOffsetBits - 1, 0), p.lsuDataBytes)
        }

        val rowAddr = VecInit.tabulate(nCells) { i =>
          Mux(uop.initAsConstStride, stridedRowAddr(i), continuousRowAddr(i))
        }
        val mask = VecInit.tabulate(nCells) { i =>
          Mux(uop.initAsConstStride, stridedMask(i), continuousMask(i))
        }
        (rowAddr, mask)
      } else {
        (continuousRowAddr, continuousMask)
      }

      // 3. Assemble cells
      val isScalarStore = (isScalar || isFloat) && uop.store
      val cellsFromUop  = VecInit.tabulate(nCells) { i =>
        val isActive = cellIsActive(i)
        val cellData = if (i < 4) {
          Mux(isActive && isScalarStore, uop.data(i * 8 + 7, i * 8), cells(i).data)
        } else {
          cells(i).data
        }

        MakeWireBundle[LsuCell](
          new LsuCell(p),
          _.state   -> cellsInitState(i),
          _.rowAddr -> Mux(isActive, cellRowAddr(i), cells(i).rowAddr),
          _.mask    -> Mux(isActive, cellMask(i), cells(i).mask),
          _.data    -> cellData
        )
      }

      // 5. Scalar Writeback Mode
      val scalarWbMode = MuxLookup(uop.op, LsuScalarWritebackMode.NONE)(
        Seq(
          LsuOp.LB      -> LsuScalarWritebackMode.S1,
          LsuOp.LBU     -> LsuScalarWritebackMode.U1,
          LsuOp.LH      -> LsuScalarWritebackMode.S2,
          LsuOp.LHU     -> LsuScalarWritebackMode.U2,
          LsuOp.LW      -> LsuScalarWritebackMode.U4,
          LsuOp.FLOAT   -> Mux(uop.store, LsuScalarWritebackMode.NONE, LsuScalarWritebackMode.U4),
          LsuOp.FLOAT_H -> Mux(uop.store, LsuScalarWritebackMode.NONE, LsuScalarWritebackMode.F2)
        )
      )

      // 6. Bus Transaction Plan (tx1Size, tx2Size)
      val (tx1_2, tx2_2) = computeScalarTxPlan(baseOffset, 2)
      val (tx1_4, tx2_4) = computeScalarTxPlan(baseOffset, 4)
      val is1Byte        = uop.op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB)
      val is2Byte        = uop.op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH, LsuOp.FLOAT_H)
      val is4Byte        = uop.op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT)
      val tx1Size        = MuxUpTo1H(
        p.lsuDataBytes.U,
        Seq(
          is1Byte -> 1.U,
          is2Byte -> tx1_2,
          is4Byte -> tx1_4
        )
      )
      val tx2Size = MuxUpTo1H(
        p.lsuDataBytes.U,
        Seq(
          is1Byte -> 1.U,
          is2Byte -> tx2_2,
          is4Byte -> tx2_4
        )
      )

      val ret = MakeWireBundle[State](
        new State(),
        _               -> this,
        _.pc            -> uop.pc,
        _.write         -> uop.store,
        _.faulted       -> false.B,
        _.strictMode    -> (isOrderedIndexed || uop.strict.getOrElse(false.B)),
        _.rd            -> uop.rd,
        _.skipWriteback -> (uop.store && (isScalar || isFloat || (if (p.enableVme) isTile
                                                                  else false.B))),
        _.scalarWritebackMode -> scalarWbMode,
        _.tx1Size             -> tx1Size,
        _.tx2Size             -> tx2Size,
        _.cells               -> cellsFromUop,
        _.leadIndex           -> 0.U,
        _.rowAddr             -> baseRowAddr,
        _.isDone              -> false.B
      )

      ret.float.foreach { x =>
        x.writeback := isFloat && !uop.store
      }

      ret.vector.foreach { x =>
        val nfields             = Mux(isTile, 0.U, uop.nfields.getOrElse(0.U))
        val maxVectorPerSegment = uop.emul_data
          .map { emul =>
            Mux(emul(2), 0.U(3.W), ((1.U << emul(1, 0)) - 1.U)(2, 0))
          }
          .getOrElse(0.U)
        val maxVectorPerSegmentOrig = uop.emul_data_orig
          .map { emul =>
            Mux(emul(2), 0.U(3.W), ((1.U << emul(1, 0)) - 1.U)(2, 0))
          }
          .getOrElse(0.U)

        val elemWidth = uop.elemWidth.getOrElse(0.U)

        val elemWidthEnum = MuxLookup(elemWidth, WireInit(LsuVectorElementWidth(), DontCare))(
          Seq(
            "b000".U -> LsuVectorElementWidth.E8,
            "b101".U -> LsuVectorElementWidth.E16,
            "b110".U -> LsuVectorElementWidth.E32
          )
        )
        val indexedElemWidthEnum =
          MuxLookup(uop.sew.getOrElse(0.U), WireInit(LsuVectorElementWidth(), DontCare))(
            Seq(
              "b000".U -> LsuVectorElementWidth.E8,
              "b001".U -> LsuVectorElementWidth.E16,
              "b010".U -> LsuVectorElementWidth.E32
            )
          )

        val subvectors = uop.emul_data
          .map { x =>
            MuxLookup(Cat(uop.sew.getOrElse(0.U), elemWidth, x), 0.U(3.W))(
              Seq(
                // e8ei16
                "b000_101_000".U -> 1.U(2.W),
                "b000_101_001".U -> 1.U(2.W),
                "b000_101_010".U -> 1.U(2.W),
                // e16ei32
                "b001_110_000".U -> 1.U(2.W),
                "b001_110_001".U -> 1.U(2.W),
                "b001_110_010".U -> 1.U(2.W),
                // e8ei32
                "b000_110_111".U -> 1.U(2.W),
                "b000_110_000".U -> 3.U(2.W),
                "b000_110_001".U -> 3.U(2.W)
              )
            )
          }
          .getOrElse(0.U)
        val subvectorsTheoretical = uop.emul_data
          .map { x =>
            MuxLookup(Cat(uop.sew.getOrElse(0.U), elemWidth), 0.U(3.W))(
              Seq(
                // e8ei16
                "b000_101".U -> 1.U(2.W),
                // e16ei32
                "b001_110".U -> 1.U(2.W),
                // e8ei32
                "b000_110".U -> 3.U(2.W)
              )
            )
          }
          .getOrElse(0.U)

        val dataElemBytesShift = Mux(
          isIndexed,
          MuxLookup(uop.sew.getOrElse(0.U), 0.U(2.W))(
            Seq(
              "b000".U -> 0.U,
              "b001".U -> 1.U,
              "b010".U -> 2.U
            )
          ),
          MuxLookup(elemWidth, 0.U(2.W))(
            Seq(
              "b000".U -> 0.U,
              "b101".U -> 1.U,
              "b110".U -> 2.U
            )
          )
        )

        x.isVme.foreach(_ := isTile)
        x.dataEew  := Mux(isIndexed, indexedElemWidthEnum, elemWidthEnum)
        x.indexEew := Mux(isIndexed, elemWidthEnum, LsuVectorElementWidth.E8)

        x.segmentStep := Mux(isVector, 1.U << dataElemBytesShift, 0.U)
        x.emulStep    := Mux(
          isVector,
          MuxLookup(dataElemBytesShift, 0.U(indexWidth.W))(
            Seq(
              0.U -> (nfields * (p.rvvVlenb - 1).U + p.rvvVlenb.U),
              1.U -> (nfields * (p.rvvVlenb - 2).U + p.rvvVlenb.U),
              2.U -> (nfields * (p.rvvVlenb - 4).U + p.rvvVlenb.U)
            )
          ),
          0.U
        )
        x.vectorsPerSegMinusOneOrig := Mux(isVector, maxVectorPerSegmentOrig, 0.U)
        x.endCell                   := Mux(isVector, uop.endCell.getOrElse(0.U), 0.U)
        x.faultingCell              := nCells.U
        x.dataSubvector             := LoopingCounter(Mux(isIndexed, subvectors, 0.U))
        x.dataSubvectorTheoretical  := Mux(isIndexed, subvectorsTheoretical, 0.U)
        x.dataSegment               := LoopingCounter(Mux(isVector, nfields, 0.U))
        x.dataEmul                  := LoopingCounter(Mux(isVector, maxVectorPerSegment, 0.U))

        val startingActiveCells = State.makeVectorStartingActiveCells(
          nfields = nfields,
          dataElemBytesShift = dataElemBytesShift
        )
        x.dataActiveCells      := startingActiveCells
        x.writebackSegment     := LoopingCounter(Mux(isVector, nfields, 0.U))
        x.writebackEmul        := LoopingCounter(Mux(isVector, maxVectorPerSegment, 0.U))
        x.writebackActiveCells := MakeValid(
          isVector && (!uop.store || !isTile),
          startingActiveCells
        )
      }

      ret
    }
  }

  object State {
    def makeStridedOffsets(
      structSize: Int, // Up to 32
      stride: UInt
    ): Vec[UInt] = {
      VecInit.tabulate(nCells) { i =>
        ((i / structSize).U(indexWidth.W) * stride)(31, 0) + (i % structSize).U
      }
    }

    def makeVectorStartingActiveCells(
      nfields: UInt,
      dataElemBytesShift: UInt
    ): Vec[UInt] = {
      val retE8 = VecInit.tabulate(p.rvvVlenb) { i =>
        i.U * nfields + i.U
      }
      val retE16 = VecInit.tabulate(p.rvvVlenb) { i =>
        Cat((i / 2).U * nfields + (i / 2).U, (i % 2).U(1.W))
      }
      val retE32 = VecInit.tabulate(p.rvvVlenb) { i =>
        Cat((i / 4).U * nfields + (i / 4).U, (i % 4).U(2.W))
      }

      MuxLookup(dataElemBytesShift, retE8)(
        Seq(
          0.U -> retE8,
          1.U -> retE16,
          2.U -> retE32
        )
      )
    }

    def apply(): State = {
      val ret = MakeWireBundle[State](
        new State,
        _.pc                  -> 0.U,
        _.write               -> false.B,
        _.faulted             -> false.B,
        _.strictMode          -> false.B,
        _.rd                  -> 0.U,
        _.skipWriteback       -> false.B,
        _.scalarWritebackMode -> LsuScalarWritebackMode.NONE,
        _.tx1Size             -> 0.U,
        _.tx2Size             -> 0.U,
        _.cells               -> VecInit.fill(nCells)(LsuCell(p)),
        _.leadIndex           -> 0.U,
        _.rowAddr             -> 0.U,
        _.isDone              -> true.B
      )
      ret.float.foreach { x =>
        x.writeback := false.B
      }
      ret.vector.foreach { x =>
        x.isVme.foreach(_ := false.B)
        x.dataEew                   := LsuVectorElementWidth.E8
        x.indexEew                  := LsuVectorElementWidth.E8
        x.segmentStep               := 0.U
        x.emulStep                  := 0.U
        x.vectorsPerSegMinusOneOrig := 0.U
        x.endCell                   := 0.U
        x.faultingCell              := nCells.U
        x.dataSubvector             := LoopingCounter(0.U)
        x.dataSubvectorTheoretical  := 0.U
        x.dataSegment               := LoopingCounter(0.U)
        x.dataEmul                  := LoopingCounter(0.U)
        // This is not used, just to make sure there are no conflicts.
        x.dataActiveCells  := VecInit.tabulate(p.rvvVlenb)(_.U)
        x.writebackSegment := LoopingCounter(0.U)
        x.writebackEmul    := LoopingCounter(0.U)
        // This is not used in MuxUpTo1H.
        x.writebackActiveCells := MakeInvalid(Vec(p.rvvVlenb, UInt(indexWidth.W)))
      }

      ret
    }
  }

  val io = IO(new Bundle {
    // Init phase
    val uop = Flipped(Decoupled(new LsuUOp(p)))
    // Data phase
    val vectorData      = Option.when(p.enableRvv)(Flipped(Decoupled(new Rvv2Lsu(p))))
    val busReq          = Irrevocable(new BusReq)
    val busResp         = Flipped(Valid(new DBus2Resp(p))) // We will never make bus wait
    val intWriteback    = Valid(Flipped(new RegfileWriteDataIO(p)))
    val floatWriteback  = Option.when(p.enableFloat)(Valid(Flipped(new FloatRegfileWriteDataIO(p))))
    val vectorWriteback = Option.when(p.enableRvv)(Decoupled(new Lsu2Rvv(p)))
    val vmeData         = Option.when(p.enableVme)(Flipped(Decoupled(new Vme2Lsu(p))))
    val vmeWriteback    = Option.when(p.enableVme)(Decoupled(new Lsu2Vme(p)))
    val pc              = UInt(p.programCounterBits.W)
    val active          = Bool()
    val storeComplete   = Bool()
    val faultingVstart  = Option.when(p.enableRvv)(Output(Valid(UInt(log2Ceil(p.rvvVlen).W))))
  })

  val state    = RegInit(State())
  val newFault = io.busResp.valid && io.busResp.bits.fault

  val (tx, starts, moveLeadOH) = state.maybeStart()
  val acceptNewTx              = RegNext(io.busReq.ready || !io.busReq.valid, true.B)
  val txPending                = RegInit(MakeInvalid(new BusReq))
  val txOutgoing               = Mux(txPending.valid, txPending, tx)
  txPending := Mux(
    io.busReq.ready || state.faulted || newFault,
    MakeInvalid(txPending.bits),
    txOutgoing
  )

  io.busReq <> IrrevocableChecker(
    MakeIrrevocable(
      Mux(
        state.faulted || newFault,
        MakeInvalid(tx.bits),
        txOutgoing
      )
    )
  )
  val stateFromUop = state.fromUop(io.uop.bits)

  // TODO: use real bookkeeping
  val busRespRowAddr   = RegNext(txOutgoing.bits.rowAddr, 0.U)
  val busRespCellIndex =
    Option.when(p.enableRvv)(RegNext(txOutgoing.bits.cellIndex.get, 0.U(ctrWidth.W)))
  val busRespData = VecInit.tabulate(p.lsuDataBytes) { i =>
    io.busResp.bits.rdata(i * 8 + 7, i * 8)
  }
  val busRespMask    = RegNext(starts, 0.U)
  val faultRespValid = RegNext(txOutgoing.valid && (state.faulted || newFault), false.B)
  // TODO: fault responses can be adjusted if needed. Currently they're junk.

  val (writebackReq, writebacks) = state.maybeWriteback()
  io.intWriteback.valid     := writebackReq.integer.valid
  io.intWriteback.bits.addr := state.rd
  io.intWriteback.bits.data := writebackReq.integer.bits
  io.floatWriteback.foreach { x =>
    x.valid     := writebackReq.float.get.valid
    x.bits.addr := state.rd
    x.bits.data := writebackReq.float.get.bits
  }

  io.vectorWriteback.foreach { x =>
    x.valid := writebackReq.vector.get.valid && !state.vector
      .map(_.isVme.getOrElse(false.B))
      .getOrElse(false.B)
    val faultLimit  = Mux(state.faulted, state.vector.get.faultingCell, busRespCellIndex.get)
    val isFault     = state.faulted || newFault
    val validLimit  = Mux(isFault, faultLimit, state.vector.get.endCell)
    val ffTailIndex = PopCount(VecInit.tabulate(p.rvvVlenb) { i =>
      state.vector.get.writebackActiveCells.bits(i) < validLimit
    })
    x.bits               := writebackReq.vector.get.bits
    x.bits.ff_tail_index := ffTailIndex
  }

  io.vmeWriteback.foreach { x =>
    x.valid     := writebackReq.vector.get.valid && state.vector.get.isVme.get
    x.bits.data := writebackReq.vector.get.bits.data
  }

  val canMoveLead = !state.isDone && (
    !io.busReq.valid || io.busReq.ready
  )
  val effectiveMoveLeadOH = Mux(canMoveLead, moveLeadOH, 1.U((windowSizeNormal + 1).W))
  val initCellsData       = VecInit.tabulate(nCells) { i =>
    if (i < 4) MakeValid(io.uop.fire, stateFromUop.cells(i).data)
    else MakeInvalid(UInt(8.W))
  }
  val stateFromAction = state.act(
    initCellsData = initCellsData,
    starts = Mux(io.busReq.ready || state.faulted || newFault, starts, 0.U),
    moveLeadOH = effectiveMoveLeadOH,
    resp = io.busResp.valid || faultRespValid,
    fault = newFault, // state will latch the fault
    respRowAddr = busRespRowAddr,
    respData = busRespData,
    respMask = busRespMask,
    writebacks = Mux(
      (
        io.intWriteback.valid ||
          io.floatWriteback.map(_.valid).getOrElse(false.B) ||
          io.vectorWriteback.map(_.fire).getOrElse(false.B) ||
          io.vmeWriteback.map(_.fire).getOrElse(false.B)
      ),
      writebacks,
      0.U
    ),
    vectorData = io.vectorData.map { x =>
      MakeValid(x.valid, x.bits)
    },
    vmeData = io.vmeData.map { x =>
      MakeValid(x.valid, x.bits)
    }
  )
  io.uop.ready := stateFromAction.isDone
  state        := Mux(io.uop.fire, stateFromUop, stateFromAction)
  // Scalar store init on io.uop.fire for cells 0..3 is already folded into the early
  // holdOrVecData branch inside stateFromAction (before the final Mux1H), and cells >= 4
  // always hold state.cells(i).data when io.uop.fire is true. Driving state.cells(i).data
  // directly from stateFromAction eliminates the post-Mux1H uop.fire mux for all cells.
  for (i <- 0 until nCells) {
    assert(!io.uop.fire || stateFromAction.cells(i).data === stateFromUop.cells(i).data)
    state.cells(i).data := stateFromAction.cells(i).data
  }

  io.active := state.cells.forall { x =>
    x.state === LsuCellState.DONE
  }
  // storeComplete is raised iff we've completed all cells and writebacks
  io.storeComplete := state.write && !state.cells.forall { x =>
    x.state === LsuCellState.DONE
  } && stateFromAction.cells.forall { x =>
    x.state === LsuCellState.DONE
  }
  io.pc := state.pc

  io.vectorData.map { x =>
    x.ready := state.cells.map(_.state === LsuCellState.W_DATA).reduce(_ || _) &&
      !state.vector.map(_.isVme.getOrElse(false.B)).getOrElse(false.B)
  }
  io.vmeData.map { x =>
    x.ready := state.cells.map(_.state === LsuCellState.W_DATA).reduce(_ || _) &&
      state.vector.get.isVme.get
  }

  io.faultingVstart.foreach { vstartOut =>
    val isVector = state.vector.map(v => v.segmentStep =/= 0.U).getOrElse(false.B)
    vstartOut.valid := isVector && newFault
    val faultingCell = busRespCellIndex.get

    // 1. Divide faultingCell by (NF + 1) in [1..8]
    val divByNf = MuxLookup(state.vector.get.dataSegment.max, faultingCell)(
      Seq(
        0.U -> faultingCell,
        1.U -> (faultingCell >> 1),
        2.U -> (faultingCell / 3.U),
        3.U -> (faultingCell >> 2),
        4.U -> (faultingCell / 5.U),
        5.U -> (faultingCell / 6.U),
        6.U -> (faultingCell / 7.U),
        7.U -> (faultingCell >> 3)
      )
    )

    // 2. Right-shift by element width (elemBytes = segmentStep: 1, 2, or 4)
    val vstart = MuxLookup(state.vector.get.segmentStep, divByNf)(
      Seq(
        1.U -> divByNf,
        2.U -> (divByNf >> 1),
        4.U -> (divByNf >> 2)
      )
    )
    vstartOut.bits := vstart(log2Ceil(p.rvvVlen) - 1, 0)
  }
}

class LsuV3(p: Parameters) extends Lsu(p) {
  // Reserve station. TODO: consider making a wrapper?
  val rs = Module(
    new CircularBufferMulti(new LsuUOp(p), p.instructionLanes, math.max(4, p.instructionLanes))
  )

  // Flush state
  val flushCmd = RegInit(MakeInvalid(new FlushCmd))

  // Accept instructions based on available space.
  val validSums = io.req.map(_.valid).scan(0.U(log2Ceil(p.instructionLanes + 1).W))(_ + _)
  for (i <- 0 until p.instructionLanes) {
    io.req(i).ready := (validSums(i) < rs.io.nSpace) && !flushCmd.valid
  }

  // Prepare and align instructions for the queue.
  val ops = (0 until p.instructionLanes).map(i =>
    MakeValid(
      io.req(i).fire && (io.req(i).bits.op =/= LsuOp.FENCEI),
      LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState)
    )
  )
  val alignedOps = Aligner(ops)

  rs.io.enqValid := PopCount(alignedOps.map(_.valid))
  rs.io.enqData  := alignedOps.map(_.bits)

  io.queueCapacity := rs.io.nSpace

  // Internals
  val slot = Module(new LsuSuperSlot(p))
  slot.io.uop.bits := rs.io.dataOut(0)
  rs.io.deqReady   := slot.io.uop.fire
  if (p.enableRvv) {
    slot.io.vectorData.get <> io.rvv2lsu.get(0)
    io.rvv2lsu.get(1).ready := false.B
  }
  if (p.enableVme) {
    slot.io.vmeData.get <> io.vme2lsu.get
  }

  // TODO: refactor out into a bus adapter
  // TODO: add bookkeeping
  val addr = Cat(slot.io.busReq.bits.rowAddr, 0.U(p.dbusOffsetBits.W))
  val itcm = p.m
    .filter(_.memType == MemoryRegionType.IMEM)
    .map(_.contains(addr))
    .reduceOption(_ || _)
    .getOrElse(false.B)
  val dtcm = p.m
    .filter(_.memType == MemoryRegionType.DMEM)
    .map(_.contains(addr))
    .reduceOption(_ || _)
    .getOrElse(true.B)
  val peri = p.m
    .filter(_.memType == MemoryRegionType.Peripheral)
    .map(_.contains(addr))
    .reduceOption(_ || _)
    .getOrElse(false.B)

  val ibusFault = MakeWireBundle[ValidIO[FaultInfo]](
    Valid(new FaultInfo(p)),
    _.valid      -> (slot.io.busReq.valid && slot.io.busReq.bits.write && itcm),
    _.bits.write -> true.B,
    _.bits.addr  -> slot.io.busReq.bits.rowAddr,
    _.bits.epc   -> slot.io.pc
  )

  val rawFault = MuxCase(
    MakeInvalid(new FaultInfo(p)),
    Seq(
      io.ebus.fault.valid -> io.ebus.fault,
      ibusFault.valid     -> ibusFault
    )
  )

  val faultReg = LsuFaultInfo(p)(
    RegNext(rawFault, MakeInvalid(new FaultInfo(p))),
    slot.io.faultingVstart
  )

  rs.io.flush       := io.pipelineFlush || faultReg.valid
  slot.io.uop.valid := (rs.io.nEnqueued > 0.U) && !rs.io.flush

  flushCmd := MuxCase(
    flushCmd,
    Seq(
      (io.pipelineFlush || faultReg.valid) -> MakeInvalid(new FlushCmd),
      io.flush.fire                        -> MakeInvalid(new FlushCmd),
      (io.req(0).fire && (io.req(0).bits.op === LsuOp.FENCEI))
        -> MakeValid(true.B, FlushCmd(io.req(0).bits))
    )
  )

  io.ibus.valid := itcm && slot.io.busReq.valid && !slot.io.busReq.bits.write
  io.ibus.addr  := addr
  val ibusResp = RegNext(io.ibus.fire || ibusFault.valid, false.B)

  io.dbus.valid := dtcm && slot.io.busReq.valid
  io.dbus.write := slot.io.busReq.bits.write
  io.dbus.pc    := slot.io.pc
  io.dbus.addr  := addr
  io.dbus.adrx  := addr
  io.dbus.size  := p.lsuDataBytes.U
  io.dbus.wdata := slot.io.busReq.bits.wdata
  io.dbus.wmask := slot.io.busReq.bits.wmask
  val dbusResp = RegNext(io.dbus.valid && io.dbus.ready, false.B)

  val use_ebus = !(itcm || dtcm)

  io.ebus.dbus.valid := use_ebus && slot.io.busReq.valid
  io.ebus.dbus.write := slot.io.busReq.bits.write
  io.ebus.dbus.pc    := slot.io.pc
  io.ebus.dbus.addr  := Cat(slot.io.busReq.bits.rowAddr, slot.io.busReq.bits.offset)
  io.ebus.dbus.adrx  := addr
  io.ebus.dbus.size  := slot.io.busReq.bits.size
  io.ebus.dbus.wdata := slot.io.busReq.bits.wdata
  io.ebus.dbus.wmask := slot.io.busReq.bits.wmask
  io.ebus.internal   := peri
  val ebusResp = RegNext(io.ebus.dbus.valid && io.ebus.dbus.ready, false.B)

  slot.io.busResp.valid      := ibusResp || dbusResp || ebusResp
  slot.io.busResp.bits.rdata := MuxUpTo1H(
    WireInit(UInt(p.lsuDataBits.W), DontCare),
    Seq(
      ibusResp -> io.ibus.rdata,
      dbusResp -> io.dbus.rdata,
      ebusResp -> io.ebus.dbus.rdata
    )
  )
  slot.io.busResp.bits.fault := faultReg.valid

  slot.io.busReq.ready := MuxUpTo1H(
    false.B,
    Seq(
      // IBus fault is detected here, not on the bus. We need to accept the req.
      itcm     -> (io.ibus.ready || ibusFault.valid),
      dtcm     -> io.dbus.ready,
      use_ebus -> io.ebus.dbus.ready
    )
  )

  io.rd     := slot.io.intWriteback
  io.rd_flt := slot.io.floatWriteback.getOrElse(MakeInvalid(new FloatRegfileWriteDataIO(p)))
  if (p.enableRvv) {
    io.lsu2rvv.get(0) <> slot.io.vectorWriteback.get
    io.lsu2rvv.get(1).valid := false.B
    io.lsu2rvv.get(1).bits  := DontCare
  }
  if (p.enableVme) {
    io.lsu2vme.get <> slot.io.vmeWriteback.get
  }

  // fault handling
  io.fault := faultReg

  // status reporting
  io.active        := rs.io.nEnqueued > 0.U || !slot.io.active || flushCmd.valid
  io.storeComplete := MakeValid(slot.io.storeComplete, slot.io.pc)

  io.flush.valid  := flushCmd.valid
  io.flush.pcNext := flushCmd.bits.pcNext

}
