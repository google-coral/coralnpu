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

class DmaDrainEngine(p: TLULParameters) extends Module {
  val N = p.w

  val io = IO(new Bundle {
    val descriptor = Flipped(Decoupled(new DrainDescriptor(p)))
    val tl         = new TLULHost2Device[NoUser, NoUser](p)
    val beat       = Flipped(Decoupled(Vec(N, UInt(8.W))))
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

  val lastPass      = status.passRemaining === 1.U
  val beatsThisPass = Mux(lastPass, active.bits.lastPassBeats, active.bits.stride)
  val moreToIssue   = status.issued < beatsThisPass
  val allAcked      = status.received === beatsThisPass
  val passEnd       = active.valid && allAcked

  val loaded = Wire(Valid(new DrainDescriptor(p)))
  loaded.valid := true.B
  loaded.bits  := io.descriptor.bits

  val cleared = Wire(Valid(new DrainDescriptor(p)))
  cleared.valid := false.B
  cleared.bits  := active.bits

  // Three ways a job ends:
  // 1. Normal completion : passEnd && lastPass : jobEnd
  // 2. Abort arrived mid pass, drain finishes the pass it is on and then stops: passEnd && io.abort
  // 3. Aborted while drain was between passes with an empty buffer: abortIdle
  val jobEnd    = passEnd && lastPass
  val abortIdle = io.abort && active.valid && (status.issued === 0.U) && io.bufIdle
  val clearNow  = jobEnd || (passEnd && io.abort) || abortIdle

  active := Mux(
    io.descriptor.fire,
    loaded,
    Mux(clearNow, cleared, active)
  )

  val jobStart = Wire(new DrainStatus(p))
  jobStart.issued        := 0.U
  jobStart.received      := 0.U
  jobStart.errSticky     := false.B
  jobStart.passRemaining := io.descriptor.bits.passes
  jobStart.passBase      := io.descriptor.bits.dstAddr
  jobStart.addr          := io.descriptor.bits.dstAddr

  val nextPass = Wire(new DrainStatus(p))
  nextPass.issued        := 0.U
  nextPass.received      := 0.U
  nextPass.errSticky     := status.errSticky
  nextPass.passRemaining := status.passRemaining - 1.U
  nextPass.passBase      := status.passBase + active.bits.passAdvance
  nextPass.addr          := status.passBase + active.bits.passAdvance

  val advanced = Wire(new DrainStatus(p))
  advanced.issued        := Mux(io.tl.a.fire, status.issued + 1.U, status.issued)
  advanced.received      := Mux(io.tl.d.fire, status.received + 1.U, status.received)
  advanced.errSticky     := status.errSticky || (io.tl.d.fire && io.tl.d.bits.error)
  advanced.passRemaining := status.passRemaining
  advanced.passBase      := status.passBase
  advanced.addr          := Mux(io.tl.a.fire, status.addr + active.bits.rowPitch, status.addr)

  status := Mux(io.descriptor.fire, jobStart, Mux(passEnd, nextPass, advanced))

  assert(
    !io.descriptor.fire || ((io.descriptor.bits.stride =/= 0.U) && (io.descriptor.bits.stride <= N.U)),
    "Stride must be non-zero and less than or equal to N"
  )
  assert(
    !io.descriptor.fire || (io.descriptor.bits.dstAddr(p.z - 1, 0) === 0.U),
    s"dstAddr must be aligned to $N bytes"
  )
  assert(!io.tl.d.fire || active.valid, "Ack outside a drain")
  assert(
    !io.tl.d.fire || (io.tl.d.bits.opcode === TLULOpcodesD.AccessAck.asUInt),
    "Drain expects AccessAck, not AccessAckData"
  )
  assert(status.received <= status.issued, "More acks than Puts issued")
  assert(!io.beat.fire || active.valid, "Beat consumed outside a drain")

  assert(
    !io.descriptor.fire || (io.descriptor.bits.passes =/= 0.U),
    "passes must be non-zero"
  )
  assert(
    !io.descriptor.fire || ((io.descriptor.bits.lastPassBeats =/= 0.U) &&
      (io.descriptor.bits.lastPassBeats <= io.descriptor.bits.stride)),
    "lastPassBeats must be in 1..stride"
  )
  // A zero rowPitch makes every beat of a pass overwrite the same address.
  assert(
    !io.descriptor.fire || ((io.descriptor.bits.rowPitch =/= 0.U) &&
      (io.descriptor.bits.rowPitch(p.z - 1, 0) === 0.U)),
    "rowPitch must be non-zero and N-aligned"
  )
  assert(
    !io.descriptor.fire || ((io.descriptor.bits.passAdvance =/= 0.U) &&
      (io.descriptor.bits.passAdvance(p.z - 1, 0) === 0.U)),
    "passAdvance must be non-zero and N-aligned"
  )

  io.descriptor.ready := !active.valid
  io.busy             := active.valid

  // ==========================================
  // A-CHANNEL — PUT ISSUE
  // ==========================================
  val canIssue = active.valid && moreToIssue
  val lastBeat = status.issued === beatsThisPass - 1.U
  val useMask  = lastPass && (active.bits.maskAll || lastBeat)

  io.tl.a.valid       := canIssue && io.beat.valid
  io.beat.ready       := canIssue && io.tl.a.ready
  io.tl.a.bits.opcode := Mux(
    useMask && !active.bits.lastMask.andR,
    TLULOpcodesA.PutPartialData,
    TLULOpcodesA.PutFullData
  ).asUInt
  io.tl.a.bits.param   := 0.U
  io.tl.a.bits.size    := p.z.U
  io.tl.a.bits.source  := status.issued
  io.tl.a.bits.address := status.addr
  io.tl.a.bits.mask    := Mux(useMask, active.bits.lastMask, Fill(N, 1.U))
  io.tl.a.bits.data    := io.beat.bits.asUInt

  // ==========================================
  // D-CHANNEL — ACK TRACKING
  // ==========================================
  io.tl.d.ready := true.B
  io.error      := status.errSticky
}
