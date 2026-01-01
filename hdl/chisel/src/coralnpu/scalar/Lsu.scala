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

class DFlushFenceiIO(p: Parameters) extends DFlushIO(p) {
  val fencei = Output(Bool())
  val pcNext = Output(UInt(32.W))
}

class Lsu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Decode cycle.
    val req = Vec(p.instructionLanes, Flipped(Decoupled(new LsuCmd(p))))
    val busPort = Flipped(new RegfileBusPortIO(p))
    val busPort_flt = Option.when(p.enableFloat)(Flipped(new RegfileBusPortIO(p)))

    // Execute cycle(s).
    val rd = Valid(Flipped(new RegfileWriteDataIO))
    val rd_flt = Valid(Flipped(new RegfileWriteDataIO))

    // Cached interface.
    val ibus = new IBusIO(p)
    val dbus = new DBusIO(p)
    val flush = new DFlushFenceiIO(p)
    val fault = Valid(new FaultInfo(p))

    // DBus that will eventually reach an external bus.
    // Intended for sending a transaction to an external
    // peripheral, likely on TileLink or AXI.
    val ebus = new EBusIO(p)

    // Vector switch.
    val vldst = Output(Bool())

    val rvv2lsu = Option.when(p.enableRvv)(
        Vec(2, Flipped(Decoupled(new Rvv2Lsu(p)))))
    val lsu2rvv = Option.when(p.enableRvv)(Vec(2, Decoupled(new Lsu2Rvv(p))))

    // RVV config state
    val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))

    val storeCount = Output(UInt(2.W))
    val queueCapacity = Output(UInt(3.W))
    val active = Output(Bool())
    val storeComplete = Output(Valid(UInt(32.W)))
  })
}

object Lsu {
  def apply(p: Parameters): Lsu = {
    return Module(new LsuV2(p))
  }
}

object LsuOp extends ChiselEnum {
  val LB  = Value
  val LH  = Value
  val LW  = Value
  val LBU = Value
  val LHU = Value
  val SB  = Value
  val SH  = Value
  val SW  = Value
  val FENCEI = Value
  val FLUSHAT = Value
  val FLUSHALL = Value
  val VLDST = Value
  val FLOAT = Value

  // Vector instructions.
  val VLOAD_UNIT = Value
  val VLOAD_STRIDED = Value
  val VLOAD_OINDEXED = Value
  val VLOAD_UINDEXED = Value
  val VSTORE_UNIT = Value
  val VSTORE_STRIDED = Value
  val VSTORE_OINDEXED = Value
  val VSTORE_UINDEXED = Value

  def isVector(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VLOAD_STRIDED,
               LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
               LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED,
               LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)
  }

  def isIndexedVector(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
               LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)
  }

  def isNonindexedVector(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VLOAD_STRIDED,
               LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED)
  }

  def isFlush(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.FENCEI, LsuOp.FLUSHAT, LsuOp.FLUSHALL)
  }

  def opSize(op: LsuOp.Type, address: UInt): (UInt, UInt) = {
    val halfAligned = (address(0) === 0.U)
    val wordAligned = (address(1, 0) === 0.U)

    val size = MuxUpTo1H(16.U, Seq(
      op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> 1.U,
      op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) -> Mux(halfAligned, 2.U, 16.U),
      op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) ->
          Mux(wordAligned, 4.U, 16.U),
      LsuOp.isVector(op) -> 16.U,
    ))

    val halfAlignedAddress = address(31, 1) << 1.U
    val wordAlignedAddress = address(31, 2) << 2.U
    val lineAlignedAddress = address(31, 4) << 4.U
    val alignedAddress = MuxUpTo1H(lineAlignedAddress, Seq(
      op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> address,
      (op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) && halfAligned) ->
          halfAlignedAddress,
      (op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) && wordAligned) ->
          wordAlignedAddress,
    ))

    (size, alignedAddress)
  }
}

class LsuCmd(p: Parameters) extends Bundle {
  val store = Bool()
  val addr = UInt(5.W)
  val op = LsuOp()
  val pc = UInt(32.W)
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  val nfields = Option.when(p.enableRvv) { UInt(3.W) }
  val umop = Option.when(p.enableRvv) { UInt(5.W) }

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
  val store = Bool()
  val rd = UInt(5.W)
  val op = LsuOp()
  val pc = UInt(32.W)
  val addr = UInt(32.W)
  val data = UInt(32.W)  // Doubles as rs2
  // This aligns with "width" in the spec. It controls index width in
  // indexed loads/stores and data width otherwise.
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  // This is the sew from vtype. It controls data width in indexed
  // loads/stores and is unused in other ops.
  val sew = Option.when(p.enableRvv) { UInt(3.W) }
  // How many data registers (per segment if applicable) to operate on.
  val emul_data = Option.when(p.enableRvv) { UInt(3.W) }
  val nfields = Option.when(p.enableRvv) { UInt(3.W) }

  override def toPrintable: Printable = {
    cf"LsuUOp(store -> ${store}, rd -> ${rd}, op -> ${op}, " +
    cf"pc -> 0x${pc}%x, addr -> 0x${addr}%x, data -> ${data})"
  }
}

object LsuUOp {
  def apply(p: Parameters,
            i: Int,
            cmd: LsuCmd,
            sbus: RegfileBusPortIO,
            fbus: Option[RegfileBusPortIO],
            rvvState: Option[Valid[RvvConfigState]]): LsuUOp = {
    val result = Wire(new LsuUOp(p))
    result.store := cmd.store
    result.rd := cmd.addr
    result.op := cmd.op
    result.pc := cmd.pc
    if (fbus.isDefined) {
      result.addr := sbus.addr(i)
      result.data := Mux(
          cmd.op === LsuOp.FLOAT, fbus.get.data(i), sbus.data(i))
    } else {
      result.addr := sbus.addr(i)
      result.data := sbus.data(i)
    }
    if (p.enableRvv) {
      val eew = cmd.elemWidth.get  // From instruction encoding
      val sew = rvvState.get.bits.sew  // From vtype
      val lmul = rvvState.get.bits.lmul
      // TODO(davidgao): Add checks for illegal LMUL values in the frontend.
      // Unit-stride, const-stride. Default value applies when eew == sew.
      val emul_data = MuxUpTo1H(lmul, Seq(
          // eew == 1/4 sew
          (eew === "b000".U && sew === "b010".U) -> (lmul - 2.U),
          // eew == 1/2 sew
          ((eew === "b000".U && sew === "b001".U) ||
           (eew === "b101".U && sew === "b010".U)) -> (lmul - 1.U),
          // eew == 2 sew
          ((eew === "b101".U && sew === "b000".U) ||
           (eew === "b110".U && sew === "b001".U)) -> (lmul + 1.U),
          // eew == 4 sew
          (eew === "b110".U && sew === "b000".U) -> (lmul + 2.U),
      ))
      result.elemWidth.get := eew
      result.emul_data.get := MuxCase(lmul, Seq(
          // If mask operation, always make LMUL=1.
          cmd.isMaskOperation() -> 0.U,
          // Section 7.9 of RVV Spec: "The nf field encodes how many vector
          // registers to load and store".
          cmd.isWholeRegister() -> MuxUpTo1H(0.U, Seq(
              (cmd.nfields.get === 0.U) -> 0.U,  // NF1 -> LMUL1
              (cmd.nfields.get === 1.U) -> 1.U,  // NF2 -> LMUL2
              (cmd.nfields.get === 3.U) -> 2.U,  // NF4 -> LMUL4
              (cmd.nfields.get === 7.U) -> 3.U,  // NF8 -> LMUL8
          )),
          LsuOp.isNonindexedVector(cmd.op) -> emul_data,
          // default: indexed vector and scalar
      ))

      // If mask operation, force fields to zero
      result.nfields.get := MuxUpTo1H(cmd.nfields.get, Seq(
          cmd.isMaskOperation() -> 0.U,
          cmd.isWholeRegister() -> 0.U,
      ))
      result.sew.get := rvvState.get.bits.sew
    }

    result
  }
}

object ComputeStridedAddrs {
  def apply(bytesPerSlot: Int,
            baseAddr: UInt,
            stride: UInt,
            elemWidth: UInt): Vec[UInt] = {
    MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // elemWidth validation is done at decode time.
      // TODO: pass this as an enum.
      (elemWidth === "b000".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + (i.U*stride))(31, 0))),  // 1-byte elements
      (elemWidth === "b101".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + ((i >> 1).U*stride))(31, 0) + (i & 1).U)),  // 2-byte elements
      (elemWidth === "b110".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + ((i >> 2).U*stride))(31, 0) + (i & 3).U)),  // 4-byte elements
    ))
  }
}

object ComputeIndexedAddrs {
  def apply(bytesPerSlot: Int,
            baseAddr: UInt,
            indices: UInt,
            indexWidth: UInt,
            sew: UInt): Vec[UInt] = {
    val indices8 = UIntToVec(indices, 8).map(x => Cat(0.U(24.W), x))
    val indices16 = UIntToVec(indices, 16).map(x => Cat(0.U(16.W), x))
    val indices32 = UIntToVec(indices, 32)

    val indices_v = MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // 8-bit indices.
      (indexWidth === "b000".U) -> VecInit(indices8),
      // 16-bit indices.
      (indexWidth === "b101".U) -> VecInit(indices16 ++ indices16),
      // 32-bit indices.
      (indexWidth === "b110".U) -> VecInit(
          indices32 ++ indices32 ++ indices32 ++ indices32),
    ))

    MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // elemWidth validation is done at decode time.
      // 8-bit data. Each byte has its own offset.
      (sew === "b000".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i)))),
      // 16-bit data. Each 2-byte element has an offset.
      (sew === "b001".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i >> 1) + (i & 1).U))),
      // 32-bit data. Each 4-byte element has an offset.
      (sew === "b010".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i >> 2) + (i & 3).U)))
    ))
  }
}

class LsuVectorLoop extends Bundle {
  // A looping state machine. Currently there are three main loops:
  // - inner: subvector, for indexed access with data narrower than indices
  // - middle: segment. Putting segment loop within lmul loop gives better
  //   locality.
  // - outer: lmul.
  val isActive = Bool()
  val subvector = new LoopingCounter(2.W)
  val segment = new LoopingCounter(3.W)
  val lmul = new LoopingCounter(3.W)
  // Additional internal states to help drive derived outputs.
  val rdStart = UInt(5.W)
  val rd = UInt(5.W)
  val indexParition = new LoopingCounter(2.W)

  def subvectorDone(): Bool = subvector.isFull()
  def segmentDone(): Bool = subvectorDone() && segment.isFull()
  def lmulDone(): Bool = segmentDone() && lmul.isFull()

  def next(): LsuVectorLoop = MakeWireBundle[LsuVectorLoop](
      new LsuVectorLoop,
      _.isActive -> (isActive && !lmulDone()),
      _.subvector -> subvector.next(),
      _.segment -> Mux(subvectorDone(), segment.next(), segment),
      _.lmul -> Mux(segmentDone(), lmul.next(), lmul),
      _.rdStart -> rdStart,
      _.rd -> MuxCase(rd, Seq(
          // First seg of the new lmul.
          segmentDone() -> (rdStart + lmul.next().curr),
          // Jump all lmuls to next seg.
          subvectorDone() -> (rd + lmul.max + 1.U),
      )),
      _.indexParition -> Mux(segmentDone(), indexParition.next(), indexParition),
  )

  override def toPrintable: Printable = {
    cf"    isActive: ${isActive}\n" +
    cf"    subvector: ${subvector.curr} of [0..${subvector.max}]\n" +
    cf"    segment: ${segment.curr} of [0..${segment.max}]\n" +
    cf"    lmul: ${lmul.curr} of [0..${lmul.max}]\n" +
    cf"    rdStart: ${rdStart}\n    rd: ${rd}\n"
  }
}

// bytesPerSlot is the number of bytes in a vector register
// p.lsuDataBytes is the number of bytes in the AXI bus
class LsuSlot(p: Parameters, bytesPerSlot: Int) extends Bundle {
  val elemBits = log2Ceil(p.lsuDataBytes)

  val op = LsuOp()
  val rd = UInt(5.W)
  val store = Bool()
  val pc = UInt(32.W)
  val active = Vec(bytesPerSlot, Bool())
  val baseAddr = UInt(32.W)
  val addrs = Vec(bytesPerSlot, UInt(32.W))
  val data = Vec(bytesPerSlot, UInt(8.W))
  val pendingVector = Bool()
  val pendingWriteback = Bool()
  val elemStride = UInt(32.W)     // Stride between lanes in a vector
  val segmentStride = UInt(32.W)  // Stride between base addr between segments
  // This aligns with "width" in the spec. It controls index width in
  // indexed loads/stores and data width otherwise.
  val elemWidth = UInt(3.W)
  // This controls data width in indexed loads/stores and is unused in
  // other ops.
  val sew = UInt(3.W)
  val vectorLoop = new LsuVectorLoop()

  // If the slot has no pending tasks and can accept a new operation
  def slotIdle(): Bool = !(
      pendingVector ||        // Awaiting data from RVV Core
      active.reduce(_||_) ||  // Active transaction
      pendingWriteback ||     // Send result back to regfile
      vectorLoop.isActive     // More vector operations in progress
  )

  // If the slot has any active transactions.
  def activeTransaction(): Bool = {
    !pendingVector && active.reduce(_||_)
  }

  def lineAddresses(): Vec[UInt] = {
    VecInit(addrs.map(x => x(31, elemBits)))
  }

  def elemAddresses(): Vec[UInt] = {
    VecInit(addrs.map(x => x(elemBits-1, 0)))
  }

  def targetAddress(lastRead: Valid[UInt]): Valid[UInt] = {
    // Determine which lines are active. If a read was issued last cycle,
    // supress those lines.
    val lineAddrs = lineAddresses()
    val lineActive = (0 until bytesPerSlot).map(i =>
        active(i) && (!lastRead.valid || (lastRead.bits =/= lineAddrs(i))))

    MuxCase(MakeInvalid(UInt(32.W)), (0 until bytesPerSlot).map(
        i => lineActive(i) -> MakeValid(true.B, addrs(i))))
  }

  def vectorUpdate(updated: Bool, rvv2lsu: Rvv2Lsu): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.pendingWriteback := pendingWriteback
    result.baseAddr := baseAddr
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.vectorLoop := vectorLoop

    val segmentBaseAddr = baseAddr + (segmentStride * vectorLoop.segment.curr)(31, 0)
    val bitsPerSlot = bytesPerSlot * 8
    val indices = MuxUpTo1H(rvv2lsu.idx.bits.data, Seq(
        // 2 of 2
        ((vectorLoop.indexParition.curr === 1.U) && (vectorLoop.indexParition.max === 1.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot - 1, bitsPerSlot / 2)),
        // 2 of 4
        ((vectorLoop.indexParition.curr === 1.U) && (vectorLoop.indexParition.max === 3.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot / 2 - 1, bitsPerSlot / 4)),
        // 3 of 4
        ((vectorLoop.indexParition.curr === 2.U) && (vectorLoop.indexParition.max === 3.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot * 3 / 4 - 1, bitsPerSlot / 2)),
        // 4 of 4
        ((vectorLoop.indexParition.curr === 3.U) && (vectorLoop.indexParition.max === 3.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot - 1, bitsPerSlot * 3 / 4)),
    ))
    result.addrs := MuxUpTo1H(addrs, Seq(
        op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
            ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
            ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
                   LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED) ->
            ComputeIndexedAddrs(bytesPerSlot, segmentBaseAddr, indices,
                                elemWidth, sew),
    ))
    result.elemWidth := elemWidth
    result.sew := sew

    val shouldUpdate = updated && (
        LsuOp.isNonindexedVector(op) ||
        (!vectorLoop.subvector.isEnabled()) ||
        rvv2lsu.idx.valid)

    result.data := Mux(shouldUpdate && LsuOp.isVector(op) && rvv2lsu.vregfile.valid,
        UIntToVec(rvv2lsu.vregfile.bits.data, 8), data)
    result.active := Mux(shouldUpdate && LsuOp.isVector(op) && rvv2lsu.mask.valid,
        VecInit(rvv2lsu.mask.bits.asBools), active)
    result.pendingVector := pendingVector && !shouldUpdate

    result
  }

  // Updates the slot based on a previous read.
  def loadUpdate(valid: Bool,
                 lineAddr: UInt,
                 lineData: UInt): LsuSlot = {
    // TODO(derekjchow): Check ordering semantics
    val lineAddrs = lineAddresses()
    val lineActive = VecInit((0 until bytesPerSlot).map(i =>
        !store &&     // Don't update if a store
        (!LsuOp.isVector(op) || !pendingVector) &&  // Has vector data if needed
        valid &&      // Update only if a valid read last cycle
        active(i) &&  // Update only if active
        (lineAddrs(i) === lineAddr)))  // Line must match read line
    val lineDataVec = UIntToVec(lineData, 8)
    val gatheredData = Gather(elemAddresses(), lineDataVec)

    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.baseAddr := baseAddr
    result.addrs := addrs
    result.pendingWriteback := pendingWriteback
    result.pendingVector := pendingVector
    result.active := (0 until bytesPerSlot).map(
        i => active(i) & ~lineActive(i))
    result.data := VecInit((0 until bytesPerSlot).map(
        i => Mux(lineActive(i), gatheredData(i), data(i))))
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew
    result.vectorLoop := vectorLoop

    result
  }

  // If the load transaction is finished, but the result needs to be written
  // back to the regfile.
  def shouldWriteback(): Bool = {
    !pendingVector && !active.reduce(_||_) && pendingWriteback
  }

  // Updates the slot if its result is written back to the regfile.
  def writebackUpdate(writeback: Bool): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.store := store
    result.pc := pc
    result.addrs := addrs
    result.active := active
    result.data := data
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew

    val vectorWriteback = writeback && vectorLoop.isActive
    result.vectorLoop := Mux(vectorWriteback, vectorLoop.next(), vectorLoop)

    result.pendingVector := MuxCase(false.B, Seq(
        (!writeback) -> pendingWriteback,
        result.vectorLoop.isActive -> true.B,  // Next LMUL
    ))
    result.pendingWriteback := MuxCase(false.B, Seq(
      (!writeback) -> pendingWriteback,
      result.vectorLoop.isActive -> true.B,        // Next LMUL
    ))

    // TODO(davidgao): absorb baseAddr offset computation into vectorLoop
    val lmulUpdate = vectorWriteback && vectorLoop.segmentDone()
    result.baseAddr := MuxCase(baseAddr, Seq(
      (!writeback || !lmulUpdate) -> baseAddr,
      // For Unit and strided updates
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
          (baseAddr + (vectorLoop.segment.max * 16.U) + 16.U),
      op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
          MuxUpTo1H(baseAddr + (elemStride * bytesPerSlot.U), Seq(
            (elemWidth === "b000".U) ->
                (baseAddr + (elemStride * bytesPerSlot.U)),
            (elemWidth === "b101".U) ->
                (baseAddr + (elemStride * (bytesPerSlot/2).U)),
            (elemWidth === "b110".U) ->
                (baseAddr + (elemStride * (bytesPerSlot/4).U)),
          ))
          // (baseAddr + (vectorLoop.segment.max * elemStride)(31, 0)),

      // Indexed don't have base addr changed.
    ))
    result.rd := result.vectorLoop.rd

    result
  }

  def scatter(lineAddr: UInt): (Vec[UInt], Vec[Bool], Vec[Bool]) = {
    val canScatter = store && (!LsuOp.isVector(op) || !pendingVector)
    val lineAddrs = lineAddresses()
    val lineActive = VecInit((0 until bytesPerSlot).map(i =>
        canScatter && active(i) & (lineAddrs(i) === lineAddr)))
    Scatter(lineActive, elemAddresses(), data)
  }

  def storeUpdate(selected: Vec[Bool]): LsuSlot = {
    assert(selected.length == active.length)
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.pendingWriteback := pendingWriteback
    result.pendingVector := pendingVector
    result.active := (0 until bytesPerSlot).map(i => active(i) & ~selected(i))
    result.baseAddr := baseAddr
    result.addrs := addrs
    result.data := data
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew
    result.vectorLoop := vectorLoop
    result
  }

  def scalarLoadResult(): UInt = {
    val word = Cat(data(3), data(2), data(1), data(0))
    val half = Cat(data(1), data(0))
    val byte =  data(0)
    // Sign extends the result of a load operation when necessary.
    val halfSigned = Wire(SInt(32.W))
    halfSigned := half.asSInt
    val byteSigned = Wire(SInt(32.W))
    byteSigned := byte.asSInt
    MuxLookup(op, 0.U)(Seq(
      LsuOp.LB -> byteSigned.asUInt,
      LsuOp.LBU -> byte,
      LsuOp.LH -> halfSigned.asUInt,
      LsuOp.LHU -> half,
      LsuOp.LW -> word,
      LsuOp.FLOAT -> word,
    ))
  }

  override def toPrintable: Printable = {
    val lines = (0 until bytesPerSlot).map(i =>
        cf"  $i: ${active(i)}, 0x${addrs(i)}%x, 0x${data(i)}%x\n")
    cf"store: $store\n  op: ${op}\n  pendingVector: ${pendingVector}\n" +
    cf"  pendingWriteback: ${pendingWriteback}\n" +
    cf"  vectorLoop:\n${vectorLoop.toPrintable}" +
    cf"  elemWidth: 0b${elemWidth}%b elemStride: ${elemStride}\n" +
    lines.reduce(_+_)
  }
}

object LsuSlot {
  def inactive(p: Parameters, bytesPerSlot: Int): LsuSlot = {
    0.U.asTypeOf(new LsuSlot(p, bytesPerSlot))
  }

  def fromLsuUOp(uop: LsuUOp, p: Parameters, bytesPerSlot: Int): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := uop.op
    result.rd := uop.rd
    result.store := uop.store
    result.pc := uop.pc
    if (p.enableRvv) {
      val effectiveLmul = MuxCase(uop.emul_data.getOrElse(0.U)(1, 0), Seq(
        // Treat fractional EMULs as EMUL=1
        (uop.emul_data.getOrElse(0.U)(2)) -> 0.U(2.W),
      ))

      val nfields = Mux(LsuOp.isVector(uop.op), uop.nfields.get, 0.U)
      // Determine number of rvv2lsu interactions required for one vector for
      // indexed loads. This occurs when the index dtype is greater than data
      // dtype.
      val elemWidth = uop.elemWidth.get
      val elemMultiplier = MuxUpTo1H(1.U, Seq(
        // 8-bit data, 16-bit indices
        ((elemWidth === "b101".U) && (uop.sew.get === 0.U)) -> 2.U,
        // 8-bit data, 32-bit indices
        ((elemWidth === "b110".U) && (uop.sew.get === 0.U)) -> 4.U,
        // 16-bit data, 32-bit indices
        ((elemWidth === "b110".U) && (uop.sew.get === 1.U)) -> 2.U,
      ))
      val max_subvector = MuxUpTo1H(0.U, Seq(
        ((elemMultiplier === 2.U) && (uop.emul_data.get.asSInt >= 0.S)) -> 1.U,
        ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt >= 0.S)) -> 3.U,
        ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt === -1.S)) -> 1.U,
      ))
      // [0..x] data vecs we can operate on with one index vec
      val indexParitions = MuxUpTo1H(0.U, Seq(
        // 16-bit data, 8-bit indices
        ((elemWidth === "b000".U) && (uop.sew.get === 1.U)) -> 1.U,
        // 32-bit data, 8-bit indices
        ((elemWidth === "b000".U) && (uop.sew.get === 2.U)) -> 3.U,
        // 32-bit data, 16-bit indices
        ((elemWidth === "b101".U) && (uop.sew.get === 2.U)) -> 1.U,
      ))
      result.vectorLoop := MakeWireBundle[LsuVectorLoop](
          new LsuVectorLoop,
          _.isActive -> LsuOp.isVector(uop.op),
          _.subvector -> LoopingCounter(Mux(
              LsuOp.isIndexedVector(uop.op), max_subvector, 0.U)),
          _.segment -> LoopingCounter(nfields),
          _.lmul -> LoopingCounter((1.U(4.W) << effectiveLmul) - 1.U),
          _.rdStart -> uop.rd,
          _.rd -> uop.rd,
          _.indexParition -> LoopingCounter(indexParitions),
      )
    } else {
      result.vectorLoop := 0.U.asTypeOf(result.vectorLoop)
    }

    // All vector ops require writeback. Lsu needs to inform RVV core store uop
    // has completed.
    result.pendingWriteback := !uop.store || LsuOp.isVector(uop.op)
    result.pendingVector := LsuOp.isVector(uop.op)

    val active = MuxUpTo1H(0.U(bytesPerSlot.W), Seq(
      uop.op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> "b1".U(bytesPerSlot.W),
      uop.op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) -> "b11".U(bytesPerSlot.W),
      uop.op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) -> "b1111".U(bytesPerSlot.W),
      // Vector
      LsuOp.isVector(uop.op) -> ~0.U(bytesPerSlot.W),
    ))
    result.active := active.asBools

    // Compute addrs
    result.baseAddr := uop.addr
    result.elemWidth := uop.elemWidth.getOrElse(0.U(3.W))
    result.sew := uop.sew.getOrElse(0.U(3.W))
    result.addrs := Mux(
        uop.op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED),
        ComputeStridedAddrs(bytesPerSlot, uop.addr, uop.data, uop.elemWidth.getOrElse(0.U(3.W))),
        VecInit((0 until bytesPerSlot).map(i => uop.addr + i.U)))

    val unitStride = Mux(
        uop.op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
                       LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED),
        // Indexed load. The unit stride also controls segment stride.
        MuxUpTo1H(1.U, Seq(
            (result.sew === "b000".U) -> 1.U,  // 1-byte elements
            (result.sew === "b001".U) -> 2.U,  // 2-byte elements
            (result.sew === "b010".U) -> 4.U,  // 4-byte elements
        )),
        // Non-indexed load.
        MuxUpTo1H(1.U, Seq(
            (uop.elemWidth.getOrElse(3.U) === "b000".U) -> 1.U,  // 1-byte elements
            (uop.elemWidth.getOrElse(3.U) === "b101".U) -> 2.U,  // 2-byte elements
            (uop.elemWidth.getOrElse(3.U) === "b110".U) -> 4.U,  // 4-byte elements
        )),
    )

    result.segmentStride := unitStride
    result.elemStride := Mux(
        uop.op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT),
        unitStride + (uop.nfields.getOrElse(3.U) * unitStride),
        uop.data)

    result.data(0) := uop.data(7, 0)
    result.data(1) := uop.data(15, 8)
    result.data(2) := uop.data(23, 16)
    result.data(3) := uop.data(31, 24)
    for (i <- 4 until bytesPerSlot) {
      result.data(i) := 0.U
    }

    result
  }
}

class LsuCtrl(p: Parameters) extends Bundle {
  val pc = UInt(32.W)
  val addr = UInt(32.W)
  val adrx = UInt(32.W)
  val data = UInt(32.W)
  val index = UInt(5.W)
  val size = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val fullsize = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val write = Bool()
  val sext = Bool()
  val iload = Bool()
  val fencei = Bool()
  val flushat = Bool()
  val flushall = Bool()
  val sldst = Bool()  // scalar load/store cached
  val vldst = Bool()  // vector load/store
  val fldst = Bool() // float load/store
  val regionType = MemoryRegionType()
  val mask = UInt(p.lsuDataBytes.W)
  val last = Bool()
}

class LsuReadData(p: Parameters) extends Bundle {
  val addr = UInt(32.W)
  val index = UInt(5.W)
  val size = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val fullsize = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val sext = Bool()
  val iload = Bool()
  val sldst = Bool()
  val fldst = Bool()
  val regionType = MemoryRegionType()
  val mask = UInt(p.lsuDataBytes.W)
  val last = Bool()
}

object LsuBus extends ChiselEnum {
  val IBUS = Value
  val DBUS = Value
  val EXTERNAL = Value
}

class LsuRead(lineBits: Int) extends Bundle {
  val bus = LsuBus()
  val lineAddr = UInt(lineBits.W)
}

object LsuRead {
  def apply(bus: LsuBus.Type, lineAddr: UInt): LsuRead = {
    val result = Wire(new LsuRead(lineAddr.getWidth))
    result.bus := bus
    result.lineAddr := lineAddr
    result
  }
}

class FlushCmd extends Bundle {
  val all = Bool()
  val fencei = Bool()
  val pcNext = UInt(32.W)
}

object FlushCmd {
  def apply(cmd: LsuCmd): FlushCmd = {
    val result = Wire(new FlushCmd)
    result.all    := cmd.op.isOneOf(LsuOp.FENCEI, LsuOp.FLUSHALL)
    result.fencei := (cmd.op === LsuOp.FENCEI)
    result.pcNext := cmd.pc + 4.U
    result
  }
}

class LsuV2(p: Parameters) extends Lsu(p) {
  // Tie-offs
  io.vldst := 0.U
  io.storeCount := 0.U

  val opQueue = Module(new CircularBufferMulti(new LsuUOp(p), p.instructionLanes, 4))
  opQueue.io.flush := false.B
  io.queueCapacity := opQueue.io.nSpace

  // Flush state
  // DispatchV2 will only flush on first slot, when LSU is inactive.

  val flushCmd = RegInit(MakeInvalid(new FlushCmd))  // Track pending flush + pc
  io.flush.valid  := flushCmd.valid
  io.flush.all    := flushCmd.bits.all
  io.flush.clean  := true.B
  io.flush.fencei := flushCmd.bits.fencei
  io.flush.pcNext := flushCmd.bits.pcNext

  flushCmd := MuxCase(flushCmd, Seq(
    // New flush command
    (io.req(0).fire && LsuOp.isFlush(io.req(0).bits.op))
        -> MakeValid(true.B, FlushCmd(io.req(0).bits)),
    // Finish flush command
    (io.flush.valid && io.flush.ready) -> MakeInvalid(new FlushCmd),
  ))

  // Accept one instruction per cycle.
  val queueSpace = opQueue.io.nSpace
  val validSum = io.req.map(_.valid).scan(
      0.U(log2Ceil(p.instructionLanes + 1).W))(_+_)
  for (i <- 0 until p.instructionLanes) {
    io.req(i).ready := (validSum(i) < queueSpace) && !flushCmd.valid
  }

  val ops = (0 until p.instructionLanes).map(i =>
    MakeValid(
        io.req(i).fire && !LsuOp.isFlush(io.req(i).bits.op),
        LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState))
  )
  val alignedOps = Aligner(ops)

  opQueue.io.enqValid := PopCount(alignedOps.map(_.valid))
  opQueue.io.enqData := alignedOps.map(_.bits)
  assert(opQueue.io.enqValid <= opQueue.io.nSpace)

  val nextSlot = LsuSlot.fromLsuUOp(opQueue.io.dataOut(0), p, 16)

  // Tracks if a read has been fired last cycle.
  val readFired = RegInit(MakeInvalid(new LsuRead(32 - nextSlot.elemBits)))
  val slot = RegInit(LsuSlot.inactive(p, 16))

  val readData = MuxLookup(readFired.bits.bus, 0.U)(Seq(
      LsuBus.IBUS -> io.ibus.rdata,
      LsuBus.DBUS -> io.dbus.rdata,
      LsuBus.EXTERNAL -> io.ebus.dbus.rdata,
  ))

  // ==========================================================================
  // Vector update
  val vectorUpdatedSlot = if (p.enableRvv) {
      io.rvv2lsu.get(0).ready := slot.pendingVector
      io.rvv2lsu.get(1).ready := false.B
      slot.vectorUpdate(
          io.rvv2lsu.get(0).fire, io.rvv2lsu.get(0).bits)
  } else {
      slot.vectorUpdate(false.B, 0.U.asTypeOf(new Rvv2Lsu(p)))
  }

  // ==========================================================================
  // Transaction update
  val faultReg = RegInit(MakeInvalid(new FaultInfo(p)))

  // First stage of load update: Update results based on bus read
  val loadUpdatedSlot = slot.loadUpdate(
      readFired.valid, readFired.bits.lineAddr, readData)

  // Compute next target transaction
  val targetAddress = loadUpdatedSlot.targetAddress(
      MakeValid(readFired.valid, readFired.bits.lineAddr))
  val targetLine = MakeValid(
      targetAddress.valid, targetAddress.bits(31, nextSlot.elemBits))
  val targetLineAddr = targetLine.bits << 4
  val itcm = p.m.filter(_.memType == MemoryRegionType.IMEM)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(false.B)
  val dtcm = p.m.filter(_.memType == MemoryRegionType.DMEM)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(true.B)
  val peri = p.m.filter(_.memType == MemoryRegionType.Peripheral)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(false.B)
  val external = !(itcm || dtcm || peri)
  assert(PopCount(Cat(itcm | dtcm | peri)) <= 1.U)

  val (wdata, wmask, wactive) = slot.scatter(targetLine.bits)

  val (opSize, alignedAddress) = LsuOp.opSize(slot.op, targetAddress.bits)

  // ibus data path
  io.ibus.valid := loadUpdatedSlot.activeTransaction() && itcm && !slot.store && !faultReg.valid
  io.ibus.addr := targetLineAddr

  // dbus data path
  io.dbus.valid := dtcm && Mux(slot.store,
                               slot.activeTransaction(),
                               loadUpdatedSlot.activeTransaction()) && !faultReg.valid
  io.dbus.write := slot.store
  io.dbus.pc := slot.pc
  io.dbus.addr := targetLineAddr
  io.dbus.adrx := targetLineAddr
  io.dbus.size := opSize
  io.dbus.wdata := Cat(wdata.reverse)
  io.dbus.wmask := Cat(wmask.reverse)

  // ebus data path
  io.ebus.dbus.valid := (external || peri) && Mux(slot.store,
                                                  slot.activeTransaction(),
                                                  loadUpdatedSlot.activeTransaction()) && !faultReg.valid
  io.ebus.dbus.write := slot.store
  io.ebus.dbus.addr := alignedAddress
  io.ebus.dbus.adrx := targetLineAddr
  io.ebus.dbus.size := opSize
  io.ebus.dbus.wdata := Cat(wdata.reverse)
  io.ebus.dbus.wmask := Cat(wmask.reverse)
  io.ebus.dbus.pc := slot.pc
  io.ebus.internal := peri

  val ibusFired = io.ibus.valid && io.ibus.ready
  val dbusFired = io.dbus.valid && io.dbus.ready
  val ebusFired = io.ebus.dbus.valid && io.ebus.dbus.ready
  assert(PopCount(Seq(ibusFired, dbusFired, ebusFired)) <= 1.U)
  val slotFired = ebusFired || dbusFired || ibusFired

  val readFiredValid = ibusFired || (dbusFired && !io.dbus.write) || (ebusFired && !io.ebus.dbus.write)
  readFired := MakeValid(readFiredValid,
    MuxCase(readFired.bits, Seq(
      (ibusFired) -> LsuRead(LsuBus.IBUS, targetLine.bits),
      (dbusFired && !io.dbus.write) -> LsuRead(LsuBus.DBUS, targetLine.bits),
      (ebusFired && !io.ebus.dbus.write) -> LsuRead(LsuBus.EXTERNAL, targetLine.bits),
    )))

  // Fault handling
  val ibusFault = Wire(Valid(new FaultInfo(p)))
  ibusFault.valid := loadUpdatedSlot.activeTransaction() && itcm && slot.store
  ibusFault.bits.write := true.B
  ibusFault.bits.addr := targetLineAddr
  ibusFault.bits.epc := slot.pc

  io.fault := faultReg
  faultReg := MuxCase(MakeInvalid(new FaultInfo(p)), Seq(
      io.ebus.fault.valid -> io.ebus.fault,
      ibusFault.valid -> ibusFault,
  ))

  // Transaction update
  val storeUpdate = Mux(slotFired, wactive, VecInit.fill(16)(false.B))
  val transactionUpdatedSlot = Mux(slot.store,
      slot.storeUpdate(storeUpdate), loadUpdatedSlot)
  val lsu2RvvFire = if (p.enableRvv) { io.lsu2rvv.get(0).fire } else { false.B }
  // For scalar stores: complete when transaction is done (slotFired && all bytes written)
  // For vector stores: complete when lsu2rvv handshake fires with last=1
  // These happen in different cycles, so we can't AND them together.
  val scalarStoreComplete = slotFired && slot.store && !slot.slotIdle() &&
      transactionUpdatedSlot.slotIdle() && !LsuOp.isVector(slot.op)
  val vectorStoreComplete = if (p.enableRvv) {
      lsu2RvvFire && io.lsu2rvv.get(0).bits.last
  } else { false.B }
  val storeComplete = scalarStoreComplete || vectorStoreComplete
  io.storeComplete := Mux(storeComplete, MakeValid(slot.pc), MakeInvalid(UInt(32.W)))

  // ==========================================================================
  // Writeback update

  // Scalar writeback
  // Write back on error. io.fault.valid will mask
  io.rd.valid := (faultReg.valid || slot.shouldWriteback()) &&
      slot.op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.LH, LsuOp.LHU, LsuOp.LW)
  io.rd.bits.data := slot.scalarLoadResult()
  io.rd.bits.addr := slot.rd

  // Float writeback
  io.rd_flt.valid := slot.shouldWriteback() &&
                     (slot.op === LsuOp.FLOAT) && !slot.store
  io.rd_flt.bits.addr := slot.rd
  io.rd_flt.bits.data := slot.scalarLoadResult()

  // Vector writeback
  if (p.enableRvv) {
    io.lsu2rvv.get(0).valid := slot.shouldWriteback() && LsuOp.isVector(slot.op)
    io.lsu2rvv.get(0).bits.addr := slot.rd
    io.lsu2rvv.get(0).bits.data := Cat(slot.data.reverse)
    io.lsu2rvv.get(0).bits.last := slot.shouldWriteback() &&
        slot.op.isOneOf(LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED,
                        LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)

    io.lsu2rvv.get(1).valid := false.B
    io.lsu2rvv.get(1).bits.addr := 0.U
    io.lsu2rvv.get(1).bits.data := 0.U
    io.lsu2rvv.get(1).bits.last := true.B
  }

  val writebacksFired = Seq(io.rd.valid, io.rd_flt.valid) ++ (if (p.enableRvv) {
      Seq(io.lsu2rvv.get(0).fire) } else { Seq() })
  assert(PopCount(writebacksFired) <= 1.U)
  val writebackFired = writebacksFired.reduce(_ || _)
  val writebackUpdatedSlot = slot.writebackUpdate(writebackFired)

  // TODO(derekjchow): Improve timing?
  opQueue.io.deqReady := Mux(slot.slotIdle() && (opQueue.io.nEnqueued > 0.U), 1.U, 0.U)

  // ==========================================================================
  // State transition

  // Slot update
  val slotNext = MuxCase(slot, Seq(
    // Move to inactive if error.
    faultReg.valid -> LsuSlot.inactive(p, 16),
    // When inactive, dequeue if possible
    (slot.slotIdle() && (opQueue.io.nEnqueued > 0.U)) -> nextSlot,
    // Vector update.
    slot.pendingVector -> vectorUpdatedSlot,
    // Active transaction update.
    slot.activeTransaction() -> transactionUpdatedSlot,
    // Writeback update.
    slot.shouldWriteback() -> writebackUpdatedSlot,
  ))

  slot := slotNext

  io.active := !slot.slotIdle() || (opQueue.io.nEnqueued =/= 0.U)
}

