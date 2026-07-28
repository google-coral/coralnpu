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

import bus.AxiMasterIO
import common._
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

object L1DCache {
  def apply(p: Parameters): L1DCache = {
    return Module(new L1DCache(p))
  }
}

object L1DCacheBank {
  def apply(p: Parameters): L1DCacheBank = {
    return Module(new L1DCacheBank(p))
  }
}

class L1DCache(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val dbus     = Flipped(new DBusIO(p))
    val axi      = new AxiMasterIO(p.axi1AddrBits, p.axi1DataBits, p.axi1IdBits)
    val flush    = Flipped(new DFlushIO(p))
    val volt_sel = Input(Bool())
  })
  io.axi.defaults()

  assert(p.axi1IdBits == 4)
  assert(p.axi1DataBits == 256 || p.axi1DataBits == 128)

  val bank0 = Module(new L1DCacheBank(p))
  val bank1 = Module(new L1DCacheBank(p))

  val linebit   = log2Ceil(p.lsuDataBits / 8)
  val linebytes = 1 << linebit

  // Remove bank select bit from address.
  def BankInAddress(addr: UInt): UInt = {
    assert(addr.getWidth == p.lsuAddrBits)
    val output = Cat(addr(p.lsuAddrBits - 1, linebit + 1), addr(linebit - 1, 0))
    assert(output.getWidth == (p.lsuAddrBits - 1))
    output
  }

  // Add bank select bit to address.
  def BankOutAddress(addr: UInt, bank: Int): UInt = {
    assert(addr.getWidth == (p.axi1AddrBits - 1))
    val output = Cat(addr(p.axi1AddrBits - 2, linebit), bank.U(1.W), addr(linebit - 1, 0))
    assert(output.getWidth == p.axi1AddrBits)
    output
  }

  assert(io.dbus.size <= linebytes.U)

  // ---------------------------------------------------------------------------
  // Data bus multiplexor.
  val lineend = (io.dbus.addr(linebit - 1, 0) + io.dbus.size) > linebytes.U
  val dempty  = io.dbus.size === 0.U
  val dsel0   = io.dbus.addr(linebit) === 0.U && !dempty || lineend
  val dsel1   = io.dbus.addr(linebit) === 1.U && !dempty || lineend
  val preread = ~io.dbus.addr(11, linebit) =/= 0.U && !io.dbus.write && !dempty // Within 4KB
  val addrA   = Mux(io.dbus.addr(linebit), BankInAddress(io.dbus.adrx), BankInAddress(io.dbus.addr))
  val addrB   = Mux(io.dbus.addr(linebit), BankInAddress(io.dbus.addr), BankInAddress(io.dbus.adrx))
  val rsel    = Reg(Vec(linebytes, Bool()))

  assert(!(io.dbus.valid && io.dbus.adrx =/= (io.dbus.addr + linebytes.U)))

  // Write masks
  val wmaskSA = ((~0.U(linebytes.W)) << io.dbus.addr(linebit - 1, 0))(linebytes - 1, 0)
  val wmaskSB =
    ((~0.U(linebytes.W)) >> (linebytes.U - io.dbus.addr(linebit - 1, 0)))(linebytes - 1, 0)
  val wmaskA = io.dbus.wmask & wmaskSA
  val wmaskB = io.dbus.wmask & wmaskSB
  assert(wmaskSA.getWidth == io.dbus.wmask.getWidth)
  assert(wmaskSB.getWidth == io.dbus.wmask.getWidth)
  assert(wmaskA.getWidth == io.dbus.wmask.getWidth)
  assert(wmaskB.getWidth == io.dbus.wmask.getWidth)
  assert((wmaskSA | wmaskSB) === ~0.U(linebytes.W))
  assert((wmaskSA & wmaskSB) === 0.U)

  bank0.io.dbus.valid := io.dbus.valid && (dsel0 || preread)
  bank0.io.dbus.write := io.dbus.write
  bank0.io.dbus.wmask := Mux(io.dbus.addr(linebit), wmaskB, wmaskA)
  bank0.io.dbus.size  := io.dbus.size
  bank0.io.dbus.addr  := addrA
  bank0.io.dbus.adrx  := addrB
  bank0.io.dbus.wdata := io.dbus.wdata
  bank0.io.dbus.pc    := 0.U

  bank1.io.dbus.valid := io.dbus.valid && (dsel1 || preread)
  bank1.io.dbus.write := io.dbus.write
  bank1.io.dbus.wmask := Mux(io.dbus.addr(linebit), wmaskA, wmaskB)
  bank1.io.dbus.size  := io.dbus.size
  bank1.io.dbus.addr  := addrB
  bank1.io.dbus.adrx  := addrA
  bank1.io.dbus.wdata := io.dbus.wdata
  bank1.io.dbus.pc    := 0.U

  val dbusready = (bank0.io.dbus.ready || !dsel0) &&
    (bank1.io.dbus.ready || !dsel1)

  // Read bank selection.
  when(io.dbus.valid && dbusready && !io.dbus.write) {
    val addr = io.dbus.addr(linebit, 0)
    for (i <- 0 until linebytes) {
      // reverse order to index usage
      rsel(linebytes - 1 - i) := (addr + i.U)(linebit)
    }
  }

  def RData(data: UInt = 0.U(1.W), i: Int = 0): UInt = {
    if (i < p.lsuDataBits / 8) {
      val d0 = bank0.io.dbus.rdata(8 * i + 7, 8 * i)
      val d1 = bank1.io.dbus.rdata(8 * i + 7, 8 * i)
      val d  = Mux(rsel(i), d1, d0)
      val r  = if (i == 0) d else Cat(d, data)
      assert(d.getWidth == 8)
      assert(r.getWidth == (i + 1) * 8)
      RData(r, i + 1)
    } else {
      data
    }
  }

  io.dbus.rdata := RData()

  io.dbus.ready := dbusready

  // dbus transaction must latch until completion.
  val addrLatchActive = RegInit(false.B)
  val addrLatchData   = Reg(UInt(p.lsuAddrBits.W))

  when(io.dbus.valid && !io.dbus.ready && !addrLatchActive) {
    addrLatchActive := true.B
    addrLatchData   := io.dbus.addr
  }.elsewhen(addrLatchActive && io.dbus.ready) {
    addrLatchActive := false.B
  }

  // assert(!(addrLatchActive && !io.dbus.valid)) -- do not use, allow temporary deassertion
  assert(!(addrLatchActive && addrLatchData =/= io.dbus.addr))

  // ---------------------------------------------------------------------------
  // AXI read bus multiplexor.
  val rresp0 = io.axi.read.data.bits.id(p.axi1IdBits - 1) === 0.U
  val rresp1 = io.axi.read.data.bits.id(p.axi1IdBits - 1) === 1.U

  val raxi0 = bank0.io.axi.read.addr.valid
  val raxi1 = !raxi0

  io.axi.read.addr.valid     := bank0.io.axi.read.addr.valid || bank1.io.axi.read.addr.valid
  io.axi.read.addr.bits.addr := Mux(
    raxi0,
    BankOutAddress(bank0.io.axi.read.addr.bits.addr, 0),
    BankOutAddress(bank1.io.axi.read.addr.bits.addr, 1)
  )
  io.axi.read.addr.bits.id := Mux(
    raxi0,
    Cat(0.U(1.W), bank0.io.axi.read.addr.bits.id),
    Cat(1.U(1.W), bank1.io.axi.read.addr.bits.id)
  )
  io.axi.read.addr.bits.prot := 2.U

  bank0.io.axi.read.addr.ready := io.axi.read.addr.ready && raxi0
  bank1.io.axi.read.addr.ready := io.axi.read.addr.ready && raxi1

  bank0.io.axi.read.data.valid := io.axi.read.data.valid && rresp0
  bank0.io.axi.read.data.bits  := io.axi.read.data.bits

  bank1.io.axi.read.data.valid := io.axi.read.data.valid && rresp1
  bank1.io.axi.read.data.bits  := io.axi.read.data.bits

  io.axi.read.data.ready := bank0.io.axi.read.data.ready && rresp0 ||
    bank1.io.axi.read.data.ready && rresp1

  // ---------------------------------------------------------------------------
  // AXI write bus multiplexor.
  val waxi0  = Wire(Bool())
  val waxi1  = Wire(Bool())
  val wresp0 = io.axi.write.resp.bits.id(p.axi1IdBits - 1) === 0.U
  val wresp1 = io.axi.write.resp.bits.id(p.axi1IdBits - 1) === 1.U

  if (true) {
    waxi0 := bank0.io.axi.write.addr.valid
    waxi1 := !waxi0
  } else {
    // Flushes interleave banks for whole line writes.
    // Change when selected bank not active and other is active.
    // Change on last transaction in a line write.
    val wsel = RegInit(false.B)

    when(wsel) {
      when(bank0.io.axi.write.addr.valid && !bank1.io.axi.write.addr.valid) {
        wsel := false.B
      }.elsewhen(
        bank1.io.axi.write.addr.valid && bank1.io.axi.write.addr.ready && bank1.io.axi.write.addr.bits.id === ~0
          .U((p.axi1IdBits - 1).W)
      ) {
        wsel := false.B
      }
    }.otherwise {
      when(bank1.io.axi.write.addr.valid && !bank0.io.axi.write.addr.valid) {
        wsel := true.B
      }.elsewhen(
        bank0.io.axi.write.addr.valid && bank0.io.axi.write.addr.ready && bank0.io.axi.write.addr.bits.id === ~0
          .U((p.axi1IdBits - 1).W)
      ) {
        wsel := true.B
      }
    }

    waxi0 := wsel === false.B
    waxi1 := wsel === true.B
  }

  io.axi.write.addr.valid := bank0.io.axi.write.addr.valid && waxi0 ||
    bank1.io.axi.write.addr.valid && waxi1
  io.axi.write.addr.bits.addr := Mux(
    waxi0,
    BankOutAddress(bank0.io.axi.write.addr.bits.addr, 0),
    BankOutAddress(bank1.io.axi.write.addr.bits.addr, 1)
  )
  io.axi.write.addr.bits.id := Mux(
    waxi0,
    Cat(0.U(1.W), bank0.io.axi.write.addr.bits.id),
    Cat(1.U(1.W), bank1.io.axi.write.addr.bits.id)
  )
  io.axi.write.addr.bits.prot := 2.U

  io.axi.write.data.valid := bank0.io.axi.write.data.valid && waxi0 ||
    bank1.io.axi.write.data.valid && waxi1
  io.axi.write.data.bits := Mux(waxi0, bank0.io.axi.write.data.bits, bank1.io.axi.write.data.bits)

  bank0.io.axi.write.addr.ready := io.axi.write.addr.ready && waxi0
  bank1.io.axi.write.addr.ready := io.axi.write.addr.ready && waxi1
  bank0.io.axi.write.data.ready := io.axi.write.data.ready && waxi0
  bank1.io.axi.write.data.ready := io.axi.write.data.ready && waxi1

  bank0.io.axi.write.resp.valid := io.axi.write.resp.valid && wresp0
  bank0.io.axi.write.resp.bits  := io.axi.write.resp.bits

  bank1.io.axi.write.resp.valid := io.axi.write.resp.valid && wresp1
  bank1.io.axi.write.resp.bits  := io.axi.write.resp.bits

  io.axi.write.resp.ready := bank0.io.axi.write.resp.ready && wresp0 ||
    bank1.io.axi.write.resp.ready && wresp1

  assert(!(io.axi.write.addr.valid && !io.axi.write.data.valid))
  assert(!(io.axi.write.addr.valid && (io.axi.write.addr.ready =/= io.axi.write.data.ready)))

  // ---------------------------------------------------------------------------
  // Flush controls.
  // bank0.io.flush.valid := io.flush.valid && bank1.io.flush.ready
  // bank1.io.flush.valid := io.flush.valid && bank0.io.flush.ready
  bank0.io.flush.valid := io.flush.valid
  bank0.io.flush.all   := io.flush.all
  bank0.io.flush.clean := io.flush.clean

  bank1.io.flush.valid := io.flush.valid
  bank1.io.flush.all   := io.flush.all
  bank1.io.flush.clean := io.flush.clean

  io.flush.ready := bank0.io.flush.ready && bank1.io.flush.ready

  // Voltage Selection
  bank0.io.volt_sel := io.volt_sel
  bank1.io.volt_sel := io.volt_sel
}

class L1DCacheBank(p: Parameters) extends Module {
  // A relatively simple cache block. Only one transaction may post at a time.
  // 2^8 * 256  / 8 = 8KiB    4-way  Tag[31,12] + Index[11,6] + Data[5,0]
  val slots    = p.l1dslots
  val slotBits = log2Ceil(slots)
  val assoc    = p.l1dassoc
  val sets     = slots / assoc
  val setLsb   = log2Ceil(p.lsuDataBits / 8)
  val setMsb   = log2Ceil(sets) + setLsb - 1
  val tagLsb   = setMsb + 1
  val tagMsb   = p.axi1AddrBits - 2

  val io = IO(new Bundle {
    val dbus     = Flipped(new DBusIO(p, true))
    val axi      = new AxiMasterIO(p.axi1AddrBits - 1, p.axi1DataBits, p.axi1IdBits - 1)
    val flush    = Flipped(new DFlushIO(p))
    val volt_sel = Input(Bool())
  })
  io.axi.defaults()

  // AXI memory consistency, maintain per-byte strobes.
  val bytes = p.lsuDataBits / 8

  def Mem8to9(d: UInt, m: UInt): UInt = {
    assert(d.getWidth == 256)
    assert(m.getWidth == 256 / 8)
    val data = Wire(Vec(bytes, UInt(9.W)))
    for (i <- 0 until bytes) {
      data(i) := Cat(m(i), d(7 + i * 8, 0 + i * 8))
    }
    data.asUInt
  }

  def Mem9to8(d: UInt): UInt = {
    assert(d.getWidth == 256 * 9 / 8)
    val data = Wire(Vec(bytes, UInt(8.W)))
    for (i <- 0 until bytes) {
      data(i) := d(7 + i * 9, 0 + i * 9)
    }
    data.asUInt
  }

  def Mem9to1(d: UInt): UInt = {
    assert(d.getWidth == 256 * 9 / 8)
    val data = Wire(Vec(bytes, UInt(1.W)))
    for (i <- 0 until bytes) {
      data(i) := Cat(d(8 + i * 9))
    }
    data.asUInt
  }

  val checkBit =
    if (p.lsuDataBits == 128) 4
    else if (p.lsuDataBits == 256) 5
    else 6
  assert(assoc == 2 || assoc == 4 || assoc == 8 || assoc == 16 || assoc == slots)
  assert(assoc != 2 || setLsb == checkBit && setMsb == (checkBit + 6) && tagLsb == (checkBit + 7))
  assert(assoc != 4 || setLsb == checkBit && setMsb == (checkBit + 5) && tagLsb == (checkBit + 6))
  assert(assoc != 8 || setLsb == checkBit && setMsb == (checkBit + 4) && tagLsb == (checkBit + 5))
  assert(assoc != 16 || setLsb == checkBit && setMsb == (checkBit + 3) && tagLsb == (checkBit + 4))
  assert(assoc != slots || tagLsb == checkBit)

  class Sram_1rwm_256x288 extends BlackBox {
    val io = IO(new Bundle {
      val clock    = Input(Clock())
      val valid    = Input(Bool())
      val write    = Input(Bool())
      val addr     = Input(UInt(slotBits.W))
      val wdata    = Input(UInt((256 * 9 / 8).W))
      val wmask    = Input(UInt((256 * 1 / 8).W))
      val rdata    = Output(UInt((256 * 9 / 8).W))
      val volt_sel = Input(Bool())
    })
  }

  // Check io.dbus.wmask is in range of addr and size.
  val busbytes = p.lsuDataBits / 8
  val linemsb  = log2Ceil(busbytes)
  val chkmask0 = (~0.U(busbytes.W)) >> (busbytes.U - io.dbus.size)
  val chkmask1 = Cat(chkmask0, chkmask0) << io.dbus.addr(linemsb - 1, 0)
  val chkmask  = chkmask1(2 * busbytes - 1, busbytes)
  assert(!(io.dbus.valid && io.dbus.write) || (io.dbus.wmask & ~chkmask) === 0.U)

  // ---------------------------------------------------------------------------
  // CAM state.
  val valid   = RegInit(VecInit(Seq.fill(slots)(false.B)))
  val dirty   = RegInit(VecInit(Seq.fill(slots)(false.B)))
  val camaddr = Reg(Vec(slots, UInt((p.lsuAddrBits - 1).W)))
  val mem     = Module(new Sram_1rwm_256x288())

  val history = Reg(Vec(slots / assoc, Vec(assoc, UInt(log2Ceil(assoc).W))))

  val matchSet  = Wire(Vec(slots, Bool()))
  val matchAddr = Wire(Vec(assoc, Bool()))

  val matchSlotB   = Wire(Vec(slots, Bool()))
  val matchSlot    = matchSlotB.asUInt
  val replaceSlotB = Wire(Vec(slots, Bool()))
  val replaceSlot  = replaceSlotB.asUInt

  def camaddrRead(i: Int, value: UInt = 0.U(p.lsuAddrBits.W)): UInt = {
    if (i < slots) {
      camaddrRead(i + assoc, value | MuxOR(matchSet(i), camaddr(i)))
    } else {
      value
    }
  }

  for (i <- 0 until assoc) {
    val ca = camaddrRead(i)
    matchAddr(i) := io.dbus.addr(tagMsb, tagLsb) === ca(tagMsb, tagLsb)
  }

  for (i <- 0 until slots) {
    val set      = i / assoc
    val setMatch = if (assoc == slots) true.B else io.dbus.addr(setMsb, setLsb) === set.U
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

  val found = matchSlot =/= 0.U

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
  val foundId = VecOR(readNum, slots)

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
      io.dbus.valid && io.dbus.ready && (if (assoc == slots) true.B
                                         else io.dbus.addr(setMsb, setLsb) === i.U)
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
  // Flush interface.
  object FlushState extends ChiselEnum {
    val sNone, sCapture, sProcess, sMemwaddr, sMemwdata, sAxiready, sAxiresp, sEnd = Value
  }

  val fstate = RegInit(FlushState.sNone)
  val flush  = RegInit(VecInit(Seq.fill(slots)(false.B)))

  // ---------------------------------------------------------------------------
  // AXI interface.
  val ractive = RegInit(false.B)
  val wactive = RegInit(false.B)
  val active  = ractive || wactive

  assert(!(ractive && fstate =/= FlushState.sNone))

  val axiraddrvalid = RegInit(false.B)
  val axirdataready = RegInit(false.B)

  val memwaddrEn    = RegInit(false.B)
  val memwdataEn    = RegInit(false.B)
  val axiwaddrvalid = RegInit(false.B)
  val axiwdatavalid = RegInit(false.B)
  val axiwdatabuf   = Reg(UInt(p.axi1DataBits.W))
  val axiwstrbbuf   = Reg(UInt((p.axi1DataBits / 8).W))

  val axiraddr = Reg(UInt((p.axi1AddrBits - 1).W))
  val axiwaddr = Reg(UInt((p.axi1AddrBits - 1).W))

  val replaceIdReg = Reg(UInt(slotBits.W))

  val alignedAddr = Cat(io.dbus.addr(tagMsb, setLsb), 0.U(setLsb.W))

  when(io.dbus.valid && !io.dbus.ready && !active) {
    ractive := true.B
    wactive := dirty(replaceId)
    assert(!(dirty(replaceId) && !valid(replaceId)))
    axiraddrvalid      := true.B
    axirdataready      := true.B
    valid(replaceId)   := false.B
    dirty(replaceId)   := false.B
    replaceIdReg       := replaceId
    camaddr(replaceId) := alignedAddr
    axiraddr           := alignedAddr
    axiwaddr           := camaddr(replaceId)
  }

  // Writeback pulsed controls to memory.
  memwaddrEn := io.dbus.valid && !io.dbus.ready && !active && dirty(replaceId)
  memwdataEn := memwaddrEn

  when(io.dbus.valid && io.dbus.ready && io.dbus.write) {
    dirty(foundId) := true.B
  }

  when(io.axi.read.addr.valid && io.axi.read.addr.ready) {
    axiraddrvalid := false.B
  }

  when(io.axi.read.data.valid && io.axi.read.data.ready) {
    valid(replaceIdReg) := true.B
    axirdataready       := false.B
    ractive             := false.B
  }

  when(memwdataEn) {
    val rdata = mem.io.rdata
    axiwdatabuf   := Mem9to8(rdata)
    axiwstrbbuf   := Mem9to1(rdata)
    axiwaddrvalid := true.B
    axiwdatavalid := true.B
  }

  when(io.axi.write.addr.valid && io.axi.write.addr.ready) {
    axiwaddrvalid := false.B
  }

  when(io.axi.write.data.valid && io.axi.write.data.ready) {
    axiwdatavalid := false.B
  }

  when(io.axi.write.resp.valid && io.axi.write.resp.ready) {
    wactive := false.B
  }

  io.axi.read.addr.valid     := axiraddrvalid
  io.axi.read.addr.bits.addr := axiraddr
  io.axi.read.addr.bits.id   := 0.U
  io.axi.read.addr.bits.prot := 2.U
  io.axi.read.data.ready     := axirdataready
  assert(!(io.axi.read.data.valid && !io.axi.read.data.ready))

  io.axi.write.addr.valid     := axiwaddrvalid
  io.axi.write.addr.bits.id   := 0.U
  io.axi.write.addr.bits.prot := 2.U
  io.axi.write.addr.bits.addr := axiwaddr

  io.axi.write.resp.ready := true.B

  io.axi.write.data.valid     := axiwdatavalid
  io.axi.write.data.bits.last := true.B
  io.axi.write.data.bits.data := axiwdatabuf.asUInt
  io.axi.write.data.bits.strb := axiwstrbbuf.asUInt

  assert(!(io.axi.read.addr.valid && !ractive))
  assert(!(io.axi.read.data.ready && !ractive))
  assert(!(io.axi.write.addr.valid && !wactive && fstate === FlushState.sNone))

  // ---------------------------------------------------------------------------
  // Axi Write Response Count.
  val wrespcnt = RegInit(0.U((slotBits + 1).W))
  val wrespinc = io.axi.write.addr.valid && io.axi.write.addr.ready
  val wrespdec = io.axi.write.resp.valid && io.axi.write.resp.ready

  when(wrespinc && !wrespdec) {
    wrespcnt := wrespcnt + 1.U
  }.elsewhen(!wrespinc && wrespdec) {
    wrespcnt := wrespcnt - 1.U
  }

  // ---------------------------------------------------------------------------
  // Flush interface.
  val flushId = Ctz(flush.asUInt)(slotBits - 1, 0)

  for (i <- 0 until slots) {
    assert(!(flush(i) && !dirty(i)))
  }

  switch(fstate) {
    is(FlushState.sNone) {
      when(io.flush.valid && !axiwaddrvalid && !axiwdatavalid && !axiraddrvalid && !axirdataready) {
        fstate       := FlushState.sCapture
        replaceIdReg := foundId
      }
    }

    is(FlushState.sCapture) {
      fstate              := FlushState.sProcess
      flush(replaceIdReg) := dirty(replaceIdReg) // matched (without .all)
      when(io.flush.all) {
        for (i <- 0 until slots) {
          flush(i) := dirty(i)
        }
      }
    }

    is(FlushState.sProcess) {
      when(flush.asUInt === 0.U) {
        fstate := FlushState.sAxiresp
      }.otherwise {
        fstate     := FlushState.sMemwaddr
        memwaddrEn := true.B
      }
      replaceIdReg := flushId
    }

    is(FlushState.sMemwaddr) {
      assert(memwaddrEn)
      fstate              := FlushState.sMemwdata
      axiwaddr            := camaddr(replaceIdReg)
      flush(replaceIdReg) := false.B
      dirty(replaceIdReg) := false.B
      when(io.flush.clean) {
        valid(replaceIdReg) := false.B
      }
    }

    is(FlushState.sMemwdata) {
      assert(memwdataEn)
      fstate := FlushState.sAxiready
    }

    is(FlushState.sAxiready) {
      when(
        (!axiwaddrvalid || io.axi.write.addr.valid && io.axi.write.addr.ready) &&
          (!axiwdatavalid || io.axi.write.data.valid && io.axi.write.data.ready)
      ) {
        fstate := FlushState.sProcess
      }
    }

    is(FlushState.sAxiresp) {
      when(wrespcnt === 0.U) {
        fstate := FlushState.sEnd
      }
    }

    is(FlushState.sEnd) {
      // Must complete the handshake as there are multiple banks.
      when(io.flush.ready && !io.flush.valid) {
        fstate := FlushState.sNone
      }
      when(io.flush.clean) {
        when(io.flush.all) {
          for (i <- 0 until slots) {
            valid(i) := false.B
            assert(!dirty(i))
            assert(!flush(i))
          }
        }
      }
    }
  }

  io.flush.ready := fstate === FlushState.sEnd

  assert(!(io.flush.valid && io.dbus.valid))

  // ---------------------------------------------------------------------------
  // Core Data Bus.
  io.dbus.ready := found && !ractive
  io.dbus.rdata := Mem9to8(mem.io.rdata)
  assert(!(io.dbus.valid && io.dbus.size === 0.U))

  // ---------------------------------------------------------------------------
  // Memory controls.
  val axiwrite = memwaddrEn
  val axiread  = io.axi.read.data.valid && io.axi.read.data.ready
  val buswrite = io.dbus.valid && io.dbus.ready && io.dbus.write
  val busread  = io.dbus.valid && !io.dbus.write && !ractive

  val wdbits = p.axi1DataBits
  val wmbits = p.axi1DataBits / 8
  val id     = io.axi.read.data.bits.id
  val rsel   = axirdataready

  mem.io.clock := clock
  mem.io.valid := busread || buswrite || axiread || axiwrite
  mem.io.write := rsel && !axiwrite || io.dbus.valid && io.dbus.write && !ractive
  mem.io.addr  := Mux(rsel || axiwrite, replaceIdReg, foundId)
  mem.io.wmask := Mux(rsel, ~0.U(wmbits.W), io.dbus.wmask)
  mem.io.wdata :=
    Mux(
      rsel,
      Mem8to9(
        Cat(0.U((256 - io.axi.read.data.bits.data.getWidth).W), io.axi.read.data.bits.data),
        Cat(0.U((32 - wmbits).W), 0.U(wmbits.W))
      ),
      Mem8to9(
        Cat(0.U((256 - io.dbus.wdata.getWidth).W), io.dbus.wdata),
        Cat(0.U((32 - wmbits).W), ~0.U(wmbits.W))
      )
    )
  mem.io.volt_sel := io.volt_sel

  assert(PopCount(busread +& buswrite +& axiread) <= 1.U)
}

@nowarn
object EmitL1DCache extends App {
  val p = new Parameters
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new L1DCache(p))) ++ Seq(
      FirtoolOption("-enable-layers=Verification")
    )
  )
}

@nowarn
object EmitL1DCacheBank extends App {
  val p = new Parameters
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new L1DCacheBank(p))) ++ Seq(
      FirtoolOption("-enable-layers=Verification")
    )
  )
}
