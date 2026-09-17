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
    val busy       = Output(Bool())
    val error      = Output(Bool())
  })

  // ==========================================
  // DESCRIPTOR CAPTURE & STATE
  // ==========================================
  val active = RegInit(0.U.asTypeOf(Valid(new DrainDescriptor(p))))
  val status = RegInit(0.U.asTypeOf(new DrainStatus(p)))

  val moreToIssue = status.issued < active.bits.stride
  val allAcked    = status.received === active.bits.stride

  val loaded = Wire(Valid(new DrainDescriptor(p)))
  loaded.valid := true.B
  loaded.bits  := io.descriptor.bits

  val cleared = Wire(Valid(new DrainDescriptor(p)))
  cleared.valid := false.B
  cleared.bits  := active.bits

  active := Mux(
    io.descriptor.fire,
    loaded,
    Mux(active.valid && allAcked, cleared, active)
  )

  val advanced = Wire(new DrainStatus(p))
  advanced.issued    := Mux(io.tl.a.fire, status.issued + 1.U, status.issued)
  advanced.received  := Mux(io.tl.d.fire, status.received + 1.U, status.received)
  advanced.errSticky := status.errSticky || (io.tl.d.fire && io.tl.d.bits.error)

  status := Mux(io.descriptor.fire, 0.U.asTypeOf(new DrainStatus(p)), advanced)

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

  io.descriptor.ready := !active.valid
  io.busy             := active.valid

  // ==========================================
  // A-CHANNEL — PUT ISSUE
  // ==========================================
  val canIssue = active.valid && moreToIssue
  val lastBeat = status.issued === active.bits.stride - 1.U

  io.tl.a.valid       := canIssue && io.beat.valid
  io.beat.ready       := canIssue && io.tl.a.ready
  io.tl.a.bits.opcode := Mux(
    lastBeat && !active.bits.lastMask.andR,
    TLULOpcodesA.PutPartialData,
    TLULOpcodesA.PutFullData
  ).asUInt
  io.tl.a.bits.param   := 0.U
  io.tl.a.bits.size    := p.z.U
  io.tl.a.bits.source  := status.issued
  io.tl.a.bits.address := active.bits.dstAddr + (status.issued << p.z)
  io.tl.a.bits.mask    := Mux(lastBeat, active.bits.lastMask, Fill(N, 1.U))
  io.tl.a.bits.data    := io.beat.bits.asUInt

  // ==========================================
  // D-CHANNEL — ACK TRACKING
  // ==========================================
  io.tl.d.ready := true.B
  io.error      := status.errSticky
}
