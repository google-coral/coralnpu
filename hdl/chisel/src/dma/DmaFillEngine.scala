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

class DmaFillEngine(p: TLULParameters) extends Module {
  val N      = p.w
  val eMax   = DmaGeometry.eMax(p)
  val eWidth = DmaGeometry.eWidth(p)
  val sWidth = DmaGeometry.sWidth(p)

  val io = IO(new Bundle {
    val descriptor = Flipped(Decoupled(new FillDescriptor(p)))
    val drainDesc  = Decoupled(new DrainDescriptor(p))
    val tl         = new TLULHost2Device[NoUser, NoUser](p)
    val cfg        = Decoupled(new Bundle { // -> io.cfg
      val stride      = UInt(sWidth.W)
      val logElemSize = UInt(eWidth.W)
    })
    val beat = Decoupled(new Bundle {
      val row  = UInt(sWidth.W)
      val data = Vec(N, UInt(8.W))
    }) // -> io.in
    val busy  = Output(Bool())
    val error = Output(Bool())
  })

// ==========================================
// DESCRIPTOR CAPTURE & STATE
// ==========================================
  val active = RegInit(0.U.asTypeOf(Valid(new FillDescriptor(p))))
  val status = RegInit(0.U.asTypeOf(new FillStatus(p)))

  val idle    = !active.valid
  val config  = active.valid && !status.cfgDone
  val issuing = active.valid && status.cfgDone

  val moreToIssue = status.issued < active.bits.stride // stride = buffer depth for memcopy
  val allReceived = status.received === active.bits.stride

  val loaded = Wire(Valid(new FillDescriptor(p)))
  loaded.valid := true.B
  loaded.bits  := io.descriptor.bits

  val cleared = Wire(Valid(new FillDescriptor(p)))
  cleared.valid := false.B
  cleared.bits  := active.bits

  active := Mux(
    io.descriptor.fire,
    loaded,
    Mux(io.drainDesc.fire, cleared, active)
  )

  val advanced = Wire(new FillStatus(p))
  advanced.cfgDone   := status.cfgDone || io.cfg.fire
  advanced.issued    := Mux(io.tl.a.fire, status.issued + 1.U, status.issued)
  advanced.received  := Mux(io.tl.d.fire, status.received + 1.U, status.received)
  advanced.errSticky := status.errSticky || (io.tl.d.fire && io.tl.d.bits.error)

  status := Mux(io.descriptor.fire, 0.U.asTypeOf(new FillStatus(p)), advanced)

  assert(
    !io.descriptor.fire || ((io.descriptor.bits.stride =/= 0.U) && (io.descriptor.bits.stride <= N.U)),
    "Stride must be non-zero and less than or equal to N"
  )
  assert(
    !io.descriptor.fire || (io.descriptor.bits.logElemSize <= eMax.U),
    s"logElemSize must be less than or equal to $eMax"
  )
  assert(
    !io.descriptor.fire || (io.descriptor.bits.srcAddr(p.z - 1, 0) === 0.U),
    s"srcAddr must be aligned to $N bytes"
  )
  assert(!io.tl.d.fire || issuing, "Response outside a fill")
  assert(!io.drainDesc.fire || allReceived, "Handoff before fill complete")

  io.descriptor.ready     := idle && io.cfg.ready
  io.busy                 := active.valid
  io.cfg.valid            := config
  io.cfg.bits.stride      := active.bits.stride
  io.cfg.bits.logElemSize := active.bits.logElemSize

  // drain Handoff
  io.drainDesc.valid         := allReceived && issuing
  io.drainDesc.bits.dstAddr  := active.bits.dstAddr
  io.drainDesc.bits.stride   := active.bits.stride
  io.drainDesc.bits.lastMask := active.bits.lastMask

// ==========================================
// A-CHANNEL — GET ISSUE
// ==========================================
  io.tl.a.valid        := issuing && moreToIssue
  io.tl.a.bits.opcode  := TLULOpcodesA.Get.asUInt
  io.tl.a.bits.param   := 0.U
  io.tl.a.bits.size    := p.z.U
  io.tl.a.bits.source  := status.issued
  io.tl.a.bits.address := active.bits.srcAddr + (status.issued << p.z)
  io.tl.a.bits.mask    := Fill(N, 1.U)
  io.tl.a.bits.data    := DontCare

// ==========================================
// D-CHANNEL — RESPONSE TO BUFFER
// ==========================================
  io.beat.valid     := io.tl.d.valid && issuing
  io.tl.d.ready     := io.beat.ready
  io.error          := status.errSticky
  io.beat.bits.row  := io.tl.d.bits.source(sWidth - 1, 0)
  io.beat.bits.data := io.tl.d.bits.data.asTypeOf(Vec(N, UInt(8.W)))
}
