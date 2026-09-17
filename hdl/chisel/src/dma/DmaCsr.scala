// Copyright 2026 Google LLC
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

package dma

import bus._

import chisel3._
import chisel3.util._

object CsrState extends ChiselEnum {
  val sIdle, sRunning = Value
}

object DmaCsrAddrs {
  val CTRL      = 0x00
  val STATUS    = 0x04
  val SRC_ADDR  = 0x08
  val DST_ADDR  = 0x0c
  val LEN_FLAGS = 0x10
}

class DmaCsr(p: TLULParameters) extends Module {
  import DmaCsrAddrs._

  val N      = p.w
  val gMax   = DmaGeometry.gMax(p)
  val sWidth = DmaGeometry.sWidth(p)

  val lenBits = (new DmaLenFlags).xfer_len.getWidth
  val tWidth  = lenBits - gMax + 1

  val regWidth     = 32
  val regBytes     = regWidth / 8
  val lanesPerBeat = (8 * p.w) / regWidth

  val io = IO(new Bundle {
    val tl          = Flipped(new TLULHost2Device[NoUser, NoUser](p))
    val desc        = Decoupled(new FillDescriptor(p))
    val fillBusy    = Input(Bool())
    val drainBusy   = Input(Bool())
    val engineError = Input(Bool())
    val busy        = Output(Bool())
    val error       = Output(Bool())
  })

  val tl_a = io.tl.a
  val tl_d = io.tl.d

  // Low bits only, so the block does not care about its crossbar base address.
  val addr        = tl_a.bits.address(11, 0)
  val alignedAddr = addr & ~((p.w - 1).U(12.W))

  val isGet = tl_a.bits.opcode === TLULOpcodesA.Get.asUInt
  val isPut = tl_a.bits.opcode === TLULOpcodesA.PutFullData.asUInt ||
    tl_a.bits.opcode === TLULOpcodesA.PutPartialData.asUInt
  val writeEn = tl_a.fire && isPut

  // A register's 32-bit lane follows from its offset. Deriving it from p.w keeps
  // this right whether the bus is 16 or 32 bytes; the map just splits across
  // more beats on a narrow bus.
  def laneOf(offset: Int): Int = (offset % p.w) / regBytes
  def wdata(offset: Int): UInt = {
    val lo = regWidth * laneOf(offset)
    tl_a.bits.data(lo + regWidth - 1, lo)
  }
  def hits(offset: Int): Bool = writeEn && (addr === offset.U)

  // ==========================================
  // SOFTWARE-VISIBLE REGISTERS
  // ==========================================
  val enableReg   = RegInit(false.B)
  val srcAddrReg  = RegInit(0.U(p.a.W))
  val dstAddrReg  = RegInit(0.U(p.a.W))
  val lenFlagsReg = RegInit(0.U(32.W))

  val doneReg     = RegInit(false.B)
  val alignErrReg = RegInit(false.B)
  val cfgErrReg   = RegInit(false.B)
  val xferErrReg  = RegInit(false.B)

  val state   = RegInit(CsrState.sIdle)
  val idle    = state === CsrState.sIdle
  val running = state === CsrState.sRunning

  val ctrlWrite = hits(CTRL)
  val ctrlData  = wdata(CTRL)

  // Taken from the write data so one ENABLE|START store both arms and fires.
  // CTRL[2] is abort: reserved, not implemented.
  val enableEff  = Mux(ctrlWrite, ctrlData(0), enableReg)
  val startWrite = ctrlWrite && ctrlData(1)

  // ==========================================
  // DERIVED GEOMETRY
  // ==========================================
  val lenFlags = lenFlagsReg.asTypeOf(new DmaLenFlags)
  val len      = lenFlags.xfer_len
  val fullMask = Fill(N, 1.U)

  val totalBeats = ((len +& (N - 1).U) >> gMax).asUInt
  val tailBytes  = len(gMax - 1, 0)
  val tailMask   = Mux(
    tailBytes === 0.U,
    fullMask,
    ((1.U((N + 1).W) << tailBytes).asUInt - 1.U)(N - 1, 0)
  )

  val alignError = (srcAddrReg(gMax - 1, 0) =/= 0.U) || (dstAddrReg(gMax - 1, 0) =/= 0.U)
  // Full-width beats only, and none of the peripheral-FIFO modes.
  val cfgError = (lenFlags.xfer_width =/= gMax.U) ||
    lenFlags.src_fixed || lenFlags.dst_fixed || lenFlags.poll_en ||
    (len === 0.U)

  val startReq = startWrite && enableEff && idle
  val startOk  = startReq && !alignError && !cfgError

  // ==========================================
  // CHUNK GENERATOR
  // ==========================================
  val cur_src     = RegInit(0.U(p.a.W))
  val cur_dst     = RegInit(0.U(p.a.W))
  val remaining   = RegInit(0.U(tWidth.W))
  val lastMaskReg = RegInit(0.U(N.W))

  val chunk  = Mux(remaining > N.U, N.U, remaining)(sWidth - 1, 0)
  val isLast = remaining <= N.U

  io.desc.valid            := running && (remaining =/= 0.U)
  io.desc.bits.srcAddr     := cur_src
  io.desc.bits.dstAddr     := cur_dst
  io.desc.bits.stride      := chunk
  io.desc.bits.logElemSize := gMax.U
  // The tail lands on the final beat of the final chunk only.
  io.desc.bits.lastMask := Mux(isLast, lastMaskReg, fullMask)

  val advance = (chunk << gMax).asUInt

  cur_src := Mux(
    startOk,
    srcAddrReg,
    Mux(io.desc.fire, cur_src + advance, cur_src)
  )
  cur_dst := Mux(
    startOk,
    dstAddrReg,
    Mux(io.desc.fire, cur_dst + advance, cur_dst)
  )
  remaining := Mux(
    startOk,
    totalBeats,
    Mux(io.desc.fire, remaining - chunk, remaining)
  )
  lastMaskReg := Mux(startOk, tailMask, lastMaskReg)

  // ==========================================
  // SEQUENCER
  // ==========================================
  val allDone = running && (remaining === 0.U) && !io.fillBusy && !io.drainBusy

  state := MuxCase(
    state,
    Seq(
      (idle && startOk) -> CsrState.sRunning,
      allDone           -> CsrState.sIdle
    )
  )

  enableReg := Mux(ctrlWrite, ctrlData(0), enableReg)

  // Config is frozen while running, so a stray write cannot corrupt a live
  // transfer or desynchronise cur_src from srcAddrReg.
  srcAddrReg  := Mux(hits(SRC_ADDR) && idle, wdata(SRC_ADDR), srcAddrReg)
  dstAddrReg  := Mux(hits(DST_ADDR) && idle, wdata(DST_ADDR), dstAddrReg)
  lenFlagsReg := Mux(hits(LEN_FLAGS) && idle, wdata(LEN_FLAGS), lenFlagsReg)

  doneReg     := Mux(startReq, false.B, Mux(allDone, true.B, doneReg))
  alignErrReg := Mux(startReq, alignError, alignErrReg)
  cfgErrReg   := Mux(startReq, cfgError, cfgErrReg)
  xferErrReg  := Mux(startReq, false.B, Mux(io.engineError, true.B, xferErrReg))

  val errorAny = alignErrReg || cfgErrReg || xferErrReg

  io.busy  := running
  io.error := errorAny

  assert(!io.desc.fire || running, "Descriptor issued outside a transfer")
  assert(!io.desc.fire || (chunk =/= 0.U), "Zero-beat chunk")
  assert(!io.desc.fire || (chunk <= N.U), "Chunk exceeds buffer depth")
  assert(!allDone || (remaining === 0.U), "Done with beats remaining")
  assert(!startOk || (totalBeats =/= 0.U), "Start with zero beats")

  // ==========================================
  // READ PATH
  // ==========================================
  val ctrlVal   = Cat(0.U((regWidth - 1).W), enableReg)
  val statusVal = Cat(0.U((regWidth - 5).W), cfgErrReg, alignErrReg, errorAny, doneReg, running)

  val readMap = Map(
    CTRL      -> ctrlVal,
    STATUS    -> statusVal,
    SRC_ADDR  -> srcAddrReg,
    DST_ADDR  -> dstAddrReg,
    LEN_FLAGS -> lenFlagsReg
  )

  val readData = Wire(Vec(lanesPerBeat, UInt(regWidth.W)))
  for (i <- 0 until lanesPerBeat) {
    readData(i) := 0.U
  }

  // A read returns every register sharing that aligned beat, each in its lane.
  for ((base, regs) <- readMap.groupBy { case (offset, _) => offset & ~(p.w - 1) }) {
    when(alignedAddr === base.U) {
      for ((offset, value) <- regs) {
        readData(laneOf(offset)) := value
      }
    }
  }

  val addrValid = readMap.keys.map(o => addr === o.U).reduce(_ || _)

  // ==========================================
  // D CHANNEL
  // ==========================================
  val d_valid_reg  = RegInit(false.B)
  val d_opcode_reg = RegInit(0.U(3.W))
  val d_size_reg   = RegInit(0.U(tl_a.bits.size.getWidth.W))
  val d_source_reg = RegInit(0.U(tl_a.bits.source.getWidth.W))
  val d_data_reg   = Reg(UInt((8 * p.w).W))
  val d_error_reg  = RegInit(false.B)

  // One-deep response buffer: hold means the consumer has not taken the last
  // response yet, so do not overwrite it and do not accept a new request.
  val hold = d_valid_reg && !tl_d.ready
  d_valid_reg := Mux(hold, true.B, tl_a.fire)

  when(!hold) {
    d_opcode_reg := Mux(isGet, TLULOpcodesD.AccessAckData.asUInt, TLULOpcodesD.AccessAck.asUInt)
    d_size_reg   := tl_a.bits.size
    d_source_reg := tl_a.bits.source
    d_error_reg  := !addrValid
    d_data_reg   := readData.asUInt
  }

  tl_d.valid       := d_valid_reg
  tl_d.bits.opcode := d_opcode_reg
  tl_d.bits.size   := d_size_reg
  tl_d.bits.source := d_source_reg
  tl_d.bits.data   := d_data_reg
  tl_d.bits.error  := d_error_reg
  tl_d.bits.param  := 0.U
  tl_d.bits.sink   := 0.U
  tl_d.bits.user   := DontCare

  tl_a.ready := !d_valid_reg || tl_d.ready
}

import scala.annotation.nowarn
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation

@nowarn
object DmaCsrEmitter extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new DmaCsr(tlul_p))) ++
      Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
