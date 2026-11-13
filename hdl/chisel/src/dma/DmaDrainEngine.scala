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

class DmaDrainEngine(p: TLULParameters) extends Module {
  val N = p.w

  val io = IO(new Bundle {
    val descriptor = Flipped(Decoupled(new DrainDescriptor(p)))
    val tl         = new TLULHost2Device[NoUser, NoUser](p)
    val beat       = Flipped(Decoupled(Vec(N, UInt(8.W))))
    val bypassBeat = Flipped(Decoupled(Vec(N, UInt(8.W))))
    val abort      = Input(Bool())
    // bufIdle distinguishes between "buffer in between passes" and "fill has aborted passes"
    val bufIdle = Input(Bool())
    val busy    = Output(Bool())
    val error   = Output(Bool())
  })

  // ==========================================
  // DESCRIPTOR CAPTURE & STATE
  // ==========================================
  val active = RegInit(0.U.asTypeOf(Valid(new DrainDescriptor(p))))
  val status = RegInit(0.U.asTypeOf(new DrainStatus(p)))

  val bypass        = active.bits.bypass
  val lastPass      = status.passRemaining === 1.U
  val beatsThisPass = Mux(lastPass, active.bits.lastPassBeats, active.bits.stride)
  val moreToIssue   = status.issued < beatsThisPass
  val allAcked      = status.received === beatsThisPass
  val passEnd       = active.valid && !bypass && allAcked

  // Bypass: on a bus error stop issuing, then wait for every outstanding ack, not for more data.
  val bpStop      = io.abort || status.errSticky
  val bpMoreBeats = status.beats < active.bits.totalBeats
  val bpCanIssue  =
    active.valid && bypass && bpMoreBeats && !bpStop &&
      (status.outstanding < DmaGeometry.bypassDepth.U)
  val bpJobEnd  = active.valid && bypass && (status.outstanding === 0.U) && (!bpMoreBeats || bpStop)
  val bpPutFire = io.tl.a.fire && bypass
  val bpAckFire = io.tl.d.fire && bypass

  val loaded  = MakeValid(io.descriptor.bits)
  val cleared = MakeValid(false.B, active.bits)

  // Four ways a job ends:
  // 1. Normal completion : passEnd && lastPass : jobEnd
  // 2. Abort arrived mid pass, drain finishes the pass it is on and then stops: passEnd && io.abort
  // 3. Aborted while drain was between passes with an empty buffer: abortIdle
  // 4. Bypass: no Put outstanding, and all beats issued or a bus error: bpJobEnd
  val jobEnd    = passEnd && lastPass
  val abortIdle = io.abort && active.valid && !bypass && (status.issued === 0.U) && io.bufIdle
  val clearNow  = jobEnd || (passEnd && io.abort) || abortIdle || bpJobEnd

  active := MuxUpTo1H(
    active,
    Seq(
      io.descriptor.fire -> loaded, // new job
      clearNow           -> cleared // job ended
    )
  )

  val jobStart = Wire(new DrainStatus(p))
  jobStart.issued        := 0.U
  jobStart.received      := 0.U
  jobStart.errSticky     := false.B
  jobStart.passRemaining := io.descriptor.bits.passes
  jobStart.passBase      := io.descriptor.bits.dstAddr
  jobStart.addr          := io.descriptor.bits.dstAddr
  jobStart.beats         := 0.U
  jobStart.outstanding   := 0.U

  val nextPass = Wire(new DrainStatus(p))
  nextPass.issued        := 0.U
  nextPass.received      := 0.U
  nextPass.errSticky     := status.errSticky
  nextPass.passRemaining := status.passRemaining - 1.U
  nextPass.passBase      := status.passBase + active.bits.passAdvance
  nextPass.addr          := status.passBase + active.bits.passAdvance
  nextPass.beats         := 0.U
  nextPass.outstanding   := 0.U

  val advanced = Wire(new DrainStatus(p))
  advanced.issued        := Mux(io.tl.a.fire && !bypass, status.issued + 1.U, status.issued)
  advanced.received      := Mux(io.tl.d.fire && !bypass, status.received + 1.U, status.received)
  advanced.errSticky     := status.errSticky || (io.tl.d.fire && io.tl.d.bits.error)
  advanced.passRemaining := status.passRemaining
  advanced.passBase      := status.passBase
  advanced.addr          := Mux(io.tl.a.fire, status.addr + active.bits.rowPitch, status.addr)
  advanced.beats         := Mux(bpPutFire, status.beats + 1.U, status.beats)
  advanced.outstanding   := status.outstanding + bpPutFire.asUInt - bpAckFire.asUInt

  status := MuxUpTo1H(
    advanced,
    Seq(
      io.descriptor.fire -> jobStart, // new job
      passEnd            -> nextPass  // pass boundary
    )
  )

  val d = io.descriptor.bits
  DmaChecks.passGeometry(p, io.descriptor.fire && !d.bypass, d.stride, d.passes, d.lastPassBeats)
  DmaChecks.aligned(p, io.descriptor.fire, d.dstAddr, "dstAddr")
  assert(!io.tl.d.fire || active.valid, "Ack outside a drain")
  assert(
    !io.tl.d.fire || (io.tl.d.bits.opcode === TLULOpcodesD.AccessAck.asUInt),
    "Drain expects AccessAck, not AccessAckData"
  )
  assert(status.received <= status.issued, "More acks than Puts issued")
  assert(!bpAckFire || (status.outstanding =/= 0.U), "Bypass ack with no Put outstanding")
  assert(!io.beat.fire || active.valid, "Beat consumed outside a drain")
  assert(!io.descriptor.fire || !d.bypass || (d.totalBeats =/= 0.U), "Bypass job with zero beats")

  // A zero rowPitch makes every beat of a pass overwrite the same address.
  assert(
    !io.descriptor.fire || ((d.rowPitch =/= 0.U) && (d.rowPitch(p.z - 1, 0) === 0.U)),
    "rowPitch must be non-zero and N-aligned"
  )
  assert(
    !io.descriptor.fire || d.bypass || ((d.passAdvance =/= 0.U) && (d
      .passAdvance(p.z - 1, 0) === 0.U)),
    "passAdvance must be non-zero and N-aligned"
  )

  io.descriptor.ready := !active.valid
  io.busy             := active.valid

  // ==========================================
  // A-CHANNEL — PUT ISSUE
  // ==========================================
  val canIssue = active.valid && moreToIssue && !bypass
  val lastBeat = status.issued === beatsThisPass - 1.U
  val useMask  = lastPass && (active.bits.maskAll || lastBeat)
  val bpLast   = status.beats === active.bits.totalBeats - 1.U
  val putMask  = Mux(
    bypass,
    Mux(bpLast, active.bits.lastMask, Fill(N, 1.U)),
    Mux(useMask, active.bits.lastMask, Fill(N, 1.U))
  )

  io.tl.a.valid := Mux(bypass, bpCanIssue && io.bypassBeat.valid, canIssue && io.beat.valid)
  io.beat.ready := canIssue && io.tl.a.ready
  // The Put pops the buffer head in the same cycle it is accepted.
  io.bypassBeat.ready := bpCanIssue && io.tl.a.ready
  io.tl.a.bits.opcode := Mux(
    putMask.andR,
    TLULOpcodesA.PutFullData,
    TLULOpcodesA.PutPartialData
  ).asUInt
  io.tl.a.bits.param := 0.U
  io.tl.a.bits.size  := p.z.U
  // Bypass Puts carry drain's own issue count mod 16, not the buffer slot tag.
  io.tl.a.bits.source := Mux(
    bypass,
    status.beats(DmaGeometry.bypassTagWidth - 1, 0),
    status.issued
  )
  io.tl.a.bits.address := status.addr
  io.tl.a.bits.mask    := putMask
  io.tl.a.bits.data    := Mux(bypass, io.bypassBeat.bits, io.beat.bits).asUInt

  // ==========================================
  // D-CHANNEL — ACK TRACKING
  // ==========================================
  io.tl.d.ready := true.B
  // Only while a job runs: DmaCsr latches it, and a stale error must not re-latch after CLEAR_ERROR.
  io.error := active.valid && status.errSticky
}
