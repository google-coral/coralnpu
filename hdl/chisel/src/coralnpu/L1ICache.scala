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

import bus.AxiMasterReadIO
import common._
import _root_.circt.stage.ChiselStage

object L1ICache {
  def apply(p: Parameters): L1ICache = {
    return Module(new L1ICache(p))
  }
}

class L1ICache(p: Parameters) extends Module {
  // A relatively simple cache block. Only one transaction may post at a time.
  // 2^8 * 256  / 8 = 8KiB    4-way  Tag[31,11] + Index[10,5] + Data[4,0]
  assert(p.axi0IdBits == 4)
  assert(p.axi0DataBits == 256 || p.axi0DataBits == 128)

  val slots    = p.l1islots
  val slotBits = log2Ceil(slots)
  val assoc    = p.l1iassoc
  val sets     = slots / assoc
  val setLsb   = log2Ceil(p.fetchDataBits / 8)
  val setMsb   = log2Ceil(sets) + setLsb - 1
  val tagLsb   = setMsb + 1
  val tagMsb   = p.axi0AddrBits - 1

  val io = IO(new Bundle {
    val ibus  = Flipped(new IBusIO(p))
    val flush = Flipped(new IFlushIO(p))
    val axi   = new Bundle {
      val read = new AxiMasterReadIO(p.axi0AddrBits, p.axi0DataBits, p.axi0IdBits)
    }
    val volt_sel = Input(Bool())
  })
  io.ibus.fault := MakeInvalid(new FaultInfo(p))

  assert(assoc == 2 || assoc == 4 || assoc == 8 || assoc == 16 || assoc == slots)
  assert(
    assoc != 2 || (setLsb == 5 && setMsb == 11 && tagLsb == 12) || (setLsb == 4 && setMsb == 10 && tagLsb == 11)
  )
  assert(
    assoc != 4 || (setLsb == 5 && setMsb == 10 && tagLsb == 11) || (setLsb == 4 && setMsb == 9 && tagLsb == 10)
  )
  assert(
    assoc != 8 || (setLsb == 5 && setMsb == 9 && tagLsb == 10) || (setLsb == 4 && setMsb == 8 && tagLsb == 9)
  )
  assert(
    assoc != 16 || (setLsb == 5 && setMsb == 8 && tagLsb == 9) || (setLsb == 4 && setMsb == 7 && tagLsb == 8)
  )
  assert(assoc != slots || tagLsb == 5)

  class Sram_1rw_256x256 extends BlackBox {
    val io = IO(new Bundle {
      val clock    = Input(Clock())
      val valid    = Input(Bool())
      val write    = Input(Bool())
      val addr     = Input(UInt(slotBits.W))
      val wdata    = Input(UInt(256.W))
      val rdata    = Output(UInt(256.W))
      val volt_sel = Input(Bool())
    })
  }

  // ---------------------------------------------------------------------------
  // CAM state.
  val valid   = RegInit(VecInit(Seq.fill(slots)(false.B)))
  val camaddr = Reg(Vec(slots, UInt(p.fetchAddrBits.W)))
  val mem     = Module(new Sram_1rw_256x256())

  val history = Reg(Vec(slots / assoc, Vec(assoc, UInt(log2Ceil(assoc).W))))

  val matchSet  = Wire(Vec(slots, Bool()))
  val matchAddr = Wire(Vec(assoc, Bool()))

  val matchSlotB   = Wire(Vec(slots, Bool()))
  val matchSlot    = matchSlotB.asUInt
  val replaceSlotB = Wire(Vec(slots, Bool()))
  val replaceSlot  = replaceSlotB.asUInt

  // OR mux lookup of associative entries.
  def camaddrRead(i: Int, value: UInt = 0.U(p.fetchAddrBits.W)): UInt = {
    if (i < slots) {
      camaddrRead(i + assoc, value | MuxOR(matchSet(i), camaddr(i)))
    } else {
      value
    }
  }

  for (i <- 0 until assoc) {
    val ca = camaddrRead(i)
    matchAddr(i) := io.ibus.addr(tagMsb, tagLsb) === ca(tagMsb, tagLsb)
  }

  for (i <- 0 until slots) {
    val set      = i / assoc
    val setMatch = if (assoc == slots) true.B else io.ibus.addr(setMsb, setLsb) === set.U
    matchSet(i) := setMatch
  }

  for (i <- 0 until slots) {
    val set   = i / assoc
    val index = i % assoc

    matchSlotB(i) := valid(i) && matchSet(i) && matchAddr(index)

    val historyMatch = history(set)(index) === 0.U
    replaceSlotB(i) := matchSet(i) && historyMatch
    assert((i - set * assoc) == index)
  }

  assert(PopCount(matchSlot) <= 1.U)
  assert(PopCount(replaceSlot) <= 1.U)

  val found = io.ibus.valid && matchSlot =/= 0.U

  val replaceNum = Wire(Vec(slots, UInt(slotBits.W)))
  for (i <- 0 until slots) {
    replaceNum(i) := MuxOR(replaceSlot(i), i.U)
  }

  val replaceId = VecOR(replaceNum, slots)
  assert(replaceId.getWidth == slotBits)

  val readNum = Wire(Vec(slots, UInt(slotBits.W)))
  for (i <- 0 until slots) {
    readNum(i) := MuxOR(matchSlotB(i), i.U)
  }
  val readId = VecOR(readNum, slots)

  for (i <- 0 until slots / assoc) {
    // Get the matched value from the OneHot encoding of the set.
    val matchSet = matchSlot((i + 1) * assoc - 1, i * assoc)
    assert(PopCount(matchSet) <= 1.U)
    val matchIndices = Wire(Vec(assoc, UInt(log2Ceil(assoc).W)))
    for (j <- 0 until assoc) {
      matchIndices(j) := MuxOR(matchSet(j), j.U)
    }
    val matchIndex = VecOR(matchIndices, assoc)
    assert(matchIndex.getWidth == log2Ceil(assoc))
    val matchValue = history(i)(matchIndex)

    // History based on count values so that high set size has less DFF usage.
    when(
      io.ibus.valid && io.ibus.ready && (if (assoc == slots) true.B
                                         else io.ibus.addr(setMsb, setLsb) === i.U)
    ) {
      for (j <- 0 until assoc) {
        when(matchSet(j)) {
          history(i)(j) := (assoc - 1).U
        }.elsewhen(history(i)(j) > matchValue) {
          history(i)(j) := history(i)(j) - 1.U
          assert(history(i)(j) > 0.U)
        }
      }
    }
  }

  // Reset history to unique values within sets.
  // Must be placed below all other assignments.
  // Note the definition is Reg() so will generate an asynchronous reset.
  when(reset.asBool) {
    for (i <- 0 until slots / assoc) {
      for (j <- 0 until assoc) {
        history(i)(j) := j.U
      }
    }
  }

  // These checks are extremely slow to compile.
  if (false) {
    for (i <- 0 until slots / assoc) {
      for (j <- 0 until assoc) {
        for (k <- 0 until assoc) {
          if (j != k) {
            assert(history(i)(j) =/= history(i)(k))
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Core Instruction Bus.
  io.ibus.ready := found

  io.ibus.rdata := mem.io.rdata

  // ---------------------------------------------------------------------------
  // axi interface.
  val axivalid = RegInit(false.B) // io.axi.read.addr.valid
  val axiready = RegInit(false.B) // io.axi.read.data.ready
  val axiaddr  = Reg(UInt(p.axi0AddrBits.W))

  val replaceIdReg = Reg(UInt(slotBits.W))

  when(io.ibus.valid && !io.ibus.ready && !axivalid && !axiready) {
    replaceIdReg := replaceId
  }

  when(io.axi.read.addr.valid && io.axi.read.addr.ready) {
    axivalid := false.B
  }.elsewhen(io.ibus.valid && !io.ibus.ready && !axivalid && !axiready) {
    axivalid := true.B
  }

  when(io.axi.read.data.valid && io.axi.read.data.ready) {
    axiready := false.B
  }.elsewhen(io.axi.read.addr.valid && io.axi.read.addr.ready && !axiready) {
    axiready := true.B
  }

  when(io.flush.valid) {
    for (i <- 0 until slots) {
      valid(i) := false.B
    }
  }.elsewhen(io.ibus.valid && !io.ibus.ready && !axivalid && !axiready) {
    valid(replaceId) := false.B
  }.elsewhen(io.axi.read.data.valid && io.axi.read.data.ready) {
    valid(replaceIdReg) := true.B
  }

  when(io.ibus.valid && !io.ibus.ready && !axivalid && !axiready) {
    val alignedAddr = Cat(io.ibus.addr(p.fetchAddrBits - 1, setLsb), 0.U(setLsb.W))
    axiaddr            := alignedAddr
    camaddr(replaceId) := alignedAddr
  }.elsewhen(io.axi.read.addr.valid && io.axi.read.addr.ready) {
    axiaddr := axiaddr + (p.axi0DataBits / 8).U
  }

  io.axi.read.defaults()
  io.axi.read.addr.valid     := axivalid
  io.axi.read.addr.bits.addr := axiaddr
  io.axi.read.addr.bits.id   := 0.U
  io.axi.read.addr.bits.prot := 2.U
  io.axi.read.data.ready     := axiready

  io.flush.ready := true.B

  // IBus transaction must latch until completion.
  val addrLatchActive = RegInit(false.B)
  val addrLatchData   = Reg(UInt(p.fetchAddrBits.W))

  when(io.flush.valid) {
    addrLatchActive := false.B
  }.elsewhen(io.ibus.valid && !io.ibus.ready && !addrLatchActive) {
    addrLatchActive := true.B
    addrLatchData   := io.ibus.addr
  }.elsewhen(addrLatchActive && io.ibus.ready) {
    addrLatchActive := false.B
  }

  assert(!(addrLatchActive && !io.ibus.valid))
  assert(!(addrLatchActive && addrLatchData =/= io.ibus.addr))

  // ---------------------------------------------------------------------------
  // Memory controls.
  val memwrite = io.axi.read.data.valid && io.axi.read.data.ready
  val memread  = io.ibus.valid && !axivalid && !axiready
  mem.io.clock    := clock
  mem.io.valid    := memread || memwrite
  mem.io.write    := axiready
  mem.io.addr     := Mux(axiready, replaceIdReg, readId)
  mem.io.wdata    := Cat(0.U((256 - p.axi0DataBits).W), io.axi.read.data.bits.data)
  mem.io.volt_sel := io.volt_sel
}

object EmitL1ICache extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new L1ICache(p), args)
}
