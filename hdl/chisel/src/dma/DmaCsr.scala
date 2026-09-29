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
  val XFER_CFG  = 0x14
  val AREA_SIZE = 0x18
  val PASS_REM  = 0x1c
}

class DmaCsr(p: TLULParameters) extends Module {
  import DmaCsrAddrs._

  val N      = p.w
  val gMax   = DmaGeometry.gMax(p)
  val sWidth = DmaGeometry.sWidth(p)

  val tWidth = DmaGeometry.pWidth(p)

  val regWidth     = 32
  val regBytes     = regWidth / 8
  val lanesPerBeat = (8 * p.w) / regWidth

  val io = IO(new Bundle {
    val tl            = Flipped(new TLULHost2Device[NoUser, NoUser](p))
    val fillDesc      = Decoupled(new FillDescriptor(p))
    val drainDesc     = Decoupled(new DrainDescriptor(p))
    val fillBusy      = Input(Bool())
    val drainBusy     = Input(Bool())
    val engineError   = Input(Bool())
    val passRemaining = Input(UInt(DmaGeometry.pWidth(p).W)) // from fill, for PASS_REM
    val abort         = Output(Bool())                       // to both engines
    val busy          = Output(Bool())
    val error         = Output(Bool())
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
  val xferCfgReg  = RegInit(1.U(32.W))                  // n_areas = 1 (memcopy) out of reset
  val areaSizeReg = RegInit(0.U(DmaGeometry.lenBits.W)) // software-written; strided only

  val doneReg     = RegInit(false.B)
  val alignErrReg = RegInit(false.B)
  val cfgErrReg   = RegInit(false.B)
  val xferErrReg  = RegInit(false.B)
  val errorAny    = alignErrReg || cfgErrReg || xferErrReg

  val state   = RegInit(CsrState.sIdle)
  val idle    = state === CsrState.sIdle
  val running = state === CsrState.sRunning

  val ctrlWrite = hits(CTRL)
  val ctrlData  = wdata(CTRL)

  // Taken from the write data so one ENABLE|START store both arms and fires.
  // CTRL[2] is abort: reserved, not implemented. CTRL[3] clears the sticky errors.
  val enableEff  = Mux(ctrlWrite, ctrlData(0), enableReg)
  val startWrite = ctrlWrite && ctrlData(1)
  val clearErr   = ctrlWrite && ctrlData(3)

  // ==========================================
  // DERIVED GEOMETRY
  // ==========================================
  val lenFlags  = lenFlagsReg.asTypeOf(new DmaLenFlags)
  val len       = lenFlags.xfer_len
  val xferCfg   = xferCfgReg.asTypeOf(new XferCfg)
  val nAreas    = xferCfg.n_areas
  val xferWidth = lenFlags.xfer_width
  val strided   = nAreas > 1.U
  val fullMask  = Fill(N, 1.U)

  // Software supplies area_size for strided jobs; memcopy is one area of len bytes.
  val areaSize = Mux(strided, areaSizeReg, len)

  // Memcopy arm only.
  val totalBeats = ((len +& (N - 1).U) >> gMax).asUInt

  // Everything below derives from areaSize with shifts and compares.
  val tailBytes    = areaSize(gMax - 1, 0)
  val beatsPerArea = ((areaSize +& (N - 1).U) >> gMax).asUInt
  val lastMask     = Mux(
    tailBytes === 0.U,
    fullMask,
    ((1.U((N + 1).W) << tailBytes).asUInt - 1.U)(N - 1, 0)
  )

  // ==========================================
  // MODE TABLE — one whole descriptor per mode
  // ==========================================
  val fillMc = Wire(new FillDescriptor(p))
  fillMc.srcAddr       := srcAddrReg
  fillMc.stride        := N.U
  fillMc.passes        := (totalBeats +& (N - 1).U) >> gMax
  fillMc.lastPassBeats := (totalBeats - ((fillMc.passes - 1.U) << gMax))(sWidth - 1, 0)
  // Forced, not taken from software: a smaller xfer_width would transpose and scramble the copy.
  fillMc.logElemSize := gMax.U

  val fillSt = Wire(new FillDescriptor(p))
  fillSt.srcAddr       := srcAddrReg
  fillSt.stride        := nAreas(sWidth - 1, 0)
  fillSt.passes        := beatsPerArea
  fillSt.lastPassBeats := nAreas(sWidth - 1, 0)
  fillSt.logElemSize   := xferWidth

  // stride / passes / lastPassBeats are shared with fill; reuse, don't recompute.
  val drainMc = Wire(new DrainDescriptor(p))
  drainMc.dstAddr       := dstAddrReg
  drainMc.stride        := fillMc.stride
  drainMc.passes        := fillMc.passes
  drainMc.lastPassBeats := fillMc.lastPassBeats
  drainMc.rowPitch      := N.U
  drainMc.passAdvance   := (N * N).U
  drainMc.lastMask      := lastMask
  drainMc.maskAll       := false.B

  val drainSt = Wire(new DrainDescriptor(p))
  drainSt.dstAddr       := dstAddrReg
  drainSt.stride        := fillSt.stride
  drainSt.passes        := fillSt.passes
  drainSt.lastPassBeats := fillSt.lastPassBeats
  // Planes are padded to a whole number of beats so every plane starts N-aligned;
  // maskAll keeps the tail from writing into the gap before the next plane.
  drainSt.rowPitch    := beatsPerArea << gMax
  drainSt.passAdvance := N.U
  drainSt.lastMask    := lastMask
  drainSt.maskAll     := true.B

  val fillDesc  = Mux(strided, fillSt, fillMc)
  val drainDesc = Mux(strided, drainSt, drainMc)

  val alignError = (srcAddrReg(gMax - 1, 0) =/= 0.U) || (dstAddrReg(gMax - 1, 0) =/= 0.U)
  // No peripheral-FIFO modes; areas must be non-empty and fit the buffer.
  val cfgError = (xferWidth > gMax.U) ||
    lenFlags.src_fixed || lenFlags.dst_fixed || lenFlags.poll_en ||
    (len === 0.U) ||
    (nAreas === 0.U) || (nAreas > N.U) ||
    (strided && (areaSizeReg === 0.U))

  val startReq = startWrite && enableEff && idle
  // Accounts for a clear in the same CTRL write, like enableEff does for enable.
  val errorEff = Mux(clearErr, false.B, errorAny)
  val startOk  = startReq && !alignError && !cfgError && !errorEff

  // ==========================================
  // DESCRIPTOR ISSUE — one whole-job descriptor per engine
  // ==========================================
  // Each engine takes its descriptor once per job, whenever it is ready; the two
  // need not fire on the same cycle.
  val fillDescIssued  = RegInit(false.B)
  val drainDescIssued = RegInit(false.B)

  fillDescIssued  := Mux(startOk, false.B, Mux(io.fillDesc.fire, true.B, fillDescIssued))
  drainDescIssued := Mux(startOk, false.B, Mux(io.drainDesc.fire, true.B, drainDescIssued))

  io.fillDesc.valid  := running && !fillDescIssued
  io.drainDesc.valid := running && !drainDescIssued
  io.fillDesc.bits   := fillDesc
  io.drainDesc.bits  := drainDesc

  // ==========================================
  // SEQUENCER
  // ==========================================
  // Issued flags set the cycle after fire, the same cycle engine busy rises.
  val allDone = running && fillDescIssued && drainDescIssued &&
    !io.fillBusy && !io.drainBusy

  state := MuxCase(
    state,
    Seq(
      (idle && startOk) -> CsrState.sRunning,
      allDone           -> CsrState.sIdle
    )
  )

  enableReg := Mux(ctrlWrite, ctrlData(0), enableReg)

  // Config is frozen while running: the descriptors read these registers
  // directly, and an engine may take its descriptor several cycles after start.
  srcAddrReg  := Mux(hits(SRC_ADDR) && idle, wdata(SRC_ADDR), srcAddrReg)
  dstAddrReg  := Mux(hits(DST_ADDR) && idle, wdata(DST_ADDR), dstAddrReg)
  lenFlagsReg := Mux(hits(LEN_FLAGS) && idle, wdata(LEN_FLAGS), lenFlagsReg)
  xferCfgReg  := Mux(hits(XFER_CFG) && idle, wdata(XFER_CFG), xferCfgReg)
  areaSizeReg := Mux(
    hits(AREA_SIZE) && idle,
    wdata(AREA_SIZE)(DmaGeometry.lenBits - 1, 0),
    areaSizeReg
  )

  // Errors are sticky: only an explicit CTRL.clear_error write clears them.
  // Done sets only on a clean finish, so an abort reads busy=0, done=0, error=1.
  doneReg     := Mux(startReq, false.B, Mux(allDone && !errorAny, true.B, doneReg))
  alignErrReg := Mux(startReq && alignError, true.B, Mux(clearErr, false.B, alignErrReg))
  cfgErrReg   := Mux(startReq && cfgError, true.B, Mux(clearErr, false.B, cfgErrReg))
  xferErrReg  := Mux(clearErr, false.B, Mux(io.engineError, true.B, xferErrReg))

  io.busy  := running
  io.error := errorAny
  // Only bus errors abort; align/config errors stop the start, so nothing is running.
  io.abort := xferErrReg

  assert(!startOk || (totalBeats =/= 0.U), "Start with zero beats")
  assert(!io.fillDesc.fire || running, "Fill descriptor issued outside a transfer")
  assert(!io.drainDesc.fire || running, "Drain descriptor issued outside a transfer")

  // Geometry checks guard on fire: that is when the engine actually takes the
  // descriptor, and config is frozen from start until then.
  assert(!io.fillDesc.fire || (fillDesc.passes =/= 0.U), "Zero passes")
  assert(
    !io.fillDesc.fire || ((fillDesc.stride =/= 0.U) && (fillDesc.stride <= N.U)),
    "stride must be in 1..N"
  )
  assert(
    !io.fillDesc.fire || ((fillDesc.lastPassBeats =/= 0.U) &&
      (fillDesc.lastPassBeats <= fillDesc.stride)),
    "lastPassBeats must be in 1..stride"
  )

  // ==========================================
  // READ PATH
  // ==========================================
  val ctrlVal   = Cat(0.U((regWidth - 1).W), enableReg)
  val statusVal = Cat(
    0.U((regWidth - 6).W),
    xferErrReg,
    cfgErrReg,
    alignErrReg,
    errorAny,
    doneReg,
    running
  )

  val readMap = Map(
    CTRL      -> ctrlVal,
    STATUS    -> statusVal,
    SRC_ADDR  -> srcAddrReg,
    DST_ADDR  -> dstAddrReg,
    LEN_FLAGS -> lenFlagsReg,
    XFER_CFG  -> xferCfgReg,
    AREA_SIZE -> areaSizeReg.pad(regWidth),
    PASS_REM  -> io.passRemaining.pad(regWidth)
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
