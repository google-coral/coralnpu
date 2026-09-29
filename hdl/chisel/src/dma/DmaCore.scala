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

class DmaCore(p: TLULParameters) extends Module {
  val M     = 2           // fill, drain
  val StIdW = log2Ceil(M) // = 1
  val p_d   = p.augmentId(StIdW)

  val io = IO(new Bundle {
    val tl_device = Flipped(new TLULHost2Device[NoUser, NoUser](p))
    val tl_host   = new TLULHost2Device[NoUser, NoUser](p_d)
    val busy      = Output(Bool())
    val error     = Output(Bool())
  })

  val buffer = Module(new TransposeBuffer(p))
  val fill   = Module(new DmaFillEngine(p))
  val drain  = Module(new DmaDrainEngine(p))
  val csr    = Module(new DmaCsr(p))
  val arb    = Module(new TlulArbiter(p, M))

  // The engines no longer talk to each other. They stay in lockstep purely
  // through the buffer: cfg.ready stops fill from starting a pass before drain
  // has emptied the previous one, and out.valid stops drain from starting
  // before fill has finished one.
  csr.io.tl <> io.tl_device
  csr.io.fillDesc <> fill.io.descriptor
  csr.io.drainDesc <> drain.io.descriptor
  fill.io.cfg <> buffer.io.cfg
  fill.io.beat <> buffer.io.in
  buffer.io.out <> drain.io.beat

  arb.io.tl_h(0) <> fill.io.tl
  arb.io.tl_h(1) <> drain.io.tl
  io.tl_host <> arb.io.tl_d

  csr.io.fillBusy      := fill.io.busy
  csr.io.drainBusy     := drain.io.busy
  csr.io.engineError   := fill.io.error || drain.io.error
  csr.io.passRemaining := fill.io.passRemaining

  fill.io.abort    := csr.io.abort
  drain.io.abort   := csr.io.abort
  drain.io.bufIdle := buffer.io.drainDone

  io.busy  := csr.io.busy
  io.error := csr.io.error || fill.io.error || drain.io.error

  // fillDone is unused — the engines count passes themselves. drainDone feeds
  // drain's bufIdle so an abort between passes can tell an empty buffer from
  // one about to be filled.
  buffer.io.fillDone := DontCare

  // Index is arbitrary while one buffer serialises fill and drain; it becomes a
  // real decision at ping-pong.
}

import scala.annotation.nowarn
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation

@nowarn
object DmaCoreEmitter extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new DmaCore(tlul_p))) ++
      Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
