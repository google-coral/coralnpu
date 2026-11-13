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
import common._

import chisel3._
import chisel3.util._

class DmaFillEngine(p: TLULParameters) extends Module {
  val N      = p.w
  val eMax   = DmaGeometry.eMax(p)
  val eWidth = DmaGeometry.eWidth(p)
  val sWidth = DmaGeometry.sWidth(p)
  val pWidth = DmaGeometry.pWidth(p)
  val tagW   = DmaGeometry.bypassTagWidth

  val io = IO(new Bundle {
    val descriptor = Flipped(Decoupled(new FillDescriptor(p)))
    val tl         = new TLULHost2Device[NoUser, NoUser](p)
    val cfg        = Decoupled(new Bundle { // -> io.cfg
      val stride      = UInt(sWidth.W)
      val logElemSize = UInt(eWidth.W)
    })
    val beat = Decoupled(new Bundle {
      val row  = UInt(sWidth.W)
      val data = Vec(N, UInt(8.W))
    }) // -> io.in
    val bypassAlloc   = Flipped(Decoupled(UInt(tagW.W)))
    val bypassWrite   = Valid(new BypassWrite(Vec(N, UInt(8.W)), tagW))
    val passRemaining = Output(UInt(pWidth.W))
    val abort         = Input(Bool())
    val busy          = Output(Bool())
    val error         = Output(Bool())
  })

// ==========================================
// DESCRIPTOR CAPTURE & STATE
// ==========================================
  val active = RegInit(0.U.asTypeOf(Valid(new FillDescriptor(p))))
  val status = RegInit(0.U.asTypeOf(new FillStatus(p)))

  val idle    = !active.valid
  val config  = active.valid && !status.cfgDone
  val issuing = active.valid && status.cfgDone
  val bypass  = active.bits.bypass

  val lastPass      = status.passRemaining === 1.U
  val beatsThisPass = Mux(lastPass, active.bits.lastPassBeats, active.bits.stride)

  val moreToIssue = status.issued < beatsThisPass
  val allReceived = status.received === beatsThisPass
  val passEnd     = issuing && !bypass && allReceived

  // Bypass: on a bus error stop issuing, then wait for every outstanding Get.
  val bpStop      = io.abort || status.errSticky
  val bpMoreBeats = status.beats < active.bits.totalBeats
  val bpCanIssue  = issuing && bypass && bpMoreBeats && !bpStop
  val bpJobEnd    = issuing && bypass && (status.outstanding === 0.U) && (!bpMoreBeats || bpStop)
  val bpGetFire   = io.tl.a.fire && bypass
  val bpRespFire  = io.tl.d.fire && bypass

  val loaded  = MakeValid(io.descriptor.bits)
  val cleared = MakeValid(false.B, active.bits)

  // Four ways a job ends:
  // 1. Normal completion : passEnd && lastPass : jobEnd
  // 2. Abort arrived mid pass, fill finishes the pass it is fetching and then stops: passEnd && io.abort
  // 3. Aborted while fill was in config state: abortConfig
  // 4. Bypass: no Get outstanding, and all beats issued or a bus error: bpJobEnd
  val jobEnd      = passEnd && lastPass
  val abortConfig = config && io.abort
  val clearNow    = jobEnd || (passEnd && io.abort) || abortConfig || bpJobEnd

  active := MuxUpTo1H(
    active,
    Seq(
      io.descriptor.fire -> loaded, // new job
      clearNow           -> cleared // job ended
    )
  )

  val jobStart = Wire(new FillStatus(p))
  jobStart.cfgDone   := io.descriptor.bits.bypass // bypass never configures the transpose buffer
  jobStart.issued    := 0.U
  jobStart.received  := 0.U
  jobStart.errSticky := false.B
  jobStart.passRemaining := Mux(io.descriptor.bits.bypass, 0.U, io.descriptor.bits.passes)
  jobStart.srcBase       := io.descriptor.bits.srcAddr
  jobStart.beats         := 0.U
  jobStart.outstanding   := 0.U

  val nextPass = Wire(new FillStatus(p))
  nextPass.cfgDone       := false.B
  nextPass.issued        := 0.U
  nextPass.received      := 0.U
  nextPass.errSticky     := status.errSticky
  nextPass.passRemaining := status.passRemaining - 1.U
  nextPass.srcBase       := status.srcBase + (active.bits.stride << p.z)
  nextPass.beats         := 0.U
  nextPass.outstanding   := 0.U

  val advanced = Wire(new FillStatus(p))
  advanced.cfgDone       := status.cfgDone || io.cfg.fire
  advanced.issued        := Mux(io.tl.a.fire && !bypass, status.issued + 1.U, status.issued)
  advanced.received      := Mux(io.tl.d.fire && !bypass, status.received + 1.U, status.received)
  advanced.errSticky     := status.errSticky || (io.tl.d.fire && io.tl.d.bits.error)
  advanced.passRemaining := status.passRemaining
  advanced.srcBase       := status.srcBase
  advanced.beats         := Mux(bpGetFire, status.beats + 1.U, status.beats)
  advanced.outstanding   := status.outstanding + bpGetFire.asUInt - bpRespFire.asUInt

  status := MuxUpTo1H(
    advanced,
    Seq(
      io.descriptor.fire -> jobStart, // new job
      passEnd            -> nextPass  // pass boundary
    )
  )

  val d = io.descriptor.bits
  DmaChecks.passGeometry(p, io.descriptor.fire && !d.bypass, d.stride, d.passes, d.lastPassBeats)
  DmaChecks.aligned(p, io.descriptor.fire, d.srcAddr, "srcAddr")
  assert(
    !io.descriptor.fire || (d.logElemSize <= eMax.U),
    s"logElemSize must be less than or equal to $eMax"
  )
  assert(!io.descriptor.fire || !d.bypass || (d.totalBeats =/= 0.U), "Bypass job with zero beats")
  assert(!io.tl.d.fire || issuing, "Response outside a fill")
  assert(!bpRespFire || (status.outstanding =/= 0.U), "Bypass response with no Get outstanding")

  // A bypass job never uses the transpose buffer, so it does not wait for its cfg port.
  io.descriptor.ready     := idle && (io.descriptor.bits.bypass || io.cfg.ready)
  io.busy                 := active.valid
  io.cfg.valid            := config
  io.cfg.bits.stride      := beatsThisPass
  io.cfg.bits.logElemSize := active.bits.logElemSize
  io.passRemaining        := status.passRemaining

// ==========================================
// A-CHANNEL — GET ISSUE
// ==========================================
  io.tl.a.valid       := Mux(bypass, bpCanIssue && io.bypassAlloc.valid, issuing && moreToIssue)
  io.tl.a.bits.opcode := TLULOpcodesA.Get.asUInt
  io.tl.a.bits.param  := 0.U
  io.tl.a.bits.size   := p.z.U
  // Bypass tags each Get with its buffer slot, so the response lands in that slot.
  io.tl.a.bits.source := Mux(bypass, io.bypassAlloc.bits, status.issued)
  // The last pass always fetches a full stride × N bytes even when less is real.
  // Software must allocate the source rounded up to the next multiple of
  // n_areas × N; the padding need only be readable, not initialised, since the
  // drain masks it off.
  io.tl.a.bits.address := Mux(
    bypass,
    active.bits.srcAddr + (status.beats << p.z),
    status.srcBase + (status.issued << p.z)
  )
  io.tl.a.bits.mask := Fill(N, 1.U)
  io.tl.a.bits.data := DontCare

  // The slot is taken in the same cycle the Get is accepted.
  io.bypassAlloc.ready := bpGetFire

// ==========================================
// D-CHANNEL — RESPONSE TO BUFFER
// ==========================================
  io.beat.valid := io.tl.d.valid && issuing && !bypass
  // Every bypass Get owns a slot, so its response can always be taken.
  io.tl.d.ready := Mux(bypass, true.B, io.beat.ready)
  // Only while a job runs: DmaCsr latches it, and a stale error must not re-latch after CLEAR_ERROR.
  io.error          := active.valid && status.errSticky
  io.beat.bits.row  := io.tl.d.bits.source(sWidth - 1, 0)
  io.beat.bits.data := io.tl.d.bits.data.asTypeOf(Vec(N, UInt(8.W)))

  io.bypassWrite.valid     := bpRespFire
  io.bypassWrite.bits.tag  := io.tl.d.bits.source(tagW - 1, 0)
  io.bypassWrite.bits.data := io.tl.d.bits.data.asTypeOf(Vec(N, UInt(8.W)))
}
