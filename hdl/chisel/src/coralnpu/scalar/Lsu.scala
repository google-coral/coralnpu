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
  val pcNext = Output(UInt(p.programCounterBits.W))
}

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
    val flush = new DFlushFenceiIO(p)
    val fault = Valid(new FaultInfo(p))

    // DBus that will eventually reach an external bus.
    // Intended for sending a transaction to an external
    // peripheral, likely on TileLink or AXI.
    val ebus = new EBusIO(p)

    // Vector switch.
    val vldst = Output(Bool())

    val rvv2lsu = Option.when(p.enableRvv)(Vec(2, Flipped(Decoupled(new Rvv2Lsu(p)))))
    val lsu2rvv = Option.when(p.enableRvv)(Vec(2, Decoupled(new Lsu2Rvv(p))))

    // RVV config state
    val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))

    val queueCapacity = Output(UInt(3.W))
    val active        = Output(Bool())
    val storeComplete = Output(Valid(UInt(p.programCounterBits.W)))
  })
}

object Lsu {
  def apply(p: Parameters): Lsu = {
    // return Module(new LsuV2(p))
    Module(new LsuV3(p))
  }
}

object LsuOp extends ChiselEnum {
  val LB       = Value
  val LH       = Value
  val LW       = Value
  val LBU      = Value
  val LHU      = Value
  val SB       = Value
  val SH       = Value
  val SW       = Value
  val FENCEI   = Value
  val FLUSHAT  = Value
  val FLUSHALL = Value
  val VLDST    = Value
  val FLOAT    = Value

  // Vector instructions.
  val VLOAD_UNIT      = Value
  val VLOAD_STRIDED   = Value
  val VLOAD_OINDEXED  = Value
  val VLOAD_UINDEXED  = Value
  val VSTORE_UNIT     = Value
  val VSTORE_STRIDED  = Value
  val VSTORE_OINDEXED = Value
  val VSTORE_UINDEXED = Value

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

  def isFlush(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.FENCEI, LsuOp.FLUSHAT, LsuOp.FLUSHALL)
  }

  def isScalarLoad(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.LH, LsuOp.LHU, LsuOp.LW)
  }

  def opSize(op: LsuOp.Type, address: UInt, p: Parameters): (UInt, UInt) = {
    val halfAligned = (address(0) === 0.U)
    val wordAligned = (address(1, 0) === 0.U)

    val size = MuxUpTo1H(
      16.U,
      Seq(
        op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB)   -> 1.U,
        op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH)   -> Mux(halfAligned, 2.U, 16.U),
        op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) ->
          Mux(wordAligned, 4.U, 16.U),
        LsuOp.isVector(op) -> 16.U
      )
    )

    val halfAlignedAddress = address(p.lsuAddrBits - 1, 1) << 1.U
    val wordAlignedAddress = address(p.lsuAddrBits - 1, 2) << 2.U
    val lineAlignedAddress = address(p.lsuAddrBits - 1, 4) << 4.U
    val alignedAddress     = MuxUpTo1H(
      lineAlignedAddress,
      Seq(
        op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB)                  -> address,
        (op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) && halfAligned) ->
          halfAlignedAddress,
        (op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) && wordAligned) ->
          wordAlignedAddress
      )
    )

    (size, alignedAddress)
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
      result.data := Mux(cmd.op === LsuOp.FLOAT, fbus.get.data(i), sbus.data(i))
    } else {
      result.addr := sbus.addr(i)
      result.data := sbus.data(i)
    }
    if (p.enableRvv) {
      val eew       = cmd.elemWidth.get     // From instruction encoding
      val sew       = rvvState.get.bits.sew // From vtype
      val lmul_eff  = rvvState.get.bits.lmul
      val lmul_orig = rvvState.get.bits.lmul_orig
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
            cmd.isMaskOperation() -> 0.U,
            // Section 7.9 of RVV Spec: "The nf field encodes how many vector
            // registers to load and store".
            cmd.isWholeRegister() -> MuxUpTo1H(
              0.U,
              Seq(
                (cmd.nfields.get === 0.U) -> 0.U, // NF1 -> LMUL1
                (cmd.nfields.get === 1.U) -> 1.U, // NF2 -> LMUL2
                (cmd.nfields.get === 3.U) -> 2.U, // NF4 -> LMUL4
                (cmd.nfields.get === 7.U) -> 3.U  // NF8 -> LMUL8
              )
            ),
            LsuOp.isNonindexedVector(cmd.op) -> emul_data
            // default: indexed vector and scalar
          )
        )
      }

      result.elemWidth.get      := eew
      result.emul_data.get      := lmulToDataEmul(lmul_eff)
      result.emul_data_orig.get := lmulToDataEmul(lmul_orig)
      result.vl.get             := MuxUpTo1H(
        rvvState.get.bits.vl,
        Seq(
          cmd.isMaskOperation() -> ((rvvState.get.bits.vl >> 3) + rvvState.get.bits.vl.take(3).orR),
          cmd.isWholeRegister() -> MuxUpTo1H(
            WireInit(UInt(result.vl.get.getWidth.W), DontCare),
            Seq(
              (cmd.nfields.get === 0.U) -> p.rvvVlenb.U,       // NF1 -> LMUL1
              (cmd.nfields.get === 1.U) -> (p.rvvVlenb * 2).U, // NF2 -> LMUL2
              (cmd.nfields.get === 3.U) -> (p.rvvVlenb * 4).U, // NF4 -> LMUL4
              (cmd.nfields.get === 7.U) -> (p.rvvVlenb * 8).U  // NF8 -> LMUL8
            )
          )
        )
      )
      result.vstart.get := rvvState.get.bits.vstart

      // If mask operation, force fields to zero
      result.nfields.get := MuxUpTo1H(
        cmd.nfields.get,
        Seq(
          cmd.isMaskOperation() -> 0.U,
          cmd.isWholeRegister() -> 0.U
        )
      )
      result.sew.get := rvvState.get.bits.sew
      // We only care about const stride here.
      // Ordered indexed is apparent on the op.
      result.strict.get := (
        cmd.op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) &&
          cmd.rs2.get =/= 0.U &&
          sbus.data(i) === 0.U
      )
      result.masked.get := !cmd.vm.get
    }

    result
  }
}

object ComputeStridedAddrs {
  def apply(bytesPerSlot: Int, baseAddr: UInt, stride: UInt, elemWidth: UInt): Vec[UInt] = {
    val addrWidth = baseAddr.getWidth
    MuxUpTo1H(
      VecInit.fill(bytesPerSlot)(0.U(addrWidth.W)),
      Seq(
        // elemWidth validation is done at decode time.
        // TODO: pass this as an enum.
        (elemWidth === "b000".U) -> VecInit(
          (0 until bytesPerSlot).map(i => (baseAddr + (i.U * stride))(addrWidth - 1, 0))
        ), // 1-byte elements
        (elemWidth === "b101".U) -> VecInit(
          (0 until bytesPerSlot).map(i =>
            (baseAddr + ((i >> 1).U * stride))(addrWidth - 1, 0) + (i & 1).U
          )
        ), // 2-byte elements
        (elemWidth === "b110".U) -> VecInit(
          (0 until bytesPerSlot).map(i =>
            (baseAddr + ((i >> 2).U * stride))(addrWidth - 1, 0) + (i & 3).U
          )
        ) // 4-byte elements
      )
    )
  }
}

object ComputeIndexedAddrs {
  def apply(
    bytesPerSlot: Int,
    baseAddr: UInt,
    indices: UInt,
    indexWidth: UInt,
    sew: UInt
  ): Vec[UInt] = {
    val addrWidth = baseAddr.getWidth
    val indices8  = UIntToVec(indices, 8).map(x => Cat(0.U((addrWidth - 8).W), x))
    val indices16 = UIntToVec(indices, 16).map(x => Cat(0.U((addrWidth - 16).W), x))
    val indices32 =
      UIntToVec(indices, 32).map(x => if (addrWidth > 32) Cat(0.U((addrWidth - 32).W), x) else x)

    val indices_v = MuxUpTo1H(
      VecInit.fill(bytesPerSlot)(0.U(addrWidth.W)),
      Seq(
        // 8-bit indices.
        (indexWidth === "b000".U) -> VecInit(indices8),
        // 16-bit indices.
        (indexWidth === "b101".U) -> VecInit(indices16 ++ indices16),
        // 32-bit indices.
        (indexWidth === "b110".U) -> VecInit(indices32 ++ indices32 ++ indices32 ++ indices32)
      )
    )

    MuxUpTo1H(
      VecInit.fill(bytesPerSlot)(0.U(addrWidth.W)),
      Seq(
        // elemWidth validation is done at decode time.
        // 8-bit data. Each byte has its own offset.
        (sew === "b000".U) -> VecInit((0 until bytesPerSlot).map(i => (baseAddr + indices_v(i)))),
        // 16-bit data. Each 2-byte element has an offset.
        (sew === "b001".U) -> VecInit(
          (0 until bytesPerSlot).map(i => (baseAddr + indices_v(i >> 1) + (i & 1).U))
        ),
        // 32-bit data. Each 4-byte element has an offset.
        (sew === "b010".U) -> VecInit(
          (0 until bytesPerSlot).map(i => (baseAddr + indices_v(i >> 2) + (i & 3).U))
        )
      )
    )
  }
}

class LsuVectorLoop extends Bundle {
  val subvector = new LoopingCounter(3.W)
  val segment   = new LoopingCounter(4.W)
  val lmul      = new LoopingCounter(4.W)
  val lmul_orig = UInt(4.W)
  // Additional internal states to help drive derived outputs.
  val rdStart = UInt(5.W)
  val rd      = UInt(5.W)

  def isActive(): Bool = {
    (!subvector.isFull()) || (!segment.isFull()) || (!lmul.isFull())
  }

  def nextSubvector(): LsuVectorLoop = {
    val result = MakeWireBundle[LsuVectorLoop](new LsuVectorLoop, _ -> this)
    result.subvector := subvector.next()
    result
  }

  def nextVector(): LsuVectorLoop = {
    val result = MakeWireBundle[LsuVectorLoop](new LsuVectorLoop, _ -> this)
    result.subvector := subvector.reset()
    result.segment   := Mux(segment.isFull(), segment.reset(), segment.next())
    result.lmul      := Mux(segment.isFull(), lmul.next(), lmul)
    result.rd        := Mux(segment.isFull(), rdStart + lmul.next().curr, rd + lmul_orig)
    result
  }

  override def toPrintable: Printable = {
    cf"    subvector: ${subvector.curr} of [0..${subvector.max}]\n" +
      cf"    segment: ${segment.curr} of [0..${segment.max}]\n" +
      cf"    lmul: ${lmul.curr} of [0..${lmul.max}], orig=${lmul_orig}\n" +
      cf"    rdStart: ${rdStart}\n    rd: ${rd}\n"
  }
}

// bytesPerSlot is the number of bytes in a vector register
// p.lsuDataBytes is the number of bytes in the AXI bus
class LsuSlot(p: Parameters, bytesPerSlot: Int) extends Bundle {
  val elemBits = log2Ceil(p.lsuDataBytes)

  val op               = LsuOp()
  val rd               = UInt(log2Ceil(p.scalarRegCount).W)
  val store            = Bool()
  val pc               = UInt(p.programCounterBits.W)
  val baseAddr         = UInt(p.lsuAddrBits.W)
  val active           = Vec(bytesPerSlot, Bool())
  val addrs            = Vec(bytesPerSlot, UInt(p.lsuAddrBits.W))
  val data             = Vec(bytesPerSlot, UInt(8.W))
  val pendingWriteback = Bool()
  val elemStride       = UInt(p.xlen.W) // Stride between lanes in a vector
  val segmentStride    = UInt(p.xlen.W) // Stride between base addr between segments
  // This aligns with "width" in the spec. It controls index width in
  // indexed loads/stores and data width otherwise.
  val elemWidth = UInt(3.W)
  // This controls data width in indexed loads/stores and is unused in
  // other ops.
  val sew = UInt(3.W)
  // Number of time indices repeats (up to 4 times)
  val indexParitions = UInt(3.W)
  val vectorLoop     = new LsuVectorLoop()

  def pendingVector(): Bool = {
    !vectorLoop.subvector.isFull()
  }

  // If the slot has no pending tasks and can accept a new operation
  def slotIdle(): Bool = !(
    active.reduce(_ || _) || // Active transaction
      pendingWriteback ||    // Send result back to regfile
      vectorLoop.isActive()  // More vector operations in progress
  )

  // If the slot has any active transactions.
  def activeTransaction(): Bool = {
    (!pendingVector()) && active.reduce(_ || _)
  }

  def lineAddresses(): Vec[UInt] = {
    VecInit(addrs.map(x => x(p.lsuAddrBits - 1, elemBits)))
  }

  def elemAddresses(): Vec[UInt] = {
    VecInit(addrs.map(x => x(elemBits - 1, 0)))
  }

  def targetAddress(lastRead: Valid[UInt]): Valid[UInt] = {
    // Determine which lines are active. If a read was issued last cycle,
    // supress those lines.
    val lineAddrs  = lineAddresses()
    val lineActive = (0 until bytesPerSlot).map(i =>
      !pendingVector() &&
        active(i) && (!lastRead.valid || (lastRead.bits =/= lineAddrs(i)))
    )

    MuxCase(
      MakeInvalid(UInt(p.lsuAddrBits.W)),
      (0 until bytesPerSlot).map(i => lineActive(i) -> MakeValid(!pendingVector(), addrs(i)))
    )
  }

  def vectorUpdate(rvv2lsu: Rvv2Lsu): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op               := op
    result.rd               := rd
    result.store            := store
    result.pc               := pc
    result.pendingWriteback := pendingWriteback
    result.baseAddr         := baseAddr
    result.elemStride       := elemStride
    result.segmentStride    := segmentStride
    result.indexParitions   := indexParitions
    result.vectorLoop       := vectorLoop.nextSubvector()
    result.elemWidth        := elemWidth
    result.sew              := sew

    val segmentBaseAddr = baseAddr + (segmentStride * vectorLoop.segment.curr)(p.lsuAddrBits - 1, 0)
    val bitsPerSlot     = bytesPerSlot * 8
    val indices         = MuxUpTo1H(
      rvv2lsu.idx.bits.data,
      Seq(
        // 2 of 2
        ((indexParitions === 2.U) && (vectorLoop.lmul.curr(0) === 1.U)) -> (rvv2lsu.idx.bits
          .data(bitsPerSlot - 1, bitsPerSlot / 2)),
        // 2 of 4
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 1.U)) -> (rvv2lsu.idx.bits
          .data(bitsPerSlot / 2 - 1, bitsPerSlot / 4)),
        // 3 of 4
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 2.U)) -> (rvv2lsu.idx.bits
          .data(bitsPerSlot * 3 / 4 - 1, bitsPerSlot / 2)),
        // 4 of 4
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 3.U)) -> (rvv2lsu.idx.bits
          .data(bitsPerSlot - 1, bitsPerSlot * 3 / 4))
      )
    )

    val shouldUpdate = LsuOp.isNonindexedVector(op) ||
      (!vectorLoop.subvector.isEnabled()) ||
      rvv2lsu.idx.valid
    val newActiveBytes = Mux(
      shouldUpdate && LsuOp.isVector(op) && rvv2lsu.mask.valid,
      VecInit(rvv2lsu.mask.bits.asBools),
      VecInit.fill(bytesPerSlot)(false.B)
    )

    val updateAddrs = MuxUpTo1H(
      addrs,
      Seq(
        op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
          ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
          ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(
          LsuOp.VLOAD_OINDEXED,
          LsuOp.VLOAD_UINDEXED,
          LsuOp.VSTORE_OINDEXED,
          LsuOp.VSTORE_UINDEXED
        ) ->
          ComputeIndexedAddrs(bytesPerSlot, segmentBaseAddr, indices, elemWidth, sew)
      )
    )

    result.active := VecInit.tabulate(bytesPerSlot)(i => active(i) || newActiveBytes(i))

    result.addrs := VecInit.tabulate(bytesPerSlot)(i =>
      Mux(newActiveBytes(i), updateAddrs(i), addrs(i))
    )

    result.data := Mux(
      shouldUpdate && LsuOp.isVector(op) && rvv2lsu.vregfile.valid,
      UIntToVec(rvv2lsu.vregfile.bits.data, 8),
      data
    )

    result
  }

  // Updates the slot based on a previous read.
  def loadUpdate(lineAddr: UInt, lineData: UInt): LsuSlot = {
    // TODO(derekjchow): Check ordering semantics
    val lineAddrs  = lineAddresses()
    val lineActive = VecInit(
      (0 until bytesPerSlot).map(i =>
        active(i) && // Update only if active
          (lineAddrs(i) === lineAddr)
      )
    ) // Line must match read line
    val lineDataVec  = UIntToVec(lineData, 8)
    val gatheredData = Gather(elemAddresses(), lineDataVec)

    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op               := op
    result.rd               := rd
    result.store            := store
    result.pc               := pc
    result.baseAddr         := baseAddr
    result.addrs            := addrs
    result.pendingWriteback := pendingWriteback
    result.active           := (0 until bytesPerSlot).map(i => active(i) & ~lineActive(i))
    result.data             := VecInit(
      (0 until bytesPerSlot).map(i => Mux(lineActive(i), gatheredData(i), data(i)))
    )
    result.elemStride     := elemStride
    result.segmentStride  := segmentStride
    result.elemWidth      := elemWidth
    result.sew            := sew
    result.indexParitions := indexParitions
    result.vectorLoop     := vectorLoop

    result
  }

  // If the load transaction is finished, but the result needs to be written
  // back to the regfile.
  def shouldWriteback(): Bool = {
    !pendingVector() && !active.reduce(_ || _) && pendingWriteback
  }

  // Updates the slot if its result is written back to the regfile.
  def writebackUpdate(): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op            := op
    result.store         := store
    result.pc            := pc
    result.addrs         := addrs
    result.active        := active
    result.data          := data
    result.elemStride    := elemStride
    result.segmentStride := segmentStride
    result.elemWidth     := elemWidth
    result.sew           := sew

    val vectorLoopNext     = vectorLoop.nextVector()
    val vectorWriteback    = vectorLoop.isActive()
    val finished           = vectorLoopNext.lmul.isFull()
    val finishedVectorLoop = Wire(new LsuVectorLoop)
    finishedVectorLoop                := vectorLoop
    finishedVectorLoop.subvector.curr := vectorLoop.subvector.max
    finishedVectorLoop.segment.curr   := vectorLoop.segment.max
    finishedVectorLoop.lmul.curr      := vectorLoop.lmul.max

    result.indexParitions   := indexParitions
    result.vectorLoop       := Mux(finished, finishedVectorLoop, vectorLoopNext)
    result.pendingWriteback := !finished

    // TODO(davidgao): absorb baseAddr offset computation into vectorLoop
    val lmulUpdate = vectorWriteback && vectorLoop.segment.isFull()
    result.baseAddr := MuxCase(
      baseAddr,
      Seq(
        !lmulUpdate -> baseAddr,
        // For Unit and strided updates
        op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
          (baseAddr + (vectorLoop.segment.max * 16.U) + 16.U),
        op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
          MuxUpTo1H(
            baseAddr + (elemStride * bytesPerSlot.U),
            Seq(
              (elemWidth === "b000".U) ->
                (baseAddr + (elemStride * bytesPerSlot.U)),
              (elemWidth === "b101".U) ->
                (baseAddr + (elemStride * (bytesPerSlot / 2).U)),
              (elemWidth === "b110".U) ->
                (baseAddr + (elemStride * (bytesPerSlot / 4).U))
            )
          )
        // (baseAddr + (vectorLoop.segment.max * elemStride)(31, 0)),

        // Indexed don't have base addr changed.
      )
    )
    result.rd := result.vectorLoop.rd

    result
  }

  def scatter(lineAddr: UInt): (Vec[UInt], Vec[Bool], Vec[Bool]) = {
    val canScatter = store && (!LsuOp.isVector(op) || !pendingVector())
    val lineAddrs  = lineAddresses()
    val lineActive = VecInit(
      (0 until bytesPerSlot).map(i => canScatter && active(i) & (lineAddrs(i) === lineAddr))
    )
    Scatter(lineActive, elemAddresses(), data)
  }

  def storeUpdate(selected: Vec[Bool]): LsuSlot = {
    assert(selected.length == active.length)
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op               := op
    result.rd               := rd
    result.store            := store
    result.pc               := pc
    result.pendingWriteback := pendingWriteback
    result.active           := (0 until bytesPerSlot).map(i => active(i) & ~selected(i))
    result.baseAddr         := baseAddr
    result.addrs            := addrs
    result.data             := data
    result.elemStride       := elemStride
    result.segmentStride    := segmentStride
    result.elemWidth        := elemWidth
    result.sew              := sew
    result.indexParitions   := indexParitions
    result.vectorLoop       := vectorLoop
    result
  }

  def scalarLoadResult(): UInt = {
    val word = Cat(data(3), data(2), data(1), data(0))
    val half = Cat(data(1), data(0))
    val byte = data(0)
    // Sign extends the result of a load operation when necessary.
    val halfSigned = Wire(SInt(32.W))
    halfSigned := half.asSInt
    val byteSigned = Wire(SInt(32.W))
    byteSigned := byte.asSInt
    MuxLookup(op, 0.U)(
      Seq(
        LsuOp.LB    -> byteSigned.asUInt,
        LsuOp.LBU   -> byte,
        LsuOp.LH    -> halfSigned.asUInt,
        LsuOp.LHU   -> half,
        LsuOp.LW    -> word,
        LsuOp.FLOAT -> word
      )
    )
  }

  override def toPrintable: Printable = {
    val lines =
      (0 until bytesPerSlot).map(i => cf"  $i: ${active(i)}, 0x${addrs(i)}%x, 0x${data(i)}%x\n")
    cf"store: $store\n  op: ${op}\n  pc: 0x${pc}%x\n" +
      cf"  baseAddr: 0x${baseAddr}%x\n" +
      cf"  pendingWriteback: ${pendingWriteback}\n" +
      cf"  vectorLoop:\n${vectorLoop.toPrintable}" +
      cf"  elemWidth: 0b${elemWidth}%b elemStride: ${elemStride}\n" +
      lines.reduce(_ + _)
  }
}

object LsuSlot {
  def inactive(p: Parameters, bytesPerSlot: Int): LsuSlot = {
    0.U.asTypeOf(new LsuSlot(p, bytesPerSlot))
  }

  def fromLsuUOp(uop: LsuUOp, p: Parameters, bytesPerSlot: Int): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op    := uop.op
    result.rd    := uop.rd
    result.store := uop.store
    result.pc    := uop.pc
    if (p.enableRvv) {
      val effectiveLmul = MuxCase(
        uop.emul_data.getOrElse(0.U)(1, 0),
        Seq(
          // Treat fractional EMULs as EMUL=1
          (uop.emul_data.getOrElse(0.U)(2)) -> 0.U(2.W)
        )
      )
      val origLmul = MuxCase(
        uop.emul_data_orig.getOrElse(0.U)(1, 0),
        Seq(
          // Treat fractional EMULs as EMUL=1
          (uop.emul_data_orig.getOrElse(0.U)(2)) -> 0.U(2.W)
        )
      )

      val nfields = Mux(LsuOp.isVector(uop.op), uop.nfields.get, 0.U)
      // Determine number of rvv2lsu interactions required for one vector for
      // indexed loads. This occurs when the index dtype is greater than data
      // dtype.
      val elemWidth      = uop.elemWidth.get
      val elemMultiplier = MuxUpTo1H(
        1.U,
        Seq(
          // 8-bit data, 16-bit indices
          ((elemWidth === "b101".U) && (uop.sew.get === 0.U)) -> 2.U,
          // 8-bit data, 32-bit indices
          ((elemWidth === "b110".U) && (uop.sew.get === 0.U)) -> 4.U,
          // 16-bit data, 32-bit indices
          ((elemWidth === "b110".U) && (uop.sew.get === 1.U)) -> 2.U
        )
      )
      val max_subvector = MuxUpTo1H(
        1.U,
        Seq(
          ((elemMultiplier === 2.U) && (uop.emul_data.get.asSInt >= 0.S))   -> 2.U,
          ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt >= 0.S))   -> 4.U,
          ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt === -1.S)) -> 2.U
        )
      )
      // [0..x] data vecs we can operate on with one index vec
      result.indexParitions := MuxUpTo1H(
        1.U,
        Seq(
          // 16-bit data, 8-bit indices
          ((elemWidth === "b000".U) && (uop.sew.get === 1.U)) -> 2.U,
          // 32-bit data, 8-bit indices
          ((elemWidth === "b000".U) && (uop.sew.get === 2.U)) -> 4.U,
          // 32-bit data, 16-bit indices
          ((elemWidth === "b101".U) && (uop.sew.get === 2.U)) -> 2.U
        )
      )
      result.vectorLoop := MakeWireBundle[LsuVectorLoop](
        new LsuVectorLoop,
        _.subvector -> LoopingCounter(
          MuxCase(
            0.U,
            Seq(
              LsuOp.isIndexedVector(uop.op) -> max_subvector,
              LsuOp.isVector(uop.op)        -> 1.U
            )
          )
        ),
        _.segment -> LoopingCounter(Mux(LsuOp.isVector(uop.op), nfields, 0.U)),
        _.lmul    -> LoopingCounter(Mux(LsuOp.isVector(uop.op), (1.U(4.W) << effectiveLmul), 0.U)),
        _.lmul_orig -> (1.U(4.W) << origLmul),
        _.rdStart   -> uop.rd,
        _.rd        -> uop.rd
      )
    } else {
      result.indexParitions := 0.U
      result.vectorLoop     := 0.U.asTypeOf(result.vectorLoop)
    }

    // All vector ops require writeback. Lsu needs to inform RVV core store uop
    // has completed.
    result.pendingWriteback := !uop.store || LsuOp.isVector(uop.op)

    val active = MuxUpTo1H(
      0.U(bytesPerSlot.W),
      Seq(
        uop.op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB)   -> "b1".U(bytesPerSlot.W),
        uop.op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH)   -> "b11".U(bytesPerSlot.W),
        uop.op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) -> "b1111".U(bytesPerSlot.W),
        // Vector
        LsuOp.isVector(uop.op) -> 0.U(bytesPerSlot.W)
      )
    )
    result.active := active.asBools

    // Compute addrs
    result.baseAddr  := uop.addr
    result.elemWidth := uop.elemWidth.getOrElse(0.U(3.W))
    result.sew       := uop.sew.getOrElse(0.U(3.W))
    result.addrs     := Mux(
      uop.op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED),
      ComputeStridedAddrs(bytesPerSlot, uop.addr, uop.data, uop.elemWidth.getOrElse(0.U(3.W))),
      VecInit((0 until bytesPerSlot).map(i => uop.addr + i.U))
    )

    val unitStride = Mux(
      uop.op.isOneOf(
        LsuOp.VLOAD_OINDEXED,
        LsuOp.VLOAD_UINDEXED,
        LsuOp.VSTORE_OINDEXED,
        LsuOp.VSTORE_UINDEXED
      ),
      // Indexed load. The unit stride also controls segment stride.
      MuxUpTo1H(
        1.U,
        Seq(
          (result.sew === "b000".U) -> 1.U, // 1-byte elements
          (result.sew === "b001".U) -> 2.U, // 2-byte elements
          (result.sew === "b010".U) -> 4.U  // 4-byte elements
        )
      ),
      // Non-indexed load.
      MuxUpTo1H(
        1.U,
        Seq(
          (uop.elemWidth.getOrElse(3.U) === "b000".U) -> 1.U, // 1-byte elements
          (uop.elemWidth.getOrElse(3.U) === "b101".U) -> 2.U, // 2-byte elements
          (uop.elemWidth.getOrElse(3.U) === "b110".U) -> 4.U  // 4-byte elements
        )
      )
    )

    result.segmentStride := unitStride
    result.elemStride    := Mux(
      uop.op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT),
      unitStride + (uop.nfields.getOrElse(3.U) * unitStride),
      uop.data
    )

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
  val pc         = UInt(32.W)
  val addr       = UInt(32.W)
  val adrx       = UInt(32.W)
  val data       = UInt(32.W)
  val index      = UInt(5.W)
  val size       = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val fullsize   = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val write      = Bool()
  val sext       = Bool()
  val iload      = Bool()
  val fencei     = Bool()
  val flushat    = Bool()
  val flushall   = Bool()
  val sldst      = Bool() // scalar load/store cached
  val vldst      = Bool() // vector load/store
  val fldst      = Bool() // float load/store
  val regionType = MemoryRegionType()
  val mask       = UInt(p.lsuDataBytes.W)
  val last       = Bool()
}

class LsuReadData(p: Parameters) extends Bundle {
  val addr       = UInt(32.W)
  val index      = UInt(5.W)
  val size       = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val fullsize   = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val sext       = Bool()
  val iload      = Bool()
  val sldst      = Bool()
  val fldst      = Bool()
  val regionType = MemoryRegionType()
  val mask       = UInt(p.lsuDataBytes.W)
  val last       = Bool()
}

object LsuBus extends ChiselEnum {
  val IBUS     = Value
  val DBUS     = Value
  val EXTERNAL = Value
}

class LsuRead(lineBits: Int) extends Bundle {
  val bus      = LsuBus()
  val lineAddr = UInt(lineBits.W)
}

object LsuRead {
  def apply(bus: LsuBus.Type, lineAddr: UInt): LsuRead = {
    val result = Wire(new LsuRead(lineAddr.getWidth))
    result.bus      := bus
    result.lineAddr := lineAddr
    result
  }
}

class FlushCmd extends Bundle {
  val all    = Bool()
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
  class LsuFault(p: Parameters) extends Bundle {
    val info  = new FaultInfo(p)
    val rd    = UInt(5.W)
    val op    = LsuOp()
    val store = Bool()
  }

  // Tie-offs
  io.vldst := 0.U

  val opQueue = Module(new CircularBufferMulti(new LsuUOp(p), p.instructionLanes, 4))
  opQueue.io.flush := false.B
  io.queueCapacity := opQueue.io.nSpace

  // Flush state
  // DispatchV2 will only flush on first slot, when LSU is inactive.

  val flushCmd = RegInit(MakeInvalid(new FlushCmd)) // Track pending flush + pc
  io.flush.valid  := flushCmd.valid
  io.flush.all    := flushCmd.bits.all
  io.flush.clean  := true.B
  io.flush.fencei := flushCmd.bits.fencei
  io.flush.pcNext := flushCmd.bits.pcNext

  flushCmd := MuxCase(
    flushCmd,
    Seq(
      // New flush command
      (io.req(0).fire && LsuOp.isFlush(io.req(0).bits.op))
        -> MakeValid(true.B, FlushCmd(io.req(0).bits)),
      // Finish flush command
      (io.flush.valid && io.flush.ready) -> MakeInvalid(new FlushCmd)
    )
  )

  // Accept one instruction per cycle.
  val queueSpace = opQueue.io.nSpace
  val validSum   = io.req.map(_.valid).scan(0.U(log2Ceil(p.instructionLanes + 1).W))(_ + _)
  for (i <- 0 until p.instructionLanes) {
    io.req(i).ready := (validSum(i) < queueSpace) && !flushCmd.valid
  }

  val ops = (0 until p.instructionLanes).map(i =>
    MakeValid(
      io.req(i).fire && !LsuOp.isFlush(io.req(i).bits.op),
      LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState)
    )
  )
  val alignedOps = Aligner(ops)

  opQueue.io.enqValid := PopCount(alignedOps.map(_.valid))
  opQueue.io.enqData  := alignedOps.map(_.bits)
  assert(opQueue.io.enqValid <= opQueue.io.nSpace)

  val nextSlot = LsuSlot.fromLsuUOp(opQueue.io.dataOut(0), p, 16)

  // Tracks if a read has been fired last cycle.
  val readFired = RegInit(MakeInvalid(new LsuRead(32 - nextSlot.elemBits)))
  val slot      = RegInit(LsuSlot.inactive(p, 16))

  val readData = MuxLookup(readFired.bits.bus, 0.U)(
    Seq(
      LsuBus.IBUS     -> io.ibus.rdata,
      LsuBus.DBUS     -> io.dbus.rdata,
      LsuBus.EXTERNAL -> io.ebus.dbus.rdata
    )
  )

  // ==========================================================================
  // Vector update
  val vectorUpdatedSlot = if (p.enableRvv) {
    io.rvv2lsu.get(0).ready := slot.pendingVector()
    io.rvv2lsu.get(1).ready := false.B
    slot.vectorUpdate(io.rvv2lsu.get(0).bits)
  } else {
    slot
  }

  // ==========================================================================
  // Transaction update
  val faultReg = RegInit(MakeInvalid(new LsuFault(p)))

  // First stage of load update: Update results based on bus read
  val loadUpdatedSlot =
    Mux(readFired.valid, slot.loadUpdate(readFired.bits.lineAddr, readData), slot)

  // Compute next target transaction
  val targetAddress =
    loadUpdatedSlot.targetAddress(MakeValid(readFired.valid, readFired.bits.lineAddr))
  val targetLine     = MakeValid(targetAddress.valid, targetAddress.bits(31, nextSlot.elemBits))
  val targetLineAddr = targetLine.bits << 4
  val itcm           = p.m
    .filter(_.memType == MemoryRegionType.IMEM)
    .map(_.contains(targetLineAddr))
    .reduceOption(_ || _)
    .getOrElse(false.B)
  val dtcm = p.m
    .filter(_.memType == MemoryRegionType.DMEM)
    .map(_.contains(targetLineAddr))
    .reduceOption(_ || _)
    .getOrElse(true.B)
  val peri = p.m
    .filter(_.memType == MemoryRegionType.Peripheral)
    .map(_.contains(targetLineAddr))
    .reduceOption(_ || _)
    .getOrElse(false.B)
  val external = !(itcm || dtcm || peri)
  assert(PopCount(Cat(itcm | dtcm | peri)) <= 1.U)

  val (wdata, wmask, wactive) = slot.scatter(targetLine.bits)

  val (opSize, alignedAddress) = LsuOp.opSize(slot.op, targetAddress.bits, p)

  // ibus data path
  io.ibus.valid := loadUpdatedSlot.activeTransaction() && itcm && !slot.store && !faultReg.valid
  io.ibus.addr  := targetLineAddr

  // dbus data path
  io.dbus.valid := dtcm && Mux(
    slot.store,
    slot.activeTransaction(),
    loadUpdatedSlot.activeTransaction()
  ) && !faultReg.valid
  io.dbus.write := slot.store
  io.dbus.pc    := slot.pc
  io.dbus.addr  := targetLineAddr
  io.dbus.adrx  := targetLineAddr
  io.dbus.size  := opSize
  io.dbus.wdata := Cat(wdata.reverse)
  io.dbus.wmask := Cat(wmask.reverse)

  // ebus data path
  io.ebus.dbus.valid := (external || peri) && Mux(
    slot.store,
    slot.activeTransaction(),
    loadUpdatedSlot.activeTransaction()
  ) && !faultReg.valid
  io.ebus.dbus.write := slot.store
  io.ebus.dbus.addr  := alignedAddress
  io.ebus.dbus.adrx  := targetLineAddr
  io.ebus.dbus.size  := opSize
  io.ebus.dbus.wdata := Cat(wdata.reverse)
  io.ebus.dbus.wmask := Cat(wmask.reverse)
  io.ebus.dbus.pc    := slot.pc
  io.ebus.internal   := peri

  val ibusFired = io.ibus.valid && io.ibus.ready
  val dbusFired = io.dbus.valid && io.dbus.ready
  val ebusFired = io.ebus.dbus.valid && io.ebus.dbus.ready
  assert(PopCount(Seq(ibusFired, dbusFired, ebusFired)) <= 1.U)
  val slotFired = ebusFired || dbusFired || ibusFired

  val readFiredValid =
    ibusFired || (dbusFired && !io.dbus.write) || (ebusFired && !io.ebus.dbus.write)
  readFired := MakeValid(
    readFiredValid,
    MuxCase(
      readFired.bits,
      Seq(
        (ibusFired)                        -> LsuRead(LsuBus.IBUS, targetLine.bits),
        (dbusFired && !io.dbus.write)      -> LsuRead(LsuBus.DBUS, targetLine.bits),
        (ebusFired && !io.ebus.dbus.write) -> LsuRead(LsuBus.EXTERNAL, targetLine.bits)
      )
    )
  )

  // Fault handling
  val ibusFault = Wire(Valid(new FaultInfo(p)))
  ibusFault.valid      := loadUpdatedSlot.activeTransaction() && itcm && slot.store
  ibusFault.bits.write := true.B
  ibusFault.bits.addr  := targetLineAddr
  ibusFault.bits.epc   := slot.pc

  io.fault.valid := faultReg.valid
  io.fault.bits  := faultReg.bits.info
  faultReg       := {
    val f             = Wire(Valid(new LsuFault(p)))
    val nextFaultInfo = MuxCase(
      MakeInvalid(new FaultInfo(p)),
      Seq(
        io.ebus.fault.valid -> io.ebus.fault,
        ibusFault.valid     -> ibusFault
      )
    )
    f.valid      := nextFaultInfo.valid
    f.bits.info  := nextFaultInfo.bits
    f.bits.rd    := slot.rd
    f.bits.op    := slot.op
    f.bits.store := slot.store
    f
  }

  // Transaction update
  val storeUpdate            = Mux(slotFired, wactive, VecInit.fill(16)(false.B))
  val transactionUpdatedSlot = Mux(slot.store, slot.storeUpdate(storeUpdate), loadUpdatedSlot)
  val lsu2RvvFire            = if (p.enableRvv) { io.lsu2rvv.get(0).fire }
  else { false.B }
  // For scalar stores: complete when transaction is done (slotFired && all bytes written)
  // For vector stores: complete when lsu2rvv handshake fires with last=1
  // These happen in different cycles, so we can't AND them together.
  val scalarStoreComplete = slotFired && slot.store && !slot.slotIdle() &&
    transactionUpdatedSlot.slotIdle() && !LsuOp.isVector(slot.op)
  val vectorStoreComplete = if (p.enableRvv) {
    lsu2RvvFire && io.lsu2rvv.get(0).bits.last
  } else { false.B }
  val storeComplete = scalarStoreComplete || vectorStoreComplete
  io.storeComplete := Mux(
    storeComplete && !io.ebus.fault.valid,
    MakeValid(slot.pc),
    MakeInvalid(UInt(p.programCounterBits.W))
  )

  // ==========================================================================
  // Writeback update

  val currentOp    = Mux(faultReg.valid, faultReg.bits.op, slot.op)
  val currentStore = Mux(faultReg.valid, faultReg.bits.store, slot.store)

  // Scalar writeback
  // Write back on error. io.fault.valid will mask
  io.rd.valid := ((faultReg.valid && LsuOp.isScalarLoad(faultReg.bits.op)) || slot
    .shouldWriteback()) &&
    currentOp.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.LH, LsuOp.LHU, LsuOp.LW)

  io.rd.bits.data := slot.scalarLoadResult()
  io.rd.bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)

  // Float writeback
  io.rd_flt.valid := ((faultReg.valid && !currentStore) || slot.shouldWriteback()) &&
    (currentOp === LsuOp.FLOAT)
  io.rd_flt.bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)
  io.rd_flt.bits.data := slot.scalarLoadResult()

  // Vector writeback
  if (p.enableRvv) {
    val faultDetected = faultReg.valid
    // If a fault occurs, we must still signal completion to the RVV core so it can
    // retire the instruction (and take the trap).
    val vectorFault = faultDetected && LsuOp.isVector(currentOp)

    io.lsu2rvv.get(0).valid := (slot.shouldWriteback() && LsuOp.isVector(currentOp)) || vectorFault
    io.lsu2rvv.get(0).bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)
    io.lsu2rvv.get(0).bits.data := Cat(slot.data.reverse)
    io.lsu2rvv.get(0).bits.last := (slot.shouldWriteback() || vectorFault) &&
      currentOp.isOneOf(
        LsuOp.VSTORE_UNIT,
        LsuOp.VSTORE_STRIDED,
        LsuOp.VSTORE_OINDEXED,
        LsuOp.VSTORE_UINDEXED
      )

    io.lsu2rvv.get(1).valid     := false.B
    io.lsu2rvv.get(1).bits.addr := 0.U
    io.lsu2rvv.get(1).bits.data := 0.U
    io.lsu2rvv.get(1).bits.last := true.B
  }

  val writebacksFired = Seq(io.rd.valid, io.rd_flt.valid) ++ (if (p.enableRvv) {
                                                                Seq(io.lsu2rvv.get(0).fire)
                                                              } else { Seq() })
  assert(PopCount(writebacksFired) <= 1.U)
  val writebackFired       = writebacksFired.reduce(_ || _)
  val writebackUpdatedSlot = slot.writebackUpdate()

  // TODO(derekjchow): Improve timing?
  opQueue.io.deqReady := Mux(slot.slotIdle() && (opQueue.io.nEnqueued > 0.U), 1.U, 0.U)

  // ==========================================================================
  // State transition

  // Assertions
  val vectorUpdate = io.rvv2lsu.map(_(0).fire).getOrElse(false.B)
  assert(!vectorUpdate || slot.pendingVector())
  assert(!writebackFired || (slot.shouldWriteback() || faultReg.valid))

  // Slot update
  val slotNext = MuxCase(
    slot,
    Seq(
      // Move to inactive if error.
      (faultReg.valid) -> LsuSlot.inactive(p, 16),
      // When inactive, dequeue if possible
      (slot.slotIdle() && (opQueue.io.nEnqueued > 0.U)) -> nextSlot,
      // Vector update.
      vectorUpdate -> vectorUpdatedSlot,
      // Active transaction update.
      slot.activeTransaction() -> transactionUpdatedSlot,
      // Writeback update.
      writebackFired -> writebackUpdatedSlot
    )
  )

  slot := slotNext

  io.active := !slot.slotIdle() || (opQueue.io.nEnqueued =/= 0.U)
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

  def next(
    write: Bool,
    vectorIndex: Option[ValidIO[UInt]],
    vectorData: Option[ValidIO[UInt]],
    vectorMask: Option[ValidIO[Bool]],
    start: Bool,
    respData: ValidIO[UInt],
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
    val noBadTransitions =
      noBadInvalidate && noBadData && noBadStart && noBadResp && noBadWb && noBadSkipWb

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

    val retBase = MakeWireBundle[LsuCell](
      new LsuCell(p),
      _       -> this,
      _.state -> MuxUpTo1H(
        state,
        Seq(
          doInvalidate -> LsuCellState.DONE,
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
      _.data -> MuxUpTo1H(
        data,
        Seq(
          (!write && doResp) -> respData.bits,
          (write && doData)  -> vectorData.map { _.bits }.getOrElse(this.data)
        )
      )
    )
    val ret = vectorIndex
      .map { x =>
        Mux(x.valid, retBase.setAddr(addr + vectorIndex.get.bits), retBase)
      }
      .getOrElse(retBase)

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

  def initDone(): LsuCell = {
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _       -> this,
      _.state -> LsuCellState.DONE
    )
  }

  def initSkip(): LsuCell = {
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _       -> this,
      _.state -> LsuCellState.W_WB
    )
  }

  def initLoad(addr: UInt, needData: Bool): LsuCell = {
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _       -> this,
      _.state -> Mux(needData, LsuCellState.W_DATA, LsuCellState.W_START)
    ).setAddr(addr)
  }

  def initScalarStore(addr: UInt, data: UInt): LsuCell = {
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _       -> this,
      _.state -> LsuCellState.W_START,
      _.data  -> data
    ).setAddr(addr)
  }

  def initVectorStore(addr: UInt): LsuCell = {
    assert(p.enableRvv)
    MakeWireBundle[LsuCell](
      new LsuCell(p),
      _       -> this,
      _.state -> LsuCellState.W_DATA
    ).setAddr(addr)
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
  val windowSizeNormal       = math.min(nCells, p.lsuDataBytes)
  val windowSizeStrict       = math.min(windowSizeNormal, p.lsuStrictWindowBytes)
  val windowIndexWidthNormal = log2Ceil(windowSizeNormal)
  val windowIndexWidthStrict = log2Ceil(windowSizeStrict)

  // Simplified bus request interface before bookkeeping.
  class BusReq extends Bundle {
    val rowAddr = UInt(p.dbusRowAddrBits.W)
    val write   = Bool()
    val wdata   = UInt(p.lsuDataBits.W)
    val wmask   = UInt(p.lsuDataBytes.W)
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

    val float = Option.when(p.enableFloat)(new Bundle {
      val writeback = Bool()
    })

    val vector = Option.when(p.enableRvv)(new Bundle {
      val dataEew                   = LsuVectorElementWidth()
      val indexEew                  = LsuVectorElementWidth()
      val segmentStep               = UInt(3.W)
      val emulStep                  = UInt(indexWidth.W)
      val vectorsPerSegMinusOneOrig = UInt(3.W)
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

    def isDone(): Bool = {
      cells.forall(_.state === LsuCellState.DONE) &&
      vector.map(!_.writebackActiveCells.valid).getOrElse(true.B)
    }

    // The second ret val indicates which cells are affected by the new tx
    def maybeStart(): (ValidIO[BusReq], UInt, UInt) = {
      def windowFn(size: Int): Vec[LsuCell] = {
        VecInit.tabulate(size) { i =>
          val index = leadIndex + i.U
          Mux(index < nCells.U(ctrWidth.W), cells(index), LsuCell(p))
        }
      }

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

      // Returns: (reqValid, wData, wMask, started, moveLead)
      def maybeStartNormal(window: Vec[LsuCell]): (Bool, UInt, UInt, UInt, UInt) = {
        val reqValid           = reqValidFn(window)
        val cellCanStartWindow = cellCanStartWindowFn(window.length)

        // bundle(i)(j) is whether window(i) is affected by byte(j)
        val bundle = VecInit.tabulate(window.length) { i =>
          Mux(cellCanStartWindow(i), window(i).mask, 0.U)
        }
        val wData = VecInit
          .tabulate(p.lsuDataBytes) { j =>
            // Priority mux, slow
            MuxCase(
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
            cellCanStart(i) &&
            // if we're reading, we can always snoop. This implies always reading
            // a full row.
            // if we're writing, we can only snoop on active bytes.
            (!write || (cells(i).mask & wMask) =/= 0.U)
          }
          .asUInt
        // Priority mux, slow
        val moveLead = MuxCase(
          window.length.U(ctrWidth.W),
          (0 until window.length).map { i =>
            (
              window(i).state === LsuCellState.W_DATA || (
                window(i).state === LsuCellState.W_START &&
                  (window(i).rowAddr =/= rowAddr || !reqValid)
              )
            ) -> i.U(ctrWidth.W)
          }
        )

        (reqValid, wData, wMask, started, moveLead)
      }

      // Returns: (reqValid, wData, wMask, started, moveLead)
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
        // Priority mux, slow
        val moveLead = MuxCase(
          windowSizeStrict.U(ctrWidth.W),
          (0 until windowSizeStrict).map { i =>
            (
              window(i).state === LsuCellState.W_DATA || (
                window(i).state === LsuCellState.W_START &&
                  (!cellActive(i) || !reqValid)
              )
            ) -> i.U(ctrWidth.W)
          }
        )

        (reqValid, wData, wMask, started, moveLead)
      }

      val (reqValidNormal, wDataNormal, wMaskNormal, startedNormal, moveLeadNormal) =
        maybeStartNormal(windowFn(windowSizeNormal))
      val (reqValidStrict, wDataStrict, wMaskStrict, startedStrict, moveLeadStrict) =
        maybeStartStrict(windowFn(windowSizeStrict))

      val tx = MakeWireBundle[ValidIO[BusReq]](
        Valid(new BusReq),
        _.valid        -> Mux(strictMode, reqValidStrict, reqValidNormal),
        _.bits.rowAddr -> rowAddr,
        _.bits.write   -> write,
        // Write signals are junk when we're reading
        _.bits.wdata -> Mux(strictMode, wDataStrict, wDataNormal),
        _.bits.wmask -> Mux(strictMode, wMaskStrict, wMaskNormal)
      )
      val started  = Mux(strictMode, startedStrict, startedNormal)
      val moveLead = Mux(strictMode, moveLeadStrict, moveLeadNormal)

      (tx, Mux(tx.valid, started, 0.U), moveLead)
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
          LsuScalarWritebackMode.U4 -> MakeValid(scalar32Valid, scalar32)
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
        x := MakeWireBundle[ValidIO[Lsu2Rvv]](
          Valid(new Lsu2Rvv(p)),
          _.valid -> vectorWritebackValid,
          // TODO: materialize this counter if needed for timing
          _.bits.addr -> (rd + vector.get.writebackSegment.curr * (vector.get.vectorsPerSegMinusOneOrig +& 1.U) + vector.get.writebackEmul.curr),
          _.bits.data -> vectorWbData,
          // This means last writeback of this vreg.
          // TODO: subvector
          _.bits.last -> write
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
      starts: UInt,
      moveLead: UInt,
      resp: Bool,
      fault: Bool,
      respRowAddr: UInt,
      respData: Vec[UInt],
      respMask: UInt,
      writebacks: UInt,
      vectorData: Option[ValidIO[Rvv2Lsu]]
    ): State = {
      val vectorDataBytes = Option.when(p.enableRvv) {
        VecInit.tabulate(p.rvvVlenb) { i =>
          vectorData.get.bits.vregfile.bits.data(i * 8 + 7, i * 8)
        }
      }
      val vectorDataActive = Option.when(p.enableRvv) {
        val enableLane = MuxLookup(
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
        VecInit.tabulate(p.rvvVlenb) { i =>
          Mux(enableLane(i), UIntToOH(vector.get.dataActiveCells(i)), 0.U)
        }
      }
      val vectorIndices = Option.when(p.enableRvv) {
        val allIndices  = vectorData.get.bits.idx.bits.data
        val selectFrom2 = (
          (vector.get.indexEew === LsuVectorElementWidth.E8 && vector.get.dataEew === LsuVectorElementWidth.E16) ||
            (vector.get.indexEew === LsuVectorElementWidth.E16 && vector.get.dataEew === LsuVectorElementWidth.E32)
        )
        val selectFrom4 = (
          vector.get.indexEew === LsuVectorElementWidth.E8 &&
            vector.get.dataEew === LsuVectorElementWidth.E32
        )
        val selected = MuxCase(
          allIndices,
          Seq(
            (selectFrom2 && vector.get.dataEmul.curr(0)) -> Cat(
              0.U((p.rvvVlen / 2).W),
              allIndices(p.rvvVlen - 1, p.rvvVlen / 2)
            ),
            (selectFrom4 && vector.get.dataEmul.curr(1, 0) === "b01".U) -> Cat(
              0.U((p.rvvVlen * 3 / 4).W),
              allIndices(p.rvvVlen / 2 - 1, p.rvvVlen / 4)
            ),
            (selectFrom4 && vector.get.dataEmul.curr(1, 0) === "b10".U) -> Cat(
              0.U((p.rvvVlen * 3 / 4).W),
              allIndices(p.rvvVlen * 3 / 4 - 1, p.rvvVlen / 2)
            ),
            (selectFrom4 && vector.get.dataEmul.curr(1, 0) === "b11".U) -> Cat(
              0.U((p.rvvVlen * 3 / 4).W),
              allIndices(p.rvvVlen - 1, p.rvvVlen * 3 / 4)
            )
          )
        )
        val concatenated = VecInit.tabulate(p.rvvVlenb) { i =>
          val i_ei8  = i
          val i_ei16 = i % (p.rvvVlenb / 2)
          val i_ei32 = i % (p.rvvVlenb / 4)

          MuxLookup(vector.get.indexEew, WireInit(UInt(32.W), DontCare))(
            Seq(
              LsuVectorElementWidth.E8  -> Cat(0.U(24.W), selected(i_ei8 * 8 + 7, i_ei8 * 8)),
              LsuVectorElementWidth.E16 -> Cat(0.U(16.W), selected(i_ei16 * 16 + 15, i_ei16 * 16)),
              LsuVectorElementWidth.E32 -> selected(i_ei32 * 32 + 31, i_ei32 * 32)
            )
          )
        }
        VecInit.tabulate(p.rvvVlenb) { i =>
          MuxLookup(vector.get.dataEew, WireInit(UInt(32.W), DontCare))(
            Seq(
              LsuVectorElementWidth.E8  -> concatenated(i),
              LsuVectorElementWidth.E16 -> concatenated(i / 2),
              LsuVectorElementWidth.E32 -> concatenated(i / 4)
            )
          )
        }
      }

      val cellsNext = VecInit.tabulate(nCells) { i =>
        // If we're in strict mode, or we're writing, there's no snooping.
        // In strict mode respMask only includes what's bundled in the tx,
        // but in non-strict writing, respMask also includes skippable cells.
        val cellAcceptResp = resp && Mux(
          strictMode || write,
          respMask(i),
          cells(i).rowAddr === respRowAddr && (
            cells(i).state === LsuCellState.W_START ||
              cells(i).state === LsuCellState.W_RESP
          )
        )
        val cellRespData = MuxUpTo1H(
          WireInit(UInt(8.W), DontCare),
          (0 until p.lsuDataBytes).map { j =>
            cells(i).mask(j) -> respData(j)
          }
        )
        val acceptVectorData = Option.when(p.enableRvv) {
          vectorData.get.valid &&
          vectorDataActive.get.map(_(i)).reduce(_ || _) &&
          cells(i).state === LsuCellState.W_DATA
        }

        val cellVectorIndex = Option.when(p.enableRvv) {
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
        if (p.enableRvv) {
          assert(
            !acceptVectorData.get ||
              !write ||
              vectorData.get.bits.vregfile.valid
          )
        }
        val cellVectorData = Option.when(p.enableRvv) {
          MuxUpTo1H(
            MakeInvalid(UInt(8.W)),
            (0 until p.rvvVlenb).map { j =>
              (
                vectorData.get.valid &&
                  vectorData.get.bits.vregfile.valid &&
                  vectorDataActive.get(j)(i) &&
                  cells(i).state === LsuCellState.W_DATA
              ) -> MakeValid(vectorDataBytes.get(j))
            }
          )
        }
        if (p.enableRvv) {
          assert(
            !acceptVectorData.get ||
              vectorData.get.bits.mask.valid
          )
        }
        val cellVectorMask = Option.when(p.enableRvv) {
          MuxUpTo1H(
            MakeInvalid(Bool()),
            (0 until p.rvvVlenb).map { j =>
              (
                vectorData.get.valid &&
                  vectorData.get.bits.mask.valid &&
                  vectorDataActive.get(j)(i) &&
                  cells(i).state === LsuCellState.W_DATA
              ) -> MakeValid(vectorData.get.bits.mask.bits(j))
            }
          )
        }
        val cellWriteback = Mux(skipWriteback, cellAcceptResp, writebacks(i))
        cells(i).next(
          write = write,
          vectorIndex = cellVectorIndex,
          vectorData = cellVectorData,
          vectorMask = cellVectorMask,
          start = starts(i),
          respData = MakeValid(cellAcceptResp, cellRespData),
          wb = cellWriteback
        )
      }
      val ret = MakeWireBundle[State](
        new State(),
        _           -> this,
        _.faulted   -> (faulted || fault),
        _.cells     -> cellsNext,
        _.leadIndex -> (leadIndex + moveLead),
        _.rowAddr   -> cellsNext(leadIndex + moveLead).rowAddr
      )
      ret.vector.foreach { x =>
        val curr = vector.get
        x.dataSubvector := Mux(
          vectorData.get.valid,
          curr.dataSubvector.next(),
          curr.dataSubvector
        )
        val nextDataSegment = vectorData.get.valid && curr.dataSubvector.isFull()
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

    def initInt(pc: UInt, addr: UInt, write: Boolean): State = {
      val ret = MakeWireBundle[State](
        new State(),
        _            -> this,
        _.pc         -> pc,
        _.write      -> write.B,
        _.faulted    -> false.B,
        _.strictMode -> false.B,
        // rd to be filled by caller
        _.skipWriteback -> write.B,
        // scalarWritebackMode to be filled by caller
        // cells to be filled by caller
        _.leadIndex -> 0.U,
        _.rowAddr   -> addr(p.lsuAddrBits - 1, p.dbusOffsetBits)
      )
      ret.float.foreach { x =>
        x.writeback := false.B
      }
      ret.vector.foreach { x =>
        x.segmentStep                := 0.U
        x.emulStep                   := 0.U
        x.dataSubvector              := LoopingCounter(0.U)
        x.dataSubvectorTheoretical   := 0.U
        x.dataSegment                := LoopingCounter(0.U)
        x.dataEmul                   := LoopingCounter(0.U)
        x.writebackSegment           := LoopingCounter(0.U)
        x.writebackEmul              := LoopingCounter(0.U)
        x.writebackActiveCells.valid := false.B
      }

      ret
    }

    def initIntLoad(
      pc: UInt,
      addr: UInt,
      rd: UInt,
      bytes: Int,
      sext: Boolean
    ): State = {
      MakeWireBundle[State](
        new State(),
        _                     -> initInt(pc, addr, write = false),
        _.rd                  -> rd,
        _.scalarWritebackMode -> ((bytes, sext) match {
          case (1, false) => LsuScalarWritebackMode.U1
          case (1, true)  => LsuScalarWritebackMode.S1
          case (2, false) => LsuScalarWritebackMode.U2
          case (2, true)  => LsuScalarWritebackMode.S2
          case (4, _)     => LsuScalarWritebackMode.U4
          // TODO: add assertion for this.
          case _ => LsuScalarWritebackMode.NONE
        }),
        _.cells -> VecInit.tabulate(nCells) { i =>
          if (i < bytes) {
            cells(i).initLoad(addr + i.U, needData = false.B)
          } else {
            cells(i).initDone()
          }
        }
      )
    }

    def initIntStore(pc: UInt, addr: UInt, data: UInt, bytes: Int): State = {
      MakeWireBundle[State](
        new State(),
        _ -> initInt(pc, addr, write = true),
        // _.rd is untouched
        _.scalarWritebackMode -> LsuScalarWritebackMode.NONE,
        _.cells               -> VecInit.tabulate(nCells) { i =>
          if (i < bytes) {
            cells(i).initScalarStore(addr + i.U, data(i * 8 + 7, i * 8))
          } else {
            cells(i).initDone()
          }
        }
      )
    }

    def initFloat(pc: UInt, addr: UInt, write: Boolean): State = {
      val ret = MakeWireBundle[State](
        new State(),
        _            -> this,
        _.pc         -> pc,
        _.write      -> write.B,
        _.faulted    -> false.B,
        _.strictMode -> false.B,
        // rd to be filled by caller
        _.skipWriteback -> write.B,
        // scalarWritebackMode to be filled by caller
        // cells to be filled by caller
        _.leadIndex -> 0.U,
        _.rowAddr   -> addr(p.lsuAddrBits - 1, p.dbusOffsetBits)
      )
      ret.vector.foreach { x =>
        x.segmentStep                := 0.U
        x.emulStep                   := 0.U
        x.dataSubvector              := LoopingCounter(0.U)
        x.dataSubvectorTheoretical   := 0.U
        x.dataSegment                := LoopingCounter(0.U)
        x.dataEmul                   := LoopingCounter(0.U)
        x.writebackSegment           := LoopingCounter(0.U)
        x.writebackEmul              := LoopingCounter(0.U)
        x.writebackActiveCells.valid := false.B
      }

      ret
    }

    def initFloatLoad(
      pc: UInt,
      addr: UInt,
      rd: UInt,
      bytes: Int
    ): State = {
      // Only 4 bytes is supported atm.
      // TODO: assert
      val ret = MakeWireBundle[State](
        new State(),
        _                     -> initFloat(pc, addr, write = false),
        _.rd                  -> rd,
        _.scalarWritebackMode -> LsuScalarWritebackMode.U4,
        _.cells               -> VecInit.tabulate(nCells) { i =>
          if (i < bytes) {
            cells(i).initLoad(addr + i.U, needData = false.B)
          } else {
            cells(i).initDone()
          }
        }
      )
      ret.float.foreach { x =>
        x.writeback := true.B
      }

      ret
    }

    def initFloatStore(pc: UInt, addr: UInt, data: UInt, bytes: Int): State = {
      // Only 4 bytes is supported atm.
      // TODO: assert
      val ret = MakeWireBundle[State](
        new State(),
        _                     -> initFloat(pc, addr, write = true),
        _.scalarWritebackMode -> LsuScalarWritebackMode.NONE,
        _.cells               -> VecInit.tabulate(nCells) { i =>
          if (i < bytes) {
            cells(i).initScalarStore(addr + i.U, data(i * 8 + 7, i * 8))
          } else {
            cells(i).initDone()
          }
        }
      )
      ret.float.foreach { x =>
        x.writeback := false.B
      }

      ret
    }

    def initVectorUS(
      pc: UInt,
      addr: UInt,
      vd: UInt,
      nfields: UInt,
      maxVectorPerSegment: UInt,
      maxVectorPerSegmentOrig: UInt,
      elemWidth: UInt,
      write: Boolean
    ): State = {
      val ret = MakeWireBundle[State](
        new State(),
        _                     -> this,
        _.pc                  -> pc,
        _.write               -> write.B,
        _.faulted             -> false.B,
        _.strictMode          -> false.B,
        _.rd                  -> vd,
        _.skipWriteback       -> false.B,
        _.scalarWritebackMode -> LsuScalarWritebackMode.NONE,
        // cells to be filled by caller
        _.leadIndex -> 0.U,
        _.rowAddr   -> addr(p.lsuAddrBits - 1, p.dbusOffsetBits)
      )
      ret.float.foreach { x =>
        x.writeback := false.B
      }
      ret.vector.foreach { x =>
        // TODO: assert
        x.segmentStep := MuxLookup(elemWidth, WireInit(UInt(3.W), DontCare))(
          Seq(
            "b000".U -> 1.U,
            "b101".U -> 2.U,
            "b110".U -> 4.U
          )
        )
        x.emulStep := MuxLookup(elemWidth, WireInit(UInt(3.W), DontCare))(
          Seq(
            "b000".U -> (nfields * (p.rvvVlenb - 1).U + p.rvvVlenb.U),
            "b101".U -> (nfields * (p.rvvVlenb - 2).U + p.rvvVlenb.U),
            "b110".U -> (nfields * (p.rvvVlenb - 4).U + p.rvvVlenb.U)
          )
        )
        x.vectorsPerSegMinusOneOrig := maxVectorPerSegmentOrig
        // Non indexed cannot have subvectors
        x.dataSubvector            := LoopingCounter(0.U)
        x.dataSubvectorTheoretical := 0.U
        x.dataSegment              := LoopingCounter(nfields)
        // This is the number, not lmul/emul encoding
        x.dataEmul        := LoopingCounter(maxVectorPerSegment)
        x.dataActiveCells := State.makeVectorStartingActiveCells(
          nfields = nfields,
          elemWidth = elemWidth,
          isIndexed = false
        )
        x.writebackSegment     := LoopingCounter(nfields)
        x.writebackEmul        := LoopingCounter(maxVectorPerSegment)
        x.writebackActiveCells := MakeValid(
          State.makeVectorStartingActiveCells(
            nfields = nfields,
            elemWidth = elemWidth,
            isIndexed = false
          )
        )
      }

      ret
    }

    def initVectorLoadUS(
      pc: UInt,
      addr: UInt,
      vd: UInt,
      nfields: UInt,
      maxVectorPerSegment: UInt,
      maxVectorPerSegmentOrig: UInt,
      elemWidth: UInt,
      vl: UInt,
      vstart: UInt,
      masked: Bool
    ): State = {
      // From lmul and nfields, inclusive
      val maxActiveReg = maxVectorPerSegment * nfields + nfields + maxVectorPerSegment
      // From vstart and nfields, inclusive
      val startElem = vstart * nfields + vstart
      val startCell = MuxLookup(elemWidth, WireInit(UInt(32.W), DontCare))(
        Seq(
          "b000".U -> Cat(0.U(2.W), startElem),
          "b101".U -> Cat(0.U(1.W), startElem, 0.U(1.W)),
          "b110".U -> Cat(startElem, 0.U(2.W))
        )
      )
      // From vl and nfields, exclusive
      val endElem = vl * nfields + vl
      val endCell = MuxLookup(elemWidth, WireInit(UInt(32.W), DontCare))(
        Seq(
          "b000".U -> Cat(0.U(2.W), endElem),
          "b101".U -> Cat(0.U(1.W), endElem, 0.U(1.W)),
          "b110".U -> Cat(endElem, 0.U(2.W))
        )
      )
      MakeWireBundle[State](
        new State(),
        _ -> initVectorUS(
          pc,
          addr,
          vd,
          nfields,
          maxVectorPerSegment,
          maxVectorPerSegmentOrig,
          elemWidth,
          write = false
        ),
        _.cells -> VecInit.tabulate(nCells) { i =>
          MuxUpTo1H(
            cells(i).initDone(),
            Seq(
              // Prestart: skip to WB
              (i.U < startCell) -> cells(i).initSkip(),
              // Active cells: skip HS if not masked
              (i.U >= startCell && i.U < endCell && (i / p.rvvVlenb).U <= maxActiveReg) -> cells(i)
                .initLoad(addr + i.U, needData = masked),
              // tail cells:  skip to WB
              (i.U >= endCell && (i / p.rvvVlenb).U <= maxActiveReg) -> cells(i).initSkip()
              // Default: unreachable cells
            )
          )
        }
      )
    }

    def initVectorStoreUS(
      pc: UInt,
      addr: UInt,
      vd: UInt,
      nfields: UInt,
      maxVectorPerSegment: UInt,
      maxVectorPerSegmentOrig: UInt,
      elemWidth: UInt
    ): State = {
      MakeWireBundle[State](
        new State(),
        _ -> initVectorUS(
          pc,
          addr,
          vd,
          nfields,
          maxVectorPerSegment,
          maxVectorPerSegmentOrig,
          elemWidth,
          write = true
        ),
        _.cells -> VecInit.tabulate(nCells) { i =>
          Mux(
            // TODO: consider vl/vstart
            (i / p.rvvVlenb).U <= maxVectorPerSegment * nfields + nfields + maxVectorPerSegment,
            cells(i).initVectorStore(addr + i.U),
            cells(i).initDone()
          )
        }
      )
    }

    def initVectorCS(
      pc: UInt,
      addr: UInt,
      vd: UInt,
      nfields: UInt,
      maxVectorPerSegment: UInt,
      maxVectorPerSegmentOrig: UInt,
      elemWidth: UInt,
      stride: UInt,
      strict: Bool,
      write: Boolean
    ): State = {
      val ret = MakeWireBundle[State](
        new State(),
        _                     -> this,
        _.pc                  -> pc,
        _.write               -> write.B,
        _.faulted             -> false.B,
        _.strictMode          -> strict,
        _.rd                  -> vd,
        _.skipWriteback       -> false.B,
        _.scalarWritebackMode -> LsuScalarWritebackMode.NONE,
        // cells to be filled by caller
        _.leadIndex -> 0.U,
        _.rowAddr   -> addr(p.lsuAddrBits - 1, p.dbusOffsetBits)
      )
      ret.float.foreach { x =>
        x.writeback := false.B
      }
      ret.vector.foreach { x =>
        // TODO: assert
        x.segmentStep := MuxLookup(elemWidth, WireInit(UInt(3.W), DontCare))(
          Seq(
            "b000".U -> 1.U,
            "b101".U -> 2.U,
            "b110".U -> 4.U
          )
        )
        x.emulStep := MuxLookup(elemWidth, WireInit(UInt(3.W), DontCare))(
          Seq(
            "b000".U -> (nfields * (p.rvvVlenb - 1).U + p.rvvVlenb.U),
            "b101".U -> (nfields * (p.rvvVlenb - 2).U + p.rvvVlenb.U),
            "b110".U -> (nfields * (p.rvvVlenb - 4).U + p.rvvVlenb.U)
          )
        )
        x.vectorsPerSegMinusOneOrig := maxVectorPerSegmentOrig
        // Non indexed cannot have subvectors
        x.dataSubvector            := LoopingCounter(0.U)
        x.dataSubvectorTheoretical := 0.U
        x.dataSegment              := LoopingCounter(nfields)
        // This is the number, not lmul/emul encoding
        x.dataEmul        := LoopingCounter(maxVectorPerSegment)
        x.dataActiveCells := State.makeVectorStartingActiveCells(
          nfields = nfields,
          elemWidth = elemWidth,
          isIndexed = false
        )
        x.writebackSegment     := LoopingCounter(nfields)
        x.writebackEmul        := LoopingCounter(maxVectorPerSegment)
        x.writebackActiveCells := MakeValid(
          State.makeVectorStartingActiveCells(
            nfields = nfields,
            elemWidth = elemWidth,
            isIndexed = false
          )
        )
      }

      ret
    }

    def initVectorLoadCS(
      pc: UInt,
      addr: UInt,
      vd: UInt,
      nfields: UInt,
      maxVectorPerSegment: UInt,
      maxVectorPerSegmentOrig: UInt,
      elemWidth: UInt,
      stride: UInt,
      strict: Bool,
      vl: UInt,
      vstart: UInt,
      masked: Bool
    ): State = {
      // From lmul and nfields, inclusive
      val maxActiveReg = maxVectorPerSegment * nfields + nfields + maxVectorPerSegment
      // From vstart and nfields, inclusive
      val startElem = vstart * nfields + vstart
      val startCell = MuxLookup(elemWidth, WireInit(UInt(32.W), DontCare))(
        Seq(
          "b000".U -> Cat(0.U(2.W), startElem),
          "b101".U -> Cat(0.U(1.W), startElem, 0.U(1.W)),
          "b110".U -> Cat(startElem, 0.U(2.W))
        )
      )
      // From vl and nfields, exclusive
      val endElem = vl * nfields + vl
      val endCell = MuxLookup(elemWidth, WireInit(UInt(32.W), DontCare))(
        Seq(
          "b000".U -> Cat(0.U(2.W), endElem),
          "b101".U -> Cat(0.U(1.W), endElem, 0.U(1.W)),
          "b110".U -> Cat(endElem, 0.U(2.W))
        )
      )
      // TODO: assert
      val offsets =
        MuxLookup(Cat(nfields, elemWidth), VecInit.fill(nCells)(WireInit(UInt(32.W), DontCare)))(
          Seq(
            // e8
            "b000_000".U -> State.makeStridedOffsets(1, stride),
            "b001_000".U -> State.makeStridedOffsets(2, stride),
            "b010_000".U -> State.makeStridedOffsets(3, stride),
            "b011_000".U -> State.makeStridedOffsets(4, stride),
            "b100_000".U -> State.makeStridedOffsets(5, stride),
            "b101_000".U -> State.makeStridedOffsets(6, stride),
            "b110_000".U -> State.makeStridedOffsets(7, stride),
            "b111_000".U -> State.makeStridedOffsets(8, stride),
            // e16
            "b000_101".U -> State.makeStridedOffsets(2, stride),
            "b001_101".U -> State.makeStridedOffsets(4, stride),
            "b010_101".U -> State.makeStridedOffsets(6, stride),
            "b011_101".U -> State.makeStridedOffsets(8, stride),
            "b100_101".U -> State.makeStridedOffsets(10, stride),
            "b101_101".U -> State.makeStridedOffsets(12, stride),
            "b110_101".U -> State.makeStridedOffsets(14, stride),
            "b111_101".U -> State.makeStridedOffsets(16, stride),
            // e32
            "b000_110".U -> State.makeStridedOffsets(4, stride),
            "b001_110".U -> State.makeStridedOffsets(8, stride),
            "b010_110".U -> State.makeStridedOffsets(12, stride),
            "b011_110".U -> State.makeStridedOffsets(16, stride),
            "b100_110".U -> State.makeStridedOffsets(20, stride),
            "b101_110".U -> State.makeStridedOffsets(24, stride),
            "b110_110".U -> State.makeStridedOffsets(28, stride),
            "b111_110".U -> State.makeStridedOffsets(32, stride)
          )
        )
      MakeWireBundle[State](
        new State(),
        _ -> initVectorCS(
          pc,
          addr,
          vd,
          nfields,
          maxVectorPerSegment,
          maxVectorPerSegmentOrig,
          elemWidth,
          stride,
          strict,
          write = false
        ),
        _.cells -> VecInit.tabulate(nCells) { i =>
          MuxUpTo1H(
            cells(i).initDone(),
            Seq(
              // Prestart: skip to WB
              (i.U < startCell) -> cells(i).initSkip(),
              // Active cells: skip HS if not masked
              (i.U >= startCell && i.U < endCell && (i / p.rvvVlenb).U <= maxActiveReg) -> cells(i)
                .initLoad(addr + offsets(i), needData = masked),
              // tail cells:  skip to WB
              (i.U >= endCell && (i / p.rvvVlenb).U <= maxActiveReg) -> cells(i).initSkip()
              // Default: unreachable cells
            )
          )
        }
      )
    }

    def initVectorStoreCS(
      pc: UInt,
      addr: UInt,
      vd: UInt,
      nfields: UInt,
      maxVectorPerSegment: UInt,
      maxVectorPerSegmentOrig: UInt,
      elemWidth: UInt,
      stride: UInt,
      strict: Bool
    ): State = {
      // TODO: assert
      val offsets =
        MuxLookup(Cat(nfields, elemWidth), VecInit.fill(nCells)(WireInit(UInt(32.W), DontCare)))(
          Seq(
            // e8
            "b000_000".U -> State.makeStridedOffsets(1, stride),
            "b001_000".U -> State.makeStridedOffsets(2, stride),
            "b010_000".U -> State.makeStridedOffsets(3, stride),
            "b011_000".U -> State.makeStridedOffsets(4, stride),
            "b100_000".U -> State.makeStridedOffsets(5, stride),
            "b101_000".U -> State.makeStridedOffsets(6, stride),
            "b110_000".U -> State.makeStridedOffsets(7, stride),
            "b111_000".U -> State.makeStridedOffsets(8, stride),
            // e16
            "b000_101".U -> State.makeStridedOffsets(2, stride),
            "b001_101".U -> State.makeStridedOffsets(4, stride),
            "b010_101".U -> State.makeStridedOffsets(6, stride),
            "b011_101".U -> State.makeStridedOffsets(8, stride),
            "b100_101".U -> State.makeStridedOffsets(10, stride),
            "b101_101".U -> State.makeStridedOffsets(12, stride),
            "b110_101".U -> State.makeStridedOffsets(14, stride),
            "b111_101".U -> State.makeStridedOffsets(16, stride),
            // e32
            "b000_110".U -> State.makeStridedOffsets(4, stride),
            "b001_110".U -> State.makeStridedOffsets(8, stride),
            "b010_110".U -> State.makeStridedOffsets(12, stride),
            "b011_110".U -> State.makeStridedOffsets(16, stride),
            "b100_110".U -> State.makeStridedOffsets(20, stride),
            "b101_110".U -> State.makeStridedOffsets(24, stride),
            "b110_110".U -> State.makeStridedOffsets(28, stride),
            "b111_110".U -> State.makeStridedOffsets(32, stride)
          )
        )
      MakeWireBundle[State](
        new State(),
        _ -> initVectorCS(
          pc,
          addr,
          vd,
          nfields,
          maxVectorPerSegment,
          maxVectorPerSegmentOrig,
          elemWidth,
          stride,
          strict,
          write = true
        ),
        _.cells -> VecInit.tabulate(nCells) { i =>
          Mux(
            // TODO: consider vl/vstart
            (i / p.rvvVlenb).U <= maxVectorPerSegment * nfields + nfields + maxVectorPerSegment,
            cells(i).initVectorStore(addr + offsets(i)),
            cells(i).initDone()
          )
        }
      )
    }

    def initVectorIndexed(
      pc: UInt,
      addr: UInt,
      vd: UInt,
      nfields: UInt,
      dataEmul: UInt,
      maxVectorPerSegment: UInt,
      maxVectorPerSegmentOrig: UInt,
      subvectors: UInt,
      subvectorsTheoretical: UInt,
      elemWidth: UInt,
      indexWidth: UInt,
      activeCellCount: UInt,
      offsets: Vec[UInt],
      strict: Bool,
      write: Bool
    ): State = {
      // TODO: assert
      val elemWidthEnum = MuxLookup(elemWidth, WireInit(LsuVectorElementWidth(), DontCare))(
        Seq(
          "b000".U -> LsuVectorElementWidth.E8,
          "b001".U -> LsuVectorElementWidth.E16,
          "b010".U -> LsuVectorElementWidth.E32
        )
      )
      val newCells = VecInit.tabulate(nCells) { i =>
        // TODO: consider vl/vstart
        val cellIsActive = i.U < activeCellCount
        MuxUpTo1H(
          cells(i).initDone(),
          Seq(
            // TODO: unmasked loads can skip W_DATA.
            (cellIsActive && !write) -> cells(i).initLoad(addr + offsets(i), needData = true.B),
            (cellIsActive && write)  -> cells(i).initVectorStore(addr + offsets(i))
            // Default: !cellIsActive
          )
        )
      }
      val ret = MakeWireBundle[State](
        new State(),
        _                     -> this,
        _.pc                  -> pc,
        _.write               -> write,
        _.faulted             -> false.B,
        _.strictMode          -> strict,
        _.rd                  -> vd,
        _.skipWriteback       -> false.B,
        _.scalarWritebackMode -> LsuScalarWritebackMode.NONE,
        _.cells               -> newCells,
        _.leadIndex           -> 0.U
        // rowAddr is untouched because we need to wait for indices
      )
      ret.float.foreach { x =>
        x.writeback := false.B
      }
      ret.vector.foreach { x =>
        x.dataEew := elemWidthEnum
        // TODO: assert
        x.indexEew := MuxLookup(indexWidth, WireInit(LsuVectorElementWidth(), DontCare))(
          Seq(
            "b000".U -> LsuVectorElementWidth.E8,
            "b101".U -> LsuVectorElementWidth.E16,
            "b110".U -> LsuVectorElementWidth.E32
          )
        )
        // TODO: assert
        x.segmentStep := MuxLookup(elemWidth, WireInit(UInt(3.W), DontCare))(
          Seq(
            "b000".U -> 1.U,
            "b001".U -> 2.U,
            "b010".U -> 4.U
          )
        )
        x.emulStep := MuxLookup(elemWidth, WireInit(UInt(3.W), DontCare))(
          Seq(
            "b000".U -> (nfields * (p.rvvVlenb - 1).U + p.rvvVlenb.U),
            "b001".U -> (nfields * (p.rvvVlenb - 2).U + p.rvvVlenb.U),
            "b010".U -> (nfields * (p.rvvVlenb - 4).U + p.rvvVlenb.U)
          )
        )
        x.vectorsPerSegMinusOneOrig := maxVectorPerSegmentOrig
        x.dataSubvector             := LoopingCounter(subvectors)
        x.dataSubvectorTheoretical  := subvectorsTheoretical
        x.dataSegment               := LoopingCounter(nfields)
        // This is the number, not lmul/emul encoding
        x.dataEmul        := LoopingCounter(maxVectorPerSegment)
        x.dataActiveCells := State.makeVectorStartingActiveCells(
          nfields = nfields,
          elemWidth = elemWidth,
          isIndexed = true
        )
        x.writebackSegment     := LoopingCounter(nfields)
        x.writebackEmul        := LoopingCounter(maxVectorPerSegment)
        x.writebackActiveCells := MakeValid(
          State.makeVectorStartingActiveCells(
            nfields = nfields,
            elemWidth = elemWidth,
            isIndexed = true
          )
        )
      }

      ret
    }

    def fromUop(uop: LsuUOp) = {
      val nfields             = uop.nfields.getOrElse(0.U)
      val maxVectorPerSegment = uop.emul_data
        .map { x =>
          MuxLookup(x, 0.U(3.W))(
            Seq(
              "b001".U -> 1.U(3.W),
              "b010".U -> 3.U(3.W),
              "b011".U -> 7.U(3.W)
            )
          )
        }
        .getOrElse(0.U)
      val maxVectorPerSegmentOrig = uop.emul_data_orig
        .map { x =>
          MuxLookup(x, 0.U(3.W))(
            Seq(
              "b001".U -> 1.U(3.W),
              "b010".U -> 3.U(3.W),
              "b011".U -> 7.U(3.W)
            )
          )
        }
        .getOrElse(0.U)
      val elemWidth  = uop.elemWidth.getOrElse(0.U)
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

      val lookupSeqScalar = Seq(
        LsuOp.LB  -> initIntLoad(uop.pc, uop.addr, uop.rd, bytes = 1, sext = true),
        LsuOp.LH  -> initIntLoad(uop.pc, uop.addr, uop.rd, bytes = 2, sext = true),
        LsuOp.LW  -> initIntLoad(uop.pc, uop.addr, uop.rd, bytes = 4, sext = false),
        LsuOp.LBU -> initIntLoad(uop.pc, uop.addr, uop.rd, bytes = 1, sext = false),
        LsuOp.LHU -> initIntLoad(uop.pc, uop.addr, uop.rd, bytes = 2, sext = false),
        LsuOp.SB  -> initIntStore(uop.pc, uop.addr, uop.data, bytes = 1),
        LsuOp.SH  -> initIntStore(uop.pc, uop.addr, uop.data, bytes = 2),
        LsuOp.SW  -> initIntStore(uop.pc, uop.addr, uop.data, bytes = 4)
        // val FENCEI = Value
        // val FLUSHAT = Value
        // val FLUSHALL = Value
        // val VLDST = Value
      )
      val lookupSeqFloat =
        if (p.enableFloat)
          Seq(
            LsuOp.FLOAT -> Mux(
              uop.store,
              initFloatStore(uop.pc, uop.addr, uop.data, bytes = 4),
              initFloatLoad(uop.pc, uop.addr, uop.rd, bytes = 4)
            )
          )
        else Seq()
      val lookupSeqVector = if (p.enableRvv) {
        val indexedElemWidthEnum =
          MuxLookup(uop.sew.getOrElse(0.U), WireInit(LsuVectorElementWidth(), DontCare))(
            Seq(
              "b000".U -> LsuVectorElementWidth.E8,
              "b001".U -> LsuVectorElementWidth.E16,
              "b010".U -> LsuVectorElementWidth.E32
            )
          )
        val activeCellCount = State.countActiveVectorCells(
          nfields = nfields,
          elemWidth = indexedElemWidthEnum,
          emul = uop.emul_data.getOrElse(0.U)
        )
        // Before applying indices, we're basically doing a stride 0 op.
        val indexedOffsets = MuxLookup(
          Cat(nfields, uop.sew.getOrElse(0.U)),
          VecInit.fill(nCells)(WireInit(UInt(32.W), DontCare))
        )(
          Seq(
            // e8
            "b000_000".U -> State.makeStride0Offsets(1),
            "b001_000".U -> State.makeStride0Offsets(2),
            "b010_000".U -> State.makeStride0Offsets(3),
            "b011_000".U -> State.makeStride0Offsets(4),
            "b100_000".U -> State.makeStride0Offsets(5),
            "b101_000".U -> State.makeStride0Offsets(6),
            "b110_000".U -> State.makeStride0Offsets(7),
            "b111_000".U -> State.makeStride0Offsets(8),
            // e16
            "b000_001".U -> State.makeStride0Offsets(2),
            "b001_001".U -> State.makeStride0Offsets(4),
            "b010_001".U -> State.makeStride0Offsets(6),
            "b011_001".U -> State.makeStride0Offsets(8),
            "b100_001".U -> State.makeStride0Offsets(10),
            "b101_001".U -> State.makeStride0Offsets(12),
            "b110_001".U -> State.makeStride0Offsets(14),
            "b111_001".U -> State.makeStride0Offsets(16),
            // e32
            "b000_010".U -> State.makeStride0Offsets(4),
            "b001_010".U -> State.makeStride0Offsets(8),
            "b010_010".U -> State.makeStride0Offsets(12),
            "b011_010".U -> State.makeStride0Offsets(16),
            "b100_010".U -> State.makeStride0Offsets(20),
            "b101_010".U -> State.makeStride0Offsets(24),
            "b110_010".U -> State.makeStride0Offsets(28),
            "b111_010".U -> State.makeStride0Offsets(32)
          )
        )
        def indexedInitFunc(strict: Bool, write: Bool) = {
          initVectorIndexed(
            pc = uop.pc,
            addr = uop.addr,
            vd = uop.rd,
            nfields = nfields,
            dataEmul = uop.emul_data.getOrElse(0.U),
            maxVectorPerSegment = maxVectorPerSegment,
            maxVectorPerSegmentOrig = maxVectorPerSegmentOrig,
            subvectors = subvectors,
            subvectorsTheoretical = subvectorsTheoretical,
            elemWidth = uop.sew.getOrElse(0.U),
            indexWidth = elemWidth,
            activeCellCount = activeCellCount,
            offsets = indexedOffsets,
            strict = strict,
            write = write
          )
        }
        Seq(
          // Vector instructions.
          // TODO: consider vstart and vl here
          LsuOp.VLOAD_UNIT -> initVectorLoadUS(
            pc = uop.pc,
            addr = uop.addr,
            vd = uop.rd,
            nfields = nfields,
            maxVectorPerSegment = maxVectorPerSegment,
            maxVectorPerSegmentOrig = maxVectorPerSegmentOrig,
            elemWidth = elemWidth,
            vl = uop.vl.get,
            vstart = uop.vstart.get,
            masked = uop.masked.get
          ),
          LsuOp.VLOAD_STRIDED -> initVectorLoadCS(
            pc = uop.pc,
            addr = uop.addr,
            vd = uop.rd,
            nfields = nfields,
            maxVectorPerSegment = maxVectorPerSegment,
            maxVectorPerSegmentOrig = maxVectorPerSegmentOrig,
            elemWidth = elemWidth,
            stride = uop.data,
            strict = uop.strict.getOrElse(false.B),
            vl = uop.vl.get,
            vstart = uop.vstart.get,
            masked = uop.masked.get
          ),
          LsuOp.VLOAD_OINDEXED -> indexedInitFunc(
            strict = true.B,
            write = false.B
          ),
          LsuOp.VLOAD_UINDEXED -> indexedInitFunc(
            strict = false.B,
            write = false.B
          ),
          LsuOp.VSTORE_UNIT -> initVectorStoreUS(
            uop.pc,
            uop.addr,
            uop.rd,
            nfields = nfields,
            maxVectorPerSegment = maxVectorPerSegment,
            maxVectorPerSegmentOrig = maxVectorPerSegmentOrig,
            elemWidth = elemWidth
          ),
          LsuOp.VSTORE_STRIDED -> initVectorStoreCS(
            pc = uop.pc,
            addr = uop.addr,
            vd = uop.rd,
            nfields = nfields,
            maxVectorPerSegment = maxVectorPerSegment,
            maxVectorPerSegmentOrig = maxVectorPerSegmentOrig,
            elemWidth = elemWidth,
            stride = uop.data,
            strict = uop.strict.getOrElse(false.B)
          ),
          LsuOp.VSTORE_OINDEXED -> indexedInitFunc(
            strict = true.B,
            write = true.B
          ),
          LsuOp.VSTORE_UINDEXED -> indexedInitFunc(
            strict = false.B,
            write = true.B
          )
        )
      } else Seq()
      // TODO: default value?
      // TODO: assert vector elemWidth legal
      MuxLookup(uop.op, this)(
        lookupSeqScalar ++ lookupSeqFloat ++ lookupSeqVector
      )
    }
  }

  object State {
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
        _.cells               -> VecInit.fill(nCells)(LsuCell(p)),
        _.leadIndex           -> 0.U,
        _.rowAddr             -> 0.U
      )
      ret.float.foreach { x =>
        x.writeback := false.B
      }
      ret.vector.foreach { x =>
        x.dataEew                   := LsuVectorElementWidth.E8
        x.indexEew                  := LsuVectorElementWidth.E8
        x.segmentStep               := 0.U
        x.emulStep                  := 0.U
        x.vectorsPerSegMinusOneOrig := 0.U
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

    def countActiveVectorCells(
      nfields: UInt,
      elemWidth: LsuVectorElementWidth.Type,
      emul: UInt
    ): UInt = {
      val nStructs = MuxUpTo1H(
        0.U,
        Seq(
          // mf4
          (emul === "b110".U && elemWidth === LsuVectorElementWidth.E8) -> (p.rvvVlenb / 4).U,
          // mf2
          (emul === "b111".U && elemWidth === LsuVectorElementWidth.E8)  -> (p.rvvVlenb / 2).U,
          (emul === "b111".U && elemWidth === LsuVectorElementWidth.E16) -> (p.rvvVlenb / 4).U,
          // m1
          (emul === "b000".U && elemWidth === LsuVectorElementWidth.E8)  -> p.rvvVlenb.U,
          (emul === "b000".U && elemWidth === LsuVectorElementWidth.E16) -> (p.rvvVlenb / 2).U,
          (emul === "b000".U && elemWidth === LsuVectorElementWidth.E32) -> (p.rvvVlenb / 4).U,
          // m2
          (emul === "b001".U && elemWidth === LsuVectorElementWidth.E8)  -> (p.rvvVlenb * 2).U,
          (emul === "b001".U && elemWidth === LsuVectorElementWidth.E16) -> p.rvvVlenb.U,
          (emul === "b001".U && elemWidth === LsuVectorElementWidth.E32) -> (p.rvvVlenb / 2).U,
          // m4
          (emul === "b010".U && elemWidth === LsuVectorElementWidth.E8)  -> (p.rvvVlenb * 4).U,
          (emul === "b010".U && elemWidth === LsuVectorElementWidth.E16) -> (p.rvvVlenb * 2).U,
          (emul === "b010".U && elemWidth === LsuVectorElementWidth.E32) -> p.rvvVlenb.U,
          // m8
          (emul === "b011".U && elemWidth === LsuVectorElementWidth.E8)  -> (p.rvvVlenb * 8).U,
          (emul === "b011".U && elemWidth === LsuVectorElementWidth.E16) -> (p.rvvVlenb * 4).U,
          (emul === "b011".U && elemWidth === LsuVectorElementWidth.E32) -> (p.rvvVlenb * 2).U
        )
      )
      val structBytes = MuxLookup(elemWidth, 0.U)(
        Seq(
          LsuVectorElementWidth.E8  -> (nfields +& 1.U),
          LsuVectorElementWidth.E16 -> ((nfields +& 1.U) << 1.U),
          LsuVectorElementWidth.E32 -> ((nfields +& 1.U) << 2.U)
        )
      )
      nStructs * structBytes
    }

    // Indices of cells that will receive vector data on the first data cycle
    // Because we only care about the first cycle, regs (or lmul) is not needed here.
    def makeVectorStartingActiveCells(
      nfields: UInt,
      elemWidth: UInt,
      isIndexed: Boolean
    ): Vec[UInt] = {
      // nfields is 0-7, so x * segs === x * nfields + x
      val retE8 = VecInit.tabulate(p.rvvVlenb) { i =>
        i.U * nfields + i.U
      }
      val retE16 = VecInit.tabulate(p.rvvVlenb) { i =>
        Cat((i / 2).U * nfields + (i / 2).U, (i % 2).U(1.W))
      }
      val retE32 = VecInit.tabulate(p.rvvVlenb) { i =>
        Cat((i / 4).U * nfields + (i / 4).U, (i % 4).U(2.W))
      }

      // TODO: assert
      if (isIndexed) {
        // This is SEW.
        MuxLookup(elemWidth, VecInit.fill(p.rvvVlenb)(WireInit(UInt(indexWidth.W), DontCare)))(
          Seq(
            "b000".U -> retE8,
            "b001".U -> retE16,
            "b010".U -> retE32
          )
        )
      } else {
        // This is the width field in the encoding.
        MuxLookup(elemWidth, VecInit.fill(p.rvvVlenb)(WireInit(UInt(indexWidth.W), DontCare)))(
          Seq(
            "b000".U -> retE8,
            "b101".U -> retE16,
            "b110".U -> retE32
          )
        )
      }
    }

    def makeStridedOffsets(
      structSize: Int, // Up to 32
      stride: UInt
    ): Vec[UInt] = {
      VecInit.tabulate(nCells) { i =>
        ((i / structSize).U(indexWidth.W) * stride)(31, 0) + (i % structSize).U
      }
    }

    def makeStride0Offsets(
      structSize: Int // Up to 32
    ): Vec[UInt] = {
      VecInit.tabulate(nCells) { i =>
        (i % structSize).U(p.lsuAddrBits.W)
      }
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
    val pc              = UInt(p.programCounterBits.W)
    val active          = Bool()
    val storeComplete   = Bool()
  })

  val state    = RegInit(State())
  val newFault = io.busResp.valid && io.busResp.bits.fault

  val (tx, starts, moveLead) = state.maybeStart()
  val acceptNewTx            = RegNext(io.busReq.ready || !io.busReq.valid, true.B)
  val txPending              = RegInit(MakeInvalid(new BusReq))
  val txOutgoing             = Mux(txPending.valid, txPending, tx)
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
  val busRespRowAddr = RegNext(txOutgoing.bits.rowAddr, 0.U)
  val busRespData    = VecInit.tabulate(p.lsuDataBytes) { i =>
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
    x.valid := writebackReq.vector.get.valid
    x.bits  := writebackReq.vector.get.bits
  }

  val canMoveLead = !state.isDone() && (
    !io.busReq.valid || io.busReq.ready
  )
  val stateFromAction = state.act(
    starts = Mux(io.busReq.ready || state.faulted || newFault, starts, 0.U),
    moveLead = Mux(canMoveLead, moveLead, 0.U),
    resp = io.busResp.valid || faultRespValid,
    fault = newFault, // state will latch the fault
    respRowAddr = busRespRowAddr,
    respData = busRespData,
    respMask = busRespMask,
    writebacks = Mux(
      (
        io.intWriteback.valid ||
          io.floatWriteback.map(_.valid).getOrElse(false.B) ||
          io.vectorWriteback.map(_.fire).getOrElse(false.B)
      ),
      writebacks,
      0.U
    ),
    vectorData = io.vectorData.map { x =>
      MakeValid(x.valid, x.bits)
    }
  )
  io.uop.ready := stateFromAction.isDone()
  state        := Mux(io.uop.fire, stateFromUop, stateFromAction)

  io.active := state.cells.forall { x =>
    x.state === LsuCellState.DONE
  }
  // storeComplete is raised iff we've just received the last response
  io.storeComplete := state.write && !state.cells.forall { x =>
    x.state === LsuCellState.W_WB || x.state === LsuCellState.DONE
  } && stateFromAction.cells.forall { x =>
    x.state === LsuCellState.W_WB || x.state === LsuCellState.DONE
  }
  io.pc := state.pc

  io.vectorData.map { x =>
    x.ready := state.cells.map(_.state === LsuCellState.W_DATA).reduce(_ || _)
  }
}

class LsuV3(p: Parameters) extends Lsu(p) {
  // Reserve station. TODO: consider making a wrapper?
  val rs = Module(
    new CircularBufferMulti(new LsuUOp(p), p.instructionLanes, math.max(4, p.instructionLanes))
  )

  // Accept instructions based on available space.
  val validSums = io.req.map(_.valid).scan(0.U(log2Ceil(p.instructionLanes + 1).W))(_ + _)
  for (i <- 0 until p.instructionLanes) {
    io.req(i).ready := validSums(i) < rs.io.nSpace
  }

  // Prepare and align instructions for the queue.
  val ops = (0 until p.instructionLanes).map(i =>
    MakeValid(io.req(i).fire, LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState))
  )
  val alignedOps = Aligner(ops)

  rs.io.enqValid := PopCount(alignedOps.map(_.valid))
  rs.io.enqData  := alignedOps.map(_.bits)

  io.queueCapacity := rs.io.nSpace

  // Internals
  val slot = Module(new LsuSuperSlot(p))
  slot.io.uop.valid := rs.io.nEnqueued > 0.U
  slot.io.uop.bits  := rs.io.dataOut(0)
  rs.io.deqReady    := Mux(slot.io.uop.fire, 1.U, 0.U)
  if (p.enableRvv) {
    slot.io.vectorData.get <> io.rvv2lsu.get(0)
    io.rvv2lsu.get(1).ready := false.B
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
  val faultReg = RegNext(
    MuxCase(
      MakeInvalid(new FaultInfo(p)),
      Seq(
        io.ebus.fault.valid -> io.ebus.fault,
        ibusFault.valid     -> ibusFault
      )
    ),
    MakeInvalid(new FaultInfo(p))
  )

  // TODO(davidgao): flush RS upon fault.
  rs.io.flush := false.B
  // rs.io.flush := faultReg.valid

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

  // Calculate transaction address offset and size from the byte mask.
  val ebus_wmask  = slot.io.busReq.bits.wmask
  val ebus_offset = PriorityEncoder(ebus_wmask)
  val ebus_last   = PriorityEncoder(Reverse(ebus_wmask))
  val ebus_span   = p.lsuDataBytes.U(p.dbusSize.W) - ebus_last - ebus_offset

  // Constrain transaction size to 1, 2, 4, or full (p.lsuDataBytes).
  val ebus_size = MuxUpTo1H(
    ebus_span,
    Seq(
      // vector access, empty or wider than 4 bytes.
      (ebus_wmask === 0.U || ebus_span > 4.U) -> p.lsuDataBytes.U,
      // 4 bytes in this row but misaligned.
      (ebus_span === 4.U && (ebus_offset(1, 0) =/= 0.U)) -> p.lsuDataBytes.U,
      // 3 bytes in this row, crossing word boundary.
      (ebus_span === 3.U && (ebus_offset(1))) -> p.lsuDataBytes.U,
      // 3 bytes in this row, not crossing word boundary.
      (ebus_span === 3.U && (!ebus_offset(1))) -> 4.U,
      // 2 bytes in this row but misaligned.
      (ebus_span === 2.U && ebus_offset(0)) -> 4.U
      // default: ebus_span (1, 2aligned, 4aligned)
    )
  )

  // Align the offset down to the chosen size boundary using MuxLookup.
  val ebus_offset_aligned = MuxLookup(ebus_size, 0.U)(
    Seq(
      1.U -> ebus_offset,
      2.U -> (ebus_offset & ~1.U(ebus_offset.getWidth.W)),
      4.U -> (ebus_offset & ~3.U(ebus_offset.getWidth.W))
    )
  )

  io.ebus.dbus.valid := use_ebus && slot.io.busReq.valid
  io.ebus.dbus.write := slot.io.busReq.bits.write
  io.ebus.dbus.pc    := slot.io.pc
  io.ebus.dbus.addr  := addr + ebus_offset_aligned
  io.ebus.dbus.adrx  := addr
  io.ebus.dbus.size  := ebus_size
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

  // fault handling
  io.fault := faultReg

  // status reporting
  io.active        := rs.io.nEnqueued > 0.U || !slot.io.active
  io.storeComplete := MakeValid(slot.io.storeComplete, slot.io.pc)

  // Tie off all outputs to safe defaults.
  // TODO(davidgao): all these should be gone once LsuV3 is fully functional

  io.flush.valid  := false.B
  io.flush.all    := false.B
  io.flush.clean  := false.B
  io.flush.fencei := false.B
  io.flush.pcNext := 0.U

  io.vldst := false.B
}
