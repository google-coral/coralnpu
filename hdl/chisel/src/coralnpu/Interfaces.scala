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

package coralnpu

import common._
import chisel3._
import chisel3.util._
import bus._

class CsrInIO(p: Parameters) extends Bundle {
  val value = Input(Vec(p.csrInCount, UInt(p.xlen.W)))
}

class CsrOutIO(p: Parameters) extends Bundle {
  val value = Output(Vec(p.csrOutCount, UInt(p.xlen.W)))
}

class CsrInOutIO(p: Parameters) extends Bundle {
  val in  = new CsrInIO(p)
  val out = new CsrOutIO(p)
}

class RegfileLinkPortIO(p: Parameters) extends Bundle {
  val valid = Output(Bool())
  val value = Output(UInt(p.programCounterBits.W))
}

class RegfileBusPortIO(p: Parameters) extends Bundle {
  val addr = Vec(p.instructionLanes, UInt(p.lsuAddrBits.W))
  val data = Vec(p.instructionLanes, UInt(p.xlen.W))
}

class FetchInstruction(p: Parameters) extends Bundle {
  val addr    = UInt(p.programCounterBits.W)
  val inst    = UInt(p.instructionBits.W)
  val brchFwd = Bool()
}

class FetchIO(p: Parameters) extends Bundle {
  val lanes = Vec(p.instructionLanes, Decoupled(new FetchInstruction(p)))
}

abstract class FetchUnit(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val csr      = new CsrInIO(p)
    val debug_pc = Flipped(Valid(UInt(p.fetchAddrBits.W)))
    val tlul     = new TLULHost2Device[NoUser, NoUser](p.tlParams)
    val inst     = new FetchIO(p)
    val branch   = Flipped(Vec(p.instructionLanes, Valid(UInt(p.programCounterBits.W))))
    val linkPort = Flipped(new RegfileLinkPortIO(p))
    val iflush   = Flipped(new IFlushIO(p))
    val pc       = UInt(p.fetchAddrBits.W)
    val fault    = Output(Valid(UInt(p.programCounterBits.W)))
  })
}

abstract class SRAM128(numEntries: Int, globalBaseAddr: Int = 0)
    extends BlackBox(
      Map(
        "NUM_ENTRIES"      -> chisel3.experimental.IntParam(numEntries),
        "GLOBAL_BASE_ADDR" -> chisel3.experimental.IntParam(globalBaseAddr)
      )
    ) {
  val addrWidth = log2Ceil(numEntries)
  val io        = IO(new Bundle {
    val clock  = Input(Clock())
    val enable = Input(Bool())
    val write  = Input(Bool())
    val addr   = Input(UInt(addrWidth.W))
    val wdata  = Input(UInt(128.W))
    val wmask  = Input(UInt(16.W))
    val rdata  = Output(UInt(128.W))
    val rvalid = Output(Bool())
  })
}

class FaultInfo(p: Parameters) extends Bundle {
  val write = Bool()
  val addr  = UInt(p.programCounterBits.W)
  val epc   = UInt(p.programCounterBits.W)
}

class LsuFaultInfo(p: Parameters) extends Bundle {
  val write  = Bool()
  val addr   = UInt(p.programCounterBits.W)
  val epc    = UInt(p.programCounterBits.W)
  val vstart = Option.when(p.enableRvv)(Valid(UInt(log2Ceil(p.rvvVlen).W)))
}

object LsuFaultInfo {
  def apply(p: Parameters)(
    fault: Valid[FaultInfo],
    vstart: Option[Valid[UInt]] = None
  ): Valid[LsuFaultInfo] = {
    val res = Wire(Valid(new LsuFaultInfo(p)))
    res.valid      := fault.valid
    res.bits.write := fault.bits.write
    res.bits.addr  := fault.bits.addr
    res.bits.epc   := fault.bits.epc
    res.bits.vstart.foreach(v => v := vstart.getOrElse(MakeInvalid(0.U)))
    res
  }
}

class DBus2Resp(p: Parameters) extends Bundle {
  val txid  = UInt(p.lsuSlotTxidWidth.W)
  val rdata = UInt(p.lsuDataBits.W)
  val fault = Bool()
}

class IFlushIO(p: Parameters) extends Bundle {
  val valid  = Output(Bool())
  val pcNext = Output(UInt(p.programCounterBits.W))
  val ready  = Input(Bool())

  def fire: Bool = valid && ready
}

class TileWrite(p: Parameters) extends Bundle {
  val idx  = UInt(p.vmeRegCountWidth.W)
  val data = Vec(p.vmeNumSubtiles, UInt(p.vmeSubtileBits.W))
}

class TileWriteDataIO(p: Parameters) extends Bundle {
  val rob_tag  = UInt(log2Ceil(p.retirementBufferSize).W)
  val is_store = Bool()
  val mask     = UInt(p.vmeMaxTileWrites.W)
  val idx      = UInt(p.vmeRegCountWidth.W)
  val data     = Option.when(p.enableVerification)(
    Vec(p.vmeMaxTileWrites, Vec(p.vmeNumSubtiles, UInt(p.vmeSubtileBits.W)))
  )
  val pc = Option.when(p.enableVerification)(UInt(p.programCounterBits.W))
}

class MtypeWriteDataIO(p: Parameters) extends Bundle {
  val rob_tag = UInt(log2Ceil(p.retirementBufferSize).W)
  val data    = Option.when(p.enableVerification)(UInt(p.xlen.W))
}

class RetirementBufferDebugIO(p: Parameters) extends Bundle {
  val inst = Vec(
    p.retirementLanes,
    Valid(new Bundle {
      val pc        = UInt(p.programCounterBits.W)
      val inst      = UInt(p.instructionBits.W)
      val idx       = UInt(p.retirementBufferIdxWidth.W)
      val data      = if (p.enableRvv) UInt(p.rvvVlen.W) else UInt(p.xlen.W)
      val vecWrites = Option.when(p.enableRvv)(
        Vec(
          8,
          Valid(new Bundle {
            val data = UInt(p.rvvVlen.W)
            val idx  = UInt(p.rvvRegCountWidth.W)
          })
        )
      )
      val tileWrites = Option.when(p.enableVme)(
        Vec(
          p.vmeMaxTileWrites,
          Valid(new TileWrite(p))
        )
      )
      val mtype = Option.when(p.enableVme)(Valid(UInt(p.xlen.W)))
      val trap  = Bool()
    })
  )
}

// Debug signals for HDL development.
class DebugIO(p: Parameters) extends Bundle {
  val en     = Output(UInt(4.W))
  val addr   = Vec(p.instructionLanes, UInt(p.programCounterBits.W))
  val inst   = Vec(p.instructionLanes, UInt(p.instructionBits.W))
  val cycles = Output(UInt(p.xlen.W))

  val dbus = Valid(new Bundle {
    val addr  = UInt(p.lsuAddrBits.W)
    val wdata = UInt(p.axi2DataBits.W)
    val write = Bool()
  })

  val dispatch = Vec(
    p.instructionLanes,
    new Bundle {
      val instFire = Bool()
      val instAddr = UInt(p.programCounterBits.W)
      val instInst = UInt(p.instructionBits.W)
    }
  )

  val regfile = new Bundle {
    // At decode time, what registers the instructions will write to.
    val writeAddr = Vec(p.instructionLanes, Valid(UInt(p.scalarRegCountWidth.W)))
    // Writeback to the register file.
    val writeData = Vec(
      p.instructionLanes + 2,
      Valid(new Bundle {
        val addr = UInt(p.scalarRegCountWidth.W)
        val data = UInt(p.xlen.W)
      })
    )
  }

  val float = Option.when(p.enableFloat)(new Bundle {
    // Decode
    val writeAddr = Valid(UInt(p.floatRegCountWidth.W))
    // Execute
    val writeData = Vec(
      2,
      Valid(new Bundle {
        val addr = UInt(p.floatRegCountWidth.W)
        val data = UInt(p.xlen.W)
      })
    )
  })

  val rb = Output(new RetirementBufferDebugIO(p))
}

class RegfileReadDataIO(p: Parameters) extends Bundle {
  val valid = Output(Bool())
  val data  = Output(UInt(p.xlen.W))
}

class RegfileWriteAddrIO(p: Parameters) extends Bundle {
  val valid = Input(Bool())
  val addr  = Input(UInt(p.scalarRegCountWidth.W))
}

class RegfileWriteDataIO(p: Parameters) extends Bundle {
  val addr = Input(UInt(p.scalarRegCountWidth.W))
  val data = Input(UInt(p.xlen.W))
}

class FloatRegfileWriteDataIO(p: Parameters) extends Bundle {
  val addr = Input(UInt(p.floatRegCountWidth.W))
  val data = Input(UInt(32.W))
}

class VectorWriteDataIO(p: Parameters) extends Bundle {
  val w_valid        = Input(Bool())
  val addr           = Input(UInt(p.rvvRegCountWidth.W))
  val data           = Option.when(p.enableVerification)(Input(UInt(p.lsuDataBits.W)))
  val uop_pc         = Option.when(p.enableVerification)(Input(UInt(p.programCounterBits.W)))
  val last_uop_valid = Input(Bool())
  val rob_tag        = Input(UInt(log2Ceil(p.retirementBufferSize).W))
}

object CsrOp extends ChiselEnum {
  val CSRRW = Value
  val CSRRS = Value
  val CSRRC = Value
}

class CsrCmd(p: Parameters) extends Bundle {
  val addr  = UInt(p.scalarRegCountWidth.W)
  val index = UInt(12.W)
  val rs1   = UInt(p.scalarRegCountWidth.W)
  val op    = CsrOp()
}

class FRegfileRead(p: Parameters) extends Bundle {
  val valid = Input(Bool())
  val addr  = Input(UInt(p.floatRegCountWidth.W))
  val data  = Output(new Fp32)
}

class FRegfileWrite(p: Parameters) extends Bundle {
  val valid = Input(Bool())
  val addr  = Input(UInt(p.floatRegCountWidth.W))
  val data  = Input(new Fp32)
}

class CoreDMIO(p: Parameters) extends Bundle {
  val debug_req  = Input(Bool())
  val resume_req = Input(Bool())
  val csr        = Input(Valid(new CsrCmd(p)))
  val csr_rs1    = Input(UInt(p.xlen.W))
  val csr_rd     = Output(Valid(UInt(p.xlen.W)))
  val scalar_rd  = Flipped(Decoupled(new RegfileWriteDataIO(p)))
  val scalar_rs  = new Bundle {
    val idx  = Input(UInt(p.scalarRegCountWidth.W))
    val data = Output(UInt(p.xlen.W))
  }
  val float_rd   = Option.when(p.enableFloat)(new FRegfileWrite(p))
  val float_rs   = Option.when(p.enableFloat)(new FRegfileRead(p))
  val debug_mode = Output(Bool())
}

class CsrTraceIO(p: Parameters) extends Bundle {
  val valid = Bool()
  val addr  = UInt(12.W)
  val data  = UInt(p.xlen.W)
}

class FaultManagerOutput(p: Parameters) extends Bundle {
  val mepc    = UInt(p.programCounterBits.W)
  val mtval   = UInt(p.xlen.W)
  val mcause  = UInt(p.xlen.W)
  val decode  = Bool()
  val is_rvv  = Option.when(p.enableRvv)(Bool())
  val rob_tag = Option.when(p.enableRvv)(UInt(log2Ceil(p.retirementBufferSize).W))
  val vstart  = Option.when(p.enableRvv)(Valid(UInt(log2Ceil(p.rvvVlen).W)))
}
